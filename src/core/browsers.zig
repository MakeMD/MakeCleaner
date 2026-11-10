//! Port of legacy/src/MakeCleaner.Core/Browsers.cs (package MC-B).
//! Browsers tab: Chromium family + Firefox. Files go through the engine (excludes, secure delete); an item's
//! Action covers what is not a file (SQLite rows via the "sqlite" module, a JSON/prefs value).
//! Cookie keep-list: cookies.zig (cookies.keep / cookies.isKept).
const std = @import("std");
const kit = @import("kit");
const common = @import("common.zig");
const rules = @import("rules.zig");
const cookies = @import("cookies.zig");
pub const c = @import("sqlite"); // SQLite 3.54.1 C API (third_party/sqlite, translated by build.zig)

const w = kit.w;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fs_path = Io.Dir.path;
const FileKey = rules.FileKey;

pub const BrowserKind = enum { chromium, firefox };

/// record Browser(Name, Kind, Root, LocalRoot, Process).
/// root = Chromium "User Data" (or the profile itself, Opera) / Firefox folder holding profiles.ini.
/// local_root = where the cache lives when it is split from the roaming profile (Opera, Firefox).
pub const Browser = struct {
    name: []const u8,
    kind: BrowserKind,
    root: []const u8,
    local_root: ?[]const u8,
    /// Process name without ".exe".
    process: []const u8,

    /// Browser.Roots: root wildcards (Arc's package folder) expand like rules (rules.paths.expandDirs).
    pub fn roots(b: *const Browser, arena: Allocator, io: Io) ![]const []const u8 {
        return rules.paths.expandDirs(arena, io, b.root);
    }

    /// Browser.Profiles: chromiumProfiles or firefoxProfiles.
    pub fn profiles(b: *const Browser, arena: Allocator, io: Io) ![]const []const u8 {
        return switch (b.kind) {
            .firefox => firefoxProfiles(arena, io, b),
            .chromium => chromiumProfiles(arena, io, b),
        };
    }

    /// Browser.LocalOf: same profile on the local side, Root\X -> LocalRoot\X; null without a local_root.
    pub fn localOf(b: *const Browser, arena: Allocator, io: Io, profile: []const u8) !?[]const u8 {
        const local_root = b.local_root orelse return null;
        for (try b.roots(arena, io)) |root| {
            if (!common.startsWithIgnoreCase(profile, root)) continue;
            const locals = try rules.paths.expandDirs(arena, io, local_root);
            const local = if (locals.len > 0) locals[0] else try kit.win.expandEnv(arena, local_root);
            return try fs_path.join(arena, &.{ local, profile[root.len..] }); // Path.Join: "" -> local itself
        }
        return null;
    }

    /// Browser.Running: PIDs of running processes with this name (GetProcessesByName: ignore case, no ".exe").
    pub fn running(b: *const Browser, gpa: Allocator) ![]u32 {
        const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap == w.INVALID_HANDLE_VALUE) return error.Unexpected;
        defer _ = w.CloseHandle(snap);
        var out: std.ArrayList(u32) = .empty;
        errdefer out.deinit(gpa);
        var pe: PROCESSENTRY32W = undefined;
        pe.dwSize = @sizeOf(PROCESSENTRY32W);
        var ok = Process32FirstW(snap, &pe);
        while (ok != 0) : (ok = Process32NextW(snap, &pe)) {
            var buf: [pe.szExeFile.len * 3]u8 = undefined;
            const exe = buf[0..std.unicode.wtf16LeToWtf8(&buf, std.mem.sliceTo(&pe.szExeFile, 0))];
            const name = if (std.ascii.endsWithIgnoreCase(exe, ".exe")) exe[0 .. exe.len - 4] else exe;
            if (common.eqlIgnoreCase(name, b.process)) try out.append(gpa, pe.th32ProcessID);
        }
        return out.toOwnedSlice(gpa);
    }
};

/// Func<bool, int> of a BrowserItem: apply=false counts rows/values that would go, apply=true removes them.
pub const Action = struct {
    ctx: *const anyopaque,
    func: *const fn (ctx: *const anyopaque, gpa: Allocator, io: Io, apply: bool) usize,
};

/// record BrowserItem(Browser, Id, Name, Default, Warning, Files, Action): one checkbox.
pub const BrowserItem = struct {
    /// Browser name ("Google Chrome").
    browser: []const u8,
    /// "cache", "history", "downloads", "lastdownload", "cookies", "session", "forms", "passwords", "compact".
    id: []const u8,
    name: []const u8,
    default: bool,
    warning: ?[]const u8 = null,
    /// Rule named "<browser>: <item>"; its FileKeys go through the engine.
    files: rules.Rule,
    action: ?Action = null,

    /// BrowserItem.Key: "<browser>: <name>" (the Settings key of the checkbox). Caller frees.
    pub fn key(item: *const BrowserItem, gpa: Allocator) ![]u8 {
        return gpa.print("{s}: {s}", .{ item.browser, item.name });
    }

    /// BrowserItem.Preview: rows/values that would go (0 without an action). Analyze opens databases read-only.
    pub fn preview(item: *const BrowserItem, gpa: Allocator, io: Io) usize {
        const a = item.action orelse return 0;
        return a.func(a.ctx, gpa, io, false);
    }

    /// BrowserItem.Run: rows/values removed.
    pub fn run(item: *const BrowserItem, gpa: Allocator, io: Io) usize {
        const a = item.action orelse return 0;
        return a.func(a.ctx, gpa, io, true);
    }
};

/// Browsers.Known: Chrome, Edge, Brave, Vivaldi, Opera, Opera GX, Arc, Firefox (paths with %vars%).
pub const known = [_]Browser{
    .{ .name = "Google Chrome", .kind = .chromium, .root = "%LocalAppData%\\Google\\Chrome\\User Data", .local_root = null, .process = "chrome" },
    .{ .name = "Microsoft Edge", .kind = .chromium, .root = "%LocalAppData%\\Microsoft\\Edge\\User Data", .local_root = null, .process = "msedge" },
    .{ .name = "Brave", .kind = .chromium, .root = "%LocalAppData%\\BraveSoftware\\Brave-Browser\\User Data", .local_root = null, .process = "brave" },
    .{ .name = "Vivaldi", .kind = .chromium, .root = "%LocalAppData%\\Vivaldi\\User Data", .local_root = null, .process = "vivaldi" },
    // ponytail: Opera and Opera GX share opera.exe, so "close Opera" closes both; split by exe path if it matters
    .{ .name = "Opera", .kind = .chromium, .root = "%AppData%\\Opera Software\\Opera Stable", .local_root = "%LocalAppData%\\Opera Software\\Opera Stable", .process = "opera" },
    .{ .name = "Opera GX", .kind = .chromium, .root = "%AppData%\\Opera Software\\Opera GX Stable", .local_root = "%LocalAppData%\\Opera Software\\Opera GX Stable", .process = "opera" },
    .{ .name = "Arc", .kind = .chromium, .root = "%LocalAppData%\\Packages\\TheBrowserCompany.Arc_*\\LocalCache\\Local\\Arc\\User Data", .local_root = null, .process = "Arc" },
    .{ .name = "Mozilla Firefox", .kind = .firefox, .root = "%AppData%\\Mozilla\\Firefox", .local_root = "%LocalAppData%\\Mozilla\\Firefox", .process = "firefox" },
};

/// Browsers.ReplacedWinapp2Sections: Winapp2 sections this tab replaces (no double entries); other browsers
/// stay with Winapp2. Compare case-insensitively.
pub const replaced_winapp2_sections = [_][]const u8{
    "Google Chrome Web Browser", "Microsoft Edge Web Browser", "Brave Web Browser", "Vivaldi Web Browser",
    "Opera Web Browser",         "Opera GX Web Browser",       "Arc Web Browser",   "Mozilla Firefox Web Browser",
};

/// ReplacedWinapp2Sections.Contains(section) (OrdinalIgnoreCase).
pub fn isReplacedSection(section: []const u8) bool {
    for (replaced_winapp2_sections) |s| if (common.eqlIgnoreCase(s, section)) return true;
    return false;
}

/// Browsers.CloseGracefully: Process.CloseMainWindow for each process (WM_CLOSE to its main window, like
/// clicking X) and waits; never kills. False if something is still running after `timeout_ms` (C# default 10000).
pub fn closeGracefully(pids: []const u32, timeout_ms: u32) bool {
    for (pids) |pid| if (mainWindow(pid)) |h| {
        // CloseMainWindow posts nothing to a disabled window (a modal dialog is up)
        if (w.IsWindowEnabled(h) != 0) _ = w.PostMessageW(h, w.WM_CLOSE, 0, 0);
    };
    const deadline = w.GetTickCount64() + timeout_ms;
    for (pids) |pid| {
        const h = w.OpenProcess(w.SYNCHRONIZE, 0, pid) orelse {
            if (w.GetLastError() == w.ERROR_INVALID_PARAMETER) continue; // already gone
            return false; // can't wait on it (access denied): don't claim it closed
        };
        defer _ = w.CloseHandle(h);
        if (w.WaitForSingleObject(h, @intCast(deadline -| w.GetTickCount64())) != w.WAIT_OBJECT_0) return false;
    }
    return true;
}

/// Process.MainWindowHandle: the first visible, unowned top-level window of `pid` (null if none). Only this one
/// gets WM_CLOSE, so a browser with several windows is closed exactly like the C# original did it.
pub fn mainWindow(pid: u32) ?w.HWND {
    var find: FindMain = .{ .pid = pid };
    _ = w.EnumWindows(findMain, @bitCast(@intFromPtr(&find)));
    return find.hwnd;
}

const FindMain = struct { pid: u32, hwnd: ?w.HWND = null };

fn findMain(hwnd: w.HWND, lp: w.LPARAM) callconv(.c) w.BOOL {
    const find: *FindMain = @ptrFromInt(@as(usize, @bitCast(lp)));
    var pid: w.DWORD = 0;
    _ = w.GetWindowThreadProcessId(hwnd, &pid);
    if (pid != find.pid or w.IsWindowVisible(hwnd) == 0 or w.GetWindow(hwnd, w.GW_OWNER) != null) return 1;
    find.hwnd = hwnd;
    return 0; // stop: the first one is the main window
}

/// Browsers.Detect: items of every browser (default: `known`) that has at least one profile.
pub fn detect(arena: Allocator, io: Io, browsers: ?[]const Browser) ![]BrowserItem {
    var out: std.ArrayList(BrowserItem) = .empty;
    for (browsers orelse &known) |*b| {
        if ((try b.profiles(arena, io)).len > 0) try out.appendSlice(arena, try items(arena, io, b));
    }
    return out.items;
}

/// Browsers.ChromiumProfiles: Default, Profile N, Guest Profile (with a Preferences file); Opera keeps the
/// profile in the root itself.
pub fn chromiumProfiles(arena: Allocator, io: Io, b: *const Browser) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try b.roots(arena, io)) |root| {
        if (isFile(io, try fs_path.join(arena, &.{ root, "Preferences" }))) try out.append(arena, root);
        var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue; // SafeDirs
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .directory and e.kind != .sym_link) continue; // GetDirectories lists junctions too
            const n = e.name;
            if (!(std.mem.eql(u8, n, "Default") or std.mem.startsWith(u8, n, "Profile ") or std.mem.eql(u8, n, "Guest Profile"))) continue;
            const d = try fs_path.join(arena, &.{ root, n });
            if (isFile(io, try fs_path.join(arena, &.{ d, "Preferences" }))) try out.append(arena, d);
        }
    }
    return out.items;
}

/// Browsers.FirefoxProfiles: every [Profile*] in profiles.ini; IsRelative=1 paths are under the root.
pub fn firefoxProfiles(arena: Allocator, io: Io, b: *const Browser) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try b.roots(arena, io)) |root| {
        const ini = try fs_path.join(arena, &.{ root, "profiles.ini" });
        const text = Io.Dir.cwd().readFileAlloc(io, ini, arena, .limited(max_text)) catch continue;
        var lines = std.mem.tokenizeAny(u8, withoutBom(text), "\r\n"); // ReadAllLines: CRLF, LF or a lone CR
        var prof: ?[]const u8 = null;
        var relative = true;
        var in_profile = false;
        var done = false;
        while (!done) {
            const line = if (lines.next()) |l| std.mem.trim(u8, l, &std.ascii.whitespace) else blk: {
                done = true;
                break :blk "[end]"; // flushes the last section
            };
            if (std.mem.startsWith(u8, line, "[")) {
                if (in_profile and prof != null) {
                    const full = if (relative) blk: {
                        const rel = try arena.dupe(u8, prof.?);
                        std.mem.replaceScalar(u8, rel, '/', '\\');
                        break :blk try fs_path.resolveAlloc(arena, &.{try fs_path.join(arena, &.{ root, rel })}); // GetFullPath(Join)
                    } else prof.?;
                    if (isDir(io, full)) try out.append(arena, full);
                }
                in_profile = common.startsWithIgnoreCase(line, "[Profile");
                prof = null;
                relative = true;
                continue;
            }
            const eq = std.mem.findScalar(u8, line, '=') orelse continue;
            if (!in_profile) continue;
            const k = std.mem.trim(u8, line[0..eq], &std.ascii.whitespace);
            const v = std.mem.trim(u8, line[eq + 1 ..], &std.ascii.whitespace);
            if (std.ascii.eqlIgnoreCase(k, "Path")) prof = v else if (std.ascii.eqlIgnoreCase(k, "IsRelative")) relative = !std.mem.eql(u8, v, "0");
        }
    }
    return out.items;
}

const lose_logins = "This deletes saved passwords. You will have to sign in again on every site.";
const lose_forms = "This deletes saved form entries and autofill addresses.";
const lose_session = "This deletes open tabs and the last session; it cannot be restored.";

/// Browsers.Items: the 9 checkboxes of one browser. Everything (incl. a copy of `b`) lives in `arena`.
pub fn items(arena: Allocator, io: Io, b: *const Browser) ![]BrowserItem {
    const bc = try arena.create(Browser);
    bc.* = .{
        .name = try arena.dupe(u8, b.name),
        .kind = b.kind,
        .root = try arena.dupe(u8, b.root),
        .local_root = if (b.local_root) |l| try arena.dupe(u8, l) else null,
        .process = try arena.dupe(u8, b.process),
    };
    const profs = try bc.profiles(arena, io);
    var locals: std.ArrayList([]const u8) = .empty; // Distinct(OrdinalIgnoreCase)
    for (profs) |p| {
        const l = (try bc.localOf(arena, io, p)) orelse p;
        for (locals.items) |x| {
            if (common.eqlIgnoreCase(x, l)) break;
        } else try locals.append(arena, l);
    }
    const s: Builder = .{ .arena = arena, .b = bc, .profiles = profs };
    return switch (bc.kind) {
        .chromium => s.chromium(locals.items),
        .firefox => s.firefox(locals.items),
    };
}

const Builder = struct {
    arena: Allocator,
    b: *const Browser,
    profiles: []const []const u8,

    fn chromium(s: Builder, locals: []const []const u8) ![]BrowserItem {
        const cache_dirs: []const []const u8 = &.{ "Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "Service Worker\\CacheStorage", "Service Worker\\ScriptCache" };
        return s.arena.dupe(BrowserItem, &.{
            try s.item("cache", "Internet Cache", true, null, try s.dirs(locals, cache_dirs), null),
            try s.item("history", "Internet History", true, null, try s.names(&.{
                "History",   "History-journal",   "Visited Links",            "Top Sites",                        "Top Sites-journal",
                "Shortcuts", "Shortcuts-journal", "Network Action Predictor", "Network Action Predictor-journal",
            }), null),
            try s.item("downloads", "Download History", true, null, &.{}, .{ .kind = .tables, .file = "History", .names = &.{ "downloads", "downloads_url_chains", "downloads_slices" } }),
            try s.item("lastdownload", "Last Download Location", true, null, &.{}, .{ .kind = .json, .file = "Preferences", .names = &.{ "savefile", "default_directory" } }),
            try s.item("cookies", "Cookies", true, null, &.{}, .{ .kind = .cookies }),
            try s.item("session", "Session", false, lose_session, try std.mem.concat(s.arena, FileKey, &.{
                try s.dirs(s.profiles, &.{"Sessions"}),
                try s.names(&.{ "Current Session", "Current Tabs", "Last Session", "Last Tabs" }),
            }), null),
            try s.item("forms", "Saved Form Information", false, lose_forms, &.{}, .{ .kind = .tables, .file = "Web Data", .names = &.{
                "autofill",                "autofill_profiles",          "autofill_profile_names", "autofill_profile_emails",
                "autofill_profile_phones", "autofill_profile_addresses", "local_addresses",        "local_addresses_type_tokens",
            } }),
            try s.item("passwords", "Saved Passwords", false, lose_logins, try s.names(&.{ "Login Data", "Login Data-journal", "Login Data For Account", "Login Data For Account-journal" }), null),
            try s.item("compact", "Compact Databases", false, null, &.{}, .{ .kind = .vacuum, .names = &.{ "History", "Web Data", "Favicons", "Top Sites", "Shortcuts", "Login Data" } }),
        });
    }

    fn firefox(s: Builder, locals: []const []const u8) ![]BrowserItem {
        // places.sqlite also holds bookmarks, so history and downloads are rows, never the file.
        const history =
            \\DELETE FROM moz_historyvisits;
            \\DELETE FROM moz_inputhistory;
            \\DELETE FROM moz_places WHERE id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL);
        ;
        const downloads = "FROM moz_annos WHERE anno_attribute_id IN (SELECT id FROM moz_anno_attributes WHERE name LIKE 'downloads/%')";
        return s.arena.dupe(BrowserItem, &.{
            try s.item("cache", "Internet Cache", true, null, try s.dirs(locals, &.{ "cache2", "startupCache", "thumbnails", "jumpListCache" }), null),
            try s.item("history", "Internet History", true, null, &.{}, .{ .kind = .sql, .file = "places.sqlite", .count = "SELECT COUNT(*) FROM moz_historyvisits", .delete = history }),
            try s.item("downloads", "Download History", true, null, &.{}, .{ .kind = .sql, .file = "places.sqlite", .count = "SELECT COUNT(*) " ++ downloads, .delete = "DELETE " ++ downloads ++ ";" }),
            try s.item("lastdownload", "Last Download Location", true, null, &.{}, .{ .kind = .prefs, .file = "prefs.js", .names = &.{"browser.download.lastDir"} }),
            try s.item("cookies", "Cookies", true, null, &.{}, .{ .kind = .cookies }),
            try s.item("session", "Session", false, lose_session, try std.mem.concat(s.arena, FileKey, &.{
                try s.names(&.{ "sessionstore.jsonlz4", "sessionstore.js" }),
                try s.dirs(s.profiles, &.{"sessionstore-backups"}),
            }), null),
            try s.item("forms", "Saved Form Information", false, lose_forms, try s.names(&.{ "formhistory.sqlite", "formhistory.sqlite-wal", "formhistory.sqlite-shm", "formhistory.sqlite-journal" }), null),
            try s.item("passwords", "Saved Passwords", false, lose_logins, try s.names(&.{ "logins.json", "logins-backup.json" }), null),
            try s.item("compact", "Compact Databases", false, null, &.{}, .{ .kind = .vacuum }), // every *.sqlite
        });
    }

    fn item(s: Builder, id: []const u8, name: []const u8, default: bool, warning: ?[]const u8, keys: []const FileKey, job: ?Job) !BrowserItem {
        var action: ?Action = null;
        if (job) |j| {
            const p = try s.arena.create(Job);
            p.* = j;
            p.b = s.b;
            p.profiles = s.profiles;
            action = .{ .ctx = p, .func = Job.run };
        }
        const rule: rules.Rule = .{ .name = try s.arena.print("{s}: {s}", .{ s.b.name, name }), .file_keys = .fromOwnedSlice(try s.arena.dupe(FileKey, keys)) };
        return .{ .browser = s.b.name, .id = id, .name = name, .default = default, .warning = warning, .files = rule, .action = action };
    }

    /// Names(p, names...) for every profile.
    fn names(s: Builder, list: []const []const u8) ![]FileKey {
        const out = try s.arena.alloc(FileKey, s.profiles.len);
        for (out, s.profiles) |*k, p| k.* = .{ .path = p, .patterns = list, .recurse = false };
        return out;
    }

    /// Dir(base\sub): everything under it, for every base x sub.
    fn dirs(s: Builder, bases: []const []const u8, subs: []const []const u8) ![]FileKey {
        var out: std.ArrayList(FileKey) = .empty;
        for (bases) |base| for (subs) |sub|
            try out.append(s.arena, .{ .path = try fs_path.join(s.arena, &.{ base, sub }), .patterns = &.{"*"}, .recurse = true });
        return out.items;
    }
};

/// The Func<bool, int> of an item, per profile of `b` (the cookies item rediscovers its databases each call).
const Job = struct {
    kind: enum { tables, sql, json, prefs, cookies, vacuum },
    /// Per-profile file: database (tables, sql), Preferences (json), prefs.js (prefs).
    file: []const u8 = "",
    /// tables: tables to empty; json: parent, key; prefs: pref name; vacuum: files (empty = every *.sqlite).
    names: []const []const u8 = &.{},
    count: [:0]const u8 = "",
    delete: [:0]const u8 = "",
    b: *const Browser = undefined,
    profiles: []const []const u8 = &.{},

    fn run(ctx: *const anyopaque, gpa: Allocator, io: Io, apply: bool) usize {
        const j: *const Job = @ptrCast(@alignCast(ctx));
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        return j.perform(arena.allocator(), io, apply) catch 0; // only OOM gets here
    }

    fn perform(j: *const Job, a: Allocator, io: Io, apply: bool) !usize {
        var total: usize = 0;
        switch (j.kind) {
            // Rows, not the file: domains on the keep-list (Options > Cookies) survive.
            .cookies => {
                const keep = try cookies.keep(a);
                for (try cookieDbs(a, io, j.b)) |d| total += dropCookies(a, d, keep, apply);
            },
            .vacuum => for (j.profiles) |p| {
                for (try j.vacuumFiles(a, io, p)) |f| {
                    if (!isSqlite(io, f)) continue;
                    total += 1;
                    if (!apply) continue;
                    const db = open(a, f, true) orelse continue;
                    defer _ = c.sqlite3_close_v2(db);
                    exec(db, "VACUUM") catch {};
                }
            },
            .json => for (j.profiles) |p| {
                total += @intFromBool(jsonRemove(a, io, try fs_path.join(a, &.{ p, j.file }), apply, j.names[0], j.names[1]));
            },
            .prefs => for (j.profiles) |p| {
                total += @intFromBool(prefsRemove(a, io, try fs_path.join(a, &.{ p, j.file }), apply, j.names[0]));
            },
            // apply=false counts rows; apply=true deletes them. Missing files/tables are skipped.
            .tables, .sql => for (j.profiles) |p| {
                const f = try fs_path.join(a, &.{ p, j.file });
                if (!isFile(io, f)) continue;
                const db = open(a, f, apply) orelse continue;
                defer _ = c.sqlite3_close_v2(db);
                total += if (j.kind == .tables) tx(db, apply, emptyTables, .{ db, j.names, apply }) else tx(db, apply, countDelete, .{ db, j.count, j.delete, apply });
            },
        }
        return total;
    }

    fn vacuumFiles(j: *const Job, a: Allocator, io: Io, p: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        if (j.names.len > 0) {
            for (j.names) |n| try out.append(a, try fs_path.join(a, &.{ p, n }));
            return out.items;
        }
        var dir = Io.Dir.cwd().openDir(io, p, .{ .iterate = true }) catch return &.{}; // SafeFiles(p, "*.sqlite")
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind == .file and std.ascii.endsWithIgnoreCase(e.name, ".sqlite")) try out.append(a, try fs_path.join(a, &.{ p, e.name }));
        }
        return out.items;
    }
};

fn emptyTables(db: *c.sqlite3, tables: []const []const u8, apply: bool) !usize {
    var n: usize = 0;
    var buf: [256]u8 = undefined;
    for (tables) |t| {
        if (!try tableExists(db, t)) continue;
        n += try scalar(db, try std.mem.printSentinel(&buf, "SELECT COUNT(*) FROM \"{s}\"", .{t}, 0));
        if (apply) try exec(db, try std.mem.printSentinel(&buf, "DELETE FROM \"{s}\"", .{t}, 0));
    }
    return n;
}

fn countDelete(db: *c.sqlite3, count: [:0]const u8, delete: [:0]const u8, apply: bool) !usize {
    const n = try scalar(db, count);
    if (apply and n > 0) try exec(db, delete);
    return n;
}

fn dropCookies(a: Allocator, d: CookieDb, keep: []const []const u8, apply: bool) usize {
    const db = open(a, d.db, apply) orelse return 0;
    defer _ = c.sqlite3_close_v2(db);
    return tx(db, apply, dropCookiesIn, .{ db, d, keep, apply });
}

/// Count (and with `apply` delete) inside one transaction: an error halfway (busy db, a failing statement)
/// rolls everything back, so the reported 0 is true. Not in C#: there the Firefox history delete could drop the
/// visits, then fail on moz_places and report 0. Preview just runs `f` (read-only connection).
fn tx(db: *c.sqlite3, apply: bool, comptime f: anytype, args: anytype) usize {
    if (!apply) return @call(.auto, f, args) catch 0;
    exec(db, "BEGIN IMMEDIATE") catch return 0;
    const n = @call(.auto, f, args) catch {
        exec(db, "ROLLBACK") catch {};
        return 0;
    };
    exec(db, "COMMIT") catch {
        exec(db, "ROLLBACK") catch {};
        return 0;
    };
    return n;
}

fn dropCookiesIn(db: *c.sqlite3, d: CookieDb, keep: []const []const u8, apply: bool) !usize {
    if (!try tableExists(db, d.table)) return 0;
    var keep_ref = keep; // outlives every statement below (the connection closes in the caller)
    if (c.sqlite3_create_function_v2(db, "mc_drop", 1, c.SQLITE_UTF8, @ptrCast(&keep_ref), mcDrop, null, null, null) != c.SQLITE_OK) return error.Sqlite;
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    const where = try std.mem.print(&b1, "FROM \"{s}\" WHERE mc_drop(\"{s}\")", .{ d.table, d.column });
    const n = try scalar(db, try std.mem.printSentinel(&b2, "SELECT COUNT(*) {s}", .{where}, 0));
    if (apply and n > 0) try exec(db, try std.mem.printSentinel(&b2, "DELETE {s}", .{where}, 0));
    return n;
}

/// mc_drop(host): 1 = the cookie goes (its domain is not on the keep-list).
fn mcDrop(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    _ = argc;
    const keep: *const []const []const u8 = @ptrCast(@alignCast(c.sqlite3_user_data(ctx)));
    const v = argv[0];
    var host: ?[]const u8 = null;
    if (c.sqlite3_value_type(v) != c.SQLITE_NULL) {
        const p = c.sqlite3_value_text(v);
        if (p == null) return c.sqlite3_result_error_nomem(ctx); // never "not kept" just because memory ran out
        host = p[0..@intCast(c.sqlite3_value_bytes(v))];
    }
    c.sqlite3_result_int(ctx, @intFromBool(!cookies.isKept(host, keep.*)));
}

/// (Db, Table, Column) of one cookie store.
pub const CookieDb = struct { db: []const u8, table: []const u8, column: []const u8 };

/// Browsers.CookieDbs: Chromium moved Cookies into Network\ (older builds: profile root); Firefox
/// cookies.sqlite. Existing files only.
pub fn cookieDbs(arena: Allocator, io: Io, b: *const Browser) ![]CookieDb {
    var out: std.ArrayList(CookieDb) = .empty;
    for (try b.profiles(arena, io)) |p| {
        const cands: [2]CookieDb = switch (b.kind) {
            .firefox => .{ .{ .db = try fs_path.join(arena, &.{ p, "cookies.sqlite" }), .table = "moz_cookies", .column = "host" }, undefined },
            .chromium => .{
                .{ .db = try fs_path.join(arena, &.{ p, "Network", "Cookies" }), .table = "cookies", .column = "host_key" },
                .{ .db = try fs_path.join(arena, &.{ p, "Cookies" }), .table = "cookies", .column = "host_key" },
            },
        };
        for (cands[0..if (b.kind == .firefox) 1 else 2]) |d| if (isFile(io, d.db)) try out.append(arena, d);
    }
    return out.items;
}

/// Browsers.CookieDomains: every cookie domain on this PC (normalized, sorted, distinct) for Options > Cookies.
/// Read-only; a db the running browser keeps locked is read from a temp copy, skipped if even copying fails.
pub fn cookieDomains(arena: Allocator, io: Io, browsers: ?[]const Browser) ![]const []const u8 {
    var hosts: std.ArrayList([]const u8) = .empty;
    for (browsers orelse &known) |*b| {
        for (try cookieDbs(arena, io, b)) |d| {
            if (readHosts(arena, d.db, d, &hosts) != 0) continue;
            const tmp = copyForRead(arena, io, d.db) orelse continue;
            defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
            _ = readHosts(arena, try fs_path.join(arena, &.{ tmp, fs_path.basename(d.db) }), d, &hosts);
        }
    }
    std.mem.sort([]const u8, hosts.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    var n: usize = 0; // SortedSet: drop duplicates
    for (hosts.items) |h| {
        if (n > 0 and std.mem.eql(u8, hosts.items[n - 1], h)) continue;
        hosts.items[n] = h;
        n += 1;
    }
    return hosts.items[0..n];
}

/// 1 = read (the table may be empty), 0 = missing table / locked / not SQLite.
fn readHosts(a: Allocator, file: []const u8, d: CookieDb, hosts: *std.ArrayList([]const u8)) usize {
    const db = open(a, file, false) orelse return 0;
    defer _ = c.sqlite3_close_v2(db);
    return readHostsIn(a, db, d, hosts) catch 0;
}

fn readHostsIn(a: Allocator, db: *c.sqlite3, d: CookieDb, hosts: *std.ArrayList([]const u8)) !usize {
    if (!try tableExists(db, d.table)) return 0;
    var buf: [256]u8 = undefined;
    const st = try prepare(db, try std.mem.printSentinel(&buf, "SELECT DISTINCT \"{s}\" FROM \"{s}\"", .{ d.column, d.table }, 0));
    defer _ = c.sqlite3_finalize(st);
    while (true) {
        switch (c.sqlite3_step(st)) {
            c.SQLITE_ROW => {},
            c.SQLITE_DONE => return 1,
            else => return error.Sqlite,
        }
        if (c.sqlite3_column_type(st, 0) == c.SQLITE_NULL) continue;
        const p = c.sqlite3_column_text(st, 0);
        if (p == null) {
            if (c.sqlite3_errcode(db) == c.SQLITE_NOMEM) return error.OutOfMemory;
            continue; // zero-length BLOB host: nothing to list
        }
        const h = try cookies.normalize(a, p[0..@intCast(c.sqlite3_column_bytes(st, 0))]);
        if (h.len > 0) try hosts.append(a, h);
    }
}

/// %TEMP%\mc-cookies-<random> holding the db and its -wal (null, and nothing left behind, if copying fails).
fn copyForRead(a: Allocator, io: Io, db: []const u8) ?[]const u8 {
    const tmp = tempSubdir(a, io, "mc-cookies-") catch return null;
    copyInto(a, io, db, tmp) catch {
        Io.Dir.cwd().deleteTree(io, tmp) catch {};
        return null;
    };
    return tmp;
}

fn copyInto(a: Allocator, io: Io, db: []const u8, tmp: []const u8) !void {
    for ([_][]const u8{ db, try a.print("{s}-wal", .{db}) }) |f| {
        if (!isFile(io, f)) continue;
        // Dir.openFile opens with FILE_SHARE_READ|WRITE|DELETE (std Io/Threaded.zig dirOpenFileWtf16 passes
        // FILE.SHARE.VALID_FLAGS), like C# FileShare.ReadWrite|Delete: the running browser keeps writing.
        // A handle that refuses sharing ends in error.FileBusy (after std's ~4 s retry) -> the db is skipped.
        const cwd = Io.Dir.cwd();
        try cwd.copyFile(f, cwd, try fs_path.join(a, &.{ tmp, fs_path.basename(f) }), io, .{});
    }
}

/// Directory.CreateTempSubdirectory(prefix).
fn tempSubdir(a: Allocator, io: Io, prefix: []const u8) ![]const u8 {
    var buf: [w.MAX_PATH + 1]u16 = undefined;
    const n = w.GetTempPathW(buf.len, &buf);
    if (n == 0 or n > buf.len) return error.Unexpected;
    const tmp = try kit.win.fromW(a, buf[0..n]);
    var rnd: [6]u8 = undefined;
    io.random(&rnd);
    const dir = try a.print("{s}\\{s}{x}", .{ std.mem.trimEnd(u8, tmp, "\\"), prefix, &rnd });
    try Io.Dir.cwd().createDir(io, dir, .default_dir);
    return dir;
}

// ---------------------------------------------------------------- SQLite

/// WithDb: a locked database (browser running: 1 s busy timeout, not 30 s per db) or a non-SQLite file counts
/// as nothing instead of failing the whole clean. Analyze opens read-only, so previewing never changes a
/// browser file; never creates a missing file.
fn open(a: Allocator, file: []const u8, write: bool) ?*c.sqlite3 {
    const z = a.dupeSentinel(u8, file, 0) catch return null;
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(z.ptr, &db, if (write) c.SQLITE_OPEN_READWRITE else c.SQLITE_OPEN_READONLY, null) != c.SQLITE_OK) {
        _ = c.sqlite3_close_v2(db);
        return null;
    }
    _ = c.sqlite3_busy_timeout(db, 1000);
    return db;
}

fn prepare(db: *c.sqlite3, sql: [:0]const u8) !*c.sqlite3_stmt {
    var st: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != c.SQLITE_OK) {
        _ = c.sqlite3_finalize(st);
        return error.Sqlite;
    }
    return st orelse error.Sqlite; // empty statement
}

fn tableExists(db: *c.sqlite3, t: []const u8) !bool {
    const st = try prepare(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1");
    defer _ = c.sqlite3_finalize(st);
    if (c.sqlite3_bind_text(st, 1, t.ptr, @intCast(t.len), null) != c.SQLITE_OK) return error.Sqlite; // null = SQLITE_STATIC
    return switch (c.sqlite3_step(st)) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => error.Sqlite,
    };
}

fn scalar(db: *c.sqlite3, sql: [:0]const u8) !usize {
    const st = try prepare(db, sql);
    defer _ = c.sqlite3_finalize(st);
    if (c.sqlite3_step(st) != c.SQLITE_ROW) return error.Sqlite;
    return @intCast(@max(0, c.sqlite3_column_int64(st, 0)));
}

/// Every statement of `sql` (the Firefox history delete is three; tx makes them all-or-nothing).
fn exec(db: *c.sqlite3, sql: [:0]const u8) !void {
    if (c.sqlite3_exec(db, sql.ptr, null, null, null) != c.SQLITE_OK) return error.Sqlite;
}

fn isSqlite(io: Io, file: []const u8) bool {
    var head: [16]u8 = undefined;
    const got = Io.Dir.cwd().readFile(io, file, &head) catch return false;
    return std.mem.eql(u8, got, "SQLite format 3\x00");
}

// ---------------------------------------------------------------- Preferences / prefs.js

const max_text = 64 << 20;

fn withoutBom(s: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, s, "\xEF\xBB\xBF")) s[3..] else s;
}

/// JsonRemove: Chromium Preferences is JSON: drop one nested key, keep the rest untouched (numbers keep their
/// exact text, key order stays).
fn jsonRemove(a: Allocator, io: Io, file: []const u8, apply: bool, parent: []const u8, key: []const u8) bool {
    const text = Io.Dir.cwd().readFileAlloc(io, file, a, .limited(max_text)) catch return false;
    var root = std.json.parseFromSliceLeaky(std.json.Value, a, withoutBom(text), .{ .parse_numbers = false }) catch return false;
    if (root != .object) return false;
    const p = root.object.getPtr(parent) orelse return false;
    if (p.* != .object or !p.object.contains(key)) return false;
    if (!apply) return true;
    _ = p.object.orderedRemove(key);
    // ponytail: re-serialized compact like C# ToJsonString (not byte-identical to it either: System.Text.Json
    // escapes non-ASCII and <>&'+, std.json writes them as UTF-8); same JSON value, Chromium reads both.
    const out = std.json.Stringify.valueAlloc(a, root, .{}) catch return false;
    return replaceFile(io, file, out);
}

/// Temp file + rename (C# wrote in place): a crash, power loss or full disk mid-write never leaves a truncated
/// Preferences / prefs.js, which the browser would answer by silently resetting the profile's settings.
fn replaceFile(io: Io, file: []const u8, data: []const u8) bool {
    var atomic = Io.Dir.cwd().createFileAtomic(io, file, .{ .replace = true }) catch return false;
    defer atomic.deinit(io);
    atomic.file.writeStreamingAll(io, data) catch return false;
    atomic.replace(io) catch return false;
    return true;
}

/// PrefsRemove: Firefox prefs.js has one user_pref("name", ...) line per pref; drops that pref's lines.
/// Unlike C# (ReadAllLines/WriteAllLines -> CRLF) the other lines keep their exact bytes and line endings.
fn prefsRemove(a: Allocator, io: Io, file: []const u8, apply: bool, pref: []const u8) bool {
    const text = Io.Dir.cwd().readFileAlloc(io, file, a, .limited(max_text)) catch return false;
    const needle = a.print("user_pref(\"{s}\"", .{pref}) catch return false;
    const bom = text.len - withoutBom(text).len;
    var kept: std.ArrayList(u8) = .empty;
    kept.appendSlice(a, text[0..bom]) catch return false;
    var removed = false;
    var rest = text[bom..];
    while (rest.len > 0) {
        const end = if (std.mem.findScalar(u8, rest, '\n')) |i| i + 1 else rest.len;
        const line = rest[0..end];
        rest = rest[end..];
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, &std.ascii.whitespace), needle)) {
            removed = true;
        } else kept.appendSlice(a, line) catch return false;
    }
    if (!removed) return false;
    return !apply or replaceFile(io, file, kept.items);
}

// ---------------------------------------------------------------- files / processes

/// File.Exists: a file (not a folder).
fn isFile(io: Io, p: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .file;
}

fn isDir(io: Io, p: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .directory;
}

const TH32CS_SNAPPROCESS = 0x2;
const PROCESSENTRY32W = extern struct {
    dwSize: u32,
    cntUsage: u32,
    th32ProcessID: u32,
    th32DefaultHeapID: usize,
    th32ModuleID: u32,
    cntThreads: u32,
    th32ParentProcessID: u32,
    pcPriClassBase: i32,
    dwFlags: u32,
    szExeFile: [260]u16,
};
// tlhelp32.h is not in kit.w.
extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, pid: u32) callconv(.winapi) w.HANDLE;
extern "kernel32" fn Process32FirstW(snap: w.HANDLE, pe: *PROCESSENTRY32W) callconv(.winapi) c_int;
extern "kernel32" fn Process32NextW(snap: w.HANDLE, pe: *PROCESSENTRY32W) callconv(.winapi) c_int;
