//! Schedule.cs. "MakeCleaner.exe /auto": the GUI's saved ticks, no window, no dialogs. The only way MakeCleaner
//! ever runs on its own is a Task Scheduler task the user creates in Options (one task, deleted completely by
//! Remove; no services or Run keys).
const std = @import("std");
const kit = @import("kit");
const common = @import("common.zig");
const cleanpass = @import("cleanpass.zig");
const sys = @import("systools_win.zig");
const Settings = @import("settings.zig").Settings;

const w = kit.w;
const win = kit.win;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const ScheduleKind = enum { once, daily, weekly, at_logon };

pub const task_name = "MakeCleaner Auto Clean";
pub const log_name = cleanpass.auto_log_name;

/// Schedule.Auto: 0 = cleaned (files in use are skipped, not an error), 1 = failed. Never wipes free space,
/// never touches a running browser. Appends one line to <settings dir>\MakeCleaner-auto.log; with `shutdown`
/// starts "shutdown /s /t 60". `exe_dir` replaces AppContext.BaseDirectory (rules\Winapp2.ini lives there).
/// The body lives with the pass it drives (MC-A's cleanpass.auto); ScheduleTests' /auto test covers it here.
pub fn auto(gpa: Allocator, io: Io, settings: *Settings, exe_dir: []const u8, shutdown: bool) u8 {
    return cleanpass.auto(gpa, io, settings, exe_dir, shutdown);
}

const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

/// SecurityElement.Escape for "{f}".
const Esc = struct {
    s: []const u8,
    pub fn format(e: Esc, out: *Io.Writer) Io.Writer.Error!void {
        for (e.s) |c| try switch (c) {
            '<' => out.writeAll("&lt;"),
            '>' => out.writeAll("&gt;"),
            '"' => out.writeAll("&quot;"),
            '\'' => out.writeAll("&apos;"),
            '&' => out.writeAll("&amp;"),
            else => out.writeByte(c),
        };
    }
};

/// Schedule.TaskXml: Task Scheduler 1.2 XML (locale-independent, unlike schtasks /SD /ST), LeastPrivilege,
/// InteractiveToken, action `exe /auto[ /shutdown]`; `at` is local time. Caller frees.
pub fn taskXml(gpa: Allocator, kind: ScheduleKind, at: common.DateTime, exe: []const u8, user: []const u8, shutdown: bool) ![]u8 {
    var start_buf: [64]u8 = undefined;
    const start = try std.mem.print(&start_buf, "<StartBoundary>{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}</StartBoundary>", .{ at.year, at.month, at.day, at.hour, at.minute, at.second });
    var trigger_buf: [512]u8 = undefined;
    const trigger = switch (kind) {
        .once => try std.mem.print(&trigger_buf, "<TimeTrigger>{s}</TimeTrigger>", .{start}),
        .daily => try std.mem.print(&trigger_buf, "<CalendarTrigger>{s}<ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>", .{start}),
        .weekly => try std.mem.print(&trigger_buf, "<CalendarTrigger>{s}<ScheduleByWeek><DaysOfWeek><{s} /></DaysOfWeek><WeeksInterval>1</WeeksInterval></ScheduleByWeek></CalendarTrigger>", .{ start, day_names[at.dayOfWeek()] }),
        .at_logon => try gpa.print("<LogonTrigger><UserId>{f}</UserId></LogonTrigger>", .{Esc{ .s = user }}),
    };
    defer if (kind == .at_logon) gpa.free(trigger);
    return gpa.print(
        \\<?xml version="1.0" encoding="UTF-16"?>
        \\<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
        \\  <RegistrationInfo><Description>MakeCleaner: cleans the items ticked in MakeCleaner (MakeCleaner.exe /auto).</Description></RegistrationInfo>
        \\  <Triggers>{s}</Triggers>
        \\  <Principals><Principal id="Author"><UserId>{f}</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
        \\  <Settings>
        \\    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
        \\    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
        \\    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
        \\    <StartWhenAvailable>true</StartWhenAvailable>
        \\    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
        \\  </Settings>
        \\  <Actions Context="Author"><Exec><Command>{f}</Command><Arguments>/auto{s}</Arguments><WorkingDirectory>{f}</WorkingDirectory></Exec></Actions>
        \\</Task>
    , .{ trigger, Esc{ .s = user }, Esc{ .s = exe }, if (shutdown) " /shutdown" else "", Esc{ .s = Io.Dir.path.dirname(exe) orelse "" } });
}

extern "secur32" fn GetUserNameExW(format: c_int, name: [*]u16, size: *u32) callconv(.winapi) u8;

/// WindowsIdentity.GetCurrent().Name: "DOMAIN\user" (NameSamCompatible). Caller frees.
fn currentUser(gpa: Allocator) ![]u8 {
    var buf: [512]u16 = undefined;
    var n: u32 = buf.len;
    if (GetUserNameExW(2, &buf, &n) == 0) return error.Unexpected;
    return win.fromW(gpa, buf[0..n]);
}

/// Environment.ProcessPath. Caller frees.
fn exePath(gpa: Allocator) ![]u8 {
    var buf: [32768]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0 or n >= buf.len) return error.Unexpected;
    return win.fromW(gpa, buf[0..n]);
}

/// Schedule.Create: registers (TASK_CREATE_OR_UPDATE) `name` for the current user with
/// TASK_LOGON_INTERACTIVE_TOKEN: runs as the current user, only while signed in, no password stored.
/// exe null = this exe.
pub fn create(gpa: Allocator, kind: ScheduleKind, at: common.DateTime, shutdown: bool, name: []const u8, exe: ?[]const u8) !void {
    const self_path = if (exe == null) try exePath(gpa) else null;
    defer if (self_path) |p| gpa.free(p);
    const user = try currentUser(gpa);
    defer gpa.free(user);
    const xml = try taskXml(gpa, kind, at, exe orelse self_path.?, user, shutdown);
    defer gpa.free(xml);

    const apt = try sys.Apartment.enter();
    defer apt.leave();
    const root = try sys.taskFolder("\\");
    defer win.release(root);
    const name_b = try sys.bstr(name);
    defer w.SysFreeString(name_b);
    const xml_b = try sys.bstr(xml);
    defer w.SysFreeString(xml_b);
    const none = sys.empty_variant;
    var task: [*c]w.IRegisteredTask = null;
    try sys.check(root.*.lpVtbl.*.RegisterTask.?(root, name_b, xml_b, w.TASK_CREATE_OR_UPDATE, none, none, w.TASK_LOGON_INTERACTIVE_TOKEN, none, &task));
    win.release(task);
}

/// Schedule.Delete: removes the task; already gone is fine ("not found" = HRESULT 0x80070002).
pub fn delete(name: []const u8) !void {
    const apt = try sys.Apartment.enter();
    defer apt.leave();
    const root = try sys.taskFolder("\\");
    defer win.release(root);
    const name_b = try sys.bstr(name);
    defer w.SysFreeString(name_b);
    sys.check(root.*.lpVtbl.*.DeleteTask.?(root, name_b, 0)) catch |e| if (e != error.NotFound) return e;
}

/// Schedule.Describe: null = no task; else "Scheduled cleaning is on. Next run: yyyy-MM-dd HH:mm" or
/// "Scheduled cleaning is on (runs at sign-in).". Caller frees.
pub fn describe(gpa: Allocator, name: []const u8) !?[]u8 {
    const apt = try sys.Apartment.enter();
    defer apt.leave();
    const root = try sys.taskFolder("\\");
    defer win.release(root);
    const name_b = try sys.bstr(name);
    defer w.SysFreeString(name_b);
    var t: [*c]w.IRegisteredTask = null;
    sys.check(root.*.lpVtbl.*.GetTask.?(root, name_b, &t)) catch |e| return if (e == error.NotFound) null else e;
    defer win.release(t);
    var next: w.DATE = 0;
    try sys.check(t.*.lpVtbl.*.get_NextRunTime.?(t, &next));
    var st = std.mem.zeroes(w.SYSTEMTIME);
    _ = w.VariantTimeToSystemTime(next, &st); // 0 (no next run: logon trigger) = 1899-12-30
    if (st.wYear <= 1900) return try gpa.dupe(u8, "Scheduled cleaning is on (runs at sign-in).");
    return try gpa.print("Scheduled cleaning is on. Next run: {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute });
}
