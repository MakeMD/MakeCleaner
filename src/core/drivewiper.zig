//! Port of legacy/src/MakeCleaner.Core/DriveWiper.cs (Tools > Drive Wiper): which drives may be erased, where
//! to wipe, format, SSD detection. Free-space wiping: securedelete.zig.
//! Tests: never format or fill a real disk (checkErasable / wipeDir are pure; wipes use limit_bytes).
const std = @import("std");
const kit = @import("kit");
const w = kit.w;
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Path.GetPathRoot ("C:\Windows\system32" -> "C:\").
fn pathRoot(p: []const u8) []const u8 {
    return std.fs.path.parsePathWindows(u8, p).root;
}

/// DriveWiper.SystemRoot: root of the system directory, e.g. "C:\". Caller frees.
pub fn systemRoot(gpa: Allocator) ![]u8 {
    var buf: [w.MAX_PATH + 1]u16 = undefined;
    const n = w.GetSystemDirectoryW(&buf, buf.len);
    if (n == 0 or n > buf.len) return error.Unexpected;
    const dir = try kit.win.fromW(gpa, buf[0..n]);
    defer gpa.free(dir);
    return gpa.dupe(u8, pathRoot(dir));
}

const tempPath = common.tempPath;

/// DriveWiper.CheckErasable: null = may be erased entirely; otherwise the reason (caller frees).
pub fn checkErasable(gpa: Allocator, root: []const u8, system_root: []const u8, exe_root: []const u8) !?[]u8 {
    if (common.eqlIgnoreCase(root, system_root)) return try gpa.print("{s} is the system drive and cannot be erased entirely.", .{root});
    if (common.eqlIgnoreCase(root, exe_root)) return try gpa.print("MakeCleaner is running from {s}; it cannot erase its own drive.", .{root});
    return null;
}

/// DriveWiper.IsSystemDrive.
pub fn isSystemDrive(gpa: Allocator, root: []const u8) !bool {
    const sys = try systemRoot(gpa);
    defer gpa.free(sys);
    return common.eqlIgnoreCase(root, sys);
}

/// DriveWiper.WipeDir: the system drive root needs admin to write to, %TEMP% lives on the same volume, so
/// the system drive is wiped through %TEMP%. Caller frees.
pub fn wipeDir(gpa: Allocator, root: []const u8) ![]u8 {
    const tmp = try tempPath(gpa);
    if (common.eqlIgnoreCase(root, pathRoot(tmp))) return tmp;
    gpa.free(tmp);
    return gpa.dupe(u8, root);
}

/// The Format-Volume command line for drive `letter` (label quotes doubled for the single-quoted string).
/// Caller frees.
fn formatCommand(gpa: Allocator, letter: u8, fs: []const u8, label: []const u8) ![]u8 {
    const quoted = try std.mem.replaceOwned(u8, gpa, label, "'", "''");
    defer gpa.free(quoted);
    return gpa.print("$ErrorActionPreference='Stop'; Format-Volume -DriveLetter {c} -FileSystem {s} -NewFileSystemLabel '{s}' -Force -Confirm:$false | Out-Null", .{ letter, fs, quoted });
}

/// DriveWiper.Format(DriveInfo): Format-Volume with the same file system and label (powershell, no window).
/// `root` = "X:\". DESTRUCTIVE: never call from tests.
pub fn format(gpa: Allocator, io: Io, root: []const u8) !void {
    const root_w = try kit.win.toW(gpa, root);
    defer gpa.free(root_w);
    var label: [w.MAX_PATH + 1]u16 = undefined;
    var fs: [w.MAX_PATH + 1]u16 = undefined;
    if (w.GetVolumeInformationW(root_w, &label, label.len, null, null, null, &fs, fs.len) == 0) return error.VolumeUnavailable;
    const label8 = try kit.win.fromWZ(gpa, @ptrCast(&label));
    defer gpa.free(label8);
    const fs8 = try kit.win.fromWZ(gpa, @ptrCast(&fs));
    defer gpa.free(fs8);
    const cmd = try formatCommand(gpa, root[0], fs8, label8);
    defer gpa.free(cmd);
    const r = try std.process.run(gpa, io, .{ .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", cmd } });
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    if (!r.term.success()) return error.FormatFailed;
}

/// DriveWiper.IsSsd: true = SSD, false = spinning disk, null = unknown (treated like SSD for the warning).
/// Read-only: the volume is opened with no access rights (no admin needed).
pub fn isSsd(root: []const u8) ?bool {
    if (root.len == 0) return null;
    var dev = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\X:").*;
    dev[4] = root[0];
    const h = w.CreateFileW(&dev, 0, 3, null, w.OPEN_EXISTING, 0, null);
    if (h == w.INVALID_HANDLE_VALUE) return null;
    defer _ = w.CloseHandle(h);
    var q: w.STORAGE_PROPERTY_QUERY = .{ .PropertyId = w.StorageDeviceSeekPenaltyProperty, .QueryType = w.PropertyStandardQuery, .AdditionalParameters = .{0} };
    var r: w.DEVICE_SEEK_PENALTY_DESCRIPTOR = undefined;
    var got: w.DWORD = 0;
    const ioctl_storage_query_property = 0x2D1400; // CTL_CODE(IOCTL_STORAGE_BASE, 0x500, METHOD_BUFFERED, FILE_ANY_ACCESS)
    if (w.DeviceIoControl(h, ioctl_storage_query_property, &q, @sizeOf(@TypeOf(q)), &r, @sizeOf(@TypeOf(r)), &got, null) == 0) return null;
    return r.IncursSeekPenalty == 0;
}

// ---------------------------------------------------------------- tests (legacy SecureDeleteTests: drive part)

const testing = std.testing;

test "System_drive_and_own_drive_cannot_be_erased_entirely" {
    const gpa = testing.allocator;
    const a = (try checkErasable(gpa, "C:\\", "C:\\", "D:\\")).?;
    defer gpa.free(a);
    const b = (try checkErasable(gpa, "d:\\", "C:\\", "D:\\")).?;
    defer gpa.free(b);
    try testing.expectEqual(null, try checkErasable(gpa, "E:\\", "C:\\", "D:\\"));
}

test "SystemRoot / IsSystemDrive / WipeDir (read-only queries)" {
    const gpa = testing.allocator;
    const sys = try systemRoot(gpa);
    defer gpa.free(sys);
    try testing.expect(sys.len == 3 and sys[1] == ':' and sys[2] == '\\');
    try testing.expect(try isSystemDrive(gpa, sys));
    const tmp = try tempPath(gpa);
    defer gpa.free(tmp);
    const wd = try wipeDir(gpa, pathRoot(tmp)); // the drive holding %TEMP% is wiped through %TEMP%
    defer gpa.free(wd);
    try testing.expectEqualStrings(tmp, wd);
    const other = try wipeDir(gpa, "Q:\\");
    defer gpa.free(other);
    try testing.expectEqualStrings("Q:\\", other);
    try testing.expectEqual(null, isSsd("?"));
    // the IOCTL agrees with Get-PhysicalDisk for the system disk (Unspecified media, e.g. a VM: not checked)
    const ps = try std.fmt.allocPrint(gpa, "$n=(Get-Partition -DriveLetter {c}).DiskNumber; (Get-PhysicalDisk | ? DeviceId -eq \"$n\").MediaType", .{sys[0]});
    defer gpa.free(ps);
    const r = try std.process.run(gpa, testing.io, .{ .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", ps } });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const media = std.mem.trim(u8, r.stdout, &std.ascii.whitespace);
    if (std.mem.eql(u8, media, "SSD") or std.mem.eql(u8, media, "HDD")) try testing.expectEqual(@as(?bool, media[0] == 'S'), isSsd(sys));
}

test "Format command doubles single quotes in the label (never executed)" {
    const cmd = try formatCommand(testing.allocator, 'E', "NTFS", "Bob's disk");
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.find(u8, cmd, "-DriveLetter E -FileSystem NTFS -NewFileSystemLabel 'Bob''s disk' -Force") != null);
}
