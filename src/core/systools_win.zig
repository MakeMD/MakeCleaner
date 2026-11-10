//! Plumbing shared by startup.zig, uninstall.zig, schedule.zig and restorepoints.zig (package MC-D):
//! a COM apartment per call, HRESULT -> error mapping, BSTR/VARIANT helpers, the Task Scheduler folder, and
//! registry values read the way .NET's RegistryKey.GetValue returns them.
const std = @import("std");
const kit = @import("kit");

const w = kit.w;
const win = kit.win;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------- COM

/// CoInitializeEx(STA) for the duration of one call, so the core works from any thread (UI or kit.jobs worker).
/// Balanced only when this call counted (S_OK / S_FALSE); a thread that is already MTA (RPC_E_CHANGED_MODE)
/// can use COM as it is.
pub const Apartment = struct {
    owned: bool,

    pub fn enter() !Apartment {
        const hr = w.CoInitializeEx(null, @intCast(w.COINIT_APARTMENTTHREADED | w.COINIT_DISABLE_OLE1DDE));
        if (@as(u32, @bitCast(hr)) == 0x80010106) return .{ .owned = false }; // RPC_E_CHANGED_MODE
        try win.check(hr);
        return .{ .owned = true };
    }

    pub fn leave(a: Apartment) void {
        if (a.owned) w.CoUninitialize();
    }
};

pub const Error = error{ AccessDenied, NotFound, ComFailed };

/// FAILED(hr) -> error: E_ACCESSDENIED / WBEM_E_ACCESS_DENIED = AccessDenied (elevated.tryOr retries those),
/// 0x80070002 = NotFound (the only "not found" Schedule.cs matches), anything else ComFailed (code in win.last_hr).
pub fn check(hr: w.HRESULT) Error!void {
    if (hr >= 0) return;
    win.last_hr = hr;
    return switch (@as(u32, @bitCast(hr))) {
        0x80070005, 0x80041003 => error.AccessDenied,
        0x80070002 => error.NotFound,
        else => error.ComFailed,
    };
}

/// UTF-8 -> BSTR without an allocator (free with w.SysFreeString).
pub fn bstr(s: []const u8) !w.BSTR {
    const n = try std.unicode.calcWtf16LeLen(s);
    const b = w.SysAllocStringLen(null, @intCast(n));
    if (b == null) return error.OutOfMemory;
    _ = std.unicode.wtf8ToWtf16Le(b[0..n], s) catch unreachable; // length checked above
    return b;
}

/// BSTR -> UTF-8 in `arena`, then frees the BSTR; null = "".
pub fn takeBstr(arena: Allocator, b: w.BSTR) ![]u8 {
    if (b == null) return arena.dupe(u8, "");
    defer w.SysFreeString(b);
    return win.fromW(arena, b[0..w.SysStringLen(b)]);
}

pub const empty_variant = std.mem.zeroes(w.VARIANT);

/// VT_I4 VARIANT (1-based collection index).
pub fn variantI4(i: i32) w.VARIANT {
    var v = empty_variant;
    v.unnamed_0.unnamed_0.vt = @intCast(w.VT_I4);
    v.unnamed_0.unnamed_0.unnamed_0.lVal = i;
    return v;
}

/// Task Scheduler folder at `path` ("\" = root) of a freshly connected local service; release it.
/// The caller holds an Apartment.
pub fn taskFolder(path: []const u8) ![*c]w.ITaskFolder {
    var svc: [*c]w.ITaskService = null;
    try check(w.CoCreateInstance(&w.CLSID_TaskScheduler, null, @intCast(w.CLSCTX_INPROC_SERVER), &w.IID_ITaskService, @ptrCast(&svc)));
    defer win.release(svc);
    try check(svc.*.lpVtbl.*.Connect.?(svc, empty_variant, empty_variant, empty_variant, empty_variant));
    const p = try bstr(path);
    defer w.SysFreeString(p);
    var folder: [*c]w.ITaskFolder = null;
    try check(svc.*.lpVtbl.*.GetFolder.?(svc, p, &folder));
    return folder;
}

// ---------------------------------------------------------------- registry values (.NET GetValue semantics)

/// `GetValue(name) as string`: REG_SZ, or REG_EXPAND_SZ expanded (GetValue expands by default); null when
/// missing or another type. Default value: name "".
pub fn string(arena: Allocator, k: win.Key, name: []const u8) !?[]const u8 {
    const v = k.readRaw(arena, name) catch |e| return if (e == error.NotFound) null else e;
    if (v.kind != w.REG_SZ and v.kind != w.REG_EXPAND_SZ) return null;
    const units = try arena.alloc(u16, v.data.len / 2); // registry data is byte-aligned: copy, don't cast
    @memcpy(std.mem.sliceAsBytes(units), v.data[0 .. units.len * 2]);
    const s = try win.fromW(arena, std.mem.trimEnd(u16, units, &.{0}));
    return if (v.kind == w.REG_EXPAND_SZ) try win.expandEnv(arena, s) else s;
}

/// `GetValue(name) is int i ? i : null` (REG_DWORD only).
pub fn int(k: win.Key, name: []const u8) ?i32 {
    return @bitCast(k.readDword(name) catch return null);
}

/// `GetValue(name) as byte[]`: REG_BINARY / REG_NONE data, else null.
pub fn binary(arena: Allocator, k: win.Key, name: []const u8) !?[]const u8 {
    const v = k.readRaw(arena, name) catch |e| return if (e == error.NotFound) null else e;
    return if (v.kind == w.REG_BINARY or v.kind == w.REG_NONE) v.data else null;
}

/// `GetValue(name)?.ToString() ?? ""` for what a Run value can hold: strings and DWORDs.
/// ponytail: other types print as "" (.NET would print "System.Byte[]").
pub fn text(arena: Allocator, k: win.Key, name: []const u8) ![]const u8 {
    if (try string(arena, k, name)) |s| return s;
    if (int(k, name)) |i| return arena.print("{d}", .{i});
    return "";
}

pub const trim = @import("common.zig").trim;

test "bstr round trip and HRESULT mapping" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const b = try bstr("Їжак \\ x");
    try std.testing.expectEqualStrings("Їжак \\ x", try takeBstr(arena_state.allocator(), b));
    try std.testing.expectEqualStrings("", try takeBstr(arena_state.allocator(), null));
    try std.testing.expectError(error.AccessDenied, check(@bitCast(@as(u32, 0x80070005))));
    try std.testing.expectError(error.NotFound, check(@bitCast(@as(u32, 0x80070002))));
    try std.testing.expectError(error.ComFailed, check(@bitCast(@as(u32, 0x80070003))));
    try check(1); // S_FALSE is success
}
