//! zig build test-rules: rules engine, clean pass, special procedures. Owner: MC-A.
//! Spec tests: legacy EngineTests, CustomTests, Winapp2Tests, WindowsTabTests (one Zig test per C# test,
//! named "<Class>.<Method>"). Destructive work happens only in fresh %TEMP%\makecleaner-test-* folders and
//! throwaway HKCU\Software\MakeCleanerTest-* keys.
const std = @import("std");
const kit = @import("kit");
const common = @import("core/common.zig");
const rules = @import("core/rules.zig");
const fs = @import("core/rules_fs.zig");
const engine = @import("core/engine.zig");
const cleanpass = @import("core/cleanpass.zig");
const special = @import("core/special.zig");
const custom = @import("core/custom.zig");
const reg = @import("core/reg.zig");
const elevated = @import("core/elevated.zig");
const browsers = @import("core/browsers.zig");
const Settings = @import("core/settings.zig").Settings;

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Rule = rules.Rule;
const FileInfo = common.FileInfo;
const w = kit.w;

test {
    const refAll = common.refAll;
    refAll(rules);
    refAll(fs);
    refAll(engine);
    refAll(cleanpass);
    refAll(special);
}

// ---------------------------------------------------------------- fixture

/// One fresh temp folder + an arena for everything the test builds.
const Fx = struct {
    t: common.TempDir,
    arena_state: std.heap.ArenaAllocator,

    fn init(tag: []const u8) !Fx {
        return .{ .t = try common.TempDir.create(gpa, io, tag), .arena_state = .init(gpa) };
    }

    fn deinit(f: *Fx) void {
        f.arena_state.deinit();
        f.t.cleanup(gpa, io);
    }

    fn a(f: *Fx) Allocator {
        return f.arena_state.allocator();
    }

    fn dir(f: *Fx) []const u8 {
        return f.t.path;
    }

    fn path(f: *Fx, rel: []const u8) ![]u8 {
        return Io.Dir.path.join(f.a(), &.{ f.t.path, rel });
    }

    fn fmt(f: *Fx, comptime s: []const u8, args: anytype) ![]u8 {
        return f.a().print(s, args);
    }

    /// File of `n` zero bytes at dir\rel (folders created).
    fn touch(f: *Fx, rel: []const u8, n: usize) ![]u8 {
        const p = try f.path(rel);
        try Io.Dir.cwd().createDirPath(io, Io.Dir.path.dirname(p).?);
        const data = try f.a().alloc(u8, n);
        @memset(data, 0);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = data });
        return p;
    }

    /// touch + LastWriteTimeUtc = now - hours.
    fn touchAged(f: *Fx, rel: []const u8, hours: i64) ![]u8 {
        const p = try f.touch(rel, 10);
        try setMtime(p, hoursAgo(hours));
        return p;
    }

    /// Rule.ParseIni(ini) must give exactly one rule.
    fn one(f: *Fx, ini: []const u8) !Rule {
        const list = try rules.parseIni(f.a(), ini);
        try testing.expectEqual(1, list.len);
        return list[0];
    }

    fn analyze(f: *Fx, r: *const Rule, extra: []const rules.ExcludeKey) ![]FileInfo {
        return engine.analyze(f.a(), io, r, extra, null);
    }

    /// new Settings(dir) + SetList(prefix, entries); caller deinits.
    fn with(f: *Fx, ini_dir: []const u8, prefix: []const u8, entries: []const []const u8) !Settings {
        _ = f;
        var s = try Settings.load(gpa, io, ini_dir);
        errdefer s.deinit();
        try s.setList(prefix, entries);
        return s;
    }
};

fn hoursAgo(h: i64) Io.Timestamp {
    return .fromNanoseconds(Io.Timestamp.now(io, .real).nanoseconds - @as(i96, h) * std.time.ns_per_hour);
}

/// File.SetLastWriteTimeUtc (Io.Dir.setTimestamps is a TODO panic on Windows in 0.17.1).
fn setMtime(p: []const u8, t: Io.Timestamp) !void {
    const pw = try kit.win.toW(gpa, p);
    defer gpa.free(pw);
    const h = w.CreateFileW(pw.ptr, w.FILE_WRITE_ATTRIBUTES, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE, null, w.OPEN_EXISTING, 0, null);
    if (h == w.INVALID_HANDLE_VALUE) return error.AccessDenied;
    defer _ = w.CloseHandle(h);
    const ft = fs.toFileTime(t);
    if (w.SetFileTime(h, null, null, &ft) == 0) return error.Unexpected;
}

/// Sorted file names (FileInfo.Name ... .Order()).
fn names(a: Allocator, files: []const FileInfo) ![]const []const u8 {
    const out = try a.alloc([]const u8, files.len);
    for (files, out) |f, *n| n.* = f.name();
    std.mem.sort([]const u8, out, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return out;
}

fn expectNames(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| try testing.expectEqualStrings(x, y);
}

fn find(list: []const Rule, name: []const u8) !*const Rule {
    for (list) |*r| if (std.mem.eql(u8, r.name, name)) return r;
    return error.TestRuleMissing;
}

fn keyExists(sub: []const u8) bool {
    const k = kit.win.openKey(.hkcu, sub, .{}) catch return false;
    k.close();
    return true;
}

// ---------------------------------------------------------------- EngineTests

test "EngineTests.Mask_deletes_only_matches" {
    var f = try Fx.init("eng");
    defer f.deinit();
    const a = try f.touch("a.log", 10);
    const keep = try f.touch("b.txt", 10);
    const deep = try f.touch("sub\\c.log", 10);
    const rule = try f.one(try f.fmt("[T]\nfilekey1={s}|*.log|RECURSE", .{f.dir()}));

    const found = try f.analyze(&rule, &.{});
    try testing.expectEqual(2, found.len);
    try testing.expect(fs.exists(a)); // analyze never deletes

    const r = engine.clean(gpa, io, found, 0);
    try testing.expectEqual(engine.CleanResult{ .deleted = 2, .bytes_freed = 20, .skipped = 0 }, r);
    try testing.expect(!fs.exists(a));
    try testing.expect(!fs.exists(deep));
    try testing.expect(fs.exists(keep));
}

test "EngineTests.Without_recurse_top_level_only_and_multi_pattern" {
    var f = try Fx.init("eng");
    defer f.deinit();
    _ = try f.touch("a.log", 10);
    _ = try f.touch("b.tmp", 10);
    _ = try f.touch("c.txt", 10);
    _ = try f.touch("sub\\d.log", 10);
    const rule = try f.one(try f.fmt("[T]\nFileKey1={s}|*.log;*.tmp", .{f.dir()}));
    try expectNames(&.{ "a.log", "b.tmp" }, try names(f.a(), try f.analyze(&rule, &.{})));
}

test "EngineTests.Env_vars_expand_and_unknown_ones_match_nothing" {
    var f = try Fx.init("eng");
    defer f.deinit();
    _ = try f.touch("x.tmp", 10);
    const name = kit.win.L("MC_TEST_DIR");
    const value = try kit.win.toW(f.a(), f.dir());
    try testing.expect(w.SetEnvironmentVariableW(name, value.ptr) != 0);
    defer _ = w.SetEnvironmentVariableW(name, null);
    const known = try f.one("[T]\nFileKey1=%MC_TEST_DIR%|*.tmp");
    try testing.expectEqual(1, (try f.analyze(&known, &.{})).len);
    const unknown = try f.one("[T]\nFileKey1=%MC_NO_SUCH_VAR%|*.*|RECURSE");
    try testing.expectEqual(0, (try f.analyze(&unknown, &.{})).len);
}

test "EngineTests.Locked_file_is_skipped_not_thrown" {
    var f = try Fx.init("eng");
    defer f.deinit();
    const locked = try f.touch("locked.log", 10);
    _ = try f.touch("free.log", 10);
    const rule = try f.one(try f.fmt("[T]\nFileKey1={s}|*.log", .{f.dir()}));
    const found = try f.analyze(&rule, &.{});
    {
        const lw = try kit.win.toW(f.a(), locked);
        const h = w.CreateFileW(lw.ptr, w.GENERIC_READ, 0, null, w.OPEN_EXISTING, 0, null); // FileShare.None
        try testing.expect(h != w.INVALID_HANDLE_VALUE);
        defer _ = w.CloseHandle(h);
        const r = engine.clean(gpa, io, found, 0);
        try testing.expectEqual(1, r.deleted);
        try testing.expectEqual(1, r.skipped);
    }
    try testing.expect(fs.exists(locked));
}

test "EngineTests.Pass_summarizes_per_item_reports_progress_and_cancel_leaves_nothing" {
    var f = try Fx.init("eng");
    defer f.deinit();
    _ = try f.touch("a.log", 5);
    _ = try f.touch("b.log", 7);
    _ = try f.touch("c.tmp", 3);
    const d = f.dir();
    const list = try rules.parseIni(f.a(), try f.fmt("[Logs]\nFileKey1={s}|*.log\n[All]\nFileKey1={s}|*.*\n[Empty]\nFileKey1={s}|*.none", .{ d, d, d }));
    var s = try Settings.load(gpa, io, try f.path("cfg"));
    defer s.deinit();
    var pass: cleanpass.CleanPass = .init(gpa, &s);
    defer pass.deinit();

    const Steps = struct {
        items: [8]common.Count = undefined,
        len: usize = 0,
        fn add(ctx: ?*anyopaque, c: common.Count) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.items[self.len] = c;
            self.len += 1;
        }
    };
    var steps: Steps = .{};
    try pass.analyze(io, list, &.{}, .{ .ctx = &steps, .func = Steps.add }, null);

    try testing.expectEqual(2, pass.summary.len); // shared files count once
    try testing.expectEqualStrings("Logs", pass.summary[0].name);
    try testing.expectEqual(2, pass.summary[0].items);
    try testing.expectEqual(12, pass.summary[0].bytes);
    try testing.expectEqualStrings("All", pass.summary[1].name);
    try testing.expectEqual(1, pass.summary[1].items);
    try testing.expectEqual(3, pass.summary[1].bytes);
    try testing.expectEqualSlices(common.Count, &.{ .{ .done = 0, .total = 3 }, .{ .done = 1, .total = 3 }, .{ .done = 2, .total = 3 }, .{ .done = 3, .total = 3 } }, steps.items[0..steps.len]);
    try testing.expectEqual(3, pass.files.len);

    var cancel: common.Cancel = .init(true);
    try testing.expectError(error.Canceled, pass.analyze(io, list, &.{}, null, &cancel));
    try testing.expect(!pass.any()); // a cancelled run never leaves the previous results armed for Clean
    try testing.expectEqual(0, pass.summary.len);
}

test "EngineTests.Builtin_temp_rule_targets_temp_recursively" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = try find(try rules.parseIni(arena.allocator(), engine.built_in_rules), "Temporary Files");
    try testing.expectEqual(1, r.file_keys.items.len);
    try testing.expectEqualStrings("%TEMP%", r.file_keys.items[0].path);
    try testing.expect(r.file_keys.items[0].recurse);
}

fn mentions(src: []const u8, needles: []const []const u8) ?[]const u8 {
    for (needles) |n| if (std.ascii.findIgnoreCase(src, n) != null) return n;
    return null;
}

/// First src\core\*.zig (read from disk, so files other packages add are covered) that mentions a needle.
fn coreMentions(a: Allocator, needles: []const []const u8) !?[]const u8 {
    var dir = try Io.Dir.cwd().openDir(io, try coreDir(), .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var seen: usize = 0;
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".zig")) continue;
        seen += 1;
        const src = try dir.readFileAlloc(io, e.name, a, .limited(16 << 20));
        if (mentions(src, needles)) |hit| return try a.print("{s} references {s}", .{ e.name, hit });
    }
    try testing.expect(seen >= 20); // really the core folder
    return null;
}

// C# walked the shipped assemblies' references for System.Net*. Zig has no assembly references: no core
// source (and not main.zig) may name a networking API or library. ponytail: a source scan.
test "EngineTests.No_shipped_assembly_references_networking (core sources: no networking APIs)" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const net = [_][]const u8{ "std.net", "std.http", "Io.net", "ws2_32", "wsock32", "winhttp", "wininet", "urlmon", "WSAStartup", "getaddrinfo", "InternetOpen", "WinHttpOpen", "URLDownloadToFile", "HttpSendRequest", "socket(" };
    if (try coreMentions(arena.allocator(), &net)) |hit| {
        std.debug.print("{s}\n", .{hit});
        return error.TestNetworkingReference;
    }
    try testing.expect(mentions(@embedFile("main.zig"), &net) == null);
    try testing.expect(mentions("extern \"ws2_32\" fn WSAStartup", &net) != null); // the check itself sees what it looks for
}

test "EngineTests.Core_has_no_ui_framework (core sources: no ImGui / kit.app / kit.ui)" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ui = [_][]const u8{ "kit.im", "kit.ui", "kit.app", "@import(\"im\")" };
    if (try coreMentions(arena.allocator(), &ui)) |hit| {
        std.debug.print("{s}\n", .{hit});
        return error.TestUiReference;
    }
    try testing.expect(mentions(@embedFile("main.zig"), &ui) != null); // the check itself sees UI references
}

var core_dir_buf: [1024]u8 = undefined;

/// src\core of this checkout: found upward from the current directory, then from the test exe.
fn coreDir() ![]const u8 {
    const p = try findUp("src\\core\\rules.zig");
    return std.mem.print(&core_dir_buf, "{s}", .{Io.Dir.path.dirname(p).?});
}

var find_buf: [1024]u8 = undefined;

fn findUp(rel: []const u8) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const starts = [_][]const u8{ try std.process.currentPathAlloc(io, arena.allocator()), try std.process.executableDirPathAlloc(io, arena.allocator()) };
    for (starts) |start| {
        var d: ?[]const u8 = start;
        while (d) |cur| : (d = Io.Dir.path.dirname(cur)) {
            const p = try std.mem.print(&find_buf, "{s}\\{s}", .{ cur, rel });
            if (fs.isFile(p)) return p;
        }
    }
    return error.FileNotFound;
}

// ---------------------------------------------------------------- Winapp2Tests

test "Winapp2Tests.Keys_are_case_insensitive_and_numbered" {
    var f = try Fx.init("w2");
    defer f.deinit();
    const r = try f.one(
        \\[App *]
        \\langsecref=3023
        \\DEFAULT=true
        \\Warning=Careful
        \\detect1=HKCU\Software\A
        \\Detect2=HKCU\Software\B
        \\DETECTFILE=%AppData%\A
        \\SpecialDetect=DET_CHROME
        \\DetectOS=6.1|
        \\filekey1=C:\x|*.log|RECURSE
        \\FILEKEY12=C:\y|*|REMOVESELF
        \\regkey1=HKCU\Software\A|Val
        \\ExcludeKey1=FILE|C:\x\|keep.log
    );
    try testing.expectEqualStrings("App *", r.name);
    try testing.expectEqualStrings("Multimedia", r.group());
    try testing.expect(r.default);
    try testing.expectEqualStrings("Careful", r.warning.?);
    try testing.expectEqualStrings("6.1|", r.detect_os.?);
    try testing.expectEqual(2, r.detect.items.len);
    try testing.expectEqual(1, r.detect_file.items.len);
    try testing.expectEqual(1, r.special_detect.items.len);
    try testing.expectEqual(2, r.file_keys.items.len);
    try testing.expect(r.file_keys.items[0].recurse and r.file_keys.items[1].recurse);
    try testing.expect(!r.file_keys.items[0].remove_self and r.file_keys.items[1].remove_self);
    try testing.expectEqual(1, r.reg_keys.items.len);
    try testing.expect(r.reg_keys.items[0].eql(.{ .key = "HKCU\\Software\\A", .value = "Val" }));
    try testing.expectEqual(rules.ExcludeKey.Kind.file, r.excludes.items[0].kind);
    try testing.expectEqualStrings("C:\\x\\", r.excludes.items[0].path);
    try testing.expectEqualStrings("keep.log", r.excludes.items[0].patterns[0]);
    try testing.expectEqualStrings("Games", (try f.one("[G]\nSection=Games\nLangSecRef=3021")).group());
    try testing.expect(!(try f.one("[N]")).default);
}

test "Winapp2Tests.Recurse_removeself_and_top_level_only" {
    var f = try Fx.init("w2");
    defer f.deinit();
    for ([_][]const u8{ "plain\\a.log", "plain\\sub\\b.log", "rec\\a.log", "rec\\sub\\b.log", "self\\a.log", "self\\sub\\b.log" }) |p| _ = try f.touch(p, 10);
    const d = f.dir();
    const r = try f.one(try f.fmt("[T]\nFileKey1={s}\\plain|*.log\nFileKey2={s}\\rec|*.log|RECURSE\nFileKey3={s}\\self|*|REMOVESELF", .{ d, d, d }));

    const found = try f.analyze(&r, &.{});
    try testing.expectEqual(5, found.len); // plain\sub\b.log is not reached
    _ = engine.clean(gpa, io, found, 0);
    _ = engine.removeEmptyDirs(gpa, io, &r);

    try testing.expect(fs.exists(try f.path("plain\\sub\\b.log")));
    try testing.expect(fs.isDir(try f.path("rec\\sub"))); // RECURSE keeps folders
    try testing.expect(!fs.exists(try f.path("self"))); // REMOVESELF drops the folder itself
}

test "Winapp2Tests.Removeself_keeps_folder_with_leftovers" {
    var f = try Fx.init("w2");
    defer f.deinit();
    _ = try f.touch("self\\a.log", 10);
    _ = try f.touch("self\\keep.txt", 10);
    const r = try f.one(try f.fmt("[T]\nFileKey1={s}\\self|*.log|REMOVESELF", .{f.dir()}));
    _ = engine.clean(gpa, io, try f.analyze(&r, &.{}), 0);
    _ = engine.removeEmptyDirs(gpa, io, &r);
    try testing.expect(fs.exists(try f.path("self\\keep.txt")));
}

test "Winapp2Tests.Wildcards_in_path_segments" {
    var f = try Fx.init("w2");
    defer f.deinit();
    _ = try f.touch("Packages\\AppA_1\\AC\\Temp\\x.tmp", 10);
    _ = try f.touch("Packages\\AppB_2\\AC\\Temp\\y.tmp", 10);
    _ = try f.touch("Packages\\Other\\AC\\Temp\\z.tmp", 10);
    const r = try f.one(try f.fmt("[T]\nFileKey1={s}\\Packages\\App*\\AC\\Temp|*.tmp", .{f.dir()}));
    try expectNames(&.{ "x.tmp", "y.tmp" }, try names(f.a(), try f.analyze(&r, &.{})));
}

test "Winapp2Tests.ExcludeKey_file_and_path_protect_matches" {
    var f = try Fx.init("w2");
    defer f.deinit();
    for ([_][]const u8{ "c\\keep.log", "c\\gone.log", "c\\sub\\gone2.log", "c\\db\\a.db", "c\\db\\b.log" }) |p| _ = try f.touch(p, 10);
    const d = f.dir();
    const r = try f.one(try f.fmt(
        \\[T]
        \\FileKey1={s}\c|*|RECURSE
        \\ExcludeKey1=FILE|{s}\c\|keep.log
        \\ExcludeKey2=PATH|{s}\c\db\|*.db
    , .{ d, d, d }));
    try expectNames(&.{ "b.log", "gone.log", "gone2.log" }, try names(f.a(), try f.analyze(&r, &.{})));
}

test "Winapp2Tests.RegKey_deletes_key_or_value_and_ExcludeKey_reg_protects" {
    var f = try Fx.init("w2");
    defer f.deinit();
    const tk = try common.TestKey.create(gpa, io, "w2");
    defer tk.cleanup(gpa);
    {
        const k = try kit.win.createKey(.hkcu, try f.fmt("{s}\\Gone", .{tk.sub}), .default);
        defer k.close();
        try k.writeDword("x", 1);
    }
    {
        const k = try kit.win.createKey(.hkcu, try f.fmt("{s}\\Vals", .{tk.sub}), .default);
        defer k.close();
        try k.writeString("drop", "1");
        try k.writeString("stay", "1");
    }
    (try kit.win.createKey(.hkcu, try f.fmt("{s}\\Kept\\Child", .{tk.sub}), .default)).close();
    const h = tk.full;
    const r = try f.one(try f.fmt(
        \\[T]
        \\RegKey1={s}\Gone
        \\RegKey2={s}\Vals|drop
        \\RegKey3={s}\Kept\Child
        \\RegKey4={s}\Missing
        \\ExcludeKey1=REG|{s}\Kept
    , .{ h, h, h, h, h }));

    const targets = try engine.analyzeRegistry(f.a(), &r, &.{});
    try testing.expectEqual(2, targets.len); // Missing doesn't exist, Kept is excluded
    try testing.expectEqual(2, engine.cleanRegistry(targets).deleted);

    try testing.expect(!keyExists(try f.fmt("{s}\\Gone", .{tk.sub})));
    const vals = try kit.win.openKey(.hkcu, try f.fmt("{s}\\Vals", .{tk.sub}), .{});
    defer vals.close();
    const v = try vals.values(f.a());
    try testing.expectEqual(1, v.len);
    try testing.expectEqualStrings("stay", v[0].name);
    try testing.expect(keyExists(try f.fmt("{s}\\Kept\\Child", .{tk.sub})));
}

test "Winapp2Tests.Top_level_hive_keys_are_never_deleted" {
    // the guard first: if a bare hive could be opened for writing, the deletes below would be dangerous
    try testing.expect(reg.tryOpen("HKCU", true, .default) == null);
    try testing.expect(!reg.delete(.{ .key = "HKCU\\Software" }));
    try testing.expect(!reg.delete(.{ .key = "HKCU" }));
    try testing.expect(keyExists("Software"));
}

test "Winapp2Tests.Detection_by_registry_file_wildcard_and_os" {
    var f = try Fx.init("w2");
    defer f.deinit();
    const tk = try common.TestKey.create(gpa, io, "w2");
    defer tk.cleanup(gpa);
    (try kit.win.createKey(.hkcu, try f.fmt("{s}\\Installed", .{tk.sub}), .default)).close();
    _ = try f.touch("Vendor\\Product 2024\\app.exe", 10);
    const d = f.dir();
    const h = tk.full;
    const Case = struct { []const u8, bool };
    const cases = [_]Case{
        .{ "[T]", true }, // no detection keys = always shown
        .{ try f.fmt("[T]\nDetect1=HKCU\\Software\\NoSuchKey_mc\nDetect2={s}\\Installed", .{h}), true },
        .{ try f.fmt("[T]\nDetect={s}\\NotInstalled", .{h}), false },
        .{ try f.fmt("[T]\nDetectFile={s}\\Vendor\\Product*", .{d}), true },
        .{ try f.fmt("[T]\nDetectFile={s}\\Vendor\\*\\app.exe", .{d}), true },
        .{ try f.fmt("[T]\nDetectFile={s}\\Vendor\\Nope*", .{d}), false },
        .{ "[T]\nSpecialDetect=DET_UNKNOWN", false },
        .{ try f.fmt("[T]\nDetectOS=99.0|\nDetect={s}\\Installed", .{h}), false }, // OS gate wins
    };
    for (cases) |c| {
        const r = try f.one(c[0]);
        testing.expectEqual(c[1], r.isDetected(gpa, io)) catch |e| {
            std.debug.print("case: {s}\n", .{c[0]});
            return e;
        };
    }
}

test "Winapp2Tests.DetectOS_min_max (6 InlineData rows)" {
    const os: kit.win.OsVersion = .{ .major = 10, .minor = 0, .build = 26300 };
    const rows = [_]struct { []const u8, bool }{
        .{ "6.1|", true },
        .{ "|6.3", false },
        .{ "10.0|10.0", true },
        .{ "10.0.21996|", true },
        .{ "10.0.30000|", false },
        .{ "|10.0.21995", false },
    };
    for (rows) |row| {
        testing.expectEqual(row[1], rules.paths.osInRange(row[0], os)) catch |e| {
            std.debug.print("row: {s}\n", .{row[0]});
            return e;
        };
    }
}

test "Winapp2Tests.ProgramFiles_expands_to_both_folders_and_unknown_var_to_nothing" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const pf = try rules.paths.expandVars(a, "%ProgramFiles%\\X");
    try testing.expectEqual(2, pf.len);
    try testing.expect(std.mem.find(u8, pf[0], "(x86)") != null or std.mem.find(u8, pf[1], "(x86)") != null);
    try testing.expectEqual(0, (try rules.paths.expandVars(a, "%MC_NO_SUCH_VAR%\\X")).len);
    const low = try rules.paths.expandVars(a, "%LocalLowAppData%\\X");
    try testing.expectEqual(1, low.len);
    try testing.expect(std.mem.endsWith(u8, low[0], "AppData\\LocalLow\\X"));
}

test "Winapp2Tests.Drive_root_is_never_swept_recursively" {
    var f = try Fx.init("w2");
    defer f.deinit();
    const root = f.dir()[0..2]; // "C:"
    // A pre-cancelled token makes any enumeration fail with error.Canceled, so "0 results, no error" proves the
    // guard refused the key before listing anything (the C# test could not fail: it only matched nothing).
    var cancel: common.Cancel = .init(true);
    const listed = try f.one(try f.fmt("[T]\nFileKey1={s}\\|*.mc_none_", .{root})); // non-recursive root: allowed
    try testing.expectError(error.Canceled, engine.analyze(f.a(), io, &listed, &.{}, &cancel)); // the probe sees listing
    const refused = [_][]const u8{
        "{s}|*.mc_none_|RECURSE",
        "{s}\\Windows\\..|*.mc_none_|RECURSE", // resolves to the root
        "{s}\\*|*.mc_none_|RECURSE", // every top-level folder (Windows, Program Files, Users)
        "{s}\\*.*|*.mc_none_", // even non-recursive: files right inside C:\Windows etc.
        "{s}\\Windows\\..\\?*|*.mc_none_|RECURSE",
        "{s}\\Use?s|*.mc_none_|REMOVESELF", // a partial wildcard never reaches Users / Windows / hidden ProgramData
        "{s}\\Win?ows\\Temp|*.mc_none_|RECURSE",
        "{s}\\Program?ata|*.mc_none_|RECURSE",
    };
    inline for (refused) |key| {
        const r = try f.one(try f.fmt("[T]\nFileKey1=" ++ key, .{root}));
        testing.expectEqual(0, (try engine.analyze(f.a(), io, &r, &.{}, &cancel)).len) catch |e| {
            std.debug.print("key: {s}\n", .{key});
            return e;
        };
    }
    try testing.expect(try fs.isRoot(f.a(), "C:\\"));
    try testing.expect(try fs.isRoot(f.a(), "C:\\Windows\\.."));
    try testing.expect(!try fs.isRoot(f.a(), f.dir()));
    const env = [_]struct { []const u8, engine.RootWildcard }{
        .{ "C:\\*", .generic },                  .{ "C:\\*.*", .generic },   .{ "%SystemDrive%\\?*", .generic },
        .{ "C:\\Windows\\..\\*", .generic },     .{ "C:\\Prog*", .partial }, .{ "%SystemDrive%\\*.tmp", .partial },
        .{ "C:\\Windows\\..\\Us?rs", .partial }, .{ "C:\\Users\\*", .none }, .{ "%LocalAppData%\\*", .none },
        .{ "C:\\Windows", .none }, .{ "%MC_NO_SUCH_VAR%\\*", .none }, // expands to nothing
    };
    for (env) |c| {
        testing.expectEqual(c[1], try engine.rootWildcard(f.a(), c[0])) catch |e| {
            std.debug.print("rootWildcard {s}\n", .{c[0]});
            return e;
        };
    }
}

test "Root wildcard guard: no bundled Winapp2 / Windows.ini FileKey is generic" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try Io.Dir.cwd().readFileAlloc(io, try findUp("rules\\Winapp2.ini"), a, .unlimited);
    var partial: usize = 0;
    for ([_][]const u8{ text, engine.built_in_rules }) |ini| for (try rules.parseIni(a, ini)) |r| for (r.file_keys.items) |k| {
        switch (try engine.rootWildcard(a, k.path)) {
            .none => {},
            .partial => partial += 1, // "%SystemDrive%\*.tmp", "%SystemDrive%\Python*": still cleaned
            .generic => {
                std.debug.print("{s}: {s}\n", .{ r.name, k.path });
                return error.TestGuardDropsBundledRule;
            },
        }
    };
    try testing.expect(partial >= 3);
}

test "Winapp2Tests.Bundled_winapp2_parses_completely" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try Io.Dir.cwd().readFileAlloc(io, try findUp("rules\\Winapp2.ini"), a, .unlimited);
    const list = try rules.parseIni(a, text);
    try testing.expect(list.len > 4000);
    var warned = false;
    var remove_self = false;
    for (list) |r| {
        if (r.file_keys.items.len + r.reg_keys.items.len == 0) {
            std.debug.print("no keys: {s}\n", .{r.name});
            return error.TestRuleWithoutKeys;
        }
        warned = warned or r.warning != null;
        for (r.file_keys.items) |k| remove_self = remove_self or k.remove_self;
    }
    try testing.expect(warned and remove_self);
}

test "Winapp2Tests.User_winapp2_next_to_exe_is_picked_up_and_overrides" {
    var f = try Fx.init("w2");
    defer f.deinit();
    try Io.Dir.cwd().createDirPath(io, try f.path("rules"));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try f.path("rules\\Winapp2.ini"), .data = "[Shared]\nWarning=bundled\nFileKey1=C:\\a|*\n[Bundled only]\nDetect=HKCU\\Software\\NoSuchKey_mc\nFileKey1=C:\\a|*" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try f.path("winapp2.ini"), .data = "[Shared]\nWarning=user\nFileKey1=C:\\a|*\n[Mine]\nFileKey1=C:\\b|*" });
    const list = try rules.loadApplications(f.a(), io, f.dir());
    try testing.expectEqual(2, list.len); // undetected bundled entry hidden
    try testing.expectEqualStrings("Mine", list[0].name); // group "Other" for both, then by name
    try testing.expectEqualStrings("Shared", list[1].name);
    try testing.expectEqualStrings("user", list[1].warning.?);
}

// ---------------------------------------------------------------- CustomTests (the engine-backed ones)

test "CustomTests.Include_modes_and_age_go_through_the_engine" {
    var f = try Fx.init("t04");
    defer f.deinit();
    const ini = try common.TempDir.create(gpa, io, "t04-ini");
    defer ini.cleanup(gpa, io);
    _ = try f.touchAged("top.log", 48);
    _ = try f.touchAged("new.log", 0);
    _ = try f.touchAged("sub\\deep.log", 48);
    const d = f.dir();
    const Case = struct { []const u8, []const []const u8 };
    const cases = [_]Case{
        .{ try f.fmt("{s}|*.log", .{d}), &.{ "new.log", "top.log" } },
        .{ try f.fmt("{s}|*.*|RECURSE", .{d}), &.{ "deep.log", "new.log", "top.log" } },
        .{ try f.fmt("{s}|*.*|RECURSE|OLDER=24", .{d}), &.{ "deep.log", "top.log" } },
        .{ try f.fmt("{s}|new.log", .{d}), &.{"new.log"} }, // single file
    };
    for (cases) |c| {
        var s = try f.with(ini.path, "Include", &.{c[0]});
        defer s.deinit();
        const r = try custom.includeRule(f.a(), &s);
        expectNames(c[1], try names(f.a(), try f.analyze(&r, &.{}))) catch |e| {
            std.debug.print("include: {s}\n", .{c[0]});
            return e;
        };
    }
    var s = try f.with(ini.path, "Include", &.{try f.fmt("{s}\\sub|*.*|REMOVESELF", .{d})});
    defer s.deinit();
    const remove_self = try custom.includeRule(f.a(), &s);
    _ = engine.clean(gpa, io, try f.analyze(&remove_self, &.{}), 0);
    _ = engine.removeEmptyDirs(gpa, io, &remove_self);
    try testing.expect(!fs.exists(try f.path("sub")));
}

test "CustomTests.System_paths_are_rejected_and_never_loaded" {
    var f = try Fx.init("t04");
    defer f.deinit();
    const ini = try common.TempDir.create(gpa, io, "t04-ini");
    defer ini.cleanup(gpa, io);
    const a = f.a();
    const profile = try kit.win.knownFolder(a, &w.FOLDERID_Profile);
    const bad = [_][]const u8{
        "C:\\",                                              "C:",                "D:\\",
        try kit.win.knownFolder(a, &w.FOLDERID_Windows),     "%windir%\\Temp",    try kit.win.knownFolder(a, &w.FOLDERID_ProgramFiles),
        try kit.win.knownFolder(a, &w.FOLDERID_ProgramData), profile,             Io.Dir.path.dirname(profile).?,
        "relative\\dir",                                     "\\\\server\\share",
    };
    for (bad) |p| {
        const why = (try custom.reject(gpa, p)) orelse {
            std.debug.print("not rejected: {s}\n", .{p});
            return error.TestExpectedRejected;
        };
        gpa.free(why);
    }
    try testing.expectEqual(null, try custom.reject(gpa, f.dir()));
    try testing.expectEqual(null, try custom.reject(gpa, try f.fmt("{s}\\Downloads", .{profile})));

    // a hand-edited ini cannot smuggle C:\ in
    var s = try f.with(ini.path, "Include", &.{ "C:\\|*.*|RECURSE", try f.fmt("{s}|*.*", .{f.dir()}) });
    defer s.deinit();
    try testing.expectEqual(1, (try custom.includeRule(a, &s)).file_keys.items.len);
}

test "CustomTests.Exclude_hides_files_from_every_rule" {
    var f = try Fx.init("t04");
    defer f.deinit();
    const ini = try common.TempDir.create(gpa, io, "t04-ini");
    defer ini.cleanup(gpa, io);
    _ = try f.touch("keep.log", 10);
    _ = try f.touch("gone.log", 10);
    _ = try f.touch("private\\secret.log", 10);
    const d = f.dir();
    const winapp2_style = try f.one(try f.fmt("[Some App]\nFileKey1={s}|*.log|RECURSE", .{d}));
    var inc = try f.with(ini.path, "Include", &.{try f.fmt("{s}|*.*|RECURSE", .{d})});
    defer inc.deinit();
    const include = try custom.includeRule(f.a(), &inc);
    var s = try f.with(ini.path, "Exclude", &.{ try f.fmt("PATH|{s}\\private", .{d}), try f.fmt("FILE|{s}|keep.log", .{d}) });
    defer s.deinit();
    const ex = try custom.excludes(f.a(), &s);

    try expectNames(&.{"gone.log"}, try names(f.a(), try f.analyze(&winapp2_style, ex)));
    try expectNames(&.{"gone.log"}, try names(f.a(), try f.analyze(&include, ex)));
    try testing.expectEqual(3, (try f.analyze(&winapp2_style, &.{})).len); // without the list nothing is hidden
}

test "CustomTests.Registry_exclude_is_shared_by_rules_and_registry_cleaner" {
    var f = try Fx.init("t04");
    defer f.deinit();
    const ini = try common.TempDir.create(gpa, io, "t04-ini");
    defer ini.cleanup(gpa, io);
    const tk = try common.TestKey.create(gpa, io, "t04");
    defer tk.cleanup(gpa);
    {
        const k = try kit.win.createKey(.hkcu, tk.sub, .default);
        defer k.close();
        try k.writeDword("v", 1);
    }
    (try kit.win.createKey(.hkcu, try f.fmt("{s}\\child", .{tk.sub}), .default)).close();
    const rule = try f.one(try f.fmt("[R]\nRegKey1={s}|v\nRegKey2={s}\\child", .{ tk.full, tk.full }));
    var s = try f.with(ini.path, "Exclude", &.{try f.fmt("REG|{s}\\child", .{tk.full})});
    defer s.deinit();
    try custom.addExclude(gpa, io, &s, try f.fmt("REG|{s}|v", .{tk.full}));

    try testing.expectEqual(2, (try engine.analyzeRegistry(f.a(), &rule, &.{})).len);
    try testing.expectEqual(0, (try engine.analyzeRegistry(f.a(), &rule, try custom.excludes(f.a(), &s))).len);
    try expectNames(&.{ try f.fmt("{s}\\child", .{tk.full}), try f.fmt("{s}\\v", .{tk.full}) }, try custom.registryExcludes(f.a(), &s));
}

// ---------------------------------------------------------------- WindowsTabTests

test "WindowsTabTests.Rule_set_groups_specials_and_warnings_are_consistent" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const windows = try rules.parseIni(arena.allocator(), engine.built_in_rules);
    // Edge lives in the Browsers tab (browsers.zig), not in rules\Windows.ini.
    var groups: std.ArrayList([]const u8) = .empty;
    for (windows) |*r| {
        for (groups.items) |g| {
            if (std.mem.eql(u8, g, r.group())) break;
        } else try groups.append(arena.allocator(), r.group());
    }
    try expectNames(&.{ "Windows Explorer", "System", "Advanced" }, groups.items);
    for (windows) |r| for (r.special_keys.items) |k| {
        var known = std.ascii.eqlIgnoreCase(k, special.wipe_free_space);
        for (special.file_keys ++ special.action_keys) |x| known = known or std.ascii.eqlIgnoreCase(k, x);
        if (!known) {
            std.debug.print("unknown SpecialKey {s}\n", .{k});
            return error.TestUnknownSpecialKey;
        }
    };
    for (windows) |*r| if (std.mem.eql(u8, r.group(), "Advanced")) {
        testing.expect(!r.default and r.warning != null) catch |e| {
            std.debug.print("{s}\n", .{r.name});
            return e;
        };
    };
    for (windows, 0..) |a, i| for (windows[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a.name, b.name));
    try testing.expectEqualStrings("TempOlderThan24h", (try find(windows, "Temporary Files")).age_option.?);
    try testing.expectEqualStrings("RecycleBinOlderThan24h", (try find(windows, "Empty Recycle Bin")).age_option.?);
}

test "WindowsTabTests.Age_option_keeps_recent_files" {
    var f = try Fx.init("t03");
    defer f.deinit();
    const old = try f.touchAged("old.tmp", 30);
    _ = try f.touch("new.tmp", 10);
    var rule = try f.one(try f.fmt("[T]\nFileKey1={s}|*.tmp", .{f.dir()}));
    try testing.expectEqual(2, (try f.analyze(&rule, &.{})).len);
    rule.older_than_hours = 24;
    const found = try f.analyze(&rule, &.{});
    try testing.expectEqual(1, found.len);
    try testing.expectEqualStrings(old, found[0].path);
}

/// $I layout: version (8) + original size (8) + deletion FILETIME (8) + path...
fn binItem(f: *Fx, bin: []const u8, id: []const u8, deleted: Io.Timestamp, folder: bool) !void {
    var meta: [40]u8 = @splat(0);
    std.mem.writeInt(i64, meta[0..8], 2, .little);
    const ft = fs.toFileTime(deleted);
    std.mem.writeInt(u32, meta[16..20], ft.dwLowDateTime, .little);
    std.mem.writeInt(u32, meta[20..24], ft.dwHighDateTime, .little);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try f.fmt("{s}\\$I{s}", .{ bin, id }), .data = &meta });
    if (folder) {
        _ = try f.touch(try f.fmt("{s}\\$R{s}\\deep\\x.bin", .{ Io.Dir.path.basename(bin), id }), 10);
    } else {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try f.fmt("{s}\\$R{s}", .{ bin, id }), .data = "12345" });
    }
}

test "WindowsTabTests.Recycle_bin_lists_metadata_and_content_and_honours_deletion_age" {
    var f = try Fx.init("t03");
    defer f.deinit();
    const bin = try f.path("S-1-5-21-test");
    try Io.Dir.cwd().createDirPath(io, bin);
    const now: Io.Timestamp = .fromNanoseconds(1792670400 * std.time.ns_per_s); // 2026-10-22 12:00:00 UTC
    try binItem(&f, bin, "OLD.txt", .fromNanoseconds(now.nanoseconds - 3 * std.time.ns_per_day), false);
    try binItem(&f, bin, "NEW", .fromNanoseconds(now.nanoseconds - std.time.ns_per_hour), true);

    const all = try special.recycleBin(f.a(), io, &.{bin}, null, now);
    try expectNames(&.{ "$INEW", "$IOLD.txt", "$ROLD.txt", "x.bin" }, try names(f.a(), all));
    const old = try special.recycleBin(f.a(), io, &.{bin}, 24, now);
    try expectNames(&.{ "$IOLD.txt", "$ROLD.txt" }, try names(f.a(), old));
}

/// A .lnk through IShellLinkW + IPersistFile::Save (the C# test used WScript.Shell).
fn makeLink(a: Allocator, lnk: []const u8, target: []const u8) !void {
    var link: [*c]w.IShellLinkW = null;
    try kit.win.check(w.CoCreateInstance(&w.CLSID_ShellLink, null, w.CLSCTX_INPROC_SERVER, &w.IID_IShellLinkW, @ptrCast(&link)));
    defer kit.win.release(link);
    try kit.win.check(link.*.lpVtbl.*.SetPath.?(link, (try kit.win.toW(a, target)).ptr));
    var pf: [*c]w.IPersistFile = null;
    try kit.win.check(link.*.lpVtbl.*.QueryInterface.?(link, &w.IID_IPersistFile, @ptrCast(&pf)));
    defer kit.win.release(pf);
    try kit.win.check(pf.*.lpVtbl.*.Save.?(pf, (try kit.win.toW(a, lnk)).ptr, 1));
}

test "WindowsTabTests.Broken_shortcuts_only_for_missing_local_targets" {
    var f = try Fx.init("t03");
    defer f.deinit();
    const com = w.CoInitializeEx(null, @intCast(w.COINIT_APARTMENTTHREADED));
    defer if (com >= 0) w.CoUninitialize();
    const existing = try f.touch("real.txt", 10);
    try makeLink(f.a(), try f.path("ok.lnk"), existing);
    try makeLink(f.a(), try f.path("broken.lnk"), try f.path("gone\\missing.exe"));
    try makeLink(f.a(), try f.path("network.lnk"), "\\\\nonexistent-host\\share\\app.exe");

    try expectNames(&.{"broken.lnk"}, try names(f.a(), try special.brokenShortcuts(f.a(), io, &.{f.dir()})));
}

test "WindowsTabTests.Action_items_are_described_not_run_by_analyze" {
    elevated.Fake.install(); // insurance: nothing here may reach UAC
    defer elevated.Fake.uninstall();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const windows = try rules.parseIni(a, engine.built_in_rules);
    const dns = try find(windows, "DNS Cache");
    const acts = try engine.analyzeActions(a, io, dns);
    try testing.expectEqual(1, acts.len);
    try testing.expectEqualStrings("DNS resolver cache", acts[0].label);
    try testing.expectEqual(1, (try engine.analyzeActions(a, io, try find(windows, "Windows Event Logs"))).len);
    try testing.expectEqual(0, (try engine.analyze(a, io, dns, &.{}, null)).len); // action rules add no files
    try testing.expectEqual(0, elevated.Fake.calls);
}

// ---------------------------------------------------------------- port-specific checks

test "CleanPass: Windows/Applications lists, analyze + clean status lines" {
    var f = try Fx.init("pass");
    defer f.deinit();
    const win_rules = try cleanpass.windowsRules(f.a(), io);
    const last = win_rules[win_rules.len - 1];
    try testing.expectEqualStrings(custom.rule_name, last.name);
    try testing.expectEqualStrings("Advanced", last.group());
    try testing.expect(cleanpass.isWipe(try find(win_rules, "Wipe Free Space")));

    // the Browsers tab replaces Winapp2's browser sections
    try Io.Dir.cwd().createDirPath(io, try f.path("app\\rules"));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try f.path("app\\rules\\Winapp2.ini"), .data = "[Google Chrome *]\nSection=Google Chrome Web Browser\nFileKey1=C:\\a|*\n[Other App *]\nFileKey1=C:\\a|*" });
    const apps = try cleanpass.appRules(f.a(), io, try f.path("app"));
    try testing.expectEqual(1, apps.len);
    try testing.expectEqualStrings("Other App *", apps[0].name);

    _ = try f.touch("data\\a.log", 5);
    _ = try f.touch("data\\b.log", 7);
    _ = try f.touch("data\\keep.txt", 3);
    var s = try Settings.load(gpa, io, try f.path("cfg"));
    defer s.deinit();
    var pass: cleanpass.CleanPass = .init(gpa, &s);
    defer pass.deinit();
    const list = try rules.parseIni(f.a(), try f.fmt("[Logs]\nFileKey1={s}\\data|*.log|REMOVESELF", .{f.dir()}));
    try pass.analyze(io, list, &.{}, null, null);
    try testing.expect(pass.any() and !pass.wipe());
    const analyzed = try pass.analyzeSummary(gpa);
    defer gpa.free(analyzed);
    try testing.expectEqualStrings("Analysis complete: 2 files, 12 B to be removed, 0 registry entries", analyzed);
    const cleaned = try pass.clean(gpa, io, &.{}, null);
    defer gpa.free(cleaned);
    try testing.expectEqualStrings("Cleaning complete: 2 files removed, 12 B freed, 0 skipped (in use), 0 registry entries removed, 0 skipped", cleaned);
    try testing.expect(!pass.any());
    try testing.expect(fs.exists(try f.path("data\\keep.txt"))); // REMOVESELF keeps a folder with leftovers
    try testing.expect(!fs.exists(try f.path("data\\a.log")));

    // a running browser's rules are skipped: its files stay
    _ = try f.touch("brw\\cache.bin", 4);
    const brw = try rules.parseIni(f.a(), try f.fmt("[Google Chrome: Cache]\nFileKey1={s}\\brw|*.*", .{f.dir()}));
    try pass.analyze(io, brw, &.{}, null, null);
    const skipped = try pass.clean(gpa, io, &.{"Google Chrome"}, null);
    defer gpa.free(skipped);
    try testing.expect(std.mem.endsWith(u8, skipped, "0 files removed, 0 B freed, 0 skipped (in use), 0 registry entries removed, 0 skipped, skipped running: Google Chrome"));
    try testing.expect(fs.exists(try f.path("brw\\cache.bin")));
}

test "Win32 wildcard semantics: enumeration patterns are translated, Paths.Matches is not" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Row = struct { []const u8, []const u8, bool };
    const enumeration = [_]Row{
        .{ "*.*", "README", true }, // *.* matches names without a dot
        .{ "*", "README", true },
        .{ "*.", "README", true }, // "*." = no extension
        .{ "*.", "a.txt", false },
        .{ "*.log", "A.LOG", true },
        .{ "*.log", "a.logx", false },
        .{ "File*.chk", "FILE0001.CHK", true },
        .{ "thumbcache_*.db", "thumbcache_32.db", true },
        .{ "a?c", "abc", true },
        .{ "a?c", "a.c", false }, // DOS_QM never matches '.'
        .{ "a?", "a", true }, // DOS_QM matches zero characters at the end
        .{ "$I*", "$IOLD.txt", true },
        .{ "*.ЛОГ", "файл.лог", true },
        .{ "found.*", "found.000", true },
        .{ "found.*", "found", true }, // DOS_DOT: '.' or the end
    };
    for (enumeration) |r| {
        const got = fs.matchW(try fs.translate(a, r[0]), try std.unicode.wtf8ToWtf16LeAlloc(a, r[1]));
        testing.expectEqual(r[2], got) catch |e| {
            std.debug.print("enumeration {s} vs {s}\n", .{ r[0], r[1] });
            return e;
        };
    }
    const direct = [_]Row{
        .{ "*.*", "README", false }, // untranslated: needs a dot
        .{ "*.*", "a.b", true },
        .{ "*", "x", true },
        .{ "a?c", "a.c", true },
        .{ " keep.log ", "KEEP.LOG", true }, // pattern trimmed, case-insensitive
        .{ "*.db", "a.db", true },
        .{ "*.db", "a.dbx", false },
    };
    for (direct) |r| {
        testing.expectEqual(r[2], rules.paths.matches(r[0], r[1])) catch |e| {
            std.debug.print("matches {s} vs {s}\n", .{ r[0], r[1] });
            return e;
        };
    }
    // and through the engine: *.* takes the file without an extension too
    var f = try Fx.init("wild");
    defer f.deinit();
    _ = try f.touch("noext", 1);
    _ = try f.touch("x.y", 1);
    const all = try f.one(try f.fmt("[T]\nFileKey1={s}|*.*", .{f.dir()}));
    try expectNames(&.{ "noext", "x.y" }, try names(f.a(), try f.analyze(&all, &.{})));
}

test "Junctions are never followed: Analyze, RemoveEmptyDirs and wildcard segments stay out of the target" {
    var f = try Fx.init("junction");
    defer f.deinit();
    const target_file = try f.touch("outside\\precious.log", 10);
    _ = try f.touch("scan\\own.log", 10);
    try Io.Dir.cwd().createDirPath(io, try f.path("scan\\Apps"));
    const link = try f.path("scan\\linked");
    if (!try junction(link, try f.path("outside"))) return error.SkipZigTest;
    defer _ = fs.removeDir(link); // the link only, before the fixture is deleted
    try testing.expect(fs.stat(link).?.attrs & fs.attr_reparse != 0);

    const d = f.dir();
    const rule = try f.one(try f.fmt("[T]\nFileKey1={s}\\scan|*.log|REMOVESELF\nFileKey2={s}\\scan\\l*|*.log", .{ d, d }));
    try expectNames(&.{"own.log"}, try names(f.a(), try f.analyze(&rule, &.{})));
    _ = engine.clean(gpa, io, try f.analyze(&rule, &.{}), 0);
    _ = engine.removeEmptyDirs(gpa, io, &rule);
    try testing.expect(fs.exists(target_file));
    try testing.expect(fs.exists(link)); // the junction holds content, so scan\ stays
    try testing.expect(!fs.exists(try f.path("scan\\Apps"))); // a real empty folder still goes
}

/// mklink /J link target; false when junctions are unavailable here (FAT, policy).
fn junction(link: []const u8, target: []const u8) !bool {
    const r = try std.process.run(gpa, io, .{ .argv = &.{ "cmd.exe", "/c", "mklink", "/J", link, target } });
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    return r.term.success();
}

test "Recycle bin: a recycled junction never exposes its target; AfterClean drops only emptied $R folders" {
    var f = try Fx.init("bin");
    defer f.deinit();
    const bin = try f.path("S-1-5-21-test");
    try Io.Dir.cwd().createDirPath(io, bin);
    const now: Io.Timestamp = .fromNanoseconds(1792670400 * std.time.ns_per_s);
    const precious = try f.touch("outside\\precious.txt", 10);
    try Io.Dir.cwd().createDirPath(io, try f.path("empty-target"));
    try binItem(&f, bin, "FULL", now, true); // $RFULL\deep\x.bin
    try Io.Dir.cwd().createDirPath(io, try f.path("S-1-5-21-test\\$REMPTY\\a\\b")); // emptied folder tree
    const j = try f.fmt("{s}\\$RJ", .{bin});
    const j_empty = try f.fmt("{s}\\$RJE", .{bin});
    if (!try junction(j, try f.path("outside"))) return error.SkipZigTest;
    defer _ = fs.removeDir(j);
    if (!try junction(j_empty, try f.path("empty-target"))) return error.SkipZigTest;
    defer _ = fs.removeDir(j_empty);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try f.fmt("{s}\\$IJ", .{bin}), .data = &@as([24]u8, @splat(0)) });

    const listed = try special.recycleBin(f.a(), io, &.{bin}, null, now);
    try expectNames(&.{ "$IFULL", "$IJ", "x.bin" }, try names(f.a(), listed)); // not precious.txt
    _ = engine.clean(gpa, io, listed, 0);
    try testing.expect(fs.exists(precious));

    try binItem(&f, bin, "KEEP", now, true); // a $R folder that still holds a file
    special.removeEmptyItems(f.a(), &.{bin});
    try testing.expect(!fs.exists(try f.fmt("{s}\\$RFULL", .{bin}))); // emptied by clean
    try testing.expect(!fs.exists(try f.fmt("{s}\\$REMPTY", .{bin})));
    try testing.expect(fs.exists(try f.fmt("{s}\\$RKEEP\\deep\\x.bin", .{bin})));
    try testing.expect(!fs.exists(j_empty)); // link to an empty folder: the link goes ...
    try testing.expect(fs.isDir(try f.path("empty-target"))); // ... its target stays
    try testing.expect(fs.exists(j)); // link to a folder with files: kept, target untouched
    try testing.expect(fs.exists(precious));
}

test "Cancel mid-enumeration: engine.analyze stops, CleanPass keeps nothing armed" {
    var f = try Fx.init("cancel");
    defer f.deinit();
    for ([_][]const u8{ "a.log", "sub\\b.log" }) |p| _ = try f.touch(p, 1);
    const list = try rules.parseIni(f.a(), try f.fmt("[T]\nFileKey1={s}|*.log|RECURSE\n[U]\nFileKey1={s}|*.log", .{ f.dir(), f.dir() }));
    var cancel: common.Cancel = .init(true);
    try testing.expectError(error.Canceled, engine.analyze(f.a(), io, &list[0], &.{}, &cancel));

    var s = try Settings.load(gpa, io, try f.path("cfg"));
    defer s.deinit();
    var pass: cleanpass.CleanPass = .init(gpa, &s);
    defer pass.deinit();
    try pass.analyze(io, list, &.{}, null, null);
    try testing.expect(pass.any());
    // the progress report of the first rule trips the token, so engine.analyze is cancelled while listing
    cancel.store(false, .release);
    const Trip = struct {
        fn report(ctx: ?*anyopaque, _: common.Count) void {
            const c: *common.Cancel = @ptrCast(@alignCast(ctx.?));
            c.store(true, .release);
        }
    };
    try testing.expectError(error.Canceled, pass.analyze(io, list, &.{}, .{ .ctx = &cancel, .func = Trip.report }, &cancel));
    try testing.expect(!pass.any());
    try testing.expect(fs.exists(try f.path("a.log")));
}

/// A browser item whose action pretends to remove `n` rows (counts preview/run calls).
const FakeRows = struct {
    n: usize,
    runs: usize = 0,
    previews: usize = 0,
    fn func(ctx: *const anyopaque, _: Allocator, _: Io, apply: bool) usize {
        const self: *FakeRows = @ptrCast(@alignCast(@constCast(ctx)));
        if (apply) self.runs += 1 else self.previews += 1;
        return self.n;
    }
};

test "CleanPass.Clean status line: registry, other items, browser entries, free space wipe" {
    var f = try Fx.init("status");
    defer f.deinit();
    elevated.Fake.install(); // EVENTLOGS goes through the fake runner: no UAC, no log is cleared
    defer elevated.Fake.uninstall();
    elevated.Fake.result = false;
    defer elevated.Fake.result = false;
    const tk = try common.TestKey.create(gpa, io, "status");
    defer tk.cleanup(gpa);
    (try kit.win.createKey(.hkcu, try f.fmt("{s}\\Gone", .{tk.sub}), .default)).close();
    _ = try f.touch("data\\a.log", 5);
    const wipe_dir = try f.path("wipe");
    try Io.Dir.cwd().createDirPath(io, wipe_dir);

    // %TEMP% (GetTempPath reads TMP first) points into the fixture for the wipe; restored afterwards
    const old_tmp = try kit.win.getEnv(gpa, "TMP");
    defer if (old_tmp) |o| gpa.free(o);
    defer _ = w.SetEnvironmentVariableW(kit.win.L("TMP"), if (old_tmp) |o| (kit.win.toW(f.a(), o) catch unreachable).ptr else null);
    try testing.expect(w.SetEnvironmentVariableW(kit.win.L("TMP"), (try kit.win.toW(f.a(), wipe_dir)).ptr) != 0);

    const list = try rules.parseIni(f.a(), try f.fmt(
        \\[Files]
        \\FileKey1={s}\data|*.log
        \\[Reg]
        \\RegKey1={s}\Gone
        \\[Logs]
        \\SpecialKey1=EVENTLOGS
        \\[Wipe]
        \\SpecialKey1=WIPEFREESPACE
    , .{ f.dir(), tk.full }));
    var rows: FakeRows = .{ .n = 3 };
    var skipped_rows: FakeRows = .{ .n = 2 };
    const items = [_]browsers.BrowserItem{
        .{ .browser = "Test Browser", .id = "x", .name = "Rows", .default = false, .files = .{ .name = "Test Browser: Rows" }, .action = .{ .ctx = &rows, .func = FakeRows.func } },
        .{ .browser = "Busy Browser", .id = "x", .name = "Rows", .default = false, .files = .{ .name = "Busy Browser: Rows" }, .action = .{ .ctx = &skipped_rows, .func = FakeRows.func } },
    };
    var s = try Settings.load(gpa, io, try f.path("cfg"));
    defer s.deinit();
    var pass: cleanpass.CleanPass = .init(gpa, &s);
    defer pass.deinit();
    pass.wipe_limit = 64 << 10; // never fill a real disk
    try pass.analyze(io, list, &items, null, null);
    const analyzed = try pass.analyzeSummary(gpa);
    defer gpa.free(analyzed);
    try testing.expectEqualStrings("Analysis complete: 1 files, 5 B to be removed, 1 registry entries, 1 other items, 5 browser entries + free space wipe", analyzed);
    try testing.expectEqual(0, elevated.Fake.calls); // analyze only describes

    const cleaned = try pass.clean(gpa, io, &.{"Busy Browser"}, null);
    defer gpa.free(cleaned);
    try testing.expectEqualStrings("Cleaning complete: 1 files removed, 5 B freed, 0 skipped (in use), 1 registry entries removed, 0 skipped, 0 other items done (1 failed), 3 browser entries removed, skipped running: Busy Browser, free space wiped", cleaned);
    try testing.expectEqual(1, elevated.Fake.calls);
    try testing.expect(std.mem.find(u8, elevated.Fake.args(), "wevtutil") != null);
    try testing.expectEqual(1, rows.runs);
    try testing.expectEqual(0, skipped_rows.runs); // a running browser's rows stay
    try testing.expect(!keyExists(try f.fmt("{s}\\Gone", .{tk.sub})));
    try testing.expect(fs.isEmpty(wipe_dir)); // the fill files are gone

    // a failing wipe is reported, not thrown
    try testing.expect(w.SetEnvironmentVariableW(kit.win.L("TMP"), (try kit.win.toW(f.a(), try f.path("no-such-dir"))).ptr) != 0);
    elevated.Fake.result = true;
    try pass.analyze(io, list[2..], &.{}, null, null);
    const failed = try pass.clean(gpa, io, &.{}, null);
    defer gpa.free(failed);
    try testing.expect(std.mem.startsWith(u8, failed, "Cleaning complete: 0 files removed, 0 B freed, 0 skipped (in use), 0 registry entries removed, 0 skipped, 1 other items done, free space wipe failed: "));
}

test "CleanPass.Saved: ticked Windows + Applications rules, never Wipe Free Space; RunningBrowsers" {
    var f = try Fx.init("saved");
    defer f.deinit();
    try Io.Dir.cwd().createDirPath(io, try f.path("app\\rules"));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try f.path("app\\rules\\Winapp2.ini"), .data = "[Mine *]\nFileKey1=C:\\a|*\n[Not Ticked *]\nFileKey1=C:\\a|*\n[On By Default *]\nDefault=True\nFileKey1=C:\\a|*" });
    var s = try Settings.load(gpa, io, try f.path("cfg"));
    defer s.deinit();
    try s.set("Mine *", true);
    try s.set("Wipe Free Space", true);
    try s.set("Temporary Files", false);
    const got = try cleanpass.saved(f.a(), io, &s, try f.path("app"));
    const has = struct {
        fn in(list: []const Rule, name: []const u8) bool {
            for (list) |r| if (std.mem.eql(u8, r.name, name)) return true;
            return false;
        }
    }.in;
    try testing.expect(has(got.rules, "Mine *"));
    try testing.expect(has(got.rules, "On By Default *"));
    try testing.expect(!has(got.rules, "Not Ticked *"));
    try testing.expect(!has(got.rules, "Wipe Free Space"));
    try testing.expect(!has(got.rules, "Temporary Files"));
    for (got.browser) |i| try testing.expect(s.getBool(try i.key(f.a()), i.default));

    // RunningBrowsers: only browsers whose items were analyzed, and only while their process runs
    var pass: cleanpass.CleanPass = .init(gpa, &s);
    defer pass.deinit();
    try pass.analyze(io, try rules.parseIni(f.a(), "[Not a browser]\nFileKey1=C:\\mc_none_dir|*"), &.{}, null, null);
    const none = try pass.runningBrowsers(gpa);
    defer gpa.free(none);
    try testing.expectEqual(0, none.len);
    try pass.analyze(io, try rules.parseIni(f.a(), "[Google Chrome: Cache]\nFileKey1=C:\\mc_none_dir|*"), &.{}, null, null);
    const chrome = try pass.runningBrowsers(gpa);
    defer gpa.free(chrome);
    const pids = try browsers.known[0].running(gpa);
    defer gpa.free(pids);
    try testing.expectEqual(@intFromBool(pids.len > 0), chrome.len);
}

test "Paths past MAX_PATH are enumerated, deleted and REMOVESELF-removed" {
    var f = try Fx.init("long");
    defer f.deinit();
    var rel: std.ArrayList(u8) = .empty;
    try rel.appendSlice(f.a(), "long");
    for (0..16) |_| try rel.appendSlice(f.a(), "\\segment_0123456789abcdef");
    try rel.appendSlice(f.a(), "\\deep.log");
    const deep = try f.touch(rel.items, 7);
    try testing.expect(deep.len > 300);
    try testing.expect(fs.isFile(deep) and fs.exists(deep) and !fs.isDir(deep) and fs.isDir(Io.Dir.path.dirname(deep).?));
    const r = try f.one(try f.fmt("[T]\nFileKey1={s}\\long|*.log|REMOVESELF", .{f.dir()}));
    const found = try f.analyze(&r, &.{});
    try testing.expectEqual(1, found.len);
    try testing.expectEqual(engine.CleanResult{ .deleted = 1, .bytes_freed = 7, .skipped = 0 }, engine.clean(gpa, io, found, 0));
    try testing.expectEqual(17, engine.removeEmptyDirs(gpa, io, &r));
    try testing.expect(!fs.exists(try f.path("long")));
}

test "FileKey pattern with a folder part (sub\\*.log) is split like .NET; '..' is refused" {
    var f = try Fx.init("subpat");
    defer f.deinit();
    _ = try f.touch("top.log", 1);
    _ = try f.touch("sub\\in.log", 1);
    _ = try f.touch("sub\\in.txt", 1);
    _ = try f.touch("x\\sibling.log", 1);
    const r = try f.one(try f.fmt("[T]\nFileKey1={s}|sub\\*.log;..\\x\\*.log", .{f.dir()}));
    try expectNames(&.{"in.log"}, try names(f.a(), try f.analyze(&r, &.{})));
    const sub = try f.one(try f.fmt("[T]\nFileKey1={s}\\sub|..\\x\\*.log", .{f.dir()}));
    try testing.expectEqual(0, (try f.analyze(&sub, &.{})).len);
}

test "User winapp2.ini saved as UTF-16 (Notepad 'Unicode') loads" {
    var f = try Fx.init("utf16");
    defer f.deinit();
    const text = "[Мій кеш *]\r\nFileKey1=C:\\a|*\r\n";
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(f.a(), "\xFF\xFE");
    for (try std.unicode.wtf8ToWtf16LeAlloc(f.a(), text)) |u| try bytes.appendSlice(f.a(), &std.mem.toBytes(std.mem.nativeToLittle(u16, u)));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try f.path("winapp2.ini"), .data = bytes.items });
    const list = try rules.loadApplications(f.a(), io, f.dir());
    try testing.expectEqual(1, list.len);
    try testing.expectEqualStrings("Мій кеш *", list[0].name);
}

test "IgnoreCaseMap hashes Cyrillic case-insensitively and spreads it" {
    const ctx: common.NameContext = .{};
    try testing.expectEqual(ctx.hash("C:\\ЄВГЕН\\ФАЙЛ.TXT"), ctx.hash("c:\\євген\\файл.txt"));
    try testing.expectEqual(ctx.hash("ЁЇІҐ"), ctx.hash("ёїіґ"));
    try testing.expect(ctx.hash("архів.log") != ctx.hash("звіт.log")); // all-Cyrillic names no longer share a bucket
    var map: common.IgnoreCaseMap(void) = .empty;
    defer map.deinit(gpa);
    try map.put(gpa, "C:\\Євген\\Файл.txt", {});
    try testing.expect((try map.getOrPut(gpa, "c:\\ЄВГЕН\\файл.TXT")).found_existing);
}

test "/auto log line: yyyy-MM-dd HH:mm:ss /auto: <line> CRLF, appended" {
    var f = try Fx.init("autolog");
    defer f.deinit();
    const log = try f.path("sub\\" ++ cleanpass.auto_log_name);
    try cleanpass.appendLog(io, log, "first");
    try cleanpass.appendLog(io, log, "Analysis complete: 0 files | Cleaning complete: 0 files removed");
    const text = try Io.Dir.cwd().readFileAlloc(io, log, f.a(), .limited(1 << 16));
    var lines = std.mem.splitSequence(u8, text, "\r\n");
    const l1 = lines.next().?;
    const l2 = lines.next().?;
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expect(lines.next() == null);
    for ([_][]const u8{ l1, l2 }) |l| {
        try testing.expect(l[4] == '-' and l[7] == '-' and l[10] == ' ' and l[13] == ':' and l[16] == ':');
        try testing.expectEqualStrings(" /auto: ", l[19..27]);
    }
    try testing.expectEqualStrings("first", l1[27..]);
    try testing.expect(std.mem.endsWith(u8, l2, "| Cleaning complete: 0 files removed"));
}

test "displayName drops Winapp2's trailing \" *\" only" {
    try std.testing.expectEqualStrings("Microsoft Visual Studio", rules.displayName("Microsoft Visual Studio *"));
    try std.testing.expectEqualStrings("Temporary Files", rules.displayName("Temporary Files"));
    try std.testing.expectEqualStrings("*", rules.displayName("*"));
}
