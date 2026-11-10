//! RegistryCleaner.cs. RegScanner: read-only scan of 15 categories; every check is conservative (anything not
//! resolvable to a local absolute path is NOT an issue). RegFix: regedit-importable .reg backup, then removal; what
//! a normal user cannot delete goes into one deletion .reg imported elevated (one UAC prompt per batch).
//! Excludes: custom.registryExcludes(settings).
const std = @import("std");
const kit = @import("kit");
const common = @import("common.zig");
const reg = @import("reg.zig");
const elevated = @import("elevated.zig");

const win = kit.win;
const w = kit.w;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// record RegIssue(Category, Problem, Data, KeyPath, ValueName). value_name null -> the whole key is the
/// problem; "" -> the default value. key_path is a full name ("HKEY_CURRENT_USER\...", like RegistryKey.Name).
pub const RegIssue = struct {
    category: []const u8,
    problem: []const u8,
    data: []const u8,
    key_path: []const u8,
    value_name: ?[]const u8,

    /// RegIssue.Target: key_path, or key_path\value ("(Default)" for ""). Caller frees.
    pub fn target(i: *const RegIssue, gpa: Allocator) ![]u8 {
        const v = i.value_name orelse return gpa.dupe(u8, i.key_path);
        return gpa.print("{s}\\{s}", .{ i.key_path, if (v.len == 0) "(Default)" else v });
    }
};

/// An open key plus its full name: RegistryKey `hkcu`/`hklm` of the C# scanner. The real hives in the app,
/// subkeys of a throwaway HKCU\Software\MakeCleanerTest-<random> branch in tests. The scanner never closes them.
pub const Hive = struct {
    key: win.Key,
    /// RegistryKey.Name of `key`, e.g. "HKEY_CURRENT_USER" or "HKEY_CURRENT_USER\Software\MakeCleanerTest-..\HKCU".
    name: []const u8,
};

/// record RegCategory(Name, Scan). `scan` allocates everything (issues and scratch) in `arena`.
pub const RegCategory = struct {
    name: []const u8,
    scan: *const fn (s: *const RegScanner, arena: Allocator) anyerror![]RegIssue,
};

/// class RegScanner(hkcu, hklm). Read-only: keys are only ever opened with KEY_READ.
pub const RegScanner = struct {
    hkcu: Hive,
    hklm: Hive,
    /// Set by `scan` for the categories: checked at every issue found, like C#'s check per yielded issue.
    cancel: ?*const common.Cancel = null,

    /// RegScanner.ForThisPc: HKEY_CURRENT_USER + HKEY_LOCAL_MACHINE (default view = 64-bit, the exe is x64).
    pub fn forThisPc() RegScanner {
        return .{
            .hkcu = .{ .key = predefined(0x80000001), .name = "HKEY_CURRENT_USER" },
            .hklm = .{ .key = predefined(0x80000002), .name = "HKEY_LOCAL_MACHINE" },
        };
    }

    /// RegScanner.Scan: issues of `cats`, minus targets equal to or under an `excluded` entry
    /// (OrdinalIgnoreCase, trailing '\' ignored). Everything lives in `arena`. Cancel -> error.Canceled.
    pub fn scan(s: *const RegScanner, arena: Allocator, cats: []const RegCategory, excluded: []const []const u8, cancel: ?*const common.Cancel) ![]RegIssue {
        const ex = try arena.alloc([2][]const u8, excluded.len); // e, e + "\"
        for (excluded, ex) |raw, *x| {
            const e = std.mem.trimEnd(u8, raw, "\\");
            x.* = .{ e, try arena.print("{s}\\", .{e}) };
        }
        var sc = s.*;
        sc.cancel = cancel;
        var all: std.ArrayList(RegIssue) = .empty;
        for (cats) |c| {
            try common.check(cancel);
            for (try c.scan(&sc, arena)) |i| {
                const t = try i.target(arena);
                for (ex) |x| {
                    if (common.eqlIgnoreCase(t, x[0]) or common.startsWithIgnoreCase(t, x[1])) break;
                } else try all.append(arena, i);
            }
        }
        return all.items;
    }

    fn classExists(s: *const RegScanner, a: Allocator, prog_id: []const u8) bool {
        const cu = a.print("Software\\Classes\\{s}", .{prog_id}) catch return true;
        const lm = a.print("SOFTWARE\\Classes\\{s}", .{prog_id}) catch return true;
        return present(s.hkcu.key, cu) or present(s.hklm.key, lm);
    }
};

/// Predefined HKEY from its magic value (kit.win.rootKey is private). ponytail: the odd handle value is never
/// dereferenced, so the alignment check is off; `v` must stay a runtime parameter (see notes K4).
fn predefined(v: usize) win.Key {
    @setRuntimeSafety(false);
    return .{ .h = @ptrFromInt(v) };
}

/// RegScanner.Categories, in C# order.
pub const categories = [_]RegCategory{
    .{ .name = "Missing Shared DLLs", .scan = sharedDlls },
    .{ .name = "Unused File Extensions", .scan = fileExtensions },
    .{ .name = "ActiveX and Class Issues", .scan = comClasses },
    .{ .name = "Type Libraries", .scan = typeLibs },
    .{ .name = "Applications", .scan = openWithApps },
    .{ .name = "Fonts", .scan = fonts },
    .{ .name = "Application Paths", .scan = appPaths },
    .{ .name = "Help Files", .scan = helpFiles },
    .{ .name = "Installer", .scan = installerFolders },
    .{ .name = "Obsolete Software", .scan = obsoleteSoftware },
    .{ .name = "Run At Startup", .scan = runAtStartup },
    .{ .name = "Start Menu Ordering", .scan = startMenuOrder },
    .{ .name = "MUI Cache", .scan = muiCache },
    .{ .name = "Sound Events", .scan = soundEvents },
    .{ .name = "Windows Services", .scan = services },
};

// ---------------------------------------------------------------- categories

const cv = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion";
const wow_cv = "SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion";
const List = std.ArrayList(RegIssue);

/// yield return: the cancel check sits here, so Cancel lands at the next issue, not at the end of the category.
fn add(s: *const RegScanner, out: *List, a: Allocator, cat: []const u8, problem: []const u8, data: []const u8, key_path: []const u8, value: ?[]const u8) !void {
    try common.check(s.cancel);
    try out.append(a, .{ .category = cat, .problem = problem, .data = data, .key_path = key_path, .value_name = value });
}

// SharedDLLs: value name = refcounted file path.
fn sharedDlls(s: *const RegScanner, a: Allocator) anyerror![]RegIssue {
    var out: List = .empty;
    for ([_][]const u8{ cv ++ "\\SharedDLLs", wow_cv ++ "\\SharedDLLs" }) |p| {
        const root = open(a, s.hklm, p) orelse continue;
        defer root.key.close();
        for (valueNames(a, root.key)) |v| {
            if (missing(a, v.name)) try add(s, &out, a, "Missing Shared DLLs", "Missing Shared DLL", v.name, root.name, v.name);
        }
    }
    return out.items;
}

// .ext whose ProgID points nowhere and that carries nothing else.
fn fileExtensions(s: *const RegScanner, a: Allocator) anyerror![]RegIssue {
    var out: List = .empty;
    const classes = open(a, s.hkcu, "Software\\Classes") orelse return out.items;
    defer classes.key.close();
    for (subkeyNames(a, classes.key)) |ext| {
        if (!std.mem.startsWith(u8, ext, ".")) continue;
        const k = open(a, classes, ext) orelse continue;
        defer k.key.close();
        const n = counts(k.key) orelse continue;
        if (n.subkeys > 0 or n.values != 1) continue;
        const prog_id = str(a, k.key, "") orelse continue;
        if (prog_id.len > 0 and !s.classExists(a, prog_id))
            try add(s, &out, a, "Unused File Extensions", "Unused File Extension", try a.print("{s} -> {s}", .{ ext, prog_id }), k.name, null);
    }
    return out.items;
}

// Per-user COM registrations whose server binary is gone.
fn comClasses(s: *const RegScanner, a: Allocator) anyerror![]RegIssue {
    var out: List = .empty;
    const clsid = open(a, s.hkcu, "Software\\Classes\\CLSID") orelse return out.items;
    defer clsid.key.close();
    for (subkeyNames(a, clsid.key)) |id| {
        const k = open(a, clsid, id) orelse continue;
        defer k.key.close();
        for ([_][]const u8{ "InprocServer32", "LocalServer32" }) |server| {
            const cmd = default(a, k.key, server) orelse continue;
            if (missingCommand(a, cmd)) {
                try add(s, &out, a, "ActiveX and Class Issues", "ActiveX/COM Issue", cmd, k.name, null);
                break;
            }
        }
    }
    return out.items;
}

// TypeLib\{guid}\{ver}\{lcid}\win32|win64 -> .tlb/.dll path.
fn typeLibs(s: *const RegScanner, a: Allocator) anyerror![]RegIssue {
    var out: List = .empty;
    const tl = open(a, s.hkcu, "Software\\Classes\\TypeLib") orelse return out.items;
    defer tl.key.close();
    for (subkeyNames(a, tl.key)) |id| {
        const g = open(a, tl, id) orelse continue;
        defer g.key.close();
        for (subkeyNames(a, g.key)) |ver| {
            const v = open(a, g, ver) orelse continue;
            defer v.key.close();
            var paths: std.ArrayList([]const u8) = .empty;
            for (subkeyNames(a, v.key)) |lcid| for ([_][]const u8{ "win32", "win64" }) |plat| {
                if (default(a, v.key, try a.print("{s}\\{s}", .{ lcid, plat }))) |p| try paths.append(a, p);
            };
            if (paths.items.len > 0 and allMissing(a, paths.items))
                try add(s, &out, a, "Type Libraries", "Missing TypeLib reference", paths.items[0], v.name, null);
        }
    }
    return out.items;
}

// Classes\Applications\<exe>\shell\<verb>\command -> program that no longer exists.
fn openWithApps(s: *const RegScanner, a: Allocator) anyerror![]RegIssue {
    var out: List = .empty;
    const apps = open(a, s.hkcu, "Software\\Classes\\Applications") orelse return out.items;
    defer apps.key.close();
    for (subkeyNames(a, apps.key)) |app| {
        const shell = open(a, apps, try a.print("{s}\\shell", .{app})) orelse continue;
        defer shell.key.close();
        var cmds: std.ArrayList([]const u8) = .empty;
        for (subkeyNames(a, shell.key)) |verb| {
            if (default(a, shell.key, try a.print("{s}\\command", .{verb}))) |c| try cmds.append(a, c);
        }
        if (cmds.items.len > 0 and allMissing(a, cmds.items))
            try add(s, &out, a, "Applications", "Open with Application Issue", cmds.items[0], try a.print("{s}\\{s}", .{ apps.name, app }), null);
    }
    return out.items;
}

// Fonts: data is a bare file name (=> %windir%\Fonts) or a full path (per-user fonts).
fn fonts(s: *const RegScanner, a: Allocator) anyerror![]RegIssue {
    var out: List = .empty;
    const fonts_dir = win.knownFolder(a, &w.FOLDERID_Fonts) catch ""; // GetFolderPath gives "" on failure
    for ([_]Hive{ s.hkcu, s.hklm }) |hive| {
        const root = open(a, hive, "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts") orelse continue;
        defer root.key.close();
        for (valueNames(a, root.key)) |v| {
            const file = str(a, root.key, v.name) orelse continue;
            if (file.len > 0 and missing(a, try combine(a, fonts_dir, file)))
                try add(s, &out, a, "Fonts", "Font Issue", file, root.name, v.name);
        }
    }
    return out.items;
}

fn appPaths(s: *const RegScanner, a: Allocator) anyerror![]RegIssue {
    var out: List = .empty;
    for ([_]Hive{ s.hkcu, s.hklm }) |hive| for ([_][]const u8{ cv ++ "\\App Paths", wow_cv ++ "\\App Paths" }) |p| {
        const root = open(a, hive, p) orelse continue;
        defer root.key.close();
        for (subkeyNames(a, root.key)) |exe| {
            const cmd = default(a, root.key, exe) orelse continue;
            if (missingCommand(a, cmd))
                try add(s, &out, a, "Application Paths", "Application Paths Issue", cmd, try a.print("{s}\\{s}", .{ root.name, exe }), null);
        }
    };
    return out.items;
}

// Help: value name = file name, data = folder.
fn helpFiles(s: *const RegScanner, a: Allocator) anyerror![]RegIssue {
    var out: List = .empty;
    for ([_][]const u8{
        "SOFTWARE\\Microsoft\\Windows\\Help",              "SOFTWARE\\Microsoft\\Windows\\HTML Help",
        "SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\Help", "SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\HTML Help",
    }) |p| {
        const root = open(a, s.hklm, p) orelse continue;
        defer root.key.close();
        for (valueNames(a, root.key)) |v| {
            if (v.name.len == 0) continue;
            const dir = str(a, root.key, v.name) orelse continue;
            if (dir.len == 0) continue;
            const file = try combine(a, dir, v.name);
            if (missing(a, file)) try add(s, &out, a, "Help Files", "Help File Issue", file, root.name, v.name);
        }
    }
    return out.items;
}

// Installer\Folders: value name = folder Windows Installer created.
fn installerFolders(s: *const RegScanner, a: Allocator) anyerror![]RegIssue {
    var out: List = .empty;
    const root = open(a, s.hklm, cv ++ "\\Installer\\Folders") orelse return out.items;
    defer root.key.close();
    for (valueNames(a, root.key)) |v| {
        if (missing(a, v.name)) try add(s, &out, a, "Installer", "Installer Reference Issue", v.name, root.name, v.name);
    }
    return out.items;
}

// HKCU\Software\<vendor> keys left completely empty by uninstallers.
fn obsoleteSoftware(s: *const RegScanner, a: Allocator) anyerror![]RegIssue {
    var out: List = .empty;
    const sw = open(a, s.hkcu, "Software") orelse return out.items;
    defer sw.key.close();
    for (subkeyNames(a, sw.key)) |name| {
        const k = open(a, sw, name) orelse continue;
        defer k.key.close();
        const n = counts(k.key) orelse continue;
        if (n.subkeys == 0 and n.values == 0) try add(s, &out, a, "Obsolete Software", "Obsolete software key", name, k.name, null);
    }
    return out.items;
}

fn runAtStartup(s: *const RegScanner, a: Allocator) anyerror![]RegIssue {
    var out: List = .empty;
    for ([_]Hive{ s.hkcu, s.hklm }) |hive| for ([_][]const u8{ cv ++ "\\Run", cv ++ "\\RunOnce", wow_cv ++ "\\Run", wow_cv ++ "\\RunOnce" }) |p| {
        const root = open(a, hive, p) orelse continue;
        defer root.key.close();
        for (valueNames(a, root.key)) |v| {
            const cmd = str(a, root.key, v.name) orelse continue;
            if (missingCommand(a, cmd)) try add(s, &out, a, "Run At Startup", "Missing Startup Software", cmd, root.name, v.name);
        }
    };
    return out.items;
}

// MenuOrder\Start Menu2\Programs\<folder>: ordering cache for Start Menu folders that are gone.
fn startMenuOrder(s: *const RegScanner, a: Allocator) anyerror![]RegIssue {
    var out: List = .empty;
    const order = open(a, s.hkcu, cv ++ "\\Explorer\\MenuOrder\\Start Menu2\\Programs") orelse return out.items;
    defer order.key.close();
    const bases = [_][]const u8{
        win.knownFolder(a, &w.FOLDERID_Programs) catch "",
        win.knownFolder(a, &w.FOLDERID_CommonPrograms) catch "",
    };
    for (subkeyNames(a, order.key)) |name| {
        for (bases) |b| {
            if (kind(try combine(a, b, name)) == .dir) break;
        } else try add(s, &out, a, "Start Menu Ordering", "Old Start Menu key", name, try a.print("{s}\\{s}", .{ order.name, name }), null);
    }
    return out.items;
}

// MuiCache: "C:\x\app.exe.FriendlyAppName" -> the exe part.
fn muiCache(s: *const RegScanner, a: Allocator) anyerror![]RegIssue {
    var out: List = .empty;
    const root = open(a, s.hkcu, "Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\MuiCache") orelse return out.items;
    defer root.key.close();
    for (valueNames(a, root.key)) |v| {
        const dot = std.mem.findScalarLast(u8, v.name, '.') orelse continue;
        if (std.mem.startsWith(u8, v.name, "@") or dot == 0) continue;
        if (missing(a, v.name[0..dot])) try add(s, &out, a, "MUI Cache", "Missing MUI reference", v.name[0..dot], root.name, v.name);
    }
    return out.items;
}

// AppEvents\Schemes\Apps\<app>\<event>\<scheme> default = .wav path.
fn soundEvents(s: *const RegScanner, a: Allocator) anyerror![]RegIssue {
    var out: List = .empty;
    const apps = open(a, s.hkcu, "AppEvents\\Schemes\\Apps") orelse return out.items;
    defer apps.key.close();
    for (subkeyNames(a, apps.key)) |app| {
        const ak = open(a, apps, app) orelse continue;
        defer ak.key.close();
        for (subkeyNames(a, ak.key)) |ev| {
            const ek = open(a, ak, ev) orelse continue;
            defer ek.key.close();
            for (subkeyNames(a, ek.key)) |scheme| {
                const sk = open(a, ek, scheme) orelse continue;
                defer sk.key.close();
                const wav = str(a, sk.key, "") orelse continue;
                if (wav.len > 0 and missing(a, wav)) try add(s, &out, a, "Sound Events", "Invalid file reference", wav, sk.name, "");
            }
        }
    }
    return out.items;
}

// Only user-mode services (Type 0x10 / 0x20); drivers are never touched.
fn services(s: *const RegScanner, a: Allocator) anyerror![]RegIssue {
    var out: List = .empty;
    const svcs = open(a, s.hklm, "SYSTEM\\CurrentControlSet\\Services") orelse return out.items;
    defer svcs.key.close();
    for (subkeyNames(a, svcs.key)) |name| {
        const k = open(a, svcs, name) orelse continue;
        defer k.key.close();
        const t = k.key.readDword("Type") catch continue; // `is not int`: REG_DWORD only
        if (t & 0x30 == 0) continue;
        const img = str(a, k.key, "ImagePath") orelse continue;
        if (missingCommand(a, servicePath(a, img) catch continue))
            try add(s, &out, a, "Windows Services", "Invalid service image path", img, k.name, null);
    }
    return out.items;
}

// ---------------------------------------------------------------- scanner helpers

/// RegistryKey.OpenSubKey(path) read-only, relative to `parent`: null when missing; denied etc. are errors.
fn openSub(parent: win.Key, path: []const u8) !?win.Key {
    var stack: [1024]u8 = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(&stack, std.heap.page_allocator);
    const p = try win.toW(bfa.allocator(), path);
    defer bfa.allocator().free(p);
    var h: w.HKEY = null;
    return switch (w.RegOpenKeyExW(parent.h, p.ptr, 0, @intCast(w.KEY_READ), &h)) {
        0 => .{ .h = h },
        w.ERROR_FILE_NOT_FOUND, w.ERROR_PATH_NOT_FOUND => null,
        w.ERROR_ACCESS_DENIED => error.AccessDenied,
        else => error.Unexpected,
    };
}

/// Scanner.Open: null on missing, denied or anything else. Caller closes `.key`.
fn open(a: Allocator, parent: Hive, path: []const u8) ?Hive {
    const k = (openSub(parent.key, path) catch return null) orelse return null;
    const name = a.print("{s}\\{s}", .{ parent.name, path }) catch {
        k.close();
        return null;
    };
    return .{ .key = k, .name = name };
}

fn present(parent: win.Key, path: []const u8) bool {
    const k = (openSub(parent, path) catch return false) orelse return false;
    k.close();
    return true;
}

/// Scanner.Values: value names, empty on error. ponytail: unreadable subkey lists, `{app}\shell` and key counts are
/// skipped too, where C# threw out of the whole scan (RegistryView catches only cancellation, so the app died on a
/// key deleted mid-scan). Skipping can only under-report, never flag a healthy entry.
fn valueNames(a: Allocator, k: win.Key) []const win.ValueInfo {
    return k.values(a) catch &.{};
}

fn subkeyNames(a: Allocator, k: win.Key) []const []u8 {
    return k.subkeys(a) catch &.{};
}

fn counts(k: win.Key) ?struct { subkeys: u32, values: u32 } {
    var subs: w.DWORD = 0;
    var vals: w.DWORD = 0;
    if (w.RegQueryInfoKeyW(k.h, null, null, null, &subs, null, null, &vals, null, null, null, null) != 0) return null;
    return .{ .subkeys = subs, .values = vals };
}

/// GetValue(name) as string: REG_SZ as is, REG_EXPAND_SZ expanded (like .NET); null for anything else.
fn str(a: Allocator, k: win.Key, name: []const u8) ?[]const u8 {
    const v = k.readRaw(a, name) catch return null;
    if (v.kind != w.REG_SZ and v.kind != w.REG_EXPAND_SZ) return null;
    const s = text(a, v.data) catch return null;
    return if (v.kind == w.REG_EXPAND_SZ) win.expandEnv(a, s) catch null else s;
}

/// REG_SZ bytes -> WTF-8, dropping one terminating NUL (as .NET does).
fn text(a: Allocator, bytes: []const u8) ![]u8 {
    const u = try units(a, bytes);
    defer a.free(u);
    return win.fromW(a, if (u.len > 0 and u[u.len - 1] == 0) u[0 .. u.len - 1] else u);
}

/// Registry data is byte-aligned: copy into a real []u16 (odd trailing byte dropped).
fn units(a: Allocator, bytes: []const u8) ![]u16 {
    const out = try a.alloc(u16, bytes.len / 2);
    @memcpy(std.mem.sliceAsBytes(out), bytes[0 .. out.len * 2]);
    return out;
}

/// Scanner.Default: default value of `parent\path` when it is a non-empty string.
fn default(a: Allocator, parent: win.Key, path: []const u8) ?[]const u8 {
    const k = (openSub(parent, path) catch return null) orelse return null;
    defer k.close();
    const s = str(a, k, "") orelse return null;
    return if (s.len > 0) s else null;
}

fn allMissing(a: Allocator, cmds: []const []const u8) bool {
    for (cmds) |c| if (!missingCommand(a, c)) return false;
    return true;
}

/// ServicePath: "\SystemRoot\x", "\??\C:\x", "system32\x" (relative to %windir%) -> absolute.
fn servicePath(a: Allocator, img: []const u8) ![]const u8 {
    const p = try win.expandEnv(a, trim(img));
    const windows = win.knownFolder(a, &w.FOLDERID_Windows) catch "";
    if (common.startsWithIgnoreCase(p, "\\SystemRoot\\")) return combine(a, windows, p[12..]);
    if (std.mem.startsWith(u8, p, "\\??\\")) return p[4..];
    if (common.startsWithIgnoreCase(p, "system32\\")) return combine(a, windows, p);
    return p;
}

// ---------------------------------------------------------------- paths (RegScanner statics)

/// RegScanner.MissingCommand: extractPath(cmd) is a local absolute path that is missing.
pub fn missingCommand(gpa: Allocator, cmd: []const u8) bool {
    const p = (extractPath(gpa, cmd) catch return false) orelse return false;
    defer gpa.free(p);
    return missing(gpa, p);
}

/// RegScanner.ExtractPath: program/file of a command line or icon reference ("file.dll,-101", quoted or
/// unquoted with an executable extension); null when unsure (rundll32, unexpanded '%', relative). Caller frees.
pub fn extractPath(gpa: Allocator, cmd: []const u8) !?[]u8 {
    const e = try win.expandEnv(gpa, trim(cmd));
    defer gpa.free(e);
    var s: []const u8 = e;
    if (s.len == 0) return null;
    if (s[0] == '"') {
        const end = std.mem.findScalarPos(u8, s, 1, '"') orelse return null;
        s = s[1..end];
    } else {
        if (std.mem.findScalarLast(u8, s, ',')) |comma| { // "file.dll,-101"
            if (comma > 0 and isInt(trim(s[comma + 1 ..]))) s = s[0..comma];
        }
        // unquoted "C:\Program Files\x\app.exe /arg": cut after the first executable extension
        if (kind(s) != .file) s = exeCut(s) orelse s;
    }
    // rundll32: the real dll is an argument; '%': unexpanded variable in the path itself
    if (std.ascii.findIgnoreCase(s, "rundll32") != null or std.mem.findScalar(u8, s, '%') != null) return null;
    return if (isLocalAbsolute(s)) try gpa.dupe(u8, s) else null;
}

/// int.TryParse (sign, digits, Int32 range). parseInt alone would also take '_' digit separators.
fn isInt(s: []const u8) bool {
    if (std.mem.findScalar(u8, s, '_') != null) return false;
    _ = std.fmt.parseInt(i32, s, 10) catch return false;
    return true;
}

/// Regex ^.+?\.(exe|dll|ocx|cpl|com|scr|tlb|olb|sys)(?=\s|$), IgnoreCase: the shortest prefix ending in an
/// executable extension that is followed by whitespace or the end. ponytail: ASCII whitespace only for \s.
fn exeCut(s: []const u8) ?[]const u8 {
    const exts = [_][]const u8{ "exe", "dll", "ocx", "cpl", "com", "scr", "tlb", "olb", "sys" };
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (s[i - 1] == '\n') return null; // '.' never matches a newline
        const end = i + 4;
        if (s[i] != '.' or end > s.len or (end < s.len and !std.ascii.isWhitespace(s[end]))) continue;
        for (exts) |x| if (std.ascii.eqlIgnoreCase(s[i + 1 .. end], x)) return s[0..end];
    }
    return null;
}

const trim = common.trim;

/// "C:\..." on a drive that is there: an unplugged/removable drive is unknown, not an issue.
fn isLocalAbsolute(p: []const u8) bool {
    return p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and p[2] == '\\' and kind(p[0..3]) == .dir;
}

/// Path.GetInvalidPathChars (.NET Core, Windows): '|' and 0..31.
const invalid_path_chars = blk: {
    var c: [33]u8 = undefined;
    for (0..32) |i| c[i] = @intCast(i);
    c[32] = '|';
    break :blk c;
};

/// RegScanner.Missing: local absolute path (drive present) where neither the file, the folder nor the
/// System32->SysWOW64 twin exists, and the deepest existing parent can be listed (access denied != missing).
pub fn missing(gpa: Allocator, path: []const u8) bool {
    if (!isLocalAbsolute(path) or std.mem.findAny(u8, path, &invalid_path_chars) != null) return false;
    if (kind(path) != .none) return false;
    const twin = replaceIgnoreCase(gpa, path, "\\System32\\", "\\SysWOW64\\") catch return false;
    defer gpa.free(twin);
    if (!std.mem.eql(u8, twin, path) and kind(twin) == .file) return false;
    return canList(deepestExistingFolder(path)); // *.Exists says false on access denied too
}

fn replaceIgnoreCase(gpa: Allocator, s: []const u8, from: []const u8, to: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        if (std.ascii.startsWithIgnoreCase(s[i..], from)) {
            try out.appendSlice(gpa, to);
            i += from.len;
        } else {
            try out.append(gpa, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn deepestExistingFolder(path: []const u8) ?[]const u8 {
    var p = Io.Dir.path.dirname(std.mem.trimEnd(u8, path, "\\"));
    while (p) |d| : (p = Io.Dir.path.dirname(d)) if (kind(d) == .dir) return d;
    return null;
}

fn canList(dir: ?[]const u8) bool {
    const d = dir orelse return false;
    var stack: [2048]u8 = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(&stack, std.heap.page_allocator);
    const al = bfa.allocator();
    const pattern = al.print("{s}{s}*", .{ d, if (std.mem.endsWith(u8, d, "\\")) "" else "\\" }) catch return false;
    const p = win.toW(al, pattern) catch return false;
    var fd: w.WIN32_FIND_DATAW = undefined;
    const h = w.FindFirstFileW(p.ptr, &fd);
    if (h == w.INVALID_HANDLE_VALUE) return w.GetLastError() == w.ERROR_FILE_NOT_FOUND; // empty drive root: listed fine
    _ = w.FindClose(h);
    return true;
}

const Kind = enum { none, file, dir };

/// File.Exists / Directory.Exists. Like .NET, a locked or unreadable entry is looked up through its parent
/// listing before it counts as absent (pagefile.sys and friends exist).
fn kind(path: []const u8) Kind {
    var stack: [2048]u8 = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(&stack, std.heap.page_allocator);
    const p = win.toW(bfa.allocator(), path) catch return .none;
    defer bfa.allocator().free(p);
    var attrs = w.GetFileAttributesW(p.ptr);
    if (attrs == w.INVALID_FILE_ATTRIBUTES) {
        const e = w.GetLastError();
        if (e != w.ERROR_ACCESS_DENIED and e != w.ERROR_SHARING_VIOLATION) return .none;
        var fd: w.WIN32_FIND_DATAW = undefined;
        const h = w.FindFirstFileW(p.ptr, &fd);
        if (h == w.INVALID_HANDLE_VALUE) return .none;
        _ = w.FindClose(h);
        attrs = fd.dwFileAttributes;
    }
    return if (attrs & w.FILE_ATTRIBUTE_DIRECTORY != 0) .dir else .file;
}

/// Path.IsPathRooted (Windows): leading separator or drive.
fn rooted(p: []const u8) bool {
    return (p.len >= 1 and (p[0] == '\\' or p[0] == '/')) or (p.len >= 2 and std.ascii.isAlphabetic(p[0]) and p[1] == ':');
}

/// Path.Combine(a, b).
fn combine(a: Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    if (dir.len == 0 or rooted(name)) return name;
    if (name.len == 0) return dir;
    const sep = dir[dir.len - 1] == '\\' or dir[dir.len - 1] == '/';
    return a.print("{s}{s}{s}", .{ dir, if (sep) "" else "\\", name });
}

// ---------------------------------------------------------------- static class RegFix

/// RegFix.Result(Fixed, Failed).
pub const FixResult = struct { fixed: usize, failed: usize };

/// RegFix importElevated hook: imports a deletion .reg elevated; false = UAC declined or reg.exe failed.
/// null = `reg.exe import "<file>" /reg:64` through elevated.run. Tests pass a fake (never UAC).
pub const ImportElevated = *const fn (reg_file: []const u8) bool;

const header = "Windows Registry Editor Version 5.00\r\n";

/// RegFix.Fix: writeBackup (fails before any change if the backup can't be written), then apply.
pub fn fix(gpa: Allocator, io: Io, issues: []const RegIssue, backup_path: []const u8, import_elevated: ?ImportElevated) !FixResult {
    try writeBackup(gpa, io, issues, backup_path);
    return apply(gpa, io, issues, import_elevated);
}

/// RegFix.Apply: removes the issues (caller already wrote the backup of all of them). Most issues live in
/// HKLM/HKCR, which a normal user cannot write: whatever is still there afterwards goes into one temp deletion
/// .reg imported elevated, so a whole batch costs one UAC prompt. The result is the registry's real state
/// afterwards, never "we tried": an issue counts as fixed only when its key/value is gone.
pub fn apply(gpa: Allocator, io: Io, issues: []const RegIssue, import_elevated: ?ImportElevated) !FixResult {
    // reg.delete never deletes a hive or a key right under one; deletable() keeps the elevated import to the same rule
    for (issues) |i| _ = reg.delete(.{ .key = i.key_path, .value = i.value_name });
    // Decide by what is still there, not by results: a failed open looks like "missing" to a direct delete.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var denied: std.ArrayList(RegIssue) = .empty;
    for (issues) |i| if (deletable(i) and exists(&i)) try denied.append(a, i);
    if (denied.items.len > 0) {
        const tmp = try tempFile(a, io);
        defer Io.Dir.cwd().deleteFile(io, tmp) catch {};
        const bytes = try utf16(a, try deletionScript(a, denied.items));
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = bytes });
        const held = try holdUnchanged(a, tmp, bytes);
        defer _ = w.CloseHandle(held); // before the deleteFile above
        _ = (import_elevated orelse importElevated)(tmp);
    }
    var fixed: usize = 0;
    for (issues) |i| fixed += @intFromBool(!exists(&i));
    return .{ .fixed = fixed, .failed = issues.len - fixed };
}

/// Guard (not in C#, whose OpenKey handed out the bare hive as a parent): a hive itself or a key right under
/// one is never deleted, neither directly (reg.delete refuses) nor through the elevated import; writeBackup skips
/// the same targets. reg.delete and this agree: RegOpenKeyEx folds "\\" and a trailing '\' like split() does.
fn deletable(i: RegIssue) bool {
    const s = reg.split(i.key_path) catch return false;
    return i.value_name != null or std.mem.findScalar(u8, s.sub, '\\') != null;
}

fn importElevated(reg_file: []const u8) bool {
    var buf: [2048]u8 = undefined;
    const args = std.mem.print(&buf, "import \"{s}\" /reg:64", .{reg_file}) catch return false;
    return elevated.run("reg.exe", args);
}

/// %TEMP%\MakeCleaner-fix-<random>.reg
fn tempFile(a: Allocator, io: Io) ![]u8 {
    var buf: [w.MAX_PATH + 1]u16 = undefined;
    const n = w.GetTempPathW(buf.len, &buf);
    if (n == 0 or n > buf.len) return error.Unexpected;
    var rnd: [16]u8 = undefined;
    io.random(&rnd);
    return a.print("{s}MakeCleaner-fix-{x}.reg", .{ try win.fromW(a, buf[0..n]), &rnd });
}

/// Hardening beyond the C# spec: %TEMP% is writable by every process of the user, yet reg.exe imports the file
/// as admin. Reopens it sharing reads only (no other writer, no rename or delete while the handle is open) and
/// checks it still holds `bytes`, so the script that was written is the one that gets imported. Caller closes.
fn holdUnchanged(a: Allocator, path: []const u8, bytes: []const u8) !w.HANDLE {
    const h = w.CreateFileW((try win.toW(a, path)).ptr, w.GENERIC_READ, w.FILE_SHARE_READ, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
    if (h == w.INVALID_HANDLE_VALUE) return error.TempFileBusy;
    errdefer _ = w.CloseHandle(h);
    const got = try a.alloc(u8, bytes.len + 1);
    var n: w.DWORD = 0;
    if (w.ReadFile(h, got.ptr, @intCast(got.len), &n, null) == 0 or !std.mem.eql(u8, got[0..n], bytes)) return error.TempFileChanged;
    return h;
}

/// "{f}": RegistryKey.Name of a key path, i.e. with the long hive name ("HKCU\x\" -> "HKEY_CURRENT_USER\x"),
/// which is what regedit wants in a .reg; as given when it has no known hive.
const KeyName = struct {
    path: []const u8,

    pub fn format(n: KeyName, wr: *Io.Writer) Io.Writer.Error!void {
        const s = reg.split(n.path) catch return wr.writeAll(n.path);
        const hive = switch (s.root) {
            .hkcu => "HKEY_CURRENT_USER",
            .hklm => "HKEY_LOCAL_MACHINE",
            .hkcr => "HKEY_CLASSES_ROOT",
            .hku => "HKEY_USERS",
        };
        try wr.print("{s}\\{s}", .{ hive, s.sub });
    }
};

/// RegFix.DeletionScript: regedit syntax for removal ([-key] deletes a key tree, "name"=- / @=- one value),
/// CRLF. Caller frees.
pub fn deletionScript(gpa: Allocator, issues: []const RegIssue) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, header);
    for (issues) |i| {
        const k: KeyName = .{ .path = i.key_path };
        if (i.value_name) |v| {
            try out.print(gpa, "\r\n[{f}]\r\n", .{k});
            try valueName(gpa, &out, v);
            try out.appendSlice(gpa, "=-\r\n");
        } else try out.print(gpa, "\r\n[-{f}]\r\n", .{k});
    }
    return out.toOwnedSlice(gpa);
}

/// RegFix.Exists: key (and value) still there; unreadable counts as there (certainly not fixed). ponytail: so does
/// a path without a known hive, where C#'s OpenKey threw ArgumentException; scanner issues always have one.
pub fn exists(issue: *const RegIssue) bool {
    const k = (reg.open(issue.key_path, false) catch return true) orelse return false;
    defer k.close();
    const v = issue.value_name orelse return true;
    return k.hasValue(v) catch true; // unknown = still there
}

/// RegFix.DefaultBackupName: "MakeCleaner_registry_yyyyMMdd_HHmmss.reg". Caller frees.
pub fn defaultBackupName(gpa: Allocator, now: common.DateTime) ![]u8 {
    return gpa.print("MakeCleaner_registry_{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}.reg", .{ now.year, now.month, now.day, now.hour, now.minute, now.second });
}

/// RegFix.WriteBackup: UTF-16LE + BOM .reg (like regedit) of every key tree / value the issues point at, under
/// the canonical key name ([k.Name]). Any read error fails the backup, so Fix changes nothing. A target apply never
/// removes (bare/unknown hive, key right under a hive) has nothing to back up: C# exported a whole hive there.
pub fn writeBackup(gpa: Allocator, io: Io, issues: []const RegIssue, path: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, header);
    for (issues) |i| {
        if (!deletable(i)) continue;
        const k = try reg.open(i.key_path, false) orelse continue;
        defer k.close();
        const name = try a.print("{f}", .{KeyName{ .path = i.key_path }});
        if (i.value_name) |v| {
            if (!(k.hasValue(v) catch true)) continue;
            try out.print(a, "\r\n[{s}]\r\n", .{name});
            try valueLine(a, &out, k, v);
            try out.appendSlice(a, "\r\n");
        } else try exportTree(a, &out, k, name);
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try utf16(a, out.items) });
}

fn exportTree(a: Allocator, out: *std.ArrayList(u8), k: win.Key, name: []const u8) !void {
    try out.print(a, "\r\n[{s}]\r\n", .{name});
    for (try k.values(a)) |v| {
        try valueLine(a, out, k, v.name);
        try out.appendSlice(a, "\r\n");
    }
    for (try k.subkeys(a)) |sub| {
        const s = try openSub(k, sub) orelse continue;
        defer s.close();
        try exportTree(a, out, s, try a.print("{s}\\{s}", .{ name, sub }));
    }
}

/// "name"=data in regedit syntax. A plain REG_SZ is quoted and a 4-byte REG_DWORD is dword:; everything else
/// is hex(<type>): with the raw bytes (hex: for REG_BINARY), exactly what regedit exports. ponytail: raw bytes
/// and the real type id where C# re-encoded its .NET objects and folded exotic types into REG_NONE.
fn valueLine(a: Allocator, out: *std.ArrayList(u8), k: win.Key, name: []const u8) !void {
    try valueName(a, out, name);
    try out.append(a, '=');
    const v = try k.readRaw(a, name);
    if (v.kind == w.REG_SZ and v.data.len % 2 == 0) {
        const u = try units(a, v.data);
        const body = if (u.len > 0 and u[u.len - 1] == 0) u[0 .. u.len - 1] else u;
        if (std.mem.findAny(u16, body, &.{ '\r', '\n', 0 }) == null) return quoted(a, out, try win.fromW(a, body));
    }
    if (v.kind == w.REG_DWORD and v.data.len == 4) return out.print(a, "dword:{x:0>8}", .{std.mem.readInt(u32, v.data[0..4], .little)});
    if (v.kind == w.REG_BINARY) try out.appendSlice(a, "hex:") else try out.print(a, "hex({x}):", .{v.kind});
    for (v.data, 0..) |b, n| try out.print(a, "{s}{x:0>2}", .{ if (n == 0) "" else ",", b });
}

fn valueName(a: Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    if (name.len == 0) return out.append(a, '@');
    try quoted(a, out, name);
}

/// "..." with \ and " escaped.
fn quoted(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    for (s) |c| {
        if (c == '\\' or c == '"') try out.append(a, '\\');
        try out.append(a, c);
    }
    try out.append(a, '"');
}

/// The bytes of File.WriteAllText(path, s, Encoding.Unicode): UTF-16LE with BOM.
fn utf16(a: Allocator, s: []const u8) ![]u8 {
    const u = try std.unicode.wtf8ToWtf16LeAlloc(a, s);
    const bytes = try a.alloc(u8, 2 + u.len * 2);
    bytes[0] = 0xFF;
    bytes[1] = 0xFE;
    @memcpy(bytes[2..], std.mem.sliceAsBytes(u));
    return bytes;
}
