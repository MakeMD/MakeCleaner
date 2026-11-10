//! Port of legacy/src/MakeCleaner.Core/Duplicates.cs (Tools > Duplicate Finder) and its shared walker `Scan`
//! (also used by diskanalyzer.zig).
const std = @import("std");
const w = @import("kit").w;
const kit_win = @import("kit").win;
const common = @import("common.zig");
const fw = @import("filetools_win.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const FileInfo = common.FileInfo;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// record DupOptions.
pub const DupOptions = struct {
    include: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    by_name: bool = true,
    by_size: bool = true,
    by_date: bool = true,
    by_content: bool = false,
    ignore_empty: bool = true,
    ignore_system: bool = true,
    ignore_hidden: bool = true,
    ignore_read_only: bool = false,
    min_size: u64 = 0,
    max_size: u64 = std.math.maxInt(u64),
};

/// record DupResult(Groups, Hashed).
pub const DupResult = struct { groups: []const []const FileInfo, hashed: usize };

/// FNV-1a over ASCII-lowered bytes, non-ASCII skipped, so keys equal under OrdinalIgnoreCase share a bucket
/// (same trick as settings.zig); `eql` does the real compare.
fn foldHash(s: []const u8, seed: u32) u32 {
    var h: u32 = seed;
    for (s) |c| if (c < 0x80) {
        h ^= std.ascii.toLower(c);
        h *%= 16777619;
    };
    return h;
}

const PathSet = std.array_hash_map.Custom([]const u8, void, struct {
    pub fn hash(_: @This(), s: []const u8) u32 {
        return foldHash(s, 2166136261);
    }
    pub fn eql(_: @This(), a: []const u8, b: []const u8, _: usize) bool {
        return common.eqlIgnoreCase(a, b);
    }
}, true);

/// GroupBy key: (Name upper-cased, Size, Date); unused parts are constant.
const Key = struct { name: []const u8, size: u64, date: i96 };

/// Insertion-ordered like LINQ GroupBy (group order = first appearance, files in scan order).
fn Groups(comptime K: type, comptime Ctx: type) type {
    return std.array_hash_map.Custom(K, std.ArrayList(FileInfo), Ctx, true);
}

const KeyCtx = struct {
    pub fn hash(_: KeyCtx, k: Key) u32 {
        return foldHash(k.name, 2166136261) ^ @as(u32, @truncate(k.size *% 0x9E3779B97F4A7C15)) ^ @as(u32, @truncate(@as(u96, @bitCast(k.date)) *% 0x9E3779B97F4A7C15));
    }
    pub fn eql(_: KeyCtx, a: Key, b: Key, _: usize) bool {
        return a.size == b.size and a.date == b.date and common.eqlIgnoreCase(a.name, b.name);
    }
};

const DigestCtx = struct {
    pub fn hash(_: DigestCtx, d: [32]u8) u32 {
        return std.mem.readInt(u32, d[0..4], .little);
    }
    pub fn eql(_: DigestCtx, a: [32]u8, b: [32]u8, _: usize) bool {
        return std.mem.eql(u8, &a, &b);
    }
};

/// Duplicates.Find: groups by the chosen keys (name case-insensitive, size, mtime); content compare hashes
/// (SHA-256) only files that already share a size; unreadable files are never duplicates. Everything returned
/// lives in `arena`.
pub fn find(arena: Allocator, io: Io, o: DupOptions, cancel: ?*const common.Cancel, progress: ?common.Progress(usize)) !DupResult {
    _ = io; // ponytail: Win32 walk + CreateFileW/ReadFile (FileShare.Read, which Io.Dir.openFile cannot ask for)
    var skip: u32 = w.FILE_ATTRIBUTE_REPARSE_POINT;
    if (o.ignore_system) skip |= w.FILE_ATTRIBUTE_SYSTEM;
    if (o.ignore_hidden) skip |= w.FILE_ATTRIBUTE_HIDDEN;
    const read_only: u32 = if (o.ignore_read_only) w.FILE_ATTRIBUTE_READONLY else 0;
    const files = try scan.walk(arena, o.include, o.exclude, skip, read_only, cancel, progress);

    const size_key = o.by_size or o.by_content;
    var by_key: Groups(Key, KeyCtx) = .empty;
    for (files) |f| {
        if (f.size < o.min_size or f.size > o.max_size) continue;
        if (o.ignore_empty and f.size == 0) continue;
        const g = try by_key.getOrPut(arena, .{
            .name = if (o.by_name) f.name() else "",
            .size = if (size_key) f.size else 0,
            .date = if (o.by_date) f.mtime.nanoseconds else 0,
        });
        if (!g.found_existing) g.value_ptr.* = .empty;
        try g.value_ptr.append(arena, f);
    }
    var groups: std.ArrayList([]const FileInfo) = .empty;
    for (by_key.values()) |l| if (l.items.len > 1) try groups.append(arena, l.items);
    if (!o.by_content) return .{ .groups = groups.items, .hashed = 0 };

    var hashed: usize = 0;
    var by_content: std.ArrayList([]const FileInfo) = .empty;
    const buf = try arena.alloc(u8, 1 << 20);
    for (groups.items) |g| {
        var hashes: Groups([32]u8, DigestCtx) = .empty;
        for (g) |f| {
            try common.check(cancel);
            const h = try hash(f.path, buf, cancel) orelse continue; // unreadable: not a provable duplicate
            hashed += 1;
            const e = try hashes.getOrPut(arena, h);
            if (!e.found_existing) e.value_ptr.* = .empty;
            try e.value_ptr.append(arena, f);
        }
        for (hashes.values()) |l| if (l.items.len > 1) try by_content.append(arena, l.items);
    }
    return .{ .groups = by_content.items, .hashed = hashed };
}

/// Duplicates.AllButFirst: default selection, everything except the first file of each group.
pub fn allButFirst(arena: Allocator, groups: []const []const FileInfo) ![]FileInfo {
    var out: std.ArrayList(FileInfo) = .empty;
    for (groups) |g| if (g.len > 1) try out.appendSlice(arena, g[1..]);
    return out.items;
}

/// SHA-256 of the file in 1 MB reads; cancel is checked per read so big files stay responsive.
/// null = could not open/read (IOException / UnauthorizedAccessException in C#), including a file another
/// process holds open for writing (OpenRead = FileShare.Read), so a half-written file is never a duplicate.
fn hash(path: []const u8, buf: []u8, cancel: ?*const common.Cancel) error{Canceled}!?[32]u8 {
    const file = fw.Handle.openRead(path) catch return null;
    defer file.close();
    var h: Sha256 = .init(.{});
    while (true) {
        const n = file.read(buf) catch return null;
        if (n == 0) break;
        try common.check(cancel);
        h.update(buf[0..n]);
    }
    return h.finalResult();
}

/// static class Scan: shared walker for the Tools scanners (roots minus excluded folders, no junction hopping).
pub const scan = struct {
    /// Scan.Files: files under `roots` (env vars expanded, missing roots skipped, each file once), skipping
    /// excluded folder prefixes and entries whose attributes intersect `skip_attrs` (FILE_ATTRIBUTE_*; a
    /// skipped folder is not entered, like .NET AttributesToSkip; pass REPARSE_POINT to never hop junctions).
    /// Breadth-first like .NET EnumerateFiles; inaccessible folders are skipped. Progress every 500 files and
    /// at the end. Everything returned lives in `arena`.
    pub fn files(arena: Allocator, io: Io, roots: []const []const u8, exclude: []const []const u8, skip_attrs: u32, cancel: ?*const common.Cancel, progress: ?common.Progress(usize)) ![]FileInfo {
        _ = io; // ponytail: Win32 FindFirstFileExW walk (std's Dir.Entry has no attributes / size / mtime)
        return walk(arena, roots, exclude, skip_attrs, 0, cancel, progress);
    }

    /// `files` plus `file_skip`: attributes that drop a file after it was counted (Find's IgnoreReadOnly
    /// post-filter: read-only folders are still entered).
    fn walk(arena: Allocator, roots: []const []const u8, exclude: []const []const u8, skip_attrs: u32, file_skip: u32, cancel: ?*const common.Cancel, progress: ?common.Progress(usize)) ![]FileInfo {
        var ex: std.ArrayList([]const u8) = .empty;
        for (exclude) |e| {
            const n = try norm(arena, e);
            if (n.len > 1) try ex.append(arena, n); // "" -> "\" must not exclude everything
        }
        var seen: PathSet = .empty;
        var out: std.ArrayList(FileInfo) = .empty;
        var count: usize = 0;
        var full: std.ArrayList(u8) = .empty;
        var fd: w.WIN32_FIND_DATAW = undefined;
        for (roots) |r| {
            const expanded = try kit_win.expandEnv(arena, std.mem.trim(u8, r, &std.ascii.whitespace));
            const attrs = fw.attributes(expanded) orelse continue; // Directory.Exists
            if (attrs & w.FILE_ATTRIBUTE_DIRECTORY == 0) continue;
            var queue: std.ArrayList([]const u8) = .empty;
            try queue.append(arena, try fw.fullPath(arena, expanded));
            var qi: usize = 0;
            while (qi < queue.items.len) : (qi += 1) {
                const dir = queue.items[qi];
                var pat = fw.winPath(dir) catch continue;
                if (pat.data[pat.len - 1] != '\\') {
                    pat.data[pat.len] = '\\';
                    pat.len += 1;
                }
                pat.data[pat.len] = '*';
                pat.data[pat.len + 1] = 0;
                const h = w.FindFirstFileExW(&pat.data, w.FindExInfoBasic, &fd, w.FindExSearchNameMatch, null, w.FIND_FIRST_EX_LARGE_FETCH);
                if (h == w.INVALID_HANDLE_VALUE) continue; // IgnoreInaccessible
                defer _ = w.FindClose(h);
                const sep: []const u8 = if (dir[dir.len - 1] == '\\') "" else "\\";
                while (true) {
                    const name: []const u16 = @ptrCast(std.mem.sliceTo(&fd.cFileName, 0));
                    const a: u32 = fd.dwFileAttributes;
                    const special = std.mem.eql(u16, name, &.{'.'}) or std.mem.eql(u16, name, &.{ '.', '.' });
                    if (!special and a & skip_attrs == 0) {
                        // built in a reused buffer; only kept folders/files are copied into the arena
                        full.clearRetainingCapacity();
                        try full.appendSlice(arena, dir);
                        try full.appendSlice(arena, sep);
                        const at = full.items.len;
                        try full.resize(arena, at + std.unicode.calcWtf8Len(name));
                        _ = std.unicode.wtf16LeToWtf8(full.items[at..], name);
                        if (a & w.FILE_ATTRIBUTE_DIRECTORY != 0) {
                            try queue.append(arena, try arena.dupe(u8, full.items));
                        } else {
                            try common.check(cancel);
                            const e = if (excluded(ex.items, full.items)) null else try seen.getOrPut(arena, full.items);
                            if (e != null and !e.?.found_existing) {
                                e.?.key_ptr.* = try arena.dupe(u8, full.items);
                                count += 1;
                                if (count % 500 == 0) if (progress) |p| p.report(count);
                                if (a & file_skip == 0) try out.append(arena, .{
                                    .path = e.?.key_ptr.*,
                                    .size = @as(u64, fd.nFileSizeHigh) << 32 | fd.nFileSizeLow,
                                    .mtime = fileTime(fd.ftLastWriteTime),
                                });
                            }
                        }
                    }
                    if (w.FindNextFileW(h, &fd) == 0) break;
                }
            }
        }
        if (progress) |p| p.report(count);
        return out.items;
    }

    fn excluded(ex: []const []const u8, path: []const u8) bool {
        for (ex) |e| if (common.startsWithIgnoreCase(path, e)) return true;
        return false;
    }

    /// Scan.Norm: TrimEndingDirectorySeparator(expand(trim(p))) + "\" (a drive root keeps its separator).
    fn norm(arena: Allocator, p: []const u8) ![]const u8 {
        var s = try kit_win.expandEnv(arena, std.mem.trim(u8, p, &std.ascii.whitespace));
        const root = std.fs.path.parsePathWindows(u8, s).root;
        if (s.len > root.len and std.fs.path.isSep(s[s.len - 1])) s = s[0 .. s.len - 1];
        return std.mem.concat(arena, u8, &.{ s, "\\" });
    }

    /// FILETIME (100 ns since 1601) -> Io.Timestamp (ns since 1970).
    fn fileTime(ft: w.FILETIME) Io.Timestamp {
        const ticks: i96 = @as(u64, ft.dwHighDateTime) << 32 | ft.dwLowDateTime;
        return .fromNanoseconds((ticks - 116444736000000000) * 100);
    }

    /// Scan.SplitPaths: "a; b;;c" -> {"a","b","c"} (slices of `text`).
    pub fn splitPaths(arena: Allocator, text: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, text, ';');
        while (it.next()) |part| {
            const t = std.mem.trim(u8, part, &std.ascii.whitespace);
            if (t.len > 0) try out.append(arena, t);
        }
        return out.toOwnedSlice(arena);
    }
};

// ---------------------------------------------------------------- tests (legacy DuplicatesTests)

const testing = std.testing;

/// DuplicatesTests fixture: a fresh temp dir + Put(rel, content).
pub const Fixture = struct {
    dir: common.TempDir,
    arena: std.heap.ArenaAllocator,
    roots: [1][]const u8 = undefined,

    pub fn init(tag: []const u8) !Fixture {
        return .{ .dir = try .create(testing.allocator, testing.io, tag), .arena = .init(testing.allocator) };
    }

    pub fn deinit(f: *Fixture) void {
        f.dir.cleanup(testing.allocator, testing.io);
        f.arena.deinit();
    }

    pub fn put(f: *Fixture, rel: []const u8, content: []const u8) ![]const u8 {
        const p = try std.fs.path.join(f.arena.allocator(), &.{ f.dir.path, rel });
        try Io.Dir.cwd().createDirPath(testing.io, std.fs.path.dirname(p).?);
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = p, .data = content });
        return p;
    }

    /// ContentOnly: Include = [dir]; the slice points into `f`, so keep `f` in place.
    pub fn contentOnly(f: *Fixture) DupOptions {
        f.roots = .{f.dir.path};
        return .{ .include = &f.roots, .by_name = false, .by_size = false, .by_date = false, .by_content = true };
    }

    /// Names(r): each group's file names sorted ordinal and joined with "|", groups sorted, joined with ";".
    pub fn names(f: *Fixture, r: DupResult) ![]const u8 {
        const a = f.arena.allocator();
        const groups = try a.alloc([]const u8, r.groups.len);
        for (r.groups, groups) |g, *out| {
            const n = try a.alloc([]const u8, g.len);
            for (g, n) |file, *x| x.* = file.name();
            std.mem.sort([]const u8, n, {}, lessThan);
            out.* = try std.mem.join(a, "|", n);
        }
        std.mem.sort([]const u8, groups, {}, lessThan);
        return std.mem.join(a, ";", groups);
    }

    fn lessThan(_: void, x: []const u8, y: []const u8) bool {
        return std.mem.order(u8, x, y) == .lt;
    }
};

test "Content_duplicates_found_despite_different_names" {
    var f: Fixture = try .init("dup");
    defer f.deinit();
    _ = try f.put("a.txt", "same bytes");
    _ = try f.put("sub\\b.dat", "same bytes");
    _ = try f.put("c.txt", "diff bytes"); // same size, different content
    _ = try f.put("d.txt", "unique");
    const r = try find(f.arena.allocator(), testing.io, f.contentOnly(), null, null);
    try testing.expectEqualStrings("a.txt|b.dat", try f.names(r));
}

test "Only_same_size_files_are_hashed" {
    var f: Fixture = try .init("dup");
    defer f.deinit();
    _ = try f.put("a.txt", "12345");
    _ = try f.put("b.txt", "12345");
    _ = try f.put("c.txt", "1234567"); // unique size -> never opened
    _ = try f.put("d.txt", "123456789");
    try testing.expectEqual(2, (try find(f.arena.allocator(), testing.io, f.contentOnly(), null, null)).hashed);
}

test "Name_and_size_match_without_content_and_ignores_apply" {
    var f: Fixture = try .init("dup");
    defer f.deinit();
    _ = try f.put("x\\report.txt", "aaaa");
    _ = try f.put("y\\REPORT.txt", "bbbb"); // same name (case-insensitive) + size, different content
    _ = try f.put("x\\empty.log", "");
    _ = try f.put("y\\empty.log", "");
    for ([_][]const u8{ "x\\h.bin", "y\\h.bin" }) |rel| {
        const p = try kit_win.toW(f.arena.allocator(), try f.put(rel, "zz"));
        try testing.expect(w.SetFileAttributesW(p, w.FILE_ATTRIBUTE_HIDDEN) != 0);
    }
    const r = try find(f.arena.allocator(), testing.io, .{ .include = &.{f.dir.path}, .by_date = false }, null, null);
    try testing.expectEqualStrings("REPORT.txt|report.txt", try f.names(r));
}

test "Size_limits_and_exclude_folders" {
    var f: Fixture = try .init("dup");
    defer f.deinit();
    _ = try f.put("keep\\a.bin", "1234567890");
    _ = try f.put("keep\\b.bin", "1234567890");
    _ = try f.put("skip\\c.bin", "1234567890");
    _ = try f.put("keep\\s1.bin", "1");
    _ = try f.put("keep\\s2.bin", "1");
    var o = f.contentOnly();
    const ex = [_][]const u8{try std.fs.path.join(f.arena.allocator(), &.{ f.dir.path, "skip" })};
    o.exclude = &ex;
    o.min_size = 5;
    const r = try find(f.arena.allocator(), testing.io, o, null, null);
    try testing.expectEqualStrings("a.bin|b.bin", try f.names(r));
}

test "Cancel_stops_scan (Duplicates.Find)" {
    var f: Fixture = try .init("dup");
    defer f.deinit();
    _ = try f.put("a.txt", "x");
    var c: common.Cancel = .init(true);
    try testing.expectError(error.Canceled, find(f.arena.allocator(), testing.io, f.contentOnly(), &c, null));
}

test "Scan: each file once across overlapping roots, env vars expanded, missing roots skipped, progress at end" {
    var f: Fixture = try .init("dup");
    defer f.deinit();
    _ = try f.put("a.txt", "1");
    _ = try f.put("Sub\\b.txt", "2");
    const a = f.arena.allocator();
    const sub_upper = try std.ascii.allocUpperString(a, try std.fs.path.join(a, &.{ f.dir.path, "sub" }));
    const Rec = struct {
        last: usize = 0,
        fn report(ctx: ?*anyopaque, v: usize) void {
            @as(*@This(), @ptrCast(@alignCast(ctx.?))).last = v;
        }
    };
    var rec: Rec = .{};
    const got = try scan.files(a, testing.io, &.{ f.dir.path, sub_upper, "%SystemRoot%\\no-such-dir-mc", "" }, &.{""}, w.FILE_ATTRIBUTE_REPARSE_POINT, null, .{ .ctx = &rec, .func = Rec.report });
    try testing.expectEqual(2, got.len);
    try testing.expectEqual(2, rec.last);
    try testing.expectEqualStrings("a.txt", got[0].name()); // root files first (breadth-first)
    try testing.expectEqual(1, got[0].size);
}

test "Scan: Cyrillic names round-trip and a root given in other case is not listed twice (AllButFirst safety)" {
    var f: Fixture = try .init("dup");
    defer f.deinit();
    _ = try f.put("Папка\\файл.txt", "дані");
    _ = try f.put("Інша\\файл.txt", "дані");
    const a = f.arena.allocator();
    const lower = try std.fs.path.join(a, &.{ f.dir.path, "Папка" });
    const upper = try std.fs.path.join(a, &.{ f.dir.path, "ПАПКА" });
    const got = try scan.files(a, testing.io, &.{ lower, upper }, &.{}, w.FILE_ATTRIBUTE_REPARSE_POINT, null, null);
    try testing.expectEqual(1, got.len);
    try testing.expectEqualStrings("файл.txt", got[0].name());
    const roots = [_][]const u8{ f.dir.path, upper };
    const r = try find(a, testing.io, .{ .include = &roots, .by_date = false }, null, null);
    try testing.expectEqualStrings("файл.txt|файл.txt", try f.names(r));
}

test "Scan never hops a junction under a root (AllButFirst would delete the only copy)" {
    var f: Fixture = try .init("dup");
    defer f.deinit();
    const a = f.arena.allocator();
    const data = std.fs.path.dirname(try f.put("data\\only.txt", "precious")).?;
    try fw.testJunction(testing.allocator, testing.io, try std.fs.path.join(a, &.{ f.dir.path, "link" }), data);
    const got = try scan.files(a, testing.io, &.{f.dir.path}, &.{}, w.FILE_ATTRIBUTE_REPARSE_POINT, null, null);
    try testing.expectEqual(1, got.len);
    try testing.expectEqual(0, (try find(a, testing.io, f.contentOnly(), null, null)).groups.len);
    try testing.expectEqual(0, (try find(a, testing.io, .{ .include = &f.roots, .by_date = false, .ignore_system = false, .ignore_hidden = false }, null, null)).groups.len);
}

test "Big files hash in 1 MB reads: last byte counts, a file open for writing is unreadable, cancel mid-file" {
    var f: Fixture = try .init("dup");
    defer f.deinit();
    const a = f.arena.allocator();
    const big = try a.alloc(u8, (5 << 20) / 2);
    for (big, 0..) |*x, i| x.* = @truncate(i *% 31);
    const pa = try f.put("a.bin", big);
    _ = try f.put("b.bin", big);
    const pw = try f.put("w.bin", big);
    big[big.len - 1] +%= 1;
    _ = try f.put("c.bin", big);
    const writer = try Io.Dir.cwd().openFile(testing.io, pw, .{ .mode = .read_write }); // another writer (shares all)
    defer writer.close(testing.io);
    const r = try find(a, testing.io, f.contentOnly(), null, null);
    try testing.expectEqualStrings("a.bin|b.bin", try f.names(r));
    try testing.expectEqual(3, r.hashed); // w.bin: OpenRead (FileShare.Read) fails -> not a provable duplicate
    var c: common.Cancel = .init(true); // set before the first read: only the per-read check can throw
    try testing.expectError(error.Canceled, hash(pa, try a.alloc(u8, 1 << 20), &c));
}

fn setAttr(f: *Fixture, path: []const u8, attr: u32) !void {
    try testing.expect(w.SetFileAttributesW(try kit_win.toW(f.arena.allocator(), path), attr) != 0);
}

test "Options: ByDate, ByName alone, MaxSize" {
    var f: Fixture = try .init("dup");
    defer f.deinit();
    const a = f.arena.allocator();
    const ft: w.FILETIME = .{ .dwLowDateTime = 0x12345678, .dwHighDateTime = 0x01D9F000 };
    const late: w.FILETIME = .{ .dwLowDateTime = ft.dwLowDateTime + 10_000_000, .dwHighDateTime = ft.dwHighDateTime };
    for ([_][]const u8{ "d\\1.txt", "d\\2.txt", "d\\3.txt" }, [_]w.FILETIME{ ft, ft, late }) |rel, t| {
        const h = try fw.Handle.open(try f.put(rel, "same"), w.OPEN_EXISTING, 0);
        defer h.close();
        try testing.expect(w.SetFileTime(h.h, null, null, &t) != 0);
    }
    const d = [_][]const u8{try std.fs.path.join(a, &.{ f.dir.path, "d" })};
    try testing.expectEqualStrings("1.txt|2.txt", try f.names(try find(a, testing.io, .{ .include = &d, .by_name = false }, null, null)));

    _ = try f.put("n\\x\\r.txt", "a");
    _ = try f.put("n\\y\\r.txt", "bbb"); // other size and content: ByName alone still groups it
    const n = [_][]const u8{try std.fs.path.join(a, &.{ f.dir.path, "n" })};
    try testing.expectEqualStrings("r.txt|r.txt", try f.names(try find(a, testing.io, .{ .include = &n, .by_size = false, .by_date = false }, null, null)));

    for ([_][]const u8{ "m\\a.bin", "m\\b.bin" }) |rel| _ = try f.put(rel, "1234567890");
    for ([_][]const u8{ "m\\c.bin", "m\\d.bin" }) |rel| _ = try f.put(rel, "12");
    var o = f.contentOnly();
    const m = [_][]const u8{try std.fs.path.join(a, &.{ f.dir.path, "m" })};
    o.include = &m;
    o.max_size = 5;
    try testing.expectEqualStrings("c.bin|d.bin", try f.names(try find(a, testing.io, o, null, null)));
}

test "Options: hidden/system files and folders skipped (folders not entered); IgnoreReadOnly drops files, still enters read-only folders" {
    var f: Fixture = try .init("dup");
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.put("s\\a.txt", "q1");
    _ = try f.put("s\\e.txt", "q1");
    const hid = std.fs.path.dirname(try f.put("s\\hid\\b.txt", "q1")).?;
    const sys = std.fs.path.dirname(try f.put("s\\sys\\c.txt", "q1")).?;
    try setAttr(&f, hid, w.FILE_ATTRIBUTE_HIDDEN);
    try setAttr(&f, sys, w.FILE_ATTRIBUTE_SYSTEM);
    try setAttr(&f, try f.put("s\\d.txt", "q1"), w.FILE_ATTRIBUTE_SYSTEM);
    var o = f.contentOnly();
    const s = [_][]const u8{try std.fs.path.join(a, &.{ f.dir.path, "s" })};
    o.include = &s;
    try testing.expectEqualStrings("a.txt|e.txt", try f.names(try find(a, testing.io, o, null, null)));
    o.ignore_hidden = false;
    o.ignore_system = false;
    try testing.expectEqualStrings("a.txt|b.txt|c.txt|d.txt|e.txt", try f.names(try find(a, testing.io, o, null, null)));

    const ro_dir = std.fs.path.dirname(try f.put("r\\ro\\a.txt", "z1")).?;
    const ro_file = try f.put("r\\b.txt", "z1");
    _ = try f.put("r\\c.txt", "z1");
    try setAttr(&f, ro_dir, w.FILE_ATTRIBUTE_READONLY);
    try setAttr(&f, ro_file, w.FILE_ATTRIBUTE_READONLY);
    defer for ([_][]const u8{ ro_dir, ro_file }) |p| setAttr(&f, p, w.FILE_ATTRIBUTE_NORMAL) catch {}; // cleanup can delete
    const r = [_][]const u8{try std.fs.path.join(a, &.{ f.dir.path, "r" })};
    o.include = &r;
    try testing.expectEqualStrings("a.txt|b.txt|c.txt", try f.names(try find(a, testing.io, o, null, null)));
    o.ignore_read_only = true;
    try testing.expectEqualStrings("a.txt|c.txt", try f.names(try find(a, testing.io, o, null, null)));
}

test "SplitPaths drops empty entries and trims" {
    const got = try scan.splitPaths(testing.allocator, " a; b;;c ;");
    defer testing.allocator.free(got);
    try testing.expectEqual(3, got.len);
    for ([_][]const u8{ "a", "b", "c" }, got) |want, g| try testing.expectEqualStrings(want, g);
}
