//! Elevated.cs: MakeCleaner runs as the user; admin-only actions ask for UAC only when the user starts one.
const std = @import("std");
const kit = @import("kit");
const win = kit.win;

/// Elevated.IsAdmin.
pub fn isAdmin() bool {
    return win.isElevated();
}

/// Elevated.RelaunchAsAdmin: true = elevated copy started (caller should close); false = UAC declined.
pub fn relaunchAsAdmin() bool {
    var buf: [32768]u16 = undefined;
    const n = kit.w.GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0 or n >= buf.len) return false;
    const gpa = std.heap.page_allocator;
    const exe = win.fromW(gpa, buf[0..n]) catch return false;
    defer gpa.free(exe);
    _ = win.shellExecute(gpa, .{ .file = exe, .verb = "runas" }) catch return false;
    return true;
}

pub const Runner = *const fn (exe: []const u8, args: []const u8) bool;

/// What `run` calls. Tests swap in a fake so no test ever shows a UAC prompt.
pub var runner: Runner = runElevated;

/// Elevated.Run: runs a system tool elevated, hidden, and waits (UAC prompt only now).
/// False if the user declined or the tool failed (exit code != 0).
pub fn run(exe: []const u8, args: []const u8) bool {
    return runner(exe, args);
}

fn runElevated(exe: []const u8, args: []const u8) bool {
    const code = win.shellExecute(std.heap.page_allocator, .{ .file = exe, .params = args, .verb = "runas", .hidden = true, .wait = true }) catch return false;
    return (code orelse return false) == 0;
}

/// Elevated.Try: `direct` is the result of the plain attempt (evaluated by the caller first). Access denied
/// repeats the action as `exe args` elevated; any other error propagates, success is true.
pub fn tryOr(direct: anyerror!void, exe: []const u8, args: []const u8) anyerror!bool {
    direct catch |e| switch (e) {
        error.AccessDenied, error.PermissionDenied => return run(exe, args),
        else => return e,
    };
    return true;
}

/// Test fake for `runner`: records the last call, answers `result`.
pub const Fake = struct {
    pub var calls: usize = 0;
    pub var last_exe: [64]u8 = undefined;
    pub var last_args: [1024]u8 = undefined;
    pub var last_exe_len: usize = 0;
    pub var last_args_len: usize = 0;
    pub var result = false;

    pub fn install() void {
        calls = 0;
        last_exe_len = 0;
        last_args_len = 0;
        runner = record;
    }

    pub fn uninstall() void {
        runner = runElevated;
    }

    pub fn exe() []const u8 {
        return last_exe[0..last_exe_len];
    }

    pub fn args() []const u8 {
        return last_args[0..last_args_len];
    }

    fn record(e: []const u8, a: []const u8) bool {
        calls += 1;
        last_exe_len = @min(e.len, last_exe.len);
        @memcpy(last_exe[0..last_exe_len], e[0..last_exe_len]);
        last_args_len = @min(a.len, last_args.len);
        @memcpy(last_args[0..last_args_len], a[0..last_args_len]);
        return result;
    }
};

test "Try: success never elevates, access denied runs the tool elevated, other errors propagate" {
    Fake.install();
    defer Fake.uninstall();
    Fake.result = true;

    try std.testing.expect(try tryOr({}, "reg.exe", "add x"));
    try std.testing.expectEqual(0, Fake.calls);

    try std.testing.expect(try tryOr(error.AccessDenied, "reg.exe", "add x"));
    try std.testing.expectEqual(1, Fake.calls);
    try std.testing.expectEqualStrings("reg.exe", Fake.exe());
    try std.testing.expectEqualStrings("add x", Fake.args());

    Fake.result = false; // UAC declined / tool failed
    try std.testing.expect(!try tryOr(error.PermissionDenied, "cmd.exe", "/c x"));
    try std.testing.expectEqual(2, Fake.calls);

    try std.testing.expectError(error.FileNotFound, tryOr(error.FileNotFound, "reg.exe", ""));
    try std.testing.expectEqual(2, Fake.calls);
}

test "IsAdmin answers without side effects" {
    _ = isAdmin();
}
