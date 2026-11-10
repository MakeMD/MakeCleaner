//! Uninstall.cs (Tools > Uninstall): the "Programs and Features" list from the Uninstall keys, launching an
//! uninstaller / repair / change, and dropping an orphaned entry.
const std = @import("std");
const kit = @import("kit");
const reg = @import("reg.zig");
const sys = @import("systools_win.zig");

const w = kit.w;
const win = kit.win;
const Allocator = std.mem.Allocator;

/// record InstalledApp.
pub const InstalledApp = struct {
    name: []const u8,
    publisher: []const u8,
    version: []const u8,
    install_date: []const u8,
    size_kb: i64,
    uninstall_string: []const u8,
    modify_path: []const u8,
    is_msi: bool,
    no_modify: bool,
    no_repair: bool,
    /// Full key path ("HKLM\...\Uninstall\{GUID}").
    key: []const u8,

    /// InstalledApp.Code: last segment of `key` (the MSI product code for MSI entries).
    pub fn code(a: *const InstalledApp) []const u8 {
        const i = std.mem.findScalarLast(u8, a.key, '\\') orelse return a.key;
        return a.key[i + 1 ..];
    }

    pub fn canRepair(a: *const InstalledApp) bool {
        return !a.no_repair and (a.is_msi or a.modify_path.len > 0);
    }

    pub fn canChange(a: *const InstalledApp) bool {
        return !a.no_modify and (a.is_msi or a.modify_path.len > 0);
    }

    /// "msiexec.exe /x {code}" for MSI, else UninstallString, else null. Caller frees.
    pub fn uninstallCommand(a: *const InstalledApp, gpa: Allocator) !?[]u8 {
        if (a.is_msi) return try gpa.print("msiexec.exe /x {s}", .{a.code()});
        return if (a.uninstall_string.len > 0) try gpa.dupe(u8, a.uninstall_string) else null;
    }

    /// "msiexec.exe /fomus {code}" / ModifyPath / null.
    pub fn repairCommand(a: *const InstalledApp, gpa: Allocator) !?[]u8 {
        if (!a.canRepair()) return null;
        return if (a.is_msi) try gpa.print("msiexec.exe /fomus {s}", .{a.code()}) else try gpa.dupe(u8, a.modify_path);
    }

    /// "msiexec.exe /i {code}" / ModifyPath / null.
    pub fn changeCommand(a: *const InstalledApp, gpa: Allocator) !?[]u8 {
        if (!a.canChange()) return null;
        return if (a.is_msi) try gpa.print("msiexec.exe /i {s}", .{a.code()}) else try gpa.dupe(u8, a.modify_path);
    }
};

/// Uninstall.Roots.
pub const roots = [_][]const u8{
    "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
    "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
    "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
};

/// Uninstall.Read(roots): same filter as "Programs and Features" (named, not SystemComponent, no ParentKeyName,
/// not Update/Hotfix/Security Update, has a way to uninstall); no de-dup (ARP lists same-name entries separately
/// too); sorted by name, case-insensitive in the user's locale (CurrentCultureIgnoreCase). Strings in `arena`.
pub fn read(arena: Allocator, root_keys: []const []const u8) ![]InstalledApp {
    const Item = struct { app: InstalledApp, sort: [:0]const u16 };
    var items: std.ArrayList(Item) = .empty;
    for (root_keys) |root| for (try reg.subKeys(arena, root)) |name| {
        const key = try arena.print("{s}\\{s}", .{ root, name });
        const k = try reg.open(key, false) orelse continue;
        defer k.close();
        const display = try s(arena, k, "DisplayName");
        const release = try s(arena, k, "ReleaseType");
        const uninstall_string = try s(arena, k, "UninstallString");
        const is_msi = b(k, "WindowsInstaller") and std.mem.startsWith(u8, name, "{");
        if (display.len == 0 or b(k, "SystemComponent") or (try s(arena, k, "ParentKeyName")).len > 0 or
            eqlAny(release, &.{ "Update", "Hotfix", "Security Update" }) or (!is_msi and uninstall_string.len == 0)) continue;
        try items.append(arena, .{ .sort = try win.toW(arena, display), .app = .{
            .name = display,
            .publisher = try s(arena, k, "Publisher"),
            .version = try s(arena, k, "DisplayVersion"),
            .install_date = try s(arena, k, "InstallDate"),
            .size_kb = sys.int(k, "EstimatedSize") orelse 0,
            .uninstall_string = uninstall_string,
            .modify_path = try s(arena, k, "ModifyPath"),
            .is_msi = is_msi,
            .no_modify = b(k, "NoModify"),
            .no_repair = b(k, "NoRepair"),
            .key = key,
        } });
    };
    std.mem.sort(Item, items.items, {}, struct { // stable, like OrderBy
        fn lessThan(_: void, x: Item, y: Item) bool {
            return w.CompareStringEx(null, w.NORM_IGNORECASE, x.sort.ptr, -1, y.sort.ptr, -1, null, null, 0) == w.CSTR_LESS_THAN;
        }
    }.lessThan);
    const apps = try arena.alloc(InstalledApp, items.items.len);
    for (items.items, apps) |it, *a| a.* = it.app;
    return apps;
}

/// `(GetValue(v) as string)?.Trim() ?? ""`.
fn s(arena: Allocator, k: win.Key, v: []const u8) ![]const u8 {
    return sys.trim(try sys.string(arena, k, v) orelse "");
}

/// `GetValue(v) is int i && i == 1`.
fn b(k: win.Key, v: []const u8) bool {
    return sys.int(k, v) == 1;
}

fn eqlAny(x: []const u8, list: []const []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

/// (Exe, Args) of a command line.
pub const Command = struct { exe: []const u8, args: []const u8 };

/// Uninstall.SplitCommand: `"C:\a b\x.exe" /S` | `C:\a b\x.exe /S` | `MsiExec.exe /X{...}`; env vars expanded.
/// Strings in `arena`.
pub fn splitCommand(arena: Allocator, cmd_in: []const u8) !Command {
    const cmd = try win.expandEnv(arena, sys.trim(cmd_in));
    if (std.mem.startsWith(u8, cmd, "\"")) {
        const end = std.mem.findScalarPos(u8, cmd, 1, '"') orelse return .{ .exe = std.mem.trim(u8, cmd, "\""), .args = "" };
        return .{ .exe = cmd[1..end], .args = sys.trim(cmd[end + 1 ..]) };
    }
    const end = if (std.ascii.findIgnoreCase(cmd, ".exe")) |i| i + 4 else std.mem.findScalar(u8, cmd, ' ') orelse cmd.len;
    if (end >= cmd.len) return .{ .exe = cmd, .args = "" };
    return .{ .exe = cmd[0..end], .args = sys.trim(cmd[end..]) };
}

/// Uninstall.Launch: shell-executes the uninstaller (it carries its own elevation manifest; Windows shows UAC
/// when it needs it).
pub fn launch(gpa: Allocator, command: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const c = try splitCommand(arena_state.allocator(), command);
    _ = try win.shellExecute(gpa, .{ .file = c.exe, .params = c.args });
}

/// Uninstall.DeleteEntry: reg.deleteKey(app.key).
pub fn deleteEntry(gpa: Allocator, app: *const InstalledApp) !bool {
    return reg.deleteKey(gpa, app.key);
}
