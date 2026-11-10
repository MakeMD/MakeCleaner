//! Startup.cs (Tools > Startup): Run keys, Startup folders (enabled state = StartupApproved, as Task Manager
//! writes it), context-menu handlers (Shell Extensions\Blocked), Win32 services, non-Microsoft scheduled tasks
//! (Task Scheduler COM). Writes go through reg.zig / elevated.zig (direct first, UAC only on access denied).
//! Every list function returns items whose strings live in `arena`.
const std = @import("std");
const kit = @import("kit");
const common = @import("common.zig");
const reg = @import("reg.zig");
const elevated = @import("elevated.zig");
const sys = @import("systools_win.zig");

const w = kit.w;
const win = kit.win;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const StartupKind = enum { run, folder, task, context_menu, service };

/// record StartupItem. location: Run = run key, Folder = file path, Task = task path, ContextMenu = handler key,
/// Service = service key. approved: StartupApproved key (Run/Folder) or Shell Extensions\Blocked key
/// (ContextMenu). id: CLSID or service name. info: shellex type / service start mode.
pub const StartupItem = struct {
    kind: StartupKind,
    name: []const u8,
    command: []const u8,
    enabled: bool,
    location: []const u8,
    approved: []const u8 = "",
    id: []const u8 = "",
    info: []const u8 = "",
};

const cv = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion";
const approved_root = cv ++ "\\Explorer\\StartupApproved";
pub const blocked_key = "HKLM\\" ++ cv ++ "\\Shell Extensions\\Blocked";
pub const services_key = "HKLM\\SYSTEM\\CurrentControlSet\\Services";
pub const prev_start_value = "MakeCleanerPrevStart";

/// (Run, Approved) key pairs.
pub const RunKey = struct { run: []const u8, approved: []const u8 };
pub const run_keys = [_]RunKey{
    .{ .run = "HKCU\\" ++ cv ++ "\\Run", .approved = "HKCU\\" ++ approved_root ++ "\\Run" },
    .{ .run = "HKLM\\" ++ cv ++ "\\Run", .approved = "HKLM\\" ++ approved_root ++ "\\Run" },
    .{ .run = "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Run", .approved = "HKLM\\" ++ approved_root ++ "\\Run32" },
};

/// (Folder, Approved) pair; folders are known folders, so they are computed at runtime (see `folders`).
pub const StartupFolder = struct { folder: []const u8, approved: []const u8 };

/// Startup.Folders: user Startup + common Startup ("" when the known folder is unavailable, as GetFolderPath).
pub fn folders(arena: Allocator) [2]StartupFolder {
    return .{
        .{ .folder = win.knownFolder(arena, &w.FOLDERID_Startup) catch "", .approved = "HKCU\\" ++ approved_root ++ "\\StartupFolder" },
        .{ .folder = win.knownFolder(arena, &w.FOLDERID_CommonStartup) catch "", .approved = "HKLM\\" ++ approved_root ++ "\\StartupFolder" },
    };
}

pub const shellex_types = [_][]const u8{ "*", "AllFilesystemObjects", "Directory", "Directory\\Background", "Folder", "Drive" };

/// Startup.IsApproved: null/empty = enabled; low bit of byte 0 set = disabled.
pub fn isApproved(v: ?[]const u8) bool {
    const b = v orelse return true;
    return b.len == 0 or b[0] & 1 == 0;
}

/// Startup.ApprovedBytes: 12 bytes, byte 0 = 2 (enabled) / 3 (disabled), then the FILETIME of disabling
/// (`utc_now`, whole seconds) at offset 4.
pub fn approvedBytes(enabled: bool, utc_now: common.DateTime) [12]u8 {
    var b: [12]u8 = @splat(0);
    b[0] = if (enabled) 2 else 3;
    if (!enabled) std.mem.writeInt(u64, b[4..12], fileTime(utc_now), .little);
    return b;
}

/// DateTime.ToFileTimeUtc (0 for a date SystemTimeToFileTime rejects).
fn fileTime(d: common.DateTime) u64 {
    const st: w.SYSTEMTIME = .{ .wYear = d.year, .wMonth = d.month, .wDayOfWeek = 0, .wDay = d.day, .wHour = d.hour, .wMinute = d.minute, .wSecond = d.second, .wMilliseconds = 0 };
    var ft: w.FILETIME = undefined;
    if (w.SystemTimeToFileTime(&st, &ft) == 0) return 0;
    return @as(u64, ft.dwHighDateTime) << 32 | ft.dwLowDateTime;
}

/// The StartupApproved value `name` (null = key or value missing: enabled).
fn approvedValue(arena: Allocator, approved: ?win.Key, name: []const u8) !?[]const u8 {
    return sys.binary(arena, approved orelse return null, name);
}

/// Startup.ReadRun: named values of a Run key.
pub fn readRun(arena: Allocator, run_key: []const u8, approved_key: []const u8) ![]StartupItem {
    const k = try reg.open(run_key, false) orelse return &.{};
    defer k.close();
    const ap = try reg.open(approved_key, false);
    defer if (ap) |a| a.close();
    const loc = try arena.dupe(u8, run_key);
    const approved = try arena.dupe(u8, approved_key);
    var out: std.ArrayList(StartupItem) = .empty;
    for (try k.values(arena)) |v| {
        if (v.name.len == 0) continue;
        try out.append(arena, .{ .kind = .run, .name = v.name, .command = try sys.text(arena, k, v.name), .enabled = isApproved(try approvedValue(arena, ap, v.name)), .location = loc, .approved = approved });
    }
    return out.items;
}

/// Startup.ReadFolder: files of a Startup folder except desktop.ini; a missing/unreadable folder lists nothing
/// (Directory.Exists).
pub fn readFolder(arena: Allocator, io: Io, folder: []const u8, approved_key: []const u8) ![]StartupItem {
    if (folder.len == 0) return &.{};
    var dir = Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    const ap = try reg.open(approved_key, false);
    defer if (ap) |a| a.close();
    const approved = try arena.dupe(u8, approved_key);
    var out: std.ArrayList(StartupItem) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or common.eqlIgnoreCase(e.name, "desktop.ini")) continue; // ponytail: file symlinks skipped
        const name = try arena.dupe(u8, e.name);
        const full = try Io.Dir.path.join(arena, &.{ folder, name });
        try out.append(arena, .{ .kind = .folder, .name = name, .command = full, .enabled = isApproved(try approvedValue(arena, ap, name)), .location = full, .approved = approved });
    }
    return out.items;
}

/// Default value of `path` as a string (null: no key / no string).
fn defaultString(arena: Allocator, path: []const u8) !?[]const u8 {
    const k = try reg.open(path, false) orelse return null;
    defer k.close();
    return sys.string(arena, k, "");
}

/// Startup.ReadContextMenu: classes_root is "HKCR" in production, a test key in tests.
pub fn readContextMenu(arena: Allocator, classes_root: []const u8, blocked: []const u8) ![]StartupItem {
    var blocked_ids: []win.ValueInfo = &.{};
    if (try reg.open(blocked, false)) |b| {
        defer b.close();
        blocked_ids = try b.values(arena);
    }
    const blocked_dup = try arena.dupe(u8, blocked);
    var out: std.ArrayList(StartupItem) = .empty;
    for (shellex_types) |t| {
        const handlers = try arena.print("{s}\\{s}\\shellex\\ContextMenuHandlers", .{ classes_root, t });
        for (try reg.subKeys(arena, handlers)) |name| {
            const loc = try arena.print("{s}\\{s}", .{ handlers, name });
            const clsid = if (std.mem.startsWith(u8, name, "{")) name else sys.trim(try defaultString(arena, loc) orelse "");
            var label: ?[]const u8 = null;
            var server: ?[]const u8 = null;
            if (clsid.len > 0) {
                label = try defaultString(arena, try arena.print("{s}\\CLSID\\{s}", .{ classes_root, clsid }));
                server = try defaultString(arena, try arena.print("{s}\\CLSID\\{s}\\InprocServer32", .{ classes_root, clsid }));
            }
            var is_blocked = false;
            for (blocked_ids) |v| is_blocked = is_blocked or common.eqlIgnoreCase(v.name, clsid);
            const l = label orelse "";
            try out.append(arena, .{
                .kind = .context_menu,
                .name = if (sys.trim(l).len == 0) name else l,
                .command = server orelse "",
                .enabled = !is_blocked,
                .location = loc,
                .approved = blocked_dup,
                .id = clsid,
                .info = t,
            });
        }
    }
    return out.items;
}

/// Startup.ReadServices: Win32 services only (Type & 0x30, no 0xC0 per-user templates/instances), Start >= 2.
pub fn readServices(arena: Allocator, services: []const u8) ![]StartupItem {
    var out: std.ArrayList(StartupItem) = .empty;
    for (try reg.subKeys(arena, services)) |name| {
        const loc = try arena.print("{s}\\{s}", .{ services, name });
        const k = try reg.open(loc, false) orelse continue;
        defer k.close();
        const typ = sys.int(k, "Type") orelse continue;
        if (typ & 0x30 == 0 or typ & 0xC0 != 0) continue;
        const start = sys.int(k, "Start") orelse continue;
        if (start < 2) continue;
        const info = switch (start) {
            2 => if (sys.int(k, "DelayedAutostart") == 1) "Auto (delayed)" else "Auto",
            3 => "Manual",
            else => "Disabled",
        };
        try out.append(arena, .{
            .kind = .service,
            .name = try indirect(arena, try sys.string(arena, k, "DisplayName") orelse name),
            .command = try sys.string(arena, k, "ImagePath") orelse "",
            .enabled = start != 4,
            .location = loc,
            .id = name,
            .info = info,
        });
    }
    return out.items;
}

extern "shlwapi" fn SHLoadIndirectString(src: [*:0]const u16, out: [*]u16, cch: c_uint, reserved: ?*anyopaque) callconv(.winapi) w.HRESULT;

/// "@%SystemRoot%\system32\x.dll,-100" -> localized name (unchanged when it cannot be resolved).
fn indirect(arena: Allocator, s: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, s, "@")) return s;
    const src = try win.toW(arena, s);
    var buf: [512]u16 = undefined;
    if (SHLoadIndirectString(src.ptr, &buf, buf.len, null) != 0) return s;
    return win.fromW(arena, std.mem.sliceTo(&buf, 0));
}

/// Startup.ReadTasks: non-\Microsoft tasks (hidden included) via Task Scheduler COM (no localized schtasks text).
pub fn readTasks(arena: Allocator) ![]StartupItem {
    const apt = try sys.Apartment.enter();
    defer apt.leave();
    const root = try sys.taskFolder("\\");
    defer win.release(root);
    var out: std.ArrayList(StartupItem) = .empty;
    try walkTasks(arena, root, &out);
    return out.items;
}

fn walkTasks(arena: Allocator, folder: [*c]w.ITaskFolder, out: *std.ArrayList(StartupItem)) !void {
    var bp: w.BSTR = null;
    try sys.check(folder.*.lpVtbl.*.get_Path.?(folder, &bp));
    if (common.startsWithIgnoreCase(try sys.takeBstr(arena, bp), "\\Microsoft")) return;

    var tasks: [*c]w.IRegisteredTaskCollection = null;
    try sys.check(folder.*.lpVtbl.*.GetTasks.?(folder, 1, &tasks)); // 1 = TASK_ENUM_HIDDEN
    defer win.release(tasks);
    var n: w.LONG = 0;
    try sys.check(tasks.*.lpVtbl.*.get_Count.?(tasks, &n));
    for (1..@as(usize, @intCast(@max(n, 0))) + 1) |i| {
        var t: [*c]w.IRegisteredTask = null;
        try sys.check(tasks.*.lpVtbl.*.get_Item.?(tasks, sys.variantI4(@intCast(i)), &t));
        defer win.release(t);
        var name: w.BSTR = null;
        var path: w.BSTR = null;
        var enabled: w.VARIANT_BOOL = 0;
        try sys.check(t.*.lpVtbl.*.get_Name.?(t, &name));
        const name_s = try sys.takeBstr(arena, name);
        try sys.check(t.*.lpVtbl.*.get_Path.?(t, &path));
        const path_s = try sys.takeBstr(arena, path);
        try sys.check(t.*.lpVtbl.*.get_Enabled.?(t, &enabled));
        const cmd = execCommand(arena, t) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => "", // definition not readable without admin
        };
        try out.append(arena, .{ .kind = .task, .name = name_s, .command = cmd, .enabled = enabled != 0, .location = path_s });
    }

    var subs: [*c]w.ITaskFolderCollection = null;
    try sys.check(folder.*.lpVtbl.*.GetFolders.?(folder, 0, &subs));
    defer win.release(subs);
    try sys.check(subs.*.lpVtbl.*.get_Count.?(subs, &n));
    for (1..@as(usize, @intCast(@max(n, 0))) + 1) |i| {
        var f: [*c]w.ITaskFolder = null;
        try sys.check(subs.*.lpVtbl.*.get_Item.?(subs, sys.variantI4(@intCast(i)), &f));
        defer win.release(f);
        try walkTasks(arena, f, out);
    }
}

/// "{Path} {Arguments}" of the first exec action, trimmed; "" when there is none.
fn execCommand(arena: Allocator, t: [*c]w.IRegisteredTask) ![]const u8 {
    var def: [*c]w.ITaskDefinition = null;
    try sys.check(t.*.lpVtbl.*.get_Definition.?(t, &def));
    defer win.release(def);
    var acts: [*c]w.IActionCollection = null;
    try sys.check(def.*.lpVtbl.*.get_Actions.?(def, &acts));
    defer win.release(acts);
    var n: w.LONG = 0;
    try sys.check(acts.*.lpVtbl.*.get_Count.?(acts, &n));
    var i: w.LONG = 1;
    while (i <= n) : (i += 1) {
        var a: [*c]w.IAction = null;
        try sys.check(acts.*.lpVtbl.*.get_Item.?(acts, i, &a));
        defer win.release(a);
        var kind: w.TASK_ACTION_TYPE = undefined;
        try sys.check(a.*.lpVtbl.*.get_Type.?(a, &kind));
        if (kind != w.TASK_ACTION_EXEC) continue;
        var ex: [*c]w.IExecAction = null;
        try sys.check(a.*.lpVtbl.*.QueryInterface.?(a, &w.IID_IExecAction, @ptrCast(&ex)));
        defer win.release(ex);
        var p: w.BSTR = null;
        var args: w.BSTR = null;
        try sys.check(ex.*.lpVtbl.*.get_Path.?(ex, &p));
        const p_s = try sys.takeBstr(arena, p);
        try sys.check(ex.*.lpVtbl.*.get_Arguments.?(ex, &args));
        const a_s = try sys.takeBstr(arena, args);
        return sys.trim(try arena.print("{s} {s}", .{ p_s, a_s }));
    }
    return "";
}

/// Startup.ReadWindows: run_keys + folders.
pub fn readWindows(arena: Allocator, io: Io) ![]StartupItem {
    var out: std.ArrayList(StartupItem) = .empty;
    for (run_keys) |r| try out.appendSlice(arena, try readRun(arena, r.run, r.approved));
    for (folders(arena)) |f| try out.appendSlice(arena, try readFolder(arena, io, f.folder, f.approved));
    return out.items;
}

/// Startup.SetEnabled. False = the elevated retry was declined or failed.
pub fn setEnabled(gpa: Allocator, it: *const StartupItem, on: bool) !bool {
    switch (it.kind) {
        .run, .folder => return reg.setBinary(gpa, it.approved, it.name, &approvedBytes(on, .nowUtc())),
        .context_menu => return if (on) reg.deleteValue(gpa, it.approved, it.id) else reg.setString(gpa, it.approved, it.id, ""),
        .task => {
            const args = try gpa.print("/change /tn \"{s}\" /{s}", .{ it.location, if (on) "enable" else "disable" });
            defer gpa.free(args);
            return taskAction(it.location, .{ .enable = on }, args);
        },
        .service => {
            const args = try serviceToggleArgs(gpa, it, on);
            defer gpa.free(args);
            return elevated.run("cmd.exe", args);
        },
    }
}

/// Startup.ServiceToggleArgs: cmd.exe args for `sc config` + the MakeCleanerPrevStart bookkeeping value.
/// ponytail: Windows has no "previous start type"; we keep it in a value inside the service's own key.
/// Caller frees.
pub fn serviceToggleArgs(gpa: Allocator, it: *const StartupItem, on: bool) ![]u8 {
    const key = services_key ++ "\\";
    if (!on) {
        const prev: u8 = if (std.mem.eql(u8, it.info, "Manual")) 3 else 2;
        return gpa.print("/c sc config \"{s}\" start= disabled & reg add \"{s}{s}\" /v {s} /t REG_DWORD /d {d} /f", .{ it.id, key, it.id, prev_start_value, prev });
    }
    var start: []const u8 = "demand";
    if (try reg.open(it.location, false)) |k| {
        defer k.close();
        if (sys.int(k, prev_start_value) == 2) start = if (sys.int(k, "DelayedAutostart") == 1) "delayed-auto" else "auto";
    }
    return gpa.print("/c sc config \"{s}\" start= {s} & reg delete \"{s}{s}\" /v {s} /f", .{ it.id, start, key, it.id, prev_start_value });
}

/// Startup.IsSystemService: command under %windir% / \Windows\ / system32 (never deleted). An unknown windir
/// counts as "" and, like string.Contains(""), marks everything as system (the safe direction).
pub fn isSystemService(it: *const StartupItem) bool {
    var buf: [2048]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const windir = win.knownFolder(fba.allocator(), &w.FOLDERID_Windows) catch "";
    const c = it.command;
    // ponytail: ASCII case folding; the needles are ASCII paths
    return std.ascii.findIgnoreCase(c, windir) != null or std.ascii.findIgnoreCase(c, "\\Windows\\") != null or std.ascii.findIgnoreCase(c, "system32") != null;
}

/// Startup.Delete. False = refused (system service) or the elevated retry was declined/failed.
pub fn delete(gpa: Allocator, io: Io, it: *const StartupItem) !bool {
    switch (it.kind) {
        .run => return try reg.deleteValue(gpa, it.location, it.name) and try dropApproved(gpa, it),
        .folder => {
            const args = try gpa.print("/c del /f /q \"{s}\"", .{it.location});
            defer gpa.free(args);
            return try elevated.tryOr(deleteFile(io, it.location), "cmd.exe", args) and try dropApproved(gpa, it);
        },
        .context_menu => return try reg.deleteKey(gpa, it.location) and (it.enabled or try reg.deleteValue(gpa, it.approved, it.id)),
        .task => {
            const loc = it.location;
            const i = std.mem.findScalarLast(u8, loc, '\\');
            const parent = if (i) |x| (if (x == 0) "\\" else loc[0..x]) else "\\";
            const leaf = if (i) |x| loc[x + 1 ..] else loc;
            const args = try gpa.print("/delete /tn \"{s}\" /f", .{loc});
            defer gpa.free(args);
            return taskAction(parent, .{ .delete = leaf }, args);
        },
        .service => {
            if (isSystemService(it)) return false;
            const args = try gpa.print("delete \"{s}\"", .{it.id});
            defer gpa.free(args);
            return elevated.run("sc.exe", args);
        },
    }
}

/// File.Delete: a missing file is fine.
fn deleteFile(io: Io, path: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, path) catch |e| if (e != error.FileNotFound) return e;
}

/// Drops the StartupApproved value too (nothing to do when there is none).
fn dropApproved(gpa: Allocator, it: *const StartupItem) !bool {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const k = try reg.open(it.approved, false) orelse return true;
    const v = approvedValue(arena_state.allocator(), k, it.name);
    k.close();
    if (try v == null) return true;
    return reg.deleteValue(gpa, it.approved, it.name);
}

const TaskOp = union(enum) { enable: bool, delete: []const u8 };

/// Direct COM first; access denied -> elevated schtasks.exe. `path` = the task (enable) or its folder (delete).
fn taskAction(path: []const u8, op: TaskOp, schtasks_args: []const u8) !bool {
    return elevated.tryOr(taskDirect(path, op), "schtasks.exe", schtasks_args);
}

fn taskDirect(path: []const u8, op: TaskOp) !void {
    const apt = try sys.Apartment.enter();
    defer apt.leave();
    switch (op) {
        .enable => |on| {
            const root = try sys.taskFolder("\\");
            defer win.release(root);
            const p = try sys.bstr(path);
            defer w.SysFreeString(p);
            var t: [*c]w.IRegisteredTask = null;
            try sys.check(root.*.lpVtbl.*.GetTask.?(root, p, &t));
            defer win.release(t);
            try sys.check(t.*.lpVtbl.*.put_Enabled.?(t, if (on) -1 else 0)); // VARIANT_TRUE / VARIANT_FALSE
        },
        .delete => |leaf| {
            const folder = try sys.taskFolder(path);
            defer win.release(folder);
            const l = try sys.bstr(leaf);
            defer w.SysFreeString(l);
            try sys.check(folder.*.lpVtbl.*.DeleteTask.?(folder, l, 0));
        },
    }
}
