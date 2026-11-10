//! Rules.cs: winapp2-format rules: FileKey / RegKey / ExcludeKey, Rule (one checkbox = one INI section) and
//! the path helpers (Paths). Memory: everything a parse returns lives in the `arena` passed in (or points
//! into the parsed text).
const std = @import("std");
const kit = @import("kit");
const common = @import("common.zig");
const reg = @import("reg.zig");
const fs = @import("rules_fs.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const trim = common.trim;

/// string.Split(sep): every field, empty ones included.
fn split(arena: Allocator, s: []const u8, sep: u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, sep);
    while (it.next()) |p| try out.append(arena, p);
    return out.toOwnedSlice(arena);
}

/// record FileKey: "path|pattern[;pattern]|RECURSE|REMOVESELF|OLDER=hours". REMOVESELF implies recursion and
/// also drops the (emptied) folder. OLDER=hours (MakeCleaner extension, Options > Include) skips newer files.
pub const FileKey = struct {
    path: []const u8,
    patterns: []const []const u8,
    recurse: bool,
    remove_self: bool = false,
    older_than_hours: i32 = 0,

    /// FileKey.Parse. Missing/empty pattern part = "*.*". `value` is copied into `arena` (custom.zig passes
    /// strings borrowed from Settings, which a later edit frees).
    pub fn parse(arena: Allocator, value: []const u8) !FileKey {
        const parts = try split(arena, try arena.dupe(u8, value), '|');
        var k: FileKey = .{
            .path = trim(parts[0]),
            .patterns = if (parts.len > 1 and parts[1].len > 0) try split(arena, parts[1], ';') else &.{"*.*"},
            .recurse = false,
        };
        var older_seen = false;
        for (parts[@min(2, parts.len)..]) |raw| {
            const p = trim(raw);
            if (std.ascii.eqlIgnoreCase(p, "REMOVESELF")) k.remove_self = true;
            if (std.ascii.eqlIgnoreCase(p, "RECURSE")) k.recurse = true;
            if (!older_seen and std.ascii.startsWithIgnoreCase(p, "OLDER=")) { // the first OLDER= only
                older_seen = true;
                const h = std.fmt.parseInt(i32, trim(p[6..]), 10) catch 0;
                k.older_than_hours = if (h > 0) h else 0;
            }
        }
        k.recurse = k.recurse or k.remove_self;
        return k;
    }
};

/// record RegKey: "HKCU\key" = whole key, "HKCU\key|Value" = one value.
pub const RegKey = struct {
    key: []const u8,
    value: ?[]const u8 = null,

    /// RegKey.Parse (slices of `value`, no allocation). The value part is not trimmed.
    pub fn parse(value: []const u8) RegKey {
        const bar = std.mem.findScalar(u8, value, '|') orelse return .{ .key = trim(value) };
        return .{ .key = trim(value[0..bar]), .value = value[bar + 1 ..] };
    }

    /// Record equality (ordinal).
    pub fn eql(a: RegKey, b: RegKey) bool {
        if (!std.mem.eql(u8, a.key, b.key)) return false;
        if (a.value == null or b.value == null) return a.value == null and b.value == null;
        return std.mem.eql(u8, a.value.?, b.value.?);
    }

    /// RegKey.ToString: "key" or "key|value". Use with "{f}".
    pub fn format(k: RegKey, wr: *std.Io.Writer) std.Io.Writer.Error!void {
        try wr.writeAll(k.key);
        if (k.value) |v| try wr.print("|{s}", .{v});
    }
};

/// record ExcludeKey: "FILE|dir|patterns" = files directly in dir, "PATH|dir|patterns" = anywhere under dir,
/// "REG|key[|value]". C# kept Kind as the upper-cased string; here it is an enum.
pub const ExcludeKey = struct {
    kind: Kind,
    path: []const u8,
    patterns: []const []const u8,

    pub const Kind = enum { file, path, reg, unknown };

    /// ExcludeKey.Parse. `value` is copied into `arena` (see FileKey.parse).
    pub fn parse(arena: Allocator, value: []const u8) !ExcludeKey {
        const parts = try split(arena, try arena.dupe(u8, value), '|');
        const k = trim(parts[0]);
        return .{
            .kind = if (common.eqlIgnoreCase(k, "FILE")) .file else if (common.eqlIgnoreCase(k, "PATH")) .path else if (common.eqlIgnoreCase(k, "REG")) .reg else .unknown,
            .path = if (parts.len > 1) trim(parts[1]) else "",
            .patterns = if (parts.len > 2 and parts[2].len > 0) try split(arena, parts[2], ';') else &.{},
        };
    }
};

/// class Rule: one checkbox = one INI section (keys case-insensitive and numbered: FileKey1..n).
pub const Rule = struct {
    name: []const u8 = "",
    section: ?[]const u8 = null,
    lang_sec_ref: ?i32 = null,
    default: bool = false,
    warning: ?[]const u8 = null,
    detect_os: ?[]const u8 = null,
    file_keys: std.ArrayList(FileKey) = .empty,
    reg_keys: std.ArrayList(RegKey) = .empty,
    excludes: std.ArrayList(ExcludeKey) = .empty,
    detect: std.ArrayList([]const u8) = .empty,
    detect_file: std.ArrayList([]const u8) = .empty,
    special_detect: std.ArrayList([]const u8) = .empty,
    special_keys: std.ArrayList([]const u8) = .empty,
    /// Options key; when on, only files older than 24 h.
    age_option: ?[]const u8 = null,
    /// Set from age_option right before Analyze.
    older_than_hours: ?i32 = null,

    /// Rule.Group: Section= wins, else the public LangSecRef groups (3021 Applications .. 3025 Windows), else "Other".
    pub fn group(r: *const Rule) []const u8 {
        return r.section orelse switch (r.lang_sec_ref orelse 0) {
            3021 => "Applications",
            3022 => "Internet",
            3023 => "Multimedia",
            3024 => "Utilities",
            3025 => "Windows",
            else => "Other",
        };
    }

    /// Rule.IsDetected: OS fits and (no detection keys, or any of them hits). `gpa` only for temporaries.
    pub fn isDetected(r: *const Rule, gpa: Allocator, io: Io) bool {
        if (r.detect_os) |os| if (!paths.osInRange(os, kit.win.osVersion())) return false;
        if (r.detect.items.len + r.detect_file.items.len + r.special_detect.items.len == 0) return true;
        for (r.detect.items) |k| if (reg.keyExists(k)) return true;
        for (r.detect_file.items) |f| if (paths.anyExists(gpa, io, f)) return true;
        for (r.special_detect.items) |s| if (paths.specialDetect(gpa, io, s)) return true;
        return false;
    }

    /// The rule has this SpecialKey (OrdinalIgnoreCase).
    pub fn hasSpecial(r: *const Rule, key: []const u8) bool {
        for (r.special_keys.items) |k| if (common.eqlIgnoreCase(k, key)) return true;
        return false;
    }
};

/// Rule.ParseIni. Strings point into `text` or `arena`; `text` must outlive the rules.
pub fn parseIni(arena: Allocator, text: []const u8) ![]Rule {
    var list: std.ArrayList(Rule) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = trim(raw);
        if (line.len == 0 or line[0] == ';') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            try list.append(arena, .{ .name = line[1 .. line.len - 1] });
            continue;
        }
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        if (list.items.len == 0) continue;
        const cur = &list.items[list.items.len - 1];
        const val = trim(line[eq + 1 ..]);
        const key = std.mem.trimEnd(u8, std.mem.trimEnd(u8, line[0..eq], &std.ascii.whitespace), "0123456789");
        const is = struct {
            fn f(k: []const u8, name: []const u8) bool {
                return std.ascii.eqlIgnoreCase(k, name);
            }
        }.f;
        if (is(key, "filekey")) {
            try cur.file_keys.append(arena, try FileKey.parse(arena, val));
        } else if (is(key, "regkey")) {
            try cur.reg_keys.append(arena, RegKey.parse(val));
        } else if (is(key, "excludekey")) {
            try cur.excludes.append(arena, try ExcludeKey.parse(arena, val));
        } else if (is(key, "detect")) {
            try cur.detect.append(arena, val);
        } else if (is(key, "detectfile")) {
            try cur.detect_file.append(arena, val);
        } else if (is(key, "specialdetect")) {
            try cur.special_detect.append(arena, val);
        } else if (is(key, "specialkey")) {
            try cur.special_keys.append(arena, val);
        } else if (is(key, "ageoption")) {
            cur.age_option = val;
        } else if (is(key, "detectos")) {
            cur.detect_os = val;
        } else if (is(key, "default")) {
            cur.default = std.ascii.eqlIgnoreCase(val, "true");
        } else if (is(key, "warning")) {
            cur.warning = val;
        } else if (is(key, "section")) {
            cur.section = val;
        } else if (is(key, "langsecref")) {
            cur.lang_sec_ref = std.fmt.parseInt(i32, val, 10) catch null;
        }
    }
    return list.toOwnedSlice(arena);
}

/// Rule.LoadApplications: exe_dir\rules\Winapp2.ini + optional exe_dir\winapp2.ini (user entries override by
/// name), detected ones only, ordered by group then name.
pub fn loadApplications(arena: Allocator, io: Io, exe_dir: []const u8) ![]Rule {
    var by_name: common.IgnoreCaseMap(Rule) = .empty;
    for ([_][]const []const u8{ &.{ exe_dir, "rules", "Winapp2.ini" }, &.{ exe_dir, "winapp2.ini" } }) |parts| {
        const file = try Io.Dir.path.join(arena, parts);
        const raw = Io.Dir.cwd().readFileAlloc(io, file, arena, .unlimited) catch |e| switch (e) {
            error.FileNotFound, error.IsDir => continue,
            else => |x| return x,
        };
        // File.ReadAllText: UTF-8 (BOM ok) or UTF-16 LE with BOM (Notepad's "Unicode"). ponytail: no UTF-16 BE.
        const text = if (std.mem.startsWith(u8, raw, "\xFF\xFE")) utf16: {
            const units = try arena.alloc(u16, (raw.len - 2) / 2);
            for (units, 0..) |*u, i| u.* = std.mem.readInt(u16, raw[2 + 2 * i ..][0..2], .little);
            break :utf16 try std.unicode.wtf16LeToWtf8Alloc(arena, units);
        } else if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) raw[3..] else raw;
        for (try parseIni(arena, text)) |r| try by_name.put(arena, r.name, r);
    }
    const out = try detected(arena, io, by_name.values());
    std.mem.sort(Rule, out, {}, struct {
        fn less(_: void, a: Rule, b: Rule) bool {
            const g = cultureOrder(a.group(), b.group());
            return if (g != .eq) g == .lt else cultureOrder(a.name, b.name) == .lt;
        }
    }.less);
    return out;
}

/// The rules whose isDetected holds (copies in `arena`); detection temporaries are freed per rule.
pub fn detected(arena: Allocator, io: Io, list: []const Rule) ![]Rule {
    var tmp: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer tmp.deinit();
    var out: std.ArrayList(Rule) = .empty;
    for (list) |r| {
        if (r.isDetected(tmp.allocator(), io)) try out.append(arena, r);
        _ = tmp.reset(.retain_capacity);
    }
    return out.toOwnedSlice(arena);
}

/// OrderBy(string) used the current culture. ponytail: ASCII case-insensitive, then ordinal; culture rules
/// (ignored punctuation, accents) would only change the display order.
fn cultureOrder(a: []const u8, b: []const u8) std.math.Order {
    const o = std.ascii.orderIgnoreCase(a, b);
    return if (o != .eq) o else std.mem.order(u8, a, b);
}

/// static class Paths.
pub const paths = struct {
    /// Paths.ExpandVars: one input can yield several paths (%ProgramFiles% = x64 + x86); unknown var -> none.
    pub fn expandVars(arena: Allocator, path: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        try expandInto(arena, &out, "", path);
        return out.toOwnedSlice(arena);
    }

    fn expandInto(arena: Allocator, out: *std.ArrayList([]const u8), prefix: []const u8, path: []const u8) !void {
        // first match of %([A-Za-z0-9_]+)%
        const m: struct { start: usize, end: usize } = for (path, 0..) |c, i| {
            if (c != '%') continue;
            var j = i + 1;
            while (j < path.len and (std.ascii.isAlphanumeric(path[j]) or path[j] == '_')) j += 1;
            if (j > i + 1 and j < path.len and path[j] == '%') break .{ .start = i, .end = j + 1 };
        } else return out.append(arena, try std.mem.concat(arena, u8, &.{ prefix, path }));
        for (try varValues(arena, path[m.start + 1 .. m.end - 1])) |v|
            try expandInto(arena, out, try std.mem.concat(arena, u8, &.{ prefix, path[0..m.start], v }), path[m.end..]);
    }

    /// winapp2 vars that are not real env vars, or mean more than one folder. Empty values dropped, distinct.
    fn varValues(arena: Allocator, name: []const u8) ![]const []const u8 {
        const w = kit.w;
        const eq = std.ascii.eqlIgnoreCase;
        var v: std.ArrayList([]const u8) = .empty;
        if (eq(name, "programfiles")) {
            try v.appendSlice(arena, &.{ try folder(arena, &w.FOLDERID_ProgramFiles), try folder(arena, &w.FOLDERID_ProgramFilesX86) });
        } else if (eq(name, "commonprogramfiles")) {
            try v.appendSlice(arena, &.{ try folder(arena, &w.FOLDERID_ProgramFilesCommon), try folder(arena, &w.FOLDERID_ProgramFilesCommonX86) });
        } else if (eq(name, "locallowappdata")) {
            const profile = try folder(arena, &w.FOLDERID_Profile);
            try v.append(arena, if (profile.len == 0) "" else try Io.Dir.path.join(arena, &.{ profile, "AppData", "LocalLow" }));
        } else if (eq(name, "documents") or eq(name, "mydocuments")) {
            try v.append(arena, try folder(arena, &w.FOLDERID_Documents));
        } else if (eq(name, "commonappdata")) {
            try v.append(arena, try folder(arena, &w.FOLDERID_ProgramData));
        } else {
            try v.append(arena, (try kit.win.getEnv(arena, name)) orelse "");
        }
        var out: std.ArrayList([]const u8) = .empty;
        next: for (v.items) |s| {
            if (s.len == 0) continue;
            for (out.items) |o| if (common.eqlIgnoreCase(o, s)) continue :next;
            try out.append(arena, s);
        }
        return out.items;
    }

    /// Environment.GetFolderPath: "" when the folder does not exist on this PC.
    fn folder(arena: Allocator, id: *const kit.w.KNOWNFOLDERID) ![]const u8 {
        return kit.win.knownFolder(arena, id) catch |e| switch (e) {
            error.OutOfMemory => e,
            else => "",
        };
    }

    fn isWild(s: []const u8) bool {
        return std.mem.findAny(u8, s, "*?") != null;
    }

    /// Paths.ExpandDirs: existing directories matching path; '*'/'?' in any segment; wildcards never enter junctions.
    /// ponytail: stricter than C#: '/' counts as '\', and the first segment must be a drive ("X:"); C# also
    /// skipped UNC paths but would have resolved a relative first segment against the current directory.
    pub fn expandDirs(arena: Allocator, io: Io, path: []const u8) ![]const []const u8 {
        _ = io;
        var out: std.ArrayList([]const u8) = .empty;
        for (try expandVars(arena, path)) |expanded| {
            const p = try arena.dupe(u8, std.mem.trimEnd(u8, trim(expanded), "\\/"));
            std.mem.replaceScalar(u8, p, '/', '\\');
            var segs = std.mem.splitScalar(u8, p, '\\');
            const drive = segs.first();
            if (drive.len != 2 or drive[1] != ':' or !std.ascii.isAlphabetic(drive[0])) continue; // UNC / relative: not supported
            var cur: std.ArrayList([]const u8) = .empty;
            try cur.append(arena, try std.mem.concat(arena, u8, &.{ drive, "\\" }));
            while (segs.next()) |seg| {
                if (seg.len == 0) continue;
                var next: std.ArrayList([]const u8) = .empty;
                for (cur.items) |d| {
                    if (isWild(seg)) {
                        for (try fs.list(arena, d, seg, .{ .files = false, .dirs = true })) |e| try next.append(arena, e.path);
                    } else {
                        try next.append(arena, try std.mem.concat(arena, u8, &.{ d, if (d[d.len - 1] == '\\') "" else "\\", seg }));
                    }
                }
                cur = next;
            }
            for (cur.items) |d| if (fs.isDir(d)) try out.append(arena, d);
        }
        return out.toOwnedSlice(arena);
    }

    /// Paths.AnyExists (DetectFile): file or folder exists; wildcards allowed in every segment incl. the last.
    pub fn anyExists(gpa: Allocator, io: Io, path: []const u8) bool {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const t = std.mem.trimEnd(u8, trim(path), "\\");
        const cut = std.mem.findScalarLast(u8, t, '\\') orelse return false;
        const leaf = t[cut + 1 ..];
        for (expandDirs(arena, io, t[0..cut]) catch return false) |dir| {
            if (isWild(leaf)) {
                const found = fs.list(arena, dir, leaf, .{ .files = true, .dirs = true, .skip = 0 }) catch continue;
                if (found.len > 0) return true;
            } else {
                const p = std.mem.concat(arena, u8, &.{ dir, if (dir[dir.len - 1] == '\\') "" else "\\", leaf }) catch return false;
                if (fs.exists(p)) return true;
            }
        }
        return false;
    }

    /// Paths.Matches: FileSystemName.MatchesWin32Expression(pattern.Trim(), name), untranslated: unlike an
    /// enumeration pattern, "*.*" here needs a dot in the name.
    pub fn matches(pattern: []const u8, name: []const u8) bool {
        var stack: [2048]u8 = undefined;
        var bfa: std.heap.BufferFirstAllocator = .init(&stack, std.heap.page_allocator);
        const a = bfa.allocator();
        const p = std.unicode.wtf8ToWtf16LeAlloc(a, trim(pattern)) catch return false;
        defer a.free(p);
        const n = std.unicode.wtf8ToWtf16LeAlloc(a, name) catch return false;
        defer a.free(n);
        return fs.matchW(p, n);
    }

    /// Paths.OsInRange: DetectOS "min|max", either side optional; compares only as many version parts as given.
    /// ponytail: an unparsable version hides the rule (C# Version.Parse threw).
    pub fn osInRange(range: []const u8, os: kit.win.OsVersion) bool {
        var parts = std.mem.splitScalar(u8, range, '|');
        const min = trim(parts.first());
        const max = if (parts.next()) |m| trim(m) else min;
        if (min.len > 0) if ((cmp(min, os) orelse return false) == .lt) return false;
        if (max.len > 0) if ((cmp(max, os) orelse return false) == .gt) return false;
        return true;
    }

    /// have.CompareTo(want) like System.Version (missing parts = -1); null if `v` is not a version.
    fn cmp(v: []const u8, os: kit.win.OsVersion) ?std.math.Order {
        var want: [4]i64 = .{ -1, -1, -1, -1 };
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, v, '.');
        while (it.next()) |part| : (n += 1) {
            if (n == 4) return null;
            want[n] = std.fmt.parseInt(u31, trim(part), 10) catch return null;
        }
        if (n == 1) want[1] = 0; // "10" = "10.0"
        const have: [4]i64 = .{ os.major, os.minor, if (want[2] < 0) @as(i64, -1) else os.build, -1 };
        for (have, want) |h, x| if (h != x) return std.math.order(h, x);
        return .eq;
    }

    /// Paths.SpecialDetect: DET_CHROME / DET_MOZILLA / DET_THUNDERBIRD / DET_OPERA; unknown -> false.
    /// ponytail (C#): only the core browsers; an unknown DET_* hides the entry.
    pub fn specialDetect(gpa: Allocator, io: Io, id: []const u8) bool {
        const map = [_]struct { []const u8, []const u8 }{
            .{ "DET_CHROME", "%LocalAppData%\\Google\\Chrome\\User Data" },
            .{ "DET_MOZILLA", "%AppData%\\Mozilla\\Firefox" },
            .{ "DET_THUNDERBIRD", "%AppData%\\Thunderbird" },
            .{ "DET_OPERA", "%AppData%\\Opera Software" },
        };
        for (map) |m| if (common.eqlIgnoreCase(trim(id), m[0])) return anyExists(gpa, io, m[1]);
        return false;
    }
};
