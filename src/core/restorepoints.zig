//! RestorePoints.cs (Tools > System Restore): list and remove restore points. WMI root\default:SystemRestore
//! denies both without admin.
const std = @import("std");
const kit = @import("kit");
const common = @import("common.zig");
const sys = @import("systools_win.zig");

const w = kit.w;
const win = kit.win;
const Allocator = std.mem.Allocator;

/// record RestorePoint(Seq, Description, Created); `created` is UTC.
pub const RestorePoint = struct { seq: u32, description: []const u8, created: common.DateTime };

/// RestorePoints.CanRemove: the newest restore point is the user's safety net, never removable.
pub fn canRemove(p: *const RestorePoint, all: []const RestorePoint) bool {
    var max: ?u32 = null;
    for (all) |x| max = @max(max orelse x.seq, x.seq);
    return p.seq != (max orelse return false);
}

/// RestorePoints.List: error.AccessDenied without admin (the GUI says "Administrator rights are required to
/// list restore points."); other WMI failures are error.ComFailed ("System Restore unavailable").
/// Strings in `arena`.
pub fn list(arena: Allocator) ![]RestorePoint {
    const apt = try sys.Apartment.enter();
    defer apt.leave();
    var loc: [*c]w.IWbemLocator = null;
    try sys.check(w.CoCreateInstance(&w.CLSID_WbemLocator, null, @intCast(w.CLSCTX_INPROC_SERVER), &w.IID_IWbemLocator, @ptrCast(&loc)));
    defer win.release(loc);
    const ns = try sys.bstr("root\\default");
    defer w.SysFreeString(ns);
    var svc: [*c]w.IWbemServices = null;
    try sys.check(loc.*.lpVtbl.*.ConnectServer.?(loc, ns, null, null, null, 0, null, null, &svc));
    defer win.release(svc);
    try sys.check(w.CoSetProxyBlanket(@ptrCast(svc), w.RPC_C_AUTHN_WINNT, w.RPC_C_AUTHZ_NONE, null, w.RPC_C_AUTHN_LEVEL_CALL, w.RPC_C_IMP_LEVEL_IMPERSONATE, null, w.EOAC_NONE));

    const wql = try sys.bstr("WQL");
    defer w.SysFreeString(wql);
    const query = try sys.bstr("SELECT * FROM SystemRestore");
    defer w.SysFreeString(query);
    var en: [*c]w.IEnumWbemClassObject = null;
    try sys.check(svc.*.lpVtbl.*.ExecQuery.?(svc, wql, query, w.WBEM_FLAG_FORWARD_ONLY | w.WBEM_FLAG_RETURN_IMMEDIATELY, null, &en));
    defer win.release(en);

    var out: std.ArrayList(RestorePoint) = .empty;
    while (true) {
        var obj: [*c]w.IWbemClassObject = null;
        var n: w.ULONG = 0;
        try sys.check(en.*.lpVtbl.*.Next.?(en, -1, 1, &obj, &n)); // -1 = WBEM_INFINITE
        if (n == 0) break;
        defer win.release(obj);
        if (obj == null) return error.AccessDenied; // what WbemScripting hands a non-admin
        var seq = try prop(obj, win.L("SequenceNumber"));
        defer _ = w.VariantClear(&seq);
        var desc = try prop(obj, win.L("Description"));
        defer _ = w.VariantClear(&desc);
        var created = try prop(obj, win.L("CreationTime"));
        defer _ = w.VariantClear(&created);
        try out.append(arena, .{
            .seq = @bitCast(seq.unnamed_0.unnamed_0.unnamed_0.lVal), // uint32 arrives as VT_I4
            .description = try str(arena, desc),
            .created = try parseCim(try str(arena, created)),
        });
    }
    return out.items;
}

fn prop(obj: [*c]w.IWbemClassObject, name: [*:0]const u16) !w.VARIANT {
    var v = sys.empty_variant;
    try sys.check(obj.*.lpVtbl.*.Get.?(obj, name, 0, &v, null, null));
    return v;
}

/// VT_BSTR -> UTF-8; anything else (VT_NULL) = "".
fn str(arena: Allocator, v: w.VARIANT) ![]const u8 {
    if (v.unnamed_0.unnamed_0.vt != w.VT_BSTR) return "";
    const b = v.unnamed_0.unnamed_0.unnamed_0.bstrVal;
    if (b == null) return "";
    return win.fromW(arena, b[0..w.SysStringLen(b)]);
}

/// RestorePoints.ParseCim: CIM_DATETIME "yyyyMMddHHmmss.ffffff+UUU" -> UTC (first 14 digits).
pub fn parseCim(s: []const u8) !common.DateTime {
    if (s.len < 14) return error.InvalidFormat;
    const num = struct {
        fn f(t: []const u8) !u16 {
            return std.fmt.parseUnsigned(u16, t, 10) catch error.InvalidFormat;
        }
    }.f;
    const d: common.DateTime = .{ .year = try num(s[0..4]), .month = @intCast(try num(s[4..6])), .day = @intCast(try num(s[6..8])), .hour = @intCast(try num(s[8..10])), .minute = @intCast(try num(s[10..12])), .second = @intCast(try num(s[12..14])) };
    if (d.month < 1 or d.month > 12 or d.hour > 23 or d.minute > 59 or d.second > 59) return error.InvalidFormat;
    // ParseExact also rejects impossible dates (Feb 30, Feb 29 outside leap years)
    if (d.year < 1 or d.day < 1 or d.day > std.time.epoch.getDaysInMonth(d.year, @fromBackingInt(@intCast(d.month)))) return error.InvalidFormat;
    return d;
}

const SrRemove = *const fn (seq: w.DWORD) callconv(.winapi) w.DWORD;

/// srclient!SRRemoveRestorePoint (no import lib in `w`); null when srclient.dll or the export is missing.
/// ponytail: srclient stays loaded for the life of the process.
fn srRemove() ?SrRemove {
    const lib = w.LoadLibraryW(win.L("srclient.dll"));
    if (lib == null) return null;
    return @ptrCast(w.GetProcAddress(lib, "SRRemoveRestorePoint") orelse return null);
}

/// RestorePoints.Remove: 0 = removed, else the Win32 error code (needs admin).
pub fn remove(seq: u32) u32 {
    const f = srRemove() orelse return w.GetLastError();
    return f(seq);
}

test "SRRemoveRestorePoint resolves from srclient.dll (never called by tests)" {
    try std.testing.expect(srRemove() != null);
}
