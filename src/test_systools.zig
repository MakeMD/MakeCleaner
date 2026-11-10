//! zig build test-systools: Startup, Uninstall, Schedule (/auto), System Restore. Owner: MC-D.
//! Spec tests: legacy ToolsTests (Startup/Uninstall parts), ScheduleTests, and the two RestorePoints tests that
//! live in SecureDeleteTests. Registry fixtures live under a throwaway HKCU\Software\MakeCleanerTest-<tag>-<rnd>
//! per test, files in a fresh %TEMP%\makecleaner-test-<tag>-<rnd>; both are removed afterwards. elevated.Fake is
//! installed wherever a write could reach UAC.
const std = @import("std");
const kit = @import("kit");
const common = @import("core/common.zig");
const reg = @import("core/reg.zig");
const elevated = @import("core/elevated.zig");
const startup = @import("core/startup.zig");
const uninstall = @import("core/uninstall.zig");
const schedule = @import("core/schedule.zig");
const restorepoints = @import("core/restorepoints.zig");
const cleanpass = @import("core/cleanpass.zig");
const Settings = @import("core/settings.zig").Settings;
const refAll = common.refAll;

const win = kit.win;
const testing = std.testing;
const Io = std.Io;

test {
    _ = @import("core/systools_win.zig");
    _ = @import("core/startup.zig");
    _ = @import("core/uninstall.zig");
    _ = @import("core/schedule.zig");
    _ = @import("core/restorepoints.zig");
    refAll(@import("core/startup.zig"));
    refAll(@import("core/uninstall.zig"));
    refAll(@import("core/schedule.zig"));
    refAll(@import("core/restorepoints.zig"));
}

// ---------------------------------------------------------------- fixtures

const V = union(enum) { s: []const u8, d: u32 };
const Val = struct { []const u8, V };

/// ToolsTests: own HKCU branch + arena + the UAC fake.
const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    tk: common.TestKey,

    fn init(tag: []const u8) !Fixture {
        elevated.Fake.install();
        elevated.Fake.result = false;
        return .{ .arena_state = .init(testing.allocator), .tk = try common.TestKey.create(testing.allocator, testing.io, tag) };
    }

    fn deinit(f: *Fixture) void {
        f.tk.cleanup(testing.allocator);
        f.arena_state.deinit();
        elevated.Fake.uninstall();
    }

    fn arena(f: *Fixture) std.mem.Allocator {
        return f.arena_state.allocator();
    }

    /// "HKCU\Software\MakeCleanerTest-...\<rel>" (ToolsTests.Root + rel).
    fn path(f: *Fixture, rel: []const u8) ![]const u8 {
        return f.arena().print("{s}\\{s}", .{ f.tk.full, rel });
    }

    /// ToolsTests.Values: creates <rel> and sets the values ("" = default value).
    fn values(f: *Fixture, rel: []const u8, vals: []const Val) !void {
        const k = try win.createKey(.hkcu, try f.arena().print("{s}\\{s}", .{ f.tk.sub, rel }), .default);
        defer k.close();
        for (vals) |v| switch (v[1]) {
            .s => |s| try k.writeString(v[0], s),
            .d => |d| try k.writeDword(v[0], d),
        };
    }
};

// ---------------------------------------------------------------- ToolsTests: Uninstall

test "ToolsTests.Uninstall_list_filters_like_programs_and_features" {
    var f = try Fixture.init("t08-uninstall");
    defer f.deinit();
    const a = f.arena();
    try f.values("U1\\App", &.{ .{ "DisplayName", .{ .s = "App" } }, .{ "DisplayVersion", .{ .s = "1.0" } }, .{ "UninstallString", .{ .s = "\"C:\\App\\un.exe\" /x" } }, .{ "Publisher", .{ .s = "Acme" } }, .{ "InstallDate", .{ .s = "20260101" } }, .{ "EstimatedSize", .{ .d = 2048 } } });
    try f.values("U1\\Sys", &.{ .{ "DisplayName", .{ .s = "Sys" } }, .{ "UninstallString", .{ .s = "x" } }, .{ "SystemComponent", .{ .d = 1 } } });
    try f.values("U1\\Patch", &.{ .{ "DisplayName", .{ .s = "Patch" } }, .{ "UninstallString", .{ .s = "x" } }, .{ "ParentKeyName", .{ .s = "App" } } });
    try f.values("U1\\Upd", &.{ .{ "DisplayName", .{ .s = "Upd" } }, .{ "UninstallString", .{ .s = "x" } }, .{ "ReleaseType", .{ .s = "Update" } } });
    try f.values("U1\\NoCmd", &.{.{ "DisplayName", .{ .s = "NoCmd" } }});
    try f.values("U1\\{11111111-2222-3333-4444-555555555555}", &.{ .{ "DisplayName", .{ .s = "Msi App" } }, .{ "WindowsInstaller", .{ .d = 1 } }, .{ "NoModify", .{ .d = 1 } } });
    try f.values("U2\\Other", &.{ .{ "DisplayName", .{ .s = "Other" } }, .{ "UninstallString", .{ .s = "x" } } });

    const apps = try uninstall.read(a, &.{ try f.path("U1"), try f.path("U2") });

    try testing.expectEqual(3, apps.len);
    for ([_][]const u8{ "App", "Msi App", "Other" }, apps) |want, app| try testing.expectEqualStrings(want, app.name);
    const app = apps[0];
    try testing.expectEqualStrings("Acme", app.publisher);
    try testing.expectEqual(2048, app.size_kb);
    try testing.expectEqualStrings("\"C:\\App\\un.exe\" /x", (try app.uninstallCommand(a)).?);
    try testing.expectEqual(null, try app.repairCommand(a)); // no ModifyPath
    const msi = apps[1];
    try testing.expectEqualStrings("msiexec.exe /x {11111111-2222-3333-4444-555555555555}", (try msi.uninstallCommand(a)).?);
    try testing.expectEqualStrings("msiexec.exe /fomus {11111111-2222-3333-4444-555555555555}", (try msi.repairCommand(a)).?);
    try testing.expectEqual(null, try msi.changeCommand(a)); // NoModify

    try testing.expect(try uninstall.deleteEntry(testing.allocator, &app));
    try testing.expectEqual(null, try reg.open(app.key, false));
    try testing.expectEqual(0, elevated.Fake.calls);
}

fn expectSplit(cmd: []const u8, exe: []const u8, args: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const c = try uninstall.splitCommand(arena_state.allocator(), cmd);
    try testing.expectEqualStrings(exe, c.exe);
    try testing.expectEqualStrings(args, c.args);
}

test "ToolsTests.SplitCommand_handles_quoted_and_bare_paths(quoted)" {
    try expectSplit("\"C:\\Program Files\\A\\un.exe\" /S", "C:\\Program Files\\A\\un.exe", "/S");
}
test "ToolsTests.SplitCommand_handles_quoted_and_bare_paths(bare with spaces)" {
    try expectSplit("C:\\Program Files\\A\\un.exe /S", "C:\\Program Files\\A\\un.exe", "/S");
}
test "ToolsTests.SplitCommand_handles_quoted_and_bare_paths(msiexec)" {
    try expectSplit("MsiExec.exe /X{ABC}", "MsiExec.exe", "/X{ABC}");
}
test "ToolsTests.SplitCommand_handles_quoted_and_bare_paths(no args)" {
    try expectSplit("C:\\a\\un.exe", "C:\\a\\un.exe", "");
}
test "ToolsTests.SplitCommand_handles_quoted_and_bare_paths(no .exe)" {
    try expectSplit("rundll32 shell32.dll,Foo", "rundll32", "shell32.dll,Foo");
}

// ---------------------------------------------------------------- ToolsTests: Startup

test "ToolsTests.Approved_bytes_match_task_manager_format" {
    try testing.expect(startup.isApproved(null));
    try testing.expect(startup.isApproved(&.{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }));
    try testing.expect(startup.isApproved(&.{ 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }));
    const off = startup.approvedBytes(false, .{ .year = 2026, .month = 10, .day = 22 });
    try testing.expectEqual(12, off.len);
    try testing.expect(!startup.isApproved(&off));
    try testing.expectEqual(134371008000000000, std.mem.readInt(u64, off[4..12], .little)); // DateTime(2026,10,22).ToFileTimeUtc()
    try testing.expectEqual([12]u8{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, startup.approvedBytes(true, .nowUtc()));
}

test "ToolsTests.Run_entry_disable_enable_delete_is_reversible" {
    var f = try Fixture.init("t08-run");
    defer f.deinit();
    const a = f.arena();
    const gpa = testing.allocator;
    try f.values("Run", &.{.{ "Tool", .{ .s = "C:\\tool.exe -min" } }});
    const run = try f.path("Run");
    const approved = try f.path("Approved");

    var items = try startup.readRun(a, run, approved);
    try testing.expectEqual(1, items.len);
    try testing.expect(items[0].enabled);

    try testing.expect(try startup.setEnabled(gpa, &items[0], false));
    items = try startup.readRun(a, run, approved);
    try testing.expectEqual(1, items.len);
    try testing.expect(!items[0].enabled);
    try testing.expectEqualStrings("C:\\tool.exe -min", items[0].command); // the Run value itself is untouched

    try testing.expect(try startup.setEnabled(gpa, &items[0], true));
    items = try startup.readRun(a, run, approved);
    try testing.expectEqual(1, items.len);
    try testing.expect(items[0].enabled);

    try testing.expect(try startup.delete(gpa, testing.io, &items[0]));
    try testing.expectEqual(0, (try startup.readRun(a, run, approved)).len);
    const k = (try reg.open(approved, false)).?;
    defer k.close();
    try testing.expectError(error.NotFound, k.readRaw(a, "Tool"));
    try testing.expectEqual(0, elevated.Fake.calls);
}

test "ToolsTests.Startup_folder_item_toggle_and_delete" {
    var f = try Fixture.init("t08-folder");
    defer f.deinit();
    const a = f.arena();
    const gpa = testing.allocator;
    const io = testing.io;
    const dir = try common.TempDir.create(gpa, io, "t08-folder");
    defer dir.cleanup(gpa, io);
    const lnk = try dir.join(a, "app.lnk");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = lnk, .data = "x" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try dir.join(a, "desktop.ini"), .data = "x" });
    const approved = try f.path("Folder");

    const items = try startup.readFolder(a, io, dir.path, approved);
    try testing.expectEqual(1, items.len);
    try testing.expectEqualStrings("app.lnk", items[0].name);
    try testing.expect(items[0].enabled);

    try testing.expect(try startup.setEnabled(gpa, &items[0], false));
    const again = try startup.readFolder(a, io, dir.path, approved);
    try testing.expectEqual(1, again.len);
    try testing.expect(!again[0].enabled);

    try testing.expect(try startup.delete(gpa, io, &items[0]));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, lnk, .{}));
    try testing.expectEqual(0, elevated.Fake.calls);
}

test "ToolsTests.Context_menu_handler_block_unblock_delete" {
    var f = try Fixture.init("t08-shellex");
    defer f.deinit();
    const a = f.arena();
    const gpa = testing.allocator;
    const clsid = "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}";
    try f.values("Classes\\Directory\\shellex\\ContextMenuHandlers\\FooExt", &.{.{ "", .{ .s = clsid } }});
    try f.values("Classes\\CLSID\\" ++ clsid, &.{.{ "", .{ .s = "Foo Extension" } }});
    try f.values("Classes\\CLSID\\" ++ clsid ++ "\\InprocServer32", &.{.{ "", .{ .s = "C:\\foo.dll" } }});
    const classes = try f.path("Classes");
    const blocked = try f.path("Blocked");

    var items = try startup.readContextMenu(a, classes, blocked);
    try testing.expectEqual(1, items.len);
    var item = items[0];
    try testing.expectEqualStrings("Foo Extension", item.name);
    try testing.expectEqualStrings("C:\\foo.dll", item.command);
    try testing.expectEqualStrings(clsid, item.id);
    try testing.expect(item.enabled);

    try testing.expect(try startup.setEnabled(gpa, &item, false));
    items = try startup.readContextMenu(a, classes, blocked);
    try testing.expectEqual(1, items.len);
    item = items[0];
    try testing.expect(!item.enabled);
    try testing.expect(try startup.setEnabled(gpa, &item, true));
    items = try startup.readContextMenu(a, classes, blocked);
    try testing.expectEqual(1, items.len);
    try testing.expect(items[0].enabled);

    try testing.expect(try startup.delete(gpa, testing.io, &item)); // the stale (disabled) item: also drops the Blocked value
    try testing.expectEqual(0, (try startup.readContextMenu(a, classes, blocked)).len);
    try testing.expectEqual(0, elevated.Fake.calls);
}

// Beyond ToolsTests: access denied on a direct write must reach the elevated fallback with the right reg.exe line.
// HKLM Run is not writable without admin; the value name is unique and missing, and elevated.Fake never runs it.
// Skipped when elevated, so the test never writes to HKLM.
test "ToolsTests+.Run_delete_without_admin_falls_back_to_elevated_reg_exe" {
    if (elevated.isAdmin()) return error.SkipZigTest;
    var f = try Fixture.init("t08-elev");
    defer f.deinit();
    elevated.Fake.result = true;
    const a = f.arena();
    var rnd: [8]u8 = undefined;
    testing.io.random(&rnd);
    const name = try a.print("MakeCleanerTest-{x}", .{&rnd});
    const run = startup.run_keys[1].run; // HKLM ...\Run
    try testing.expect(common.startsWithIgnoreCase(run, "HKLM\\"));
    const item: startup.StartupItem = .{ .kind = .run, .name = name, .command = "x", .enabled = true, .location = run, .approved = try f.path("Approved") };
    try testing.expect(try startup.delete(testing.allocator, testing.io, &item));
    try testing.expectEqual(1, elevated.Fake.calls);
    try testing.expectEqualStrings("reg.exe", elevated.Fake.exe());
    try testing.expectEqualStrings(try a.print("delete \"{s}\" /v \"{s}\" /f /reg:64", .{ run, name }), elevated.Fake.args());
}

test "ToolsTests.Services_list_skips_drivers_and_user_templates_and_remembers_start" {
    var f = try Fixture.init("t08-services");
    defer f.deinit();
    const a = f.arena();
    const gpa = testing.allocator;
    try f.values("Svc\\AutoSvc", &.{ .{ "Type", .{ .d = 16 } }, .{ "Start", .{ .d = 2 } }, .{ "DisplayName", .{ .s = "Auto Service" } }, .{ "ImagePath", .{ .s = "C:\\Acme\\svc.exe" } } });
    try f.values("Svc\\OffSvc", &.{ .{ "Type", .{ .d = 32 } }, .{ "Start", .{ .d = 4 } }, .{ "ImagePath", .{ .s = "C:\\Windows\\system32\\svchost.exe -k x" } }, .{ startup.prev_start_value, .{ .d = 2 } } });
    try f.values("Svc\\Driver", &.{ .{ "Type", .{ .d = 1 } }, .{ "Start", .{ .d = 3 } } });
    try f.values("Svc\\UserTmpl", &.{ .{ "Type", .{ .d = 0x50 } }, .{ "Start", .{ .d = 3 } } });
    try f.values("Svc\\Boot", &.{ .{ "Type", .{ .d = 16 } }, .{ "Start", .{ .d = 0 } } });

    const items = try startup.readServices(a, try f.path("Svc"));
    std.mem.sort(startup.StartupItem, items, {}, struct {
        fn lessThan(_: void, x: startup.StartupItem, y: startup.StartupItem) bool {
            return std.mem.lessThan(u8, x.id, y.id);
        }
    }.lessThan);
    try testing.expectEqual(2, items.len);
    try testing.expectEqualStrings("AutoSvc", items[0].id);
    try testing.expectEqualStrings("OffSvc", items[1].id);
    const auto = items[0];
    const off = items[1];
    try testing.expectEqualStrings("Auto Service", auto.name);
    try testing.expectEqualStrings("Auto", auto.info);
    try testing.expect(auto.enabled);
    try testing.expectEqualStrings("Disabled", off.info);
    try testing.expect(!off.enabled);

    const disable = try startup.serviceToggleArgs(a, &auto, false);
    try testing.expect(std.mem.find(u8, disable, "start= disabled") != null);
    try testing.expect(std.mem.find(u8, disable, "/d 2") != null);
    try testing.expect(std.mem.find(u8, try startup.serviceToggleArgs(a, &off, true), "start= auto") != null); // restored from the remembered value
    try testing.expect(!startup.isSystemService(&auto));
    try testing.expect(startup.isSystemService(&off));
    try testing.expect(!try startup.delete(gpa, testing.io, &off)); // system services are never deleted
    try testing.expectEqual(0, elevated.Fake.calls);
}

test "ToolsTests.Scheduled_tasks_enumerate_read_only" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    for (try startup.readTasks(arena_state.allocator())) |t| {
        try testing.expectEqual(startup.StartupKind.task, t.kind);
        try testing.expect(!common.startsWithIgnoreCase(t.location, "\\Microsoft\\"));
    }
}

// ---------------------------------------------------------------- SecureDeleteTests: RestorePoints

test "SecureDeleteTests.Newest_restore_point_is_never_removable" {
    const now = common.DateTime.nowUtc();
    const all = [_]restorepoints.RestorePoint{ .{ .seq = 10, .description = "rp10", .created = now }, .{ .seq = 12, .description = "rp12", .created = now }, .{ .seq = 11, .description = "rp11", .created = now } };
    try testing.expect(!restorepoints.canRemove(&all[1], &all));
    try testing.expect(restorepoints.canRemove(&all[0], &all));
    try testing.expectEqual(common.DateTime{ .year = 2026, .month = 10, .day = 22, .hour = 8, .minute = 15, .second = 0 }, try restorepoints.parseCim("20261022081500.000000-000"));
    // ParseExact rejects impossible dates
    try testing.expectError(error.InvalidFormat, restorepoints.parseCim("20260230000000.000000-000"));
    try testing.expectError(error.InvalidFormat, restorepoints.parseCim("20250229000000.000000-000"));
    _ = try restorepoints.parseCim("20240229000000.000000-000");
}

test "SecureDeleteTests.Restore_points_list_reads_wmi_or_asks_for_admin" { // read-only query of the real machine
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    if (!elevated.isAdmin()) return testing.expectError(error.AccessDenied, restorepoints.list(arena_state.allocator()));
    for (try restorepoints.list(arena_state.allocator())) |p| try testing.expect(p.seq > 0 and p.created.year > 2000);
}

// ---------------------------------------------------------------- ScheduleTests

const at: common.DateTime = .{ .year = 2031, .month = 3, .day = 5, .hour = 12, .minute = 30 }; // a Wednesday

/// Text between `open` and `close` (the element's value), or null.
fn element(x: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const i = std.mem.find(u8, x, open) orelse return null;
    const rest = x[i + open.len ..];
    return rest[0 .. std.mem.find(u8, rest, close) orelse return null];
}

/// Stand-in for XDocument.Parse: tags nest and close, text has no '<'/'>' and '&' only starts the five entities.
/// ponytail: no attribute-value or comment/CDATA parsing (taskXml writes neither with user data).
fn expectWellFormed(x: []const u8) !void {
    var stack: [16][]const u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (true) {
        const lt = std.mem.findScalarPos(u8, x, i, '<') orelse x.len;
        const text = x[i..lt];
        try testing.expect(std.mem.findScalar(u8, text, '>') == null);
        var amp = std.mem.findScalar(u8, text, '&');
        while (amp) |p| : (amp = std.mem.findScalarPos(u8, text, p + 1, '&')) {
            const ok = for ([_][]const u8{ "&amp;", "&lt;", "&gt;", "&quot;", "&apos;" }) |e| {
                if (std.mem.startsWith(u8, text[p..], e)) break true;
            } else false;
            try testing.expect(ok);
        }
        if (lt == x.len) break;
        const gt = std.mem.findScalarPos(u8, x, lt, '>') orelse return error.TestUnclosedTag;
        const tag = x[lt + 1 .. gt];
        i = gt + 1;
        try testing.expect(tag.len > 0 and std.mem.findScalar(u8, tag, '<') == null);
        if (tag[0] == '?' or tag[tag.len - 1] == '/') continue; // declaration, empty element
        if (tag[0] == '/') {
            try testing.expect(n > 0);
            n -= 1;
            try testing.expectEqualStrings(stack[n], tag[1..]);
        } else {
            stack[n] = tag[0 .. std.mem.findScalar(u8, tag, ' ') orelse tag.len];
            n += 1;
        }
    }
    try testing.expectEqual(0, n);
}

fn expectTaskXml(kind: schedule.ScheduleKind, comptime trigger: []const u8) !void {
    const x = try schedule.taskXml(testing.allocator, kind, at, "C:\\Apps & Tools\\MakeCleaner.exe", "PC\\me", false);
    defer testing.allocator.free(x);
    try expectWellFormed(x);
    const t = element(x, "<Triggers>", "</Triggers>").?;
    // exactly one trigger element, of the expected kind
    try testing.expect(std.mem.startsWith(u8, t, "<" ++ trigger ++ ">") and std.mem.endsWith(u8, t, "</" ++ trigger ++ ">"));
    try testing.expectEqual(1, std.mem.count(u8, t, "<" ++ trigger ++ ">"));
    if (kind != .at_logon) try testing.expectEqualStrings("2031-03-05T12:30:00", element(t, "<StartBoundary>", "</StartBoundary>").?);
    if (kind == .weekly) try testing.expectEqual(1, std.mem.count(u8, element(t, "<DaysOfWeek>", "</DaysOfWeek>").?, "<Wednesday />"));
    if (kind == .at_logon) try testing.expectEqualStrings("PC\\me", element(t, "<UserId>", "</UserId>").?);
    try testing.expectEqualStrings("C:\\Apps &amp; Tools\\MakeCleaner.exe", element(x, "<Command>", "</Command>").?); // escaped
    try testing.expectEqualStrings("C:\\Apps &amp; Tools", element(x, "<WorkingDirectory>", "</WorkingDirectory>").?);
    try testing.expectEqualStrings("/auto", element(x, "<Arguments>", "</Arguments>").?);
    try testing.expectEqualStrings("LeastPrivilege", element(x, "<RunLevel>", "</RunLevel>").?);
}

test "ScheduleTests.Task_xml_has_the_right_trigger_and_runs_auto(Once)" {
    try expectTaskXml(.once, "TimeTrigger");
}
test "ScheduleTests.Task_xml_has_the_right_trigger_and_runs_auto(Daily)" {
    try expectTaskXml(.daily, "CalendarTrigger");
}
test "ScheduleTests.Task_xml_has_the_right_trigger_and_runs_auto(Weekly)" {
    try expectTaskXml(.weekly, "CalendarTrigger");
}
test "ScheduleTests.Task_xml_has_the_right_trigger_and_runs_auto(AtLogon)" {
    try expectTaskXml(.at_logon, "LogonTrigger");
}

test "ScheduleTests.Shutdown_is_passed_to_auto" {
    const x = try schedule.taskXml(testing.allocator, .daily, at, "C:\\m.exe", "u", true);
    defer testing.allocator.free(x);
    try testing.expect(std.mem.find(u8, x, "<Arguments>/auto /shutdown</Arguments>") != null);
}

// Beyond ScheduleTests: the user name is escaped in both the Principal and the LogonTrigger.
test "ScheduleTests+.Task_xml_escapes_the_user_name" {
    const x = try schedule.taskXml(testing.allocator, .at_logon, at, "C:\\m.exe", "PC\\a&b<'\">", false);
    defer testing.allocator.free(x);
    try expectWellFormed(x);
    try testing.expectEqual(2, std.mem.count(u8, x, "<UserId>PC\\a&amp;b&lt;&apos;&quot;&gt;</UserId>"));
}

// Registers real tasks under a throwaway name, pointing at a missing exe (in a folder with '&', so Task Scheduler
// also parses the escaping) with a trigger years away; always deleted.
test "ScheduleTests.Task_scheduler_accepts_every_kind_and_delete_leaves_nothing" {
    const gpa = testing.allocator;
    const io = testing.io;
    const dir = try common.TempDir.create(gpa, io, "sched");
    defer dir.cleanup(gpa, io);
    var rnd: [16]u8 = undefined;
    io.random(&rnd);
    const name = try gpa.print("MakeCleaner Test {x}", .{&rnd});
    defer gpa.free(name);
    const exe = try dir.join(gpa, "Apps & Tools\\missing.exe");
    defer gpa.free(exe);
    var when = common.DateTime.nowLocal();
    when.year += 5;
    if (when.month == 2 and when.day == 29) when.day = 28; // DateTime.AddYears
    {
        defer schedule.delete(name) catch {}; // finally
        for ([_]schedule.ScheduleKind{ .once, .daily, .weekly, .at_logon }) |kind| {
            try schedule.create(gpa, kind, when, false, name, exe);
            gpa.free((try schedule.describe(gpa, name)) orelse return error.TestExpectedDescription);
        }
    }
    try testing.expectEqual(null, try schedule.describe(gpa, name));
    try schedule.delete(name); // deleting twice is fine
}

/// ScheduleTests.CopyApp: only what the app needs to run (the exe and rules\).
fn copyApp(io: Io, from: []const u8, to: []const u8, a: std.mem.Allocator) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, try Io.Dir.path.join(a, &.{ to, "rules" }));
    try cwd.copyFile(try Io.Dir.path.join(a, &.{ from, "MakeCleaner.exe" }), cwd, try Io.Dir.path.join(a, &.{ to, "MakeCleaner.exe" }), io, .{});
    var rules = try cwd.openDir(io, try Io.Dir.path.join(a, &.{ from, "rules" }), .{ .iterate = true });
    defer rules.close(io);
    var it = rules.iterate();
    while (try it.next(io)) |e| {
        if (e.kind == .file) try rules.copyFile(e.name, cwd, try Io.Dir.path.join(a, &.{ to, "rules", e.name }), io, .{});
    }
}

// The C# /auto test also ticks Wipe Free Space to prove /auto ignores it. Here that guard is proven in-process
// instead (no exe, nothing wiped): if `saved` ever stopped dropping it, the exe run would fill the system drive.
test "ScheduleTests+.Auto_never_picks_wipe_free_space_even_when_ticked" {
    const gpa = testing.allocator;
    const io = testing.io;
    const dir = try common.TempDir.create(gpa, io, "sched-saved");
    defer dir.cleanup(gpa, io);
    var s = try Settings.load(gpa, io, dir.path);
    defer s.deinit();
    try s.set("Wipe Free Space", true);
    try s.set("Temporary Files", true);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var listed = false; // not vacuous: the Windows tab does offer it
    for (try cleanpass.windowsRules(a, io)) |*r| listed = listed or cleanpass.isWipe(r);
    try testing.expect(listed);
    var temp = false;
    for ((try cleanpass.saved(a, io, &s, dir.path)).rules) |*r| {
        try testing.expect(!cleanpass.isWipe(r));
        temp = temp or std.mem.eql(u8, r.name, "Temporary Files");
    }
    try testing.expect(temp);
}

/// Newest mtime (ns) of the files under `sub`, recursively; test roots are not part of the exe.
fn newestMtime(gpa: std.mem.Allocator, io: Io, sub: []const u8) !i96 {
    var d = try Io.Dir.cwd().openDir(io, sub, .{ .iterate = true });
    defer d.close(io);
    var walker = try d.walk(gpa);
    defer walker.deinit();
    var m: i96 = 0;
    while (try walker.next(io)) |e| {
        if (e.kind == .file and !std.mem.startsWith(u8, e.basename, "test_")) m = @max(m, (try e.dir.statFile(io, e.basename, .{})).mtime.nanoseconds);
    }
    return m;
}

// The real exe, in its own process: portable ini with only Temporary Files ticked, TEMP/AppData pointed at a fixture.
// Runs zig-out\bin\MakeCleaner.exe, so it refuses (skips, saying why) a missing exe or one older than src\ or rules\Windows.ini:
// a stale build might ignore portable.dat or the ini and clean the rule defaults (Recycle Bin, Clipboard, ...).
// build.zig orders test-systools / test after the install step, so the exe is current there.
test "ScheduleTests.Auto_cleans_saved_items_without_a_window_and_logs" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bin = "zig-out\\bin";
    const built = (Io.Dir.cwd().statFile(io, bin ++ "\\MakeCleaner.exe", .{}) catch {
        std.debug.print("SKIP Auto_cleans_saved_items: no {s}\\MakeCleaner.exe, run `zig build` first\n", .{bin});
        return error.SkipZigTest;
    }).mtime.nanoseconds;
    const windows_ini = (try Io.Dir.cwd().statFile(io, "rules\\Windows.ini", .{})).mtime.nanoseconds; // embedded in the exe
    if (built < @max(try newestMtime(gpa, io, "src"), windows_ini)) {
        std.debug.print("SKIP Auto_cleans_saved_items: {s}\\MakeCleaner.exe is older than src\\ or rules\\Windows.ini, run `zig build` first\n", .{bin});
        return error.SkipZigTest;
    }

    const dir = try common.TempDir.create(gpa, io, "sched-auto");
    defer dir.cleanup(gpa, io);
    const cwd = Io.Dir.cwd();
    const app = try dir.join(a, "app");
    try copyApp(io, bin, app, a);
    try cwd.writeFile(io, .{ .sub_path = try Io.Dir.path.join(a, &.{ app, "portable.dat" }), .data = "#PORTABLE#" });

    var ini: std.ArrayList(u8) = .empty;
    try ini.appendSlice(a, "[Options]\r\n");
    var lines = std.mem.splitScalar(u8, @embedFile("windows_ini"), '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len < 2 or l[0] != '[' or l[l.len - 1] != ']') continue;
        const n = l[1 .. l.len - 1];
        // Only Temporary Files. Unlike the C# test, Wipe Free Space stays off: its guard is the in-process test above,
        // so a regression there cannot turn this run into an unbounded fill of the system drive.
        try ini.print(a, "{s}={s}\r\n", .{ n, if (std.mem.eql(u8, n, "Temporary Files")) "True" else "False" });
    }
    // Belt and braces beyond the C# test: every browser checkbox explicitly off, so the run never reaches a real
    // profile even if a browser root were resolved without %LOCALAPPDATA%/%APPDATA%.
    for ([_][]const u8{ "Google Chrome", "Microsoft Edge", "Brave", "Vivaldi", "Opera", "Opera GX", "Arc", "Mozilla Firefox" }) |b|
        for ([_][]const u8{ "Internet Cache", "Internet History", "Download History", "Last Download Location", "Session", "Saved Form Information", "Saved Passwords", "Compact Databases", "Cookies" }) |item|
            try ini.print(a, "{s}: {s}=False\r\n", .{ b, item });
    try ini.appendSlice(a, "Custom Files and Folders=False\r\n");
    try cwd.writeFile(io, .{ .sub_path = try Io.Dir.path.join(a, &.{ app, "MakeCleaner.ini" }), .data = ini.items });

    const temp = try dir.join(a, "temp");
    const empty = try dir.join(a, "empty");
    try cwd.createDirPath(io, try Io.Dir.path.join(a, &.{ temp, "sub" }));
    try cwd.createDirPath(io, empty);
    try cwd.writeFile(io, .{ .sub_path = try Io.Dir.path.join(a, &.{ temp, "a.tmp" }), .data = "x" });
    try cwd.writeFile(io, .{ .sub_path = try Io.Dir.path.join(a, &.{ temp, "sub", "b.tmp" }), .data = "yy" });
    const keep = try dir.join(a, "keep.txt");
    try cwd.writeFile(io, .{ .sub_path = keep, .data = "z" });

    var env = try testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("TEMP", temp);
    try env.put("TMP", temp);
    try env.put("LOCALAPPDATA", empty);
    try env.put("APPDATA", empty);
    const r = try std.process.run(gpa, io, .{
        .argv = &.{ try Io.Dir.path.join(a, &.{ app, "MakeCleaner.exe" }), "/auto" },
        .environ_map = &env,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } },
    });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const log = cwd.readFileAlloc(io, try Io.Dir.path.join(a, &.{ app, schedule.log_name }), a, .limited(1 << 20)) catch "";

    try testing.expect(r.term == .exited and r.term.exited == 0);
    var tree = try cwd.openDir(io, temp, .{ .iterate = true });
    defer tree.close(io);
    var walker = try tree.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |e| try testing.expect(e.kind != .file);
    try cwd.access(io, keep, .{});
    try testing.expect(std.mem.find(u8, log, "Analysis complete: 2 files") != null);
    try testing.expect(std.mem.find(u8, log, "Cleaning complete: 2 files removed") != null);
    try testing.expect(std.mem.find(u8, log, "free space") == null);
}
