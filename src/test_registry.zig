//! zig build test-registry: registry cleaner (RegScanner + RegFix). Owner: MC-C.
//! Spec tests: legacy RegistryTests. Every test works on its own HKCU\Software\MakeCleanerTest-registry-<random>
//! branch with fake HKCU/HKLM roots and its own %TEMP%\makecleaner-test-reg-<random> folder; nothing else is
//! touched (the real-system scan only reads). Anything that could reach UAC goes through a fake.
const std = @import("std");
const kit = @import("kit");
const common = @import("core/common.zig");
const elevated = @import("core/elevated.zig");
const rc = @import("core/regcleaner.zig");

const win = kit.win;
const w = kit.w;
const testing = std.testing;
const Io = std.Io;
const RegIssue = rc.RegIssue;

test {
    common.refAll(rc);
}

const Root = enum { hkcu, hklm };

const Val = union(enum) {
    sz: []const u8,
    expand: []const u8,
    dword: u32,
    qword: u64,
    binary: []const u8,
    none: []const u8,
    multi: []const []const u8,
};

const Fx = struct {
    arena: std.heap.ArenaAllocator,
    branch: common.TestKey,
    dir: common.TempDir,
    hkcu: rc.Hive,
    hklm: rc.Hive,
    missing: []const u8,
    existing: []const u8,

    /// In place: the arena must not move once used.
    fn init(fx: *Fx) !void {
        const gpa = testing.allocator;
        const io = testing.io;
        fx.arena = .init(gpa);
        errdefer fx.arena.deinit();
        fx.branch = try common.TestKey.create(gpa, io, "registry");
        errdefer fx.branch.cleanup(gpa);
        fx.dir = try common.TempDir.create(gpa, io, "reg");
        errdefer fx.dir.cleanup(gpa, io);
        fx.hkcu = try fx.root(.hkcu);
        errdefer fx.hkcu.key.close();
        fx.hklm = try fx.root(.hklm);
        errdefer fx.hklm.key.close();
        fx.missing = try fx.path("nope.exe");
        fx.existing = try fx.path("here.exe");
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = fx.existing, .data = "x" });
    }

    fn deinit(fx: *Fx) void {
        fx.hkcu.key.close();
        fx.hklm.key.close();
        fx.branch.cleanup(testing.allocator);
        fx.dir.cleanup(testing.allocator, testing.io);
        fx.arena.deinit();
    }

    fn alloc(fx: *Fx) std.mem.Allocator {
        return fx.arena.allocator();
    }

    fn path(fx: *Fx, name: []const u8) ![]u8 {
        return fx.dir.join(fx.alloc(), name);
    }

    /// Path relative to HKCU of `key` under the fake root.
    fn rel(fx: *Fx, r: Root, key: []const u8) ![]u8 {
        return fx.alloc().print("{s}\\{s}{s}{s}", .{ fx.branch.sub, @tagName(r), if (key.len > 0) "\\" else "", key });
    }

    fn root(fx: *Fx, r: Root) !rc.Hive {
        const k = try win.createKey(.hkcu, try fx.rel(r, ""), .default);
        return .{ .key = k, .name = try fx.alloc().print("HKEY_CURRENT_USER\\{s}\\{s}", .{ fx.branch.sub, @tagName(r) }) };
    }

    fn create(fx: *Fx, r: Root, key: []const u8) !void {
        (try win.createKey(.hkcu, try fx.rel(r, key), .default)).close();
    }

    fn set(fx: *Fx, r: Root, key: []const u8, name: []const u8, v: Val) !void {
        const k = try win.createKey(.hkcu, try fx.rel(r, key), .default);
        defer k.close();
        switch (v) {
            .sz => |s| try k.writeString(name, s),
            .expand => |s| try k.writeExpandString(name, s),
            .dword => |d| try k.writeDword(name, d),
            .qword => |q| try k.writeRaw(name, w.REG_QWORD, std.mem.asBytes(&q)),
            .binary => |b| try k.writeBinary(name, b),
            .none => |b| try k.writeRaw(name, w.REG_NONE, b),
            .multi => |m| try k.writeMultiSz(name, m),
        }
    }

    fn scan(fx: *Fx, excluded: []const []const u8) ![]RegIssue {
        const s: rc.RegScanner = .{ .hkcu = fx.hkcu, .hklm = fx.hklm };
        return s.scan(fx.alloc(), &rc.categories, excluded, null);
    }

    /// WriteBackup of the whole test branch, read back as text.
    fn snapshot(fx: *Fx, file: []const u8) ![]u8 {
        const whole: RegIssue = .{ .category = "", .problem = "", .data = "", .key_path = try fx.alloc().print("HKEY_CURRENT_USER\\{s}", .{fx.branch.sub}), .value_name = null };
        try rc.writeBackup(testing.allocator, testing.io, &.{whole}, file);
        return readReg(fx.alloc(), file);
    }

    /// One bad + one good (or out-of-scope) entry for each of the 15 categories.
    fn seedAll(fx: *Fx) !void {
        const a = fx.alloc();
        const cv = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion";
        try fx.set(.hklm, cv ++ "\\SharedDLLs", fx.missing, .{ .dword = 1 });
        try fx.set(.hklm, cv ++ "\\SharedDLLs", fx.existing, .{ .dword = 1 });

        try fx.set(.hkcu, "Software\\Classes\\.mcbad", "", .{ .sz = "MakeCleaner.NoSuchProgId" });
        try fx.set(.hkcu, "Software\\Classes\\.mcgood", "", .{ .sz = "MakeCleaner.GoodProg" });
        try fx.set(.hkcu, "Software\\Classes\\MakeCleaner.GoodProg", "", .{ .sz = "Good" });

        try fx.set(.hkcu, "Software\\Classes\\CLSID\\{00000000-0000-0000-0000-00000000BAD1}\\InprocServer32", "", .{ .sz = fx.missing });
        try fx.set(.hkcu, "Software\\Classes\\CLSID\\{00000000-0000-0000-0000-00000000600D}\\InprocServer32", "", .{ .sz = fx.existing });

        try fx.set(.hkcu, "Software\\Classes\\TypeLib\\{00000000-0000-0000-0000-00000000BAD2}\\1.0\\0\\win32", "", .{ .sz = fx.missing });
        try fx.set(.hkcu, "Software\\Classes\\TypeLib\\{00000000-0000-0000-0000-00000000600E}\\1.0\\0\\win64", "", .{ .sz = fx.existing });

        try fx.set(.hkcu, "Software\\Classes\\Applications\\nope.exe\\shell\\open\\command", "", .{ .sz = try a.print("\"{s}\" \"%1\"", .{fx.missing}) });
        try fx.set(.hkcu, "Software\\Classes\\Applications\\here.exe\\shell\\open\\command", "", .{ .sz = try a.print("\"{s}\" \"%1\"", .{fx.existing}) });

        try fx.set(.hkcu, "Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts", "Bad (TrueType)", .{ .sz = try fx.path("nope.ttf") });
        try fx.set(.hklm, "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts", "Bad (TrueType)", .{ .sz = "makecleaner-nope.ttf" });
        try fx.set(.hklm, "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts", "Arial (TrueType)", .{ .sz = "arial.ttf" });

        try fx.set(.hkcu, cv ++ "\\App Paths\\nope.exe", "", .{ .sz = fx.missing });
        try fx.set(.hkcu, cv ++ "\\App Paths\\here.exe", "", .{ .sz = fx.existing });

        try fx.set(.hklm, "SOFTWARE\\Microsoft\\Windows\\Help", "nope.hlp", .{ .sz = fx.dir.path });
        try fx.set(.hklm, "SOFTWARE\\Microsoft\\Windows\\Help", "here.exe", .{ .sz = fx.dir.path });

        try fx.set(.hklm, cv ++ "\\Installer\\Folders", try a.print("{s}\\gone\\", .{fx.dir.path}), .{ .sz = "" });
        try fx.set(.hklm, cv ++ "\\Installer\\Folders", try a.print("{s}\\", .{fx.dir.path}), .{ .sz = "" });

        try fx.create(.hkcu, "Software\\EmptyVendor");
        try fx.set(.hkcu, "Software\\UsedVendor", "x", .{ .sz = "1" });

        try fx.set(.hkcu, cv ++ "\\Run", "Bad", .{ .sz = try a.print("\"{s}\" /min", .{fx.missing}) });
        try fx.set(.hkcu, cv ++ "\\Run", "Good", .{ .sz = try a.print("\"{s}\" /min", .{fx.existing}) });
        try fx.set(.hkcu, cv ++ "\\Run", "OnPath", .{ .sz = "notepad.exe" }); // relative -> unknown -> not an issue

        try fx.set(.hkcu, cv ++ "\\Explorer\\MenuOrder\\Start Menu2\\Programs\\MakeCleanerNoSuchFolder", "Order", .{ .binary = &.{1} });

        const mui = "Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\MuiCache";
        try fx.set(.hkcu, mui, try a.print("{s}.FriendlyAppName", .{fx.missing}), .{ .sz = "Gone" });
        try fx.set(.hkcu, mui, try a.print("{s}.FriendlyAppName", .{fx.existing}), .{ .sz = "Here" });
        try fx.set(.hkcu, mui, "@shell32.dll,-1", .{ .sz = "Resource" }); // indirect string, ignored

        try fx.set(.hkcu, "AppEvents\\Schemes\\Apps\\.Default\\MCBad\\.Current", "", .{ .sz = try fx.path("nope.wav") });
        try fx.set(.hkcu, "AppEvents\\Schemes\\Apps\\.Default\\MCGood\\.Current", "", .{ .sz = fx.existing });
        try fx.set(.hkcu, "AppEvents\\Schemes\\Apps\\.Default\\MCEmpty\\.Current", "", .{ .sz = "" });

        const svc = "SYSTEM\\CurrentControlSet\\Services";
        try fx.set(.hklm, svc ++ "\\BadSvc", "ImagePath", .{ .expand = try a.print("\"{s}\" -k", .{fx.missing}) });
        try fx.set(.hklm, svc ++ "\\BadSvc", "Type", .{ .dword = 0x10 });
        try fx.set(.hklm, svc ++ "\\GoodSvc", "ImagePath", .{ .expand = fx.existing });
        try fx.set(.hklm, svc ++ "\\GoodSvc", "Type", .{ .dword = 0x20 });
        try fx.set(.hklm, svc ++ "\\SomeDriver", "ImagePath", .{ .expand = fx.missing });
        try fx.set(.hklm, svc ++ "\\SomeDriver", "Type", .{ .dword = 1 }); // kernel driver: never touched
    }
};

/// A .reg file as text (UTF-16LE + BOM, like regedit).
fn readReg(a: std.mem.Allocator, file: []const u8) ![]u8 {
    const bytes = try Io.Dir.cwd().readFileAlloc(testing.io, file, a, .limited(64 << 20));
    try testing.expect(bytes.len >= 2 and bytes[0] == 0xFF and bytes[1] == 0xFE);
    const u = try a.alloc(u16, (bytes.len - 2) / 2);
    @memcpy(std.mem.sliceAsBytes(u), bytes[2 .. 2 + u.len * 2]);
    return std.unicode.wtf16LeToWtf8Alloc(a, u);
}

/// Key order after re-import can differ; compare as sets of lines.
fn sortedLines(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitSequence(u8, text, "\r\n");
    while (it.next()) |l| if (l.len > 0) try lines.append(a, l);
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lt(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.order(u8, l, r) == .lt;
        }
    }.lt);
    return lines.items;
}

fn single(all: []const RegIssue, category: []const u8) !RegIssue {
    var found: ?RegIssue = null;
    for (all) |i| if (std.mem.eql(u8, i.category, category)) {
        if (found != null) return error.TestExpectedSingle;
        found = i;
    };
    return found orelse error.TestExpectedSingle;
}

fn regImport(file: []const u8) !bool {
    const gpa = testing.allocator;
    const r = try std.process.run(gpa, testing.io, .{ .argv = &.{ "reg.exe", "import", file } });
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    if (!r.term.success()) std.debug.print("reg import failed: {s}\n", .{r.stderr});
    return r.term.success();
}

test "RegistryTests.Each_category_flags_only_the_broken_entry" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.seedAll();
    const a = fx.alloc();
    const found = try fx.scan(&.{});
    var wrong = false;
    for (rc.categories) |c| {
        var n: usize = 0;
        for (found) |i| n += @intFromBool(std.mem.eql(u8, i.category, c.name));
        const expected: usize = if (std.mem.eql(u8, c.name, "Fonts")) 2 else 1; // one per-user + one machine-wide broken font
        if (n == expected) continue;
        wrong = true;
        std.debug.print("{s}: expected {d}, got {d}\n", .{ c.name, expected, n });
        for (found) |i| if (std.mem.eql(u8, i.category, c.name)) std.debug.print("  {s}\n", .{try i.target(a)});
    }
    try testing.expect(!wrong);
    for (found) |i| {
        const t = try i.target(a);
        try testing.expect(std.ascii.findIgnoreCase(t, "here") == null);
        try testing.expect(std.mem.find(u8, t, "Good") == null);
        try testing.expect(std.mem.find(u8, t, "SomeDriver") == null);
    }
}

test "RegistryTests.Scan_changes_nothing" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.seedAll();
    const before = try fx.snapshot(try fx.path("before.reg"));
    _ = try fx.scan(&.{});
    try testing.expectEqualStrings(before, try fx.snapshot(try fx.path("after.reg")));
}

test "RegistryTests.Excluded_keys_and_values_are_not_reported" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.seedAll();
    const a = fx.alloc();
    const all = try fx.scan(&.{});
    const run = try single(all, "Run At Startup");
    const com = try single(all, "ActiveX and Class Issues");
    const run_target = try run.target(a);
    const com_target = try com.target(a);

    const rest = try fx.scan(&.{ run_target, try a.print("{s}\\", .{com.key_path}) });
    try testing.expectEqual(all.len - 2, rest.len);
    for (rest) |i| {
        const t = try i.target(a);
        try testing.expect(!std.mem.eql(u8, t, run_target) and !std.mem.eql(u8, t, com_target));
    }
}

test "RegistryTests.Fix_deletes_after_backup_and_backup_restores_everything" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    elevated.Fake.install(); // nothing here is denied; never a real UAC prompt either way
    defer elevated.Fake.uninstall();
    elevated.Fake.result = false;
    try fx.seedAll();
    const a = fx.alloc();
    // give one key-level issue every value type, plus a subkey, to prove the export round-trips
    const clsid = "Software\\Classes\\CLSID\\{00000000-0000-0000-0000-00000000BAD1}";
    try fx.set(.hkcu, clsid, "dw", .{ .dword = 0xDEADBEEF });
    try fx.set(.hkcu, clsid, "qw", .{ .qword = 0x0123456789ABCDEF });
    try fx.set(.hkcu, clsid, "exp", .{ .expand = "%SystemRoot%\\x" });
    try fx.set(.hkcu, clsid, "multi", .{ .multi = &.{ "a", "b \"q\"" } });
    try fx.set(.hkcu, clsid, "bin", .{ .binary = &.{ 0, 1, 255 } });
    try fx.set(.hkcu, clsid, "none", .{ .none = &.{7} });
    try fx.set(.hkcu, clsid, "", .{ .sz = "line1\r\nline2" });
    try fx.set(.hkcu, clsid, "quote\"and\\slash", .{ .sz = "C:\\a \"b\"" });

    const issues = try fx.scan(&.{});
    const full = try fx.path("full.reg");
    const before = try fx.snapshot(full);

    const backup = try fx.path(try rc.defaultBackupName(a, common.DateTime.nowLocal()));
    try testing.expect(std.mem.startsWith(u8, Io.Dir.path.basename(backup), "MakeCleaner_registry_") and std.mem.endsWith(u8, backup, ".reg"));
    const r = try rc.fix(testing.allocator, testing.io, issues, backup, null);
    try testing.expectEqual(rc.FixResult{ .fixed = issues.len, .failed = 0 }, r);
    try testing.expect(std.mem.startsWith(u8, try readReg(a, backup), "Windows Registry Editor Version 5.00"));
    try testing.expectEqual(0, (try fx.scan(&.{})).len);
    try testing.expectError(error.NotFound, win.openKey(.hkcu, try fx.rel(.hkcu, clsid), .{}));
    try testing.expectEqual(0, elevated.Fake.calls);

    try testing.expect(try regImport(backup));
    const after_lines = try sortedLines(a, try fx.snapshot(full));
    const before_lines = try sortedLines(a, before);
    for (before_lines, 0..) |l, n| {
        if (n >= after_lines.len) break;
        try testing.expectEqualStrings(l, after_lines[n]);
    }
    try testing.expectEqual(before_lines.len, after_lines.len);
}

// The fix dialog: one backup of every ticked issue, then fixes one at a time.
test "RegistryTests.Backup_once_then_apply_one_by_one" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    elevated.Fake.install();
    defer elevated.Fake.uninstall();
    try fx.seedAll();
    const gpa = testing.allocator;
    const io = testing.io;
    const issues = try fx.scan(&.{});
    try testing.expect(issues.len > 1);
    const backup = try fx.path("once.reg");
    try rc.writeBackup(gpa, io, issues, backup);
    const saved = try Io.Dir.cwd().readFileAlloc(io, backup, fx.alloc(), .unlimited);

    try testing.expectEqual(rc.FixResult{ .fixed = 1, .failed = 0 }, try rc.apply(gpa, io, issues[0..1], null));
    try testing.expectEqual(rc.FixResult{ .fixed = 1, .failed = 0 }, try rc.apply(gpa, io, issues[0..1], null)); // already gone: still counts as fixed, no error
    try testing.expectEqual(issues.len - 1, (try fx.scan(&.{})).len);
    try testing.expectEqualSlices(u8, saved, try Io.Dir.cwd().readFileAlloc(io, backup, fx.alloc(), .unlimited)); // Apply never touches the backup
    try testing.expectEqual(rc.FixResult{ .fixed = issues.len - 1, .failed = 0 }, try rc.apply(gpa, io, issues[1..], null));
    try testing.expectEqual(0, (try fx.scan(&.{})).len);
    try testing.expectEqual(0, elevated.Fake.calls);
}

// ---- HKLM/HKCR entries are not writable for a normal user. Simulated with a Deny ACL on test keys: the direct
// delete fails, everything denied goes into one elevated import, and the result is the registry's real state.

var hook: struct { parent: win.Key = undefined, prompts: usize = 0, tampered: bool = false } = .{};

fn uacDeclined(file: []const u8) bool {
    hook.prompts += 1;
    hook.tampered = tamper(file);
    return false;
}

/// What another process of the user could try between writing the deletion .reg and the elevated import:
/// open it for writing, or delete it (rename needs the same DELETE access). True = it worked.
fn tamper(file: []const u8) bool {
    const p = win.toW(testing.allocator, file) catch return true;
    defer testing.allocator.free(p);
    const h = w.CreateFileW(p.ptr, w.GENERIC_WRITE, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
    if (h != w.INVALID_HANDLE_VALUE) {
        _ = w.CloseHandle(h);
        return true;
    }
    return w.DeleteFileW(p.ptr) != 0;
}

/// "elevated": admin rights are what lift the deny; reg.exe then applies the generated deletion script.
fn uacAccepted(file: []const u8) bool {
    deny(hook.parent, "LockedKey", false) catch return false;
    deny(hook.parent, "LockedValue", false) catch return false;
    return regImport(file) catch false;
}

/// Deny(path, on) of the C# test: an explicit Deny ACE for Delete|SetValue for the current user on a test key, or
/// every Deny ACE of the current user removed again (RemoveAccessRuleAll; a key already deleted is fine).
fn deny(parent: win.Key, leaf: []const u8, on: bool) !void {
    var tok: w.HANDLE = null;
    if (w.OpenProcessToken(w.GetCurrentProcess(), w.TOKEN_QUERY, &tok) == 0) return error.Unexpected;
    defer _ = w.CloseHandle(tok);
    var tu_buf: [512]u8 align(8) = undefined;
    var tu_len: w.DWORD = 0;
    if (w.GetTokenInformation(tok, w.TokenUser, &tu_buf, tu_buf.len, &tu_len) == 0) return error.Unexpected;
    const me = @as(*const w.TOKEN_USER, @ptrCast(&tu_buf)).User.Sid; // WindowsIdentity.GetCurrent().User

    const name = try win.toW(testing.allocator, leaf);
    defer testing.allocator.free(name);
    var h: w.HKEY = null;
    switch (w.RegOpenKeyExW(parent.h, name.ptr, 0, @intCast(w.READ_CONTROL | w.WRITE_DAC), &h)) {
        0 => {},
        w.ERROR_FILE_NOT_FOUND => return,
        else => return error.Unexpected,
    }
    defer _ = w.RegCloseKey(h);
    var sd_buf: [16384]u8 align(8) = undefined;
    var size: w.DWORD = sd_buf.len;
    if (w.RegGetKeySecurity(h, w.DACL_SECURITY_INFORMATION, &sd_buf, &size) != 0) return error.Unexpected;
    var present: w.WINBOOL = 0;
    var defaulted: w.WINBOOL = 0;
    var dacl: w.PACL = null;
    if (w.GetSecurityDescriptorDacl(&sd_buf, &present, &dacl, &defaulted) == 0 or dacl == null) return error.Unexpected;
    if (!on) {
        var i: w.DWORD = dacl.*.AceCount;
        while (i > 0) {
            i -= 1;
            var ace: w.LPVOID = null;
            if (w.GetAce(dacl, i, &ace) == 0) return error.Unexpected;
            const d: *w.ACCESS_DENIED_ACE = @ptrCast(@alignCast(ace.?));
            if (d.Header.AceType != w.ACCESS_DENIED_ACE_TYPE or w.EqualSid(&d.SidStart, me) == 0) continue;
            if (w.DeleteAce(dacl, i) == 0) return error.Unexpected;
        }
        if (w.RegSetKeySecurity(h, w.DACL_SECURITY_INFORMATION, &sd_buf) != 0) return error.Unexpected;
        return;
    }
    var acl_buf: [16384]u8 align(8) = undefined;
    const acl: w.PACL = @ptrCast(&acl_buf);
    if (w.InitializeAcl(acl, @as(w.DWORD, dacl.*.AclSize) + 8 + w.GetLengthSid(me), dacl.*.AclRevision) == 0) return error.Unexpected;
    if (w.AddAccessDeniedAce(acl, w.ACL_REVISION, w.DELETE | w.KEY_SET_VALUE, me) == 0) return error.Unexpected;
    for (0..dacl.*.AceCount) |i| {
        var ace: w.LPVOID = null;
        if (w.GetAce(dacl, @intCast(i), &ace) == 0) return error.Unexpected;
        const hdr: *const w.ACE_HEADER = @ptrCast(@alignCast(ace.?));
        if (w.AddAce(acl, dacl.*.AclRevision, w.MAXDWORD, ace, hdr.AceSize) == 0) return error.Unexpected;
    }
    var sd: w.SECURITY_DESCRIPTOR = undefined;
    if (w.InitializeSecurityDescriptor(&sd, w.SECURITY_DESCRIPTOR_REVISION) == 0) return error.Unexpected;
    if (w.SetSecurityDescriptorDacl(&sd, 1, acl, 0) == 0) return error.Unexpected;
    if (w.RegSetKeySecurity(h, w.DACL_SECURITY_INFORMATION, &sd) != 0) return error.Unexpected;
}

test "RegistryTests.Denied_entries_go_through_one_elevated_import" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.alloc();
    const gpa = testing.allocator;
    const io = testing.io;
    const whole = try a.print("{s}\\LockedKey", .{fx.branch.sub});
    const with_value = try a.print("{s}\\LockedValue", .{fx.branch.sub});
    (try win.createKey(.hkcu, whole, .default)).close();
    {
        const k = try win.createKey(.hkcu, with_value, .default);
        defer k.close();
        try k.writeString("stale", "x");
    }
    const issues = [_]RegIssue{
        .{ .category = "t", .problem = "t", .data = "", .key_path = try a.print("HKEY_CURRENT_USER\\{s}", .{whole}), .value_name = null },
        .{ .category = "t", .problem = "t", .data = "", .key_path = try a.print("HKEY_CURRENT_USER\\{s}", .{with_value}), .value_name = "stale" },
    };
    const parent = try win.openKey(.hkcu, fx.branch.sub, .{});
    defer parent.close();
    hook = .{ .parent = parent };
    defer { // before fx.deinit: a denied key could not be deleted
        deny(parent, "LockedKey", false) catch {};
        deny(parent, "LockedValue", false) catch {};
    }
    try deny(parent, "LockedKey", true);
    try deny(parent, "LockedValue", true);

    try testing.expectEqual(rc.FixResult{ .fixed = 0, .failed = 2 }, try rc.apply(gpa, io, &issues, uacDeclined));
    try testing.expectEqual(1, hook.prompts); // one prompt for the whole batch, not one per issue
    for (issues) |i| try testing.expect(rc.exists(&i));
    // hardening beyond C#: during the import nobody else could write, rename or delete the deletion .reg ...
    try testing.expect(!hook.tampered);
    const plain = try fx.path("plain.reg");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = plain, .data = "x" });
    try testing.expect(tamper(plain)); // (control: an ordinary file can be tampered with)
    // ... while reg.exe itself still reads it (uacAccepted runs the real reg.exe import on the held file)

    try testing.expectEqual(rc.FixResult{ .fixed = 2, .failed = 0 }, try rc.apply(gpa, io, &issues, uacAccepted));
    for (issues) |i| try testing.expect(!rc.exists(&i));
}

// Guard beyond the C# spec: a hive itself is never deleted, neither directly nor through the elevated import.
test "Apply never sends a bare hive to the elevated import" {
    const issues = [_]RegIssue{
        .{ .category = "t", .problem = "t", .data = "", .key_path = "HKEY_CURRENT_USER", .value_name = null },
        .{ .category = "t", .problem = "t", .data = "", .key_path = "HKEY_CURRENT_USER", .value_name = "MakeCleanerTest-no-such-value" },
    };
    hook = .{};
    try testing.expectEqual(rc.FixResult{ .fixed = 0, .failed = 2 }, try rc.apply(testing.allocator, testing.io, &issues, uacDeclined));
    try testing.expectEqual(0, hook.prompts);
    // so the backup has nothing to save for them either: no whole-hive export (C#), no error
    const dir = try common.TempDir.create(testing.allocator, testing.io, "reg");
    defer dir.cleanup(testing.allocator, testing.io);
    const file = try dir.join(testing.allocator, "hive.reg");
    defer testing.allocator.free(file);
    try rc.writeBackup(testing.allocator, testing.io, &issues, file);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("Windows Registry Editor Version 5.00\r\n", try readReg(arena.allocator(), file));
}

// RegFix writes [k.Name]: the long hive name, whatever alias the issue was built with; regedit wants that.
test "Backup and deletion script name keys like RegistryKey.Name" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.alloc();
    try fx.set(.hkcu, "Alias", "v", .{ .sz = "1" });
    const short = try a.print("hkcu\\{s}\\hkcu\\Alias\\", .{fx.branch.sub});
    const long = try a.print("HKEY_CURRENT_USER\\{s}\\hkcu\\Alias]\r\n", .{fx.branch.sub});
    const issues = [_]RegIssue{
        .{ .category = "t", .problem = "t", .data = "", .key_path = short, .value_name = "v" },
        .{ .category = "t", .problem = "t", .data = "", .key_path = short, .value_name = null },
    };
    const file = try fx.path("alias.reg");
    try rc.writeBackup(testing.allocator, testing.io, &issues, file);
    try testing.expectEqual(2, std.mem.count(u8, try readReg(a, file), try a.print("[{s}", .{long})));
    const del = try rc.deletionScript(a, &issues);
    try testing.expect(std.mem.find(u8, del, try a.print("\r\n[{s}\"v\"=-", .{long})) != null);
    try testing.expect(std.mem.find(u8, del, try a.print("\r\n[-{s}", .{long})) != null);
}

var cancel_flag: common.Cancel = .init(false);

/// A category during which the user presses Cancel; it then finds the seeded broken Run entry.
fn cancelDuring(s: *const rc.RegScanner, a: std.mem.Allocator) anyerror![]RegIssue {
    cancel_flag.store(true, .release);
    for (rc.categories) |c| if (std.mem.eql(u8, c.name, "Run At Startup")) return c.scan(s, a);
    unreachable;
}

// C# checks the token per yielded issue: Cancel lands inside a category, not only between categories.
test "Scan: Cancel lands at the next issue, inside the category" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.seedAll();
    cancel_flag.store(false, .release);
    const s: rc.RegScanner = .{ .hkcu = fx.hkcu, .hklm = fx.hklm };
    try testing.expectError(error.Canceled, s.scan(fx.alloc(), &.{.{ .name = "t", .scan = cancelDuring }}, &.{}, &cancel_flag));
}

test "RegistryTests.Deletion_script_uses_regedit_removal_syntax" {
    const gpa = testing.allocator;
    const s = try rc.deletionScript(gpa, &.{
        .{ .category = "t", .problem = "t", .data = "", .key_path = "HKEY_LOCAL_MACHINE\\SOFTWARE\\A", .value_name = null },
        .{ .category = "t", .problem = "t", .data = "", .key_path = "HKEY_CLASSES_ROOT\\B", .value_name = "x\"y" },
        .{ .category = "t", .problem = "t", .data = "", .key_path = "HKEY_CURRENT_USER\\C", .value_name = "" },
    });
    defer gpa.free(s);
    try testing.expect(std.mem.startsWith(u8, s, "Windows Registry Editor Version 5.00\r\n"));
    try testing.expect(std.mem.find(u8, s, "\r\n[-HKEY_LOCAL_MACHINE\\SOFTWARE\\A]\r\n") != null);
    try testing.expect(std.mem.find(u8, s, "\r\n[HKEY_CLASSES_ROOT\\B]\r\n\"x\\\"y\"=-\r\n") != null);
    try testing.expect(std.mem.find(u8, s, "\r\n[HKEY_CURRENT_USER\\C]\r\n@=-\r\n") != null);
}

test "RegistryTests.Backup_failure_changes_nothing" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    elevated.Fake.install();
    defer elevated.Fake.uninstall();
    try fx.seedAll();
    const issues = try fx.scan(&.{});
    if (rc.fix(testing.allocator, testing.io, issues, try fx.path("no-such-dir\\b.reg"), null)) |_| return error.TestUnexpectedResult else |_| {}
    try testing.expectEqual(issues.len, (try fx.scan(&.{})).len);
}

fn expectExtract(cmd: []const u8, expected: ?[]const u8) !void {
    const got = try rc.extractPath(testing.allocator, cmd);
    defer if (got) |g| testing.allocator.free(g);
    if (expected) |e| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(e, got.?);
    } else if (got) |g| {
        std.debug.print("expected null, got {s}\n", .{g});
        return error.TestUnexpectedResult;
    }
}

test "RegistryTests.ExtractPath_is_conservative(quoted with args)" {
    try expectExtract("\"C:\\Program Files\\App\\app.exe\" /min", "C:\\Program Files\\App\\app.exe");
}

test "RegistryTests.ExtractPath_is_conservative(unquoted with args)" {
    try expectExtract("C:\\Program Files\\App\\app.exe /min", "C:\\Program Files\\App\\app.exe");
}

test "RegistryTests.ExtractPath_is_conservative(icon resource index)" {
    try expectExtract("C:\\Windows\\System32\\shell32.dll,-101", "C:\\Windows\\System32\\shell32.dll");
}

test "ExtractPath: the resource index is an int.TryParse number, so no '_' separators" {
    try expectExtract("C:\\Windows\\System32\\shell32.dll,1_0", "C:\\Windows\\System32\\shell32.dll,1_0");
}

test "RegistryTests.ExtractPath_is_conservative(relative)" {
    try expectExtract("notepad.exe", null);
}

test "RegistryTests.ExtractPath_is_conservative(rundll32)" {
    try expectExtract("rundll32.exe C:\\x\\y.dll,Entry", null);
}

test "RegistryTests.ExtractPath_is_conservative(UNC)" {
    try expectExtract("\\\\server\\share\\app.exe", null);
}

test "RegistryTests.ExtractPath_is_conservative(unexpanded variable)" {
    try expectExtract("%MC_NO_SUCH_VAR%\\app.exe", null);
}

test "RegistryTests.Unreadable_location_is_unknown_not_missing" {
    // non-admin cannot list %windir%\System32\config; anything below it must never be reported
    if (elevated.isAdmin()) return error.SkipZigTest; // admin can list it: the case doesn't apply
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.alloc();
    const cfg = try Io.Dir.path.join(a, &.{ try win.knownFolder(a, &w.FOLDERID_System), "config\\systemprofile\\makecleaner-nope.dll" });
    try testing.expect(!rc.missing(a, cfg));
    try testing.expect(rc.missing(a, fx.missing));
}

test "RegistryTests.Real_system_scan_is_read_only_and_does_not_throw" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = rc.RegScanner.forThisPc();
    const issues = try s.scan(arena.allocator(), &rc.categories, &.{}, null);
    for (issues) |i| try testing.expect(i.key_path.len > 0);
}
