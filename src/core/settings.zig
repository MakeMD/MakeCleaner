//! Settings.cs: flat key=value MakeCleaner.ini under an "[Options]" header. Keys are case-insensitive;
//! lists are numbered keys (Include1=, Include2=, ...). portable.dat next to the exe -> the ini lives
//! next to the exe, else in %AppData%\MakeCleaner (resolveDir).
const std = @import("std");
const kit = @import("kit");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const path = Io.Dir.path;

pub const file_name = "MakeCleaner.ini";

/// Settings.ResolveDir: the folder that holds MakeCleaner.ini (caller frees).
pub fn resolveDir(gpa: Allocator, io: Io, exe_dir: []const u8) ![]u8 {
    const marker = try path.join(gpa, &.{ exe_dir, "portable.dat" });
    defer gpa.free(marker);
    if (Io.Dir.cwd().statFile(io, marker, .{})) |st| {
        if (st.kind == .file) return gpa.dupe(u8, exe_dir);
    } else |_| {}
    const appdata = try kit.win.knownFolder(gpa, &kit.w.FOLDERID_RoamingAppData);
    defer gpa.free(appdata);
    return path.join(gpa, &.{ appdata, "MakeCleaner" });
}

/// Keys compare OrdinalIgnoreCase.
const Map = common.IgnoreCaseMap([]const u8);

pub const Settings = struct {
    gpa: Allocator,
    /// Full path of MakeCleaner.ini.
    path: []u8,
    /// Keys and values owned by `gpa`; insertion order = file order.
    values: Map = .empty,

    /// new Settings(dir): reads `dir\MakeCleaner.ini` if it exists (missing file = empty settings).
    pub fn load(gpa: Allocator, io: Io, dir: []const u8) !Settings {
        var s: Settings = .{ .gpa = gpa, .path = try path.join(gpa, &.{ dir, file_name }) };
        errdefer s.deinit();
        const raw = Io.Dir.cwd().readFileAlloc(io, s.path, gpa, .limited(64 << 20)) catch |e| switch (e) {
            error.FileNotFound => return s,
            else => |x| return x,
        };
        defer gpa.free(raw);
        // UTF-8 with or without BOM (what Save writes), or UTF-16 LE from a Notepad "Unicode" save (as File.ReadAllLines)
        var decoded: std.heap.ArenaAllocator = .init(gpa);
        defer decoded.deinit();
        const text = try common.readAllText(decoded.allocator(), raw);
        var lines = std.mem.splitAny(u8, text, "\r\n"); // File.ReadAllLines: \r\n, \n or \r
        while (lines.next()) |line| {
            const eq = std.mem.findScalar(u8, line, '=') orelse continue;
            if (eq > 0) try s.set(line[0..eq], line[eq + 1 ..]); // later duplicates win
        }
        return s;
    }

    pub fn deinit(s: *Settings) void {
        for (s.values.keys(), s.values.values()) |k, v| {
            s.gpa.free(k);
            s.gpa.free(v);
        }
        s.values.deinit(s.gpa);
        s.gpa.free(s.path);
    }

    /// Settings.Get. The slice is valid until the next set/setList/deinit.
    pub fn get(s: *const Settings, key: []const u8, fallback: []const u8) []const u8 {
        return s.values.get(key) orelse fallback;
    }

    /// Settings.GetBool: bool.TryParse ("true"/"false", any case) or `fallback`.
    pub fn getBool(s: *const Settings, key: []const u8, fallback: bool) bool {
        const v = std.mem.trim(u8, s.values.get(key) orelse return fallback, " \t\r\n\x00");
        if (std.ascii.eqlIgnoreCase(v, "true")) return true;
        if (std.ascii.eqlIgnoreCase(v, "false")) return false;
        return fallback;
    }

    /// Settings.GetInt: int.TryParse or `fallback`.
    pub fn getInt(s: *const Settings, key: []const u8, fallback: i32) i32 {
        return parseInt(s.values.get(key) orelse return fallback) orelse fallback;
    }

    /// Settings.Set(key, object): bool -> "True"/"False" (like bool.ToString), integers -> decimal,
    /// strings as they are. An existing key keeps its spelling, only the value changes.
    pub fn set(s: *Settings, key: []const u8, value: anytype) !void {
        var buf: [32]u8 = undefined;
        const text: []const u8 = switch (@typeInfo(@TypeOf(value))) {
            .bool => if (value) "True" else "False",
            .int, .comptime_int => try std.mem.print(&buf, "{d}", .{value}),
            else => value,
        };
        const k = try s.gpa.dupe(u8, key);
        errdefer s.gpa.free(k);
        const v = try s.gpa.dupe(u8, text);
        errdefer s.gpa.free(v);
        const gop = try s.values.getOrPut(s.gpa, k);
        if (gop.found_existing) {
            s.gpa.free(k);
            s.gpa.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = v;
    }

    /// Settings.GetList: values of prefix1, prefix2, ... up to the first missing/empty one.
    /// The outer slice is the caller's (free with `gpa`); the strings are borrowed like `get`.
    pub fn getList(s: *const Settings, gpa: Allocator, prefix: []const u8) ![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(gpa);
        var i: usize = 1;
        while (true) : (i += 1) {
            var kb: [256]u8 = undefined;
            const v = s.get(try std.mem.print(&kb, "{s}{d}", .{ prefix, i }), "");
            if (v.len == 0) break;
            try list.append(gpa, v);
        }
        return list.toOwnedSlice(gpa);
    }

    /// Settings.SetList: drops every prefix<number> key, then writes prefix1..prefixN. `prefix` is ASCII.
    pub fn setList(s: *Settings, prefix: []const u8, items: []const []const u8) !void {
        // `items` may be borrowed from this map (getList): copy them before the old values are freed
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const copy = try arena.allocator().alloc([]const u8, items.len);
        for (items, copy) |item, *c| c.* = try arena.allocator().dupe(u8, item);

        var i = s.values.count();
        while (i > 0) {
            i -= 1;
            const k = s.values.keys()[i];
            if (!std.ascii.startsWithIgnoreCase(k, prefix) or parseInt(k[prefix.len..]) == null) continue;
            const v = s.values.values()[i];
            s.values.orderedRemoveAt(i);
            s.gpa.free(k);
            s.gpa.free(v);
        }
        for (copy, 1..) |item, n| {
            var kb: [256]u8 = undefined;
            try s.set(try std.mem.print(&kb, "{s}{d}", .{ prefix, n }), item);
        }
    }

    /// Settings.Save: "[Options]" + key=value lines (CRLF, UTF-8 without BOM). Written to a temp file and
    /// renamed over the old one, so a crash mid-save never leaves a truncated ini.
    pub fn save(s: *const Settings, io: Io) !void {
        if (path.dirname(s.path)) |d| try Io.Dir.cwd().createDirPath(io, d);
        var atomic = try Io.Dir.cwd().createFileAtomic(io, s.path, .{ .replace = true });
        defer atomic.deinit(io);
        var buf: [4096]u8 = undefined;
        var fw = atomic.file.writer(io, &buf);
        try fw.interface.writeAll("[Options]\r\n");
        for (s.values.keys(), s.values.values()) |k, v| try fw.interface.print("{s}={s}\r\n", .{ k, v });
        try fw.interface.flush();
        try atomic.replace(io);
    }
};

/// int.TryParse (NumberStyles.Integer): surrounding whitespace, optional sign, decimal digits, Int32 range.
fn parseInt(text: []const u8) ?i32 {
    const t = common.trim(text);
    if (std.mem.findScalar(u8, t, '_') != null) return null; // std accepts digit separators, .NET does not
    return std.fmt.parseInt(i32, t, 10) catch null;
}

test "Portable_dat_keeps_settings_next_to_exe" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const t = try common.TempDir.create(gpa, io, "settings");
    defer t.cleanup(gpa, io);

    const appdata = try kit.win.knownFolder(gpa, &kit.w.FOLDERID_RoamingAppData);
    defer gpa.free(appdata);
    const want = try path.join(gpa, &.{ appdata, "MakeCleaner" });
    defer gpa.free(want);
    const before = try resolveDir(gpa, io, t.path);
    defer gpa.free(before);
    try std.testing.expectEqualStrings(want, before);

    const marker = try t.join(gpa, "portable.dat");
    defer gpa.free(marker);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "#PORTABLE#" });
    const after = try resolveDir(gpa, io, t.path);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(t.path, after);

    var s = try Settings.load(gpa, io, t.path);
    defer s.deinit();
    try s.set("Temporary Files", false);
    try s.save(io);
    var again = try Settings.load(gpa, io, t.path);
    defer again.deinit();
    try std.testing.expect(!again.getBool("Temporary Files", true));
    const ini = try t.join(gpa, file_name);
    defer gpa.free(ini);
    try std.testing.expectEqual(.file, (try Io.Dir.cwd().statFile(io, ini, .{})).kind);
}

test "Lists_and_checkbox_states_survive_a_restart" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const t = try common.TempDir.create(gpa, io, "settings");
    defer t.cleanup(gpa, io);
    const dir = try t.join(gpa, "ini"); // Save creates the folder
    defer gpa.free(dir);

    var s = try Settings.load(gpa, io, dir);
    defer s.deinit();
    try s.setList("Include", &.{ "a|*.*", "b|*.*", "c|*.*" });
    try s.setList("Include", &.{"b|*.*"}); // shrinking must drop Include2/Include3
    try s.set("Temporary Files", false);
    try s.set("Custom Files and Folders", true);
    try s.save(io);

    var again = try Settings.load(gpa, io, dir);
    defer again.deinit();
    const list = try again.getList(gpa, "Include");
    defer gpa.free(list);
    try std.testing.expectEqual(1, list.len);
    try std.testing.expectEqualStrings("b|*.*", list[0]);
    try std.testing.expect(!again.getBool("Temporary Files", true));
    try std.testing.expect(again.getBool("Custom Files and Folders", false));
}

test "ini format: case-insensitive keys, TryParse fallbacks, set over a borrowed list" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const t = try common.TempDir.create(gpa, io, "settings");
    defer t.cleanup(gpa, io);
    const ini = try t.join(gpa, file_name);
    defer gpa.free(ini);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = ini, .data = "\xEF\xBB\xBF[Options]\nPasses= 3 \r\nflag=TRUE\r=x\nbad=yes\nN=99999999999\nWeird Key=a=b\nX1=one\nx2=two\nX4=four\n" });
    var s = try Settings.load(gpa, io, t.path);
    defer s.deinit();
    try std.testing.expectEqual(3, s.getInt("PASSES", 0));
    try std.testing.expectEqual(7, s.getInt("N", 7)); // out of Int32 range
    try std.testing.expect(s.getBool("Flag", false));
    try std.testing.expect(s.getBool("bad", true)); // not a bool -> fallback
    try std.testing.expectEqualStrings("a=b", s.get("weird key", ""));
    try std.testing.expectEqualStrings("-", s.get("", "-")); // "=x" has no key
    const list = try s.getList(gpa, "x");
    defer gpa.free(list);
    try std.testing.expectEqual(2, list.len); // stops at the gap before X4
    try s.setList("X", list); // items borrowed from the map itself
    try s.set("passes", 35);
    try std.testing.expectEqual(35, s.getInt("Passes", 0));
    try s.save(io);
    const text = try Io.Dir.cwd().readFileAlloc(io, ini, gpa, .limited(1 << 16));
    defer gpa.free(text);
    // first spelling of a key is kept; setList dropped X4 too (every X<number>) and appended the new list
    try std.testing.expectEqualStrings("[Options]\r\nPasses=35\r\nflag=TRUE\r\nbad=yes\r\nN=99999999999\r\nWeird Key=a=b\r\nX1=one\r\nX2=two\r\n", text);

    // Notepad's "Unicode" (UTF-16 LE + BOM) reads like the UTF-8 file; Save writes UTF-8 again.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = ini, .data = "\xFF\xFE[\x00O\x00]\x00\r\x00\n\x00K\x00=\x00\x16\x04\x10\x04\r\x00\n\x00" });
    var u = try Settings.load(gpa, io, t.path);
    defer u.deinit();
    try std.testing.expectEqualStrings("ЖА", u.get("k", ""));
}
