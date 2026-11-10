//! Reg.cs: registry by full path ("HKLM\SOFTWARE\..."). open / subKeys / set* / delete* always use the 64-bit
//! view (32-bit keys are addressed via WOW6432Node); writes go direct first and only on access denied repeat
//! through an elevated reg.exe, so UAC appears at the moment of the action. tryOpen / keyExists / exists /
//! delete are the non-throwing side used by rule detection and cleaning.
const std = @import("std");
const kit = @import("kit");
const elevated = @import("elevated.zig");
const RegKey = @import("rules.zig").RegKey;

const win = kit.win;
const w = kit.w;
const Allocator = std.mem.Allocator;

pub const Split = struct { root: win.Root, sub: []const u8 };

/// Reg.Split / Reg.TrySplit: "HKCU\Software\X" -> (.hkcu, "Software\X"). Hive aliases HKCU/HKLM/HKCR/HKU and
/// their HKEY_* long forms, any case. Never yields an empty `sub`: an empty sub would address the hive itself
/// (RegDeleteTree on it wipes the whole hive), so "HKCU" and "HKCU\" are error.InvalidPath.
pub fn split(path: []const u8) error{ UnknownHive, InvalidPath }!Split {
    const i = std.mem.findScalar(u8, path, '\\') orelse return error.InvalidPath;
    const root = hive(path[0..i]) orelse return error.UnknownHive;
    const sub = std.mem.trim(u8, path[i + 1 ..], "\\");
    if (sub.len == 0) return error.InvalidPath;
    return .{ .root = root, .sub = sub };
}

fn hive(name: []const u8) ?win.Root {
    const names = [_]struct { []const u8, []const u8, win.Root }{
        .{ "HKCU", "HKEY_CURRENT_USER", .hkcu },
        .{ "HKLM", "HKEY_LOCAL_MACHINE", .hklm },
        .{ "HKCR", "HKEY_CLASSES_ROOT", .hkcr },
        .{ "HKU", "HKEY_USERS", .hku },
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(name, n[0]) or std.ascii.eqlIgnoreCase(name, n[1])) return n[2];
    return null;
}

/// Reg.Open (64-bit view): null when the key is missing; access denied and bad paths are errors.
pub fn open(path: []const u8, writable: bool) !?win.Key {
    const s = try split(path);
    return win.openKey(s.root, s.sub, .{ .write = writable, .view = .wow64_64 }) catch |e| switch (e) {
        error.NotFound => null,
        else => |x| x,
    };
}

/// Reg.SubKeys: names of direct subkeys, empty when the key is missing. Free with `kit.win.freeList`.
pub fn subKeys(gpa: Allocator, path: []const u8) ![][]u8 {
    const k = try open(path, false) orelse return gpa.alloc([]u8, 0);
    defer k.close();
    return k.subkeys(gpa);
}

/// Reg.SetBinary: REG_BINARY value (creates the key). False only when the elevated retry was declined/failed.
pub fn setBinary(gpa: Allocator, key: []const u8, name: []const u8, value: []const u8) !bool {
    const args = try gpa.print("add \"{s}\" /v \"{s}\" /t REG_BINARY /d {X} /f /reg:64", .{ key, name, value });
    defer gpa.free(args);
    return elevated.tryOr(setDirect(key, name, w.REG_BINARY, value), "reg.exe", args);
}

/// Reg.SetString: REG_SZ value (creates the key).
pub fn setString(gpa: Allocator, key: []const u8, name: []const u8, value: []const u8) !bool {
    const args = try gpa.print("add \"{s}\" /v \"{s}\" /t REG_SZ /d \"{s}\" /f /reg:64", .{ key, name, value });
    defer gpa.free(args);
    return elevated.tryOr(setDirect(key, name, w.REG_SZ, value), "reg.exe", args);
}

fn setDirect(key: []const u8, name: []const u8, kind: u32, value: []const u8) !void {
    const s = try split(key);
    const k = try win.createKey(s.root, s.sub, .wow64_64);
    defer k.close();
    if (kind == w.REG_SZ) try k.writeString(name, value) else try k.writeRaw(name, kind, value);
}

/// Reg.DeleteValue: a missing key or value is fine (true).
pub fn deleteValue(gpa: Allocator, key: []const u8, name: []const u8) !bool {
    const args = try gpa.print("delete \"{s}\" /v \"{s}\" /f /reg:64", .{ key, name });
    defer gpa.free(args);
    return elevated.tryOr(deleteValueDirect(key, name), "reg.exe", args);
}

fn deleteValueDirect(key: []const u8, name: []const u8) !void {
    const k = try open(key, true) orelse return;
    defer k.close();
    k.deleteValue(name) catch |e| if (e != error.NotFound) return e;
}

/// Reg.DeleteKey: the key with all subkeys; a missing key is fine (true). Never a whole hive (see split).
pub fn deleteKey(gpa: Allocator, key: []const u8) !bool {
    const args = try gpa.print("delete \"{s}\" /f /reg:64", .{key});
    defer gpa.free(args);
    return elevated.tryOr(deleteKeyDirect(key), "reg.exe", args);
}

fn deleteKeyDirect(key: []const u8) !void {
    const s = try split(key);
    win.deleteKeyTree(s.root, s.sub, .wow64_64) catch |e| if (e != error.NotFound) return e;
}

/// Reg.TryOpen: null on a missing key, bad hive, bare hive or access denied.
pub fn tryOpen(key: []const u8, writable: bool, view: win.View) ?win.Key {
    const s = split(key) catch return null;
    return win.openKey(s.root, s.sub, .{ .write = writable, .view = view }) catch null;
}

/// Reg.KeyExists (Detect=): checks both views, 32-bit apps live under WOW6432Node.
pub fn keyExists(key: []const u8) bool {
    for ([_]win.View{ .wow64_64, .wow64_32 }) |view| {
        if (tryOpen(key, false, view)) |k| {
            k.close();
            return true;
        }
    }
    return false;
}

/// Reg.Exists: the key exists and, for a value target, so does the value (names compare case-insensitively).
pub fn exists(t: RegKey) bool {
    const k = tryOpen(t.key, false, .default) orelse return false;
    defer k.close();
    const v = t.value orelse return true;
    var stack: [2048]u8 = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(&stack, std.heap.page_allocator);
    const name = win.toW(bfa.allocator(), v) catch return false;
    defer bfa.allocator().free(name);
    return w.RegQueryValueExW(k.h, name.ptr, null, null, null, null) == 0;
}

/// Reg.Delete (rule cleaning): false when nothing could be done. A value target deletes just the value; a key
/// target deletes the key tree through its parent, and a key directly under a hive ("HKCU\Software") is never
/// deleted because its parent is the bare hive, which tryOpen refuses.
pub fn delete(t: RegKey) bool {
    if (t.value) |v| {
        const k = tryOpen(t.key, true, .default) orelse return false;
        defer k.close();
        k.deleteValue(v) catch |e| return e == error.NotFound; // throwOnMissingValue: false
        return true;
    }
    const key = std.mem.trimEnd(u8, t.key, "\\");
    const cut = std.mem.findScalarLast(u8, key, '\\') orelse return false;
    const parent = tryOpen(key[0..cut], true, .default) orelse return false;
    defer parent.close();
    var stack: [2048]u8 = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(&stack, std.heap.page_allocator);
    const leaf = win.toW(bfa.allocator(), key[cut + 1 ..]) catch return false;
    defer bfa.allocator().free(leaf);
    const rc = w.RegDeleteTreeW(parent.h, leaf.ptr); // deletes the leaf key itself too
    return rc == 0 or rc == w.ERROR_FILE_NOT_FOUND; // throwOnMissingSubKey: false
}

test "split: hive aliases, never an empty sub" {
    const s = try split("hkey_local_machine\\SOFTWARE\\X\\");
    try std.testing.expectEqual(win.Root.hklm, s.root);
    try std.testing.expectEqualStrings("SOFTWARE\\X", s.sub);
    try std.testing.expectEqual(win.Root.hku, (try split("HKU\\.DEFAULT")).root);
    try std.testing.expectError(error.UnknownHive, split("HKXX\\Software"));
    try std.testing.expectError(error.InvalidPath, split("HKCU"));
    try std.testing.expectError(error.InvalidPath, split("HKCU\\"));
    try std.testing.expectError(error.InvalidPath, split("HKCU\\\\"));
}

test "top-level keys and bare hives are never deleted (Winapp2Tests guard)" {
    // the guard first: if a bare hive could be opened, the deletes below would be dangerous, so stop here
    try std.testing.expect(tryOpen("HKCU", true, .default) == null);
    try std.testing.expect(tryOpen("HKCU\\", true, .default) == null);
    try std.testing.expect(!delete(.{ .key = "HKCU\\Software" }));
    try std.testing.expect(!delete(.{ .key = "HKCU\\Software\\" }));
    try std.testing.expect(!delete(.{ .key = "HKCU" }));
    try std.testing.expect(keyExists("HKCU\\Software"));
}

test "values and keys round trip under a throwaway HKCU key" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tk = try @import("common.zig").TestKey.create(gpa, io, "reg");
    defer tk.cleanup(gpa);
    const sub = try gpa.print("{s}\\Sub\\Deep", .{tk.full});
    defer gpa.free(sub);

    try std.testing.expect(try setBinary(gpa, sub, "bin", &.{ 0x02, 0xAB }));
    try std.testing.expect(try setString(gpa, sub, "str", "Привіт"));
    {
        const k = (try open(sub, false)).?;
        defer k.close();
        const b = try k.readBinary(gpa, "bin");
        defer gpa.free(b);
        try std.testing.expectEqualSlices(u8, &.{ 0x02, 0xAB }, b);
        const s = try k.readString(gpa, "str");
        defer gpa.free(s);
        try std.testing.expectEqualStrings("Привіт", s);
    }
    const children = try subKeys(gpa, tk.full);
    defer win.freeList(gpa, children);
    try std.testing.expectEqual(1, children.len);
    try std.testing.expectEqualStrings("Sub", children[0]);
    const none = try subKeys(gpa, "HKCU\\Software\\MakeCleanerTest-no-such-key");
    defer gpa.free(none);
    try std.testing.expectEqual(0, none.len);

    try std.testing.expect(exists(.{ .key = sub, .value = "BIN" })); // value names are case-insensitive
    try std.testing.expect(!exists(.{ .key = sub, .value = "nope" }));
    try std.testing.expect(keyExists(sub));
    try std.testing.expect(delete(.{ .key = sub, .value = "bin" }));
    try std.testing.expect(!exists(.{ .key = sub, .value = "bin" }));
    try std.testing.expect(delete(.{ .key = sub, .value = "bin" })); // missing value: still true
    try std.testing.expect(try deleteValue(gpa, sub, "str"));
    try std.testing.expect(try deleteValue(gpa, sub, "str")); // missing value: fine

    const mid = try gpa.print("{s}\\Sub", .{tk.full});
    defer gpa.free(mid);
    try std.testing.expect(delete(.{ .key = mid })); // tree: Sub and Sub\Deep
    try std.testing.expect(!keyExists(sub) and !keyExists(mid));
    try std.testing.expect(delete(.{ .key = mid })); // missing subkey: true
    try std.testing.expect(!delete(.{ .key = "HKCU\\Software\\MakeCleanerTest-no-such-key\\x" })); // no parent

    try std.testing.expect(try setString(gpa, mid, "x", "1"));
    try std.testing.expect(try deleteKey(gpa, mid));
    try std.testing.expect((try open(mid, false)) == null);
    try std.testing.expect(try deleteKey(gpa, mid)); // already gone
    try std.testing.expect(keyExists(tk.full));
    try std.testing.expectError(error.InvalidPath, deleteKey(gpa, "HKCU\\"));
}

test "access denied goes through elevated reg.exe (fake runner, never UAC)" {
    if (elevated.isAdmin()) return error.SkipZigTest; // an admin could really write HKLM; nothing to prove then
    const gpa = std.testing.allocator;
    elevated.Fake.install();
    defer elevated.Fake.uninstall();
    elevated.Fake.result = false;
    try std.testing.expect(!try setBinary(gpa, "HKLM\\SOFTWARE\\MakeCleanerTest-denied", "v", &.{ 0x0A, 0xFF }));
    try std.testing.expectEqualStrings("reg.exe", elevated.Fake.exe());
    try std.testing.expectEqualStrings("add \"HKLM\\SOFTWARE\\MakeCleanerTest-denied\" /v \"v\" /t REG_BINARY /d 0AFF /f /reg:64", elevated.Fake.args());
    try std.testing.expect(!try setString(gpa, "HKLM\\SOFTWARE\\MakeCleanerTest-denied", "s", "x y"));
    try std.testing.expectEqualStrings("add \"HKLM\\SOFTWARE\\MakeCleanerTest-denied\" /v \"s\" /t REG_SZ /d \"x y\" /f /reg:64", elevated.Fake.args());
    try std.testing.expectEqual(2, elevated.Fake.calls);
    try std.testing.expect((try open("HKLM\\SOFTWARE\\MakeCleanerTest-denied", false)) == null);
}
