//! Win32 file system layer of the rules engine (MC-A). Mirrors what the C# code got from .NET:
//! DirectoryInfo.Enumerate* with EnumerationOptions (MatchType.Win32, IgnoreInaccessible, AttributesToSkip,
//! RecurseSubdirectories), FileSystemName.MatchesWin32Expression, FileInfo/File/Directory basics.
//! Strings are UTF-8 (WTF-8) in and out; Win32 gets WTF-16 from fixed stack buffers.
const std = @import("std");
const kit = @import("kit");
const common = @import("common.zig");

const w = kit.w;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const attr_readonly: u32 = 0x1;
pub const attr_hidden: u32 = 0x2;
pub const attr_system: u32 = 0x4;
pub const attr_directory: u32 = 0x10;
pub const attr_reparse: u32 = 0x400;

/// Longest Win32 path in UTF-16 units (+ room for "\*" and NUL).
const max_w = 32768;

pub const Entry = struct {
    path: []const u8,
    attrs: u32,
    size: u64,
    /// LastWriteTimeUtc.
    mtime: Io.Timestamp,

    pub fn isDir(e: Entry) bool {
        return e.attrs & attr_directory != 0;
    }

    pub fn info(e: Entry) common.FileInfo {
        return .{ .path = e.path, .size = e.size, .mtime = e.mtime };
    }
};

pub const ListOptions = struct {
    files: bool = true,
    dirs: bool = false,
    recurse: bool = false,
    /// EnumerationOptions.AttributesToSkip: such entries are neither returned nor entered.
    skip: u32 = attr_reparse,
    cancel: ?*const common.Cancel = null,
};

/// DirectoryInfo.Enumerate{Files,Directories,FileSystemInfos}(pattern, options) with MatchType.Win32
/// (the pattern is translated first, so "*.*" also matches names without a dot). Missing or inaccessible
/// folders yield nothing (IgnoreInaccessible). Never recurses into a reparse point (junction/symlink),
/// whatever `skip` says. Paths are allocated in `arena`.
pub fn list(arena: Allocator, dir: []const u8, pattern: []const u8, o: ListOptions) ![]Entry {
    const pat = try translate(arena, pattern);
    var out: std.ArrayList(Entry) = .empty;
    var todo: std.ArrayList([]const u8) = .empty;
    try todo.append(arena, dir);
    var qbuf: [max_w]u16 = undefined;
    var fd: w.WIN32_FIND_DATAW = undefined;
    while (todo.pop()) |d| {
        const q = toW(&qbuf, d, if (endsWithSep(d)) "*" else "\\*") orelse continue;
        const h = w.FindFirstFileExW(q.ptr, w.FindExInfoBasic, &fd, w.FindExSearchNameMatch, null, w.FIND_FIRST_EX_LARGE_FETCH);
        if (h == w.INVALID_HANDLE_VALUE) continue;
        defer _ = w.FindClose(h);
        while (true) {
            try common.check(o.cancel);
            const name = std.mem.sliceTo(&fd.cFileName, 0);
            const a = fd.dwFileAttributes;
            if (!isDots(name) and a & o.skip == 0) {
                const is_dir = a & attr_directory != 0;
                const want = (if (is_dir) o.dirs else o.files) and matchW(pat, name);
                const enter = is_dir and o.recurse and a & attr_reparse == 0;
                if (want or enter) {
                    const p = try join(arena, d, name);
                    if (want) try out.append(arena, .{
                        .path = p,
                        .attrs = a,
                        .size = @as(u64, fd.nFileSizeHigh) << 32 | fd.nFileSizeLow,
                        .mtime = fromFileTime(fd.ftLastWriteTime),
                    });
                    if (enter) try todo.append(arena, p);
                }
            }
            if (w.FindNextFileW(h, &fd) == 0) break;
        }
    }
    return out.toOwnedSlice(arena);
}

/// Directory.EnumerateFileSystemEntries(dir).Any() == false. False also when `dir` cannot be read.
pub fn isEmpty(dir: []const u8) bool {
    var qbuf: [max_w]u16 = undefined;
    const q = toW(&qbuf, dir, if (endsWithSep(dir)) "*" else "\\*") orelse return false;
    var fd: w.WIN32_FIND_DATAW = undefined;
    const h = w.FindFirstFileExW(q.ptr, w.FindExInfoBasic, &fd, w.FindExSearchNameMatch, null, 0);
    if (h == w.INVALID_HANDLE_VALUE) return w.GetLastError() == w.ERROR_FILE_NOT_FOUND; // empty drive root
    defer _ = w.FindClose(h);
    while (isDots(std.mem.sliceTo(&fd.cFileName, 0))) {
        if (w.FindNextFileW(h, &fd) == 0) return w.GetLastError() == w.ERROR_NO_MORE_FILES;
    }
    return false;
}

/// FileInfo.Refresh / GetFileAttributesEx: null when the path does not exist (or is unreadable).
pub fn stat(path: []const u8) ?Entry {
    var buf: [max_w]u16 = undefined;
    const p = toW(&buf, path, "") orelse return null;
    var d: w.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (w.GetFileAttributesExW(p.ptr, w.GetFileExInfoStandard, &d) == 0) return null;
    return .{ .path = path, .attrs = d.dwFileAttributes, .size = @as(u64, d.nFileSizeHigh) << 32 | d.nFileSizeLow, .mtime = fromFileTime(d.ftLastWriteTime) };
}

/// Path.Exists: a file or a folder.
pub fn exists(path: []const u8) bool {
    return stat(path) != null;
}

/// Directory.Exists.
pub fn isDir(path: []const u8) bool {
    return if (stat(path)) |s| s.isDir() else false;
}

/// File.Exists.
pub fn isFile(path: []const u8) bool {
    return if (stat(path)) |s| !s.isDir() else false;
}

/// File.SetAttributes.
pub fn setAttrs(path: []const u8, attrs: u32) !void {
    var buf: [max_w]u16 = undefined;
    const p = toW(&buf, path, "") orelse return error.NameTooLong;
    if (w.SetFileAttributesW(p.ptr, attrs) == 0) return error.AccessDenied;
}

/// File.Delete: a missing file is fine; locked -> error.FileBusy, anything else -> error.AccessDenied.
pub fn deleteFile(path: []const u8) !void {
    var buf: [max_w]u16 = undefined;
    const p = toW(&buf, path, "") orelse return error.NameTooLong;
    if (w.DeleteFileW(p.ptr) != 0) return;
    return switch (w.GetLastError()) {
        w.ERROR_FILE_NOT_FOUND, w.ERROR_PATH_NOT_FOUND => {},
        w.ERROR_SHARING_VIOLATION, w.ERROR_LOCK_VIOLATION => error.FileBusy,
        else => error.AccessDenied,
    };
}

/// Directory.Delete(path) (non-recursive): only an empty folder (or a junction/symlink itself) goes.
pub fn removeDir(path: []const u8) bool {
    var buf: [max_w]u16 = undefined;
    const p = toW(&buf, path, "") orelse return false;
    return w.RemoveDirectoryW(p.ptr) != 0;
}

/// Directory.Delete(path, true) for a tree known to hold no files: folders bottom-up; a junction/symlink
/// is removed as a link, never entered. Any file left inside makes the removal fail (nothing is lost).
pub fn removeEmptyTree(arena: Allocator, path: []const u8) bool {
    const s = stat(path) orelse return false;
    if (s.attrs & attr_reparse == 0) {
        const subs = list(arena, path, "*", .{ .files = false, .dirs = true, .skip = 0 }) catch return false;
        for (subs) |d| _ = removeEmptyTree(arena, d.path);
    }
    return removeDir(path);
}

/// Path.GetFullPath (GetFullPathNameW: "." / ".." / "/" resolved). Null when invalid.
pub fn fullPath(arena: Allocator, path: []const u8) !?[]u8 {
    var buf: [max_w]u16 = undefined;
    if (path.len + 1 > buf.len) return null;
    const len = std.unicode.wtf8ToWtf16Le(&buf, path) catch return null; // no \\?\ here: a pure string op
    buf[len] = 0;
    const p = buf[0..len :0];
    var out: [max_w]u16 = undefined;
    const n = w.GetFullPathNameW(p.ptr, out.len, &out, null);
    if (n == 0 or n >= out.len) return null;
    return try kit.win.fromW(arena, out[0..n]);
}

/// Path.GetPathRoot(dir) == dir, made robust: `dir` is resolved first ("C:\x\.." is the root too) and a
/// UNC share root counts. Never sweep a whole drive.
pub fn isRoot(arena: Allocator, dir: []const u8) !bool {
    const full = std.mem.trimEnd(u8, (try fullPath(arena, dir)) orelse return true, "\\/"); // unresolvable: refuse
    if (full.len <= 2) return true; // "C:" (or garbage)
    if (std.mem.startsWith(u8, full, "\\\\")) return std.mem.countScalar(u8, full[2..], '\\') <= 1; // \\server\share
    return false;
}

pub fn fromFileTime(ft: w.FILETIME) Io.Timestamp {
    const t: i96 = @as(u64, ft.dwHighDateTime) << 32 | ft.dwLowDateTime;
    return .fromNanoseconds((t - 116444736000000000) * 100);
}

pub fn toFileTime(t: Io.Timestamp) w.FILETIME {
    const v: u64 = @intCast(@divFloor(t.nanoseconds, 100) + 116444736000000000);
    return .{ .dwLowDateTime = @truncate(v), .dwHighDateTime = @truncate(v >> 32) };
}

/// `dir` + "\" + `name16` (no doubled separator after a drive root).
fn join(arena: Allocator, dir: []const u8, name16: []const u16) ![]u8 {
    var nb: [260 * 3]u8 = undefined;
    const n = std.unicode.wtf16LeToWtf8(&nb, name16);
    return std.mem.concat(arena, u8, &.{ dir, if (endsWithSep(dir)) "" else "\\", nb[0..n] });
}

fn endsWithSep(s: []const u8) bool {
    return s.len > 0 and (s[s.len - 1] == '\\' or s[s.len - 1] == '/');
}

fn isDots(name: []const u16) bool {
    return (name.len == 1 and name[0] == '.') or (name.len == 2 and name[0] == '.' and name[1] == '.');
}

/// `s ++ suffix` as NUL-terminated WTF-16 in `buf`; null when too long or not WTF-8. Long "X:\" paths get the
/// \\?\ prefix like .NET adds it, so they work with LongPathsEnabled = 0 too (only already-normal paths:
/// \\?\ turns off '/' and "." / ".." handling).
fn toW(buf: []u16, s: []const u8, suffix: []const u8) ?[:0]u16 {
    if (s.len + suffix.len + 5 > buf.len) return null;
    var n: usize = 0;
    if (s.len + suffix.len >= 248 and isNormalDrivePath(s)) { // 248 = MAX_PATH - 12 (CreateDirectory's limit)
        for ("\\\\?\\") |c| {
            buf[n] = c;
            n += 1;
        }
    }
    n += std.unicode.wtf8ToWtf16Le(buf[n..], s) catch return null;
    for (suffix) |c| {
        buf[n] = c;
        n += 1;
    }
    buf[n] = 0;
    return buf[0..n :0];
}

/// "X:\a\b" with backslashes only and no "." / ".." segment.
fn isNormalDrivePath(s: []const u8) bool {
    if (s.len < 3 or !std.ascii.isAlphabetic(s[0]) or s[1] != ':' or s[2] != '\\') return false;
    if (std.mem.findScalar(u8, s, '/') != null) return false;
    var it = std.mem.tokenizeScalar(u8, s[3..], '\\');
    while (it.next()) |seg| if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    return true;
}

// ---------------------------------------------------------------- Win32 wildcard matching

/// EnumerationOptions MatchType.Win32: NormalizeInputs + FileSystemName.TranslateWin32Expression.
/// "*", "*.*", "." and "" mean everything; '?' -> DOS_QM '>', '.' before '?'/'*' -> DOS_DOT '"',
/// a trailing "*." -> DOS_STAR '<' (names without an extension).
pub fn translate(arena: Allocator, pattern: []const u8) ![]u16 {
    const all = [_][]const u8{ "", "*", ".", "*.*" };
    for (all) |a| if (std.mem.eql(u8, pattern, a)) return arena.dupe(u16, &.{'*'});
    const src = try std.unicode.wtf8ToWtf16LeAlloc(arena, pattern);
    var out: std.ArrayList(u16) = .empty;
    for (src, 0..) |c, i| switch (c) {
        '.' => if (i >= 1 and i == src.len - 1 and src[i - 1] == '*') {
            out.items[out.items.len - 1] = '<';
        } else if (i < src.len - 1 and (src[i + 1] == '?' or src[i + 1] == '*')) {
            try out.append(arena, '"');
        } else {
            try out.append(arena, '.');
        },
        '?' => try out.append(arena, '>'),
        else => try out.append(arena, c),
    };
    return out.toOwnedSlice(arena);
}

/// FileSystemName.MatchesWin32Expression(expr, name, ignoreCase: true): the NT FsRtlIsNameInExpression
/// automaton with '*', '?', '<' (DOS_STAR), '>' (DOS_QM), '"' (DOS_DOT) and '\' escapes. `expr` is used as
/// is (callers translate enumeration patterns first). ponytail: the state lists are bool sets instead of
/// .NET's sorted arrays with duplicate skipping; same language, O(len(expr)) per name character.
pub fn matchW(expr: []const u16, name: []const u16) bool {
    if (expr.len == 0 or name.len == 0) return false;
    if (expr[0] == '*') {
        if (expr.len == 1) return true;
        const end = expr[1..];
        if (std.mem.findAny(u16, end, &.{ '"', '*', '<', '>', '?' }) == null) { // "*suffix" = ends with
            if (name.len < end.len) return false;
            for (name[name.len - end.len ..], end) |a, b| if (!eqlFold(a, b)) return false;
            return true;
        }
    }
    const max = expr.len * 2;
    var stack: [1024]u8 = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(&stack, std.heap.page_allocator);
    const sets = bfa.allocator().alloc(bool, 2 * (max + 1)) catch return false;
    defer bfa.allocator().free(sets);
    var prior = sets[0 .. max + 1];
    var cur = sets[max + 1 ..];
    @memset(prior, false);
    prior[0] = true;
    var name_off: usize = 0;
    var ch: u16 = 0;
    var finished = false;
    while (!finished) {
        if (name_off < name.len) {
            ch = name[name_off];
            name_off += 1;
        } else {
            if (prior[max]) break;
            finished = true; // one more round: some wildcards match zero characters past the end
        }
        @memset(cur, false);
        for (prior, 0..) |on, state| {
            if (!on) continue;
            var off = (state + 1) / 2;
            step: while (off < expr.len) {
                var st = off * 2;
                var ec = expr[off];
                switch (ec) {
                    '*' => {
                        cur[st] = true;
                        cur[st + 1] = true;
                    },
                    '<' => { // any characters except the last '.'
                        const not_last = !finished and ch == '.' and std.mem.findScalar(u16, name[name_off..], '.') != null;
                        if (finished or ch != '.' or not_last) cur[st] = true;
                        cur[st + 1] = true;
                    },
                    else => {
                        st += 2;
                        if (ec == '>') { // one character, but not '.'; zero at the end
                            if (!finished and ch != '.') {
                                cur[st] = true;
                                break :step;
                            }
                        } else if (ec == '"') { // '.' or zero characters at the end
                            if (!finished) {
                                if (ch == '.') cur[st] = true;
                                break :step;
                            }
                        } else {
                            if (ec == '\\') {
                                off += 1;
                                if (off == expr.len) {
                                    cur[max] = true;
                                    break :step;
                                }
                                st = off * 2 + 2;
                                ec = expr[off];
                            }
                            if (!finished and (ec == '?' or eqlFold(ec, ch))) cur[st] = true;
                            break :step;
                        }
                    },
                }
                off += 1;
                if (off == expr.len) cur[max] = true;
            }
        }
        if (std.mem.findScalar(bool, cur, true) == null) return false;
        std.mem.swap([]bool, &prior, &cur);
    }
    return prior[max];
}

/// One UTF-16 unit, OrdinalIgnoreCase (char.ToUpperInvariant equality).
fn eqlFold(a: u16, b: u16) bool {
    if (a == b) return true;
    if (a < 0x80 and b < 0x80) return std.ascii.toUpper(@intCast(a)) == std.ascii.toUpper(@intCast(b));
    return w.CompareStringOrdinal(&a, 1, &b, 1, 1) == w.CSTR_EQUAL;
}
