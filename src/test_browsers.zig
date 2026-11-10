//! zig build test-browsers: Browsers tab (Chromium/Firefox, SQLite). Owner: MC-B.
//! Port of legacy BrowsersTests: fake browser profiles in a fresh %TEMP%\makecleaner-test-browsers-* folder;
//! the real browsers of this machine are never touched.
const std = @import("std");
const w = @import("kit").w;
const common = @import("core/common.zig");
const browsers = @import("core/browsers.zig");
const cookies = @import("core/cookies.zig");
const engine = @import("core/engine.zig");
const rules = @import("core/rules.zig");
const Settings = @import("core/settings.zig").Settings;
const c = browsers.c;

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Browser = browsers.Browser;
const BrowserItem = browsers.BrowserItem;

test {
    _ = @import("core/browsers.zig");
    common.refAll(browsers);
}

/// One test's sandbox: temp folder + arena for everything the browsers module returns.
const Fx = struct {
    gpa: Allocator,
    io: Io,
    tmp: common.TempDir,
    arena_state: std.heap.ArenaAllocator,

    fn init() !Fx {
        return .{ .gpa = testing.allocator, .io = testing.io, .tmp = try .create(testing.allocator, testing.io, "browsers"), .arena_state = .init(testing.allocator) };
    }

    fn deinit(f: *Fx) void {
        f.arena_state.deinit();
        f.tmp.cleanup(f.gpa, f.io);
    }

    fn arena(f: *Fx) Allocator {
        return f.arena_state.allocator();
    }

    /// Absolute path of a formatted relative path inside the sandbox.
    fn at(f: *Fx, comptime fmt: []const u8, args: anytype) ![]const u8 {
        return Io.Dir.path.join(f.arena(), &.{ f.tmp.path, try f.arena().print(fmt, args) });
    }

    fn put(f: *Fx, file: []const u8, content: []const u8) !void {
        try Io.Dir.cwd().createDirPath(f.io, Io.Dir.path.dirname(file).?);
        try Io.Dir.cwd().writeFile(f.io, .{ .sub_path = file, .data = content });
    }

    fn read(f: *Fx, file: []const u8) ![]const u8 {
        return Io.Dir.cwd().readFileAlloc(f.io, file, f.arena(), .limited(1 << 20));
    }

    fn db(f: *Fx, file: []const u8, sql: [:0]const u8) !void {
        try Io.Dir.cwd().createDirPath(f.io, Io.Dir.path.dirname(file).?);
        const h = try f.open(file);
        defer _ = c.sqlite3_close_v2(h);
        try exec(h, sql);
    }

    fn open(f: *Fx, file: []const u8) !*c.sqlite3 {
        var h: ?*c.sqlite3 = null;
        const z = try f.arena().dupeSentinel(u8, file, 0);
        if (c.sqlite3_open_v2(z.ptr, &h, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null) != c.SQLITE_OK) {
            _ = c.sqlite3_close_v2(h);
            return error.Sqlite;
        }
        return h.?;
    }

    fn count(f: *Fx, file: []const u8, table: []const u8) !i64 {
        const h = try f.open(file);
        defer _ = c.sqlite3_close_v2(h);
        const rows = try column(f.arena(), h, try f.arena().printSentinel("SELECT COUNT(*) FROM {s}", .{table}, 0));
        return std.fmt.parseInt(i64, rows[0], 10);
    }

    /// Engine.Analyze(item.Files): the files the item's rule would delete, sorted.
    fn found(f: *Fx, it: *const BrowserItem) ![]const []const u8 {
        const files = try engine.analyze(f.arena(), f.io, &it.files, &.{}, null);
        const out = try f.arena().alloc([]const u8, files.len);
        for (out, files) |*o, x| o.* = x.path;
        std.mem.sort([]const u8, out, {}, lessThan);
        return out;
    }

    fn profileNames(f: *Fx, b: *const Browser) ![]const []const u8 {
        const ps = try b.profiles(f.arena(), f.io);
        const out = try f.arena().alloc([]const u8, ps.len);
        for (out, ps) |*o, p| o.* = Io.Dir.path.basename(p);
        std.mem.sort([]const u8, out, {}, lessThan);
        return out;
    }

    // example.com x2, a subdomain of google.com, a look-alike and a tracker
    const chrome_cookies =
        \\CREATE TABLE cookies(host_key TEXT, name TEXT);
        \\INSERT INTO cookies VALUES('.example.com','a'),('www.example.com','b'),('mail.google.com','c'),('.badexample.com','d'),('tracker.net','e');
    ;

    fn chromium(f: *Fx) !Browser {
        for ([_][]const u8{ "Default", "Profile 1" }) |p| {
            try f.put(try f.at("Chrome\\User Data\\{s}\\Preferences", .{p}),
                \\{"savefile":{"default_directory":"C:\\Old","type":1},"homepage":"x"}
            );
            try f.put(try f.at("Chrome\\User Data\\{s}\\Cache\\Cache_Data\\data_0", .{p}), "x");
            try f.put(try f.at("Chrome\\User Data\\{s}\\Code Cache\\js\\abc", .{p}), "x");
            try f.db(try f.at("Chrome\\User Data\\{s}\\Network\\Cookies", .{p}), chrome_cookies);
            try f.put(try f.at("Chrome\\User Data\\{s}\\Login Data", .{p}), "x");
            try f.put(try f.at("Chrome\\User Data\\{s}\\Bookmarks", .{p}), "{}");
            try f.db(try f.at("Chrome\\User Data\\{s}\\History", .{p}),
                \\CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT); INSERT INTO urls(url) VALUES('a'),('b');
                \\CREATE TABLE downloads(id INTEGER PRIMARY KEY); INSERT INTO downloads VALUES(1),(2),(3);
                \\CREATE TABLE downloads_url_chains(id INTEGER); INSERT INTO downloads_url_chains VALUES(1);
            );
            try f.db(try f.at("Chrome\\User Data\\{s}\\Web Data", .{p}),
                \\CREATE TABLE autofill(name TEXT); INSERT INTO autofill VALUES('email');
                \\CREATE TABLE keywords(id INTEGER); INSERT INTO keywords VALUES(1);
            );
        }
        try f.put(try f.at("Chrome\\User Data\\System Profile\\Cache\\x", .{}), "x"); // no Preferences -> not a profile
        return .{ .name = "Fake Chrome", .kind = .chromium, .root = try f.at("Chrome\\User Data", .{}), .local_root = null, .process = "mc-no-such-process" };
    }

    fn firefox(f: *Fx) !Browser {
        const roaming = try f.at("Roaming\\Firefox", .{});
        const abs = try f.at("ElsewhereProfile", .{});
        try f.put(try f.at("Roaming\\Firefox\\profiles.ini", .{}), try f.arena().print(
            \\[General]
            \\StartWithLastProfile=1
            \\
            \\[Profile0]
            \\Name=default-release
            \\IsRelative=1
            \\Path=Profiles/abc.default-release
            \\
            \\[Profile1]
            \\Name=other
            \\IsRelative=0
            \\Path={s}
            \\
            \\[Install123]
            \\Default=Profiles/abc.default-release
            \\
        , .{abs}));
        for ([_][]const u8{ try Io.Dir.path.join(f.arena(), &.{ roaming, "Profiles\\abc.default-release" }), abs }) |p| {
            try f.db(try Io.Dir.path.join(f.arena(), &.{ p, "places.sqlite" }),
                \\CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT); INSERT INTO moz_places VALUES(1,'bookmarked'),(2,'visited');
                \\CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, fk INTEGER); INSERT INTO moz_bookmarks VALUES(1,1),(2,NULL);
                \\CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY, place_id INTEGER); INSERT INTO moz_historyvisits VALUES(1,1),(2,2);
                \\CREATE TABLE moz_inputhistory(place_id INTEGER); INSERT INTO moz_inputhistory VALUES(2);
                \\CREATE TABLE moz_anno_attributes(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO moz_anno_attributes VALUES(1,'downloads/destinationFileURI'),(2,'other');
                \\CREATE TABLE moz_annos(id INTEGER PRIMARY KEY, anno_attribute_id INTEGER); INSERT INTO moz_annos VALUES(1,1),(2,2);
            );
            try f.db(try Io.Dir.path.join(f.arena(), &.{ p, "cookies.sqlite" }),
                \\CREATE TABLE moz_cookies(id INTEGER PRIMARY KEY, host TEXT); INSERT INTO moz_cookies(host) VALUES('.example.com'),('accounts.google.com'),('tracker.net');
            );
            try f.put(try Io.Dir.path.join(f.arena(), &.{ p, "logins.json" }), "{}");
            try f.put(try Io.Dir.path.join(f.arena(), &.{ p, "prefs.js" }), "user_pref(\"browser.download.lastDir\", \"C:\\\\Old\");\nuser_pref(\"browser.startup.page\", 3);\n");
            try f.put(try Io.Dir.path.join(f.arena(), &.{ p, "sessionstore-backups\\recovery.jsonlz4" }), "x");
        }
        try f.put(try f.at("Local\\Firefox\\Profiles\\abc.default-release\\cache2\\entries\\E1", .{}), "x");
        return .{ .name = "Fake Firefox", .kind = .firefox, .root = roaming, .local_root = try f.at("Local\\Firefox", .{}), .process = "mc-no-such-process" };
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn exec(h: *c.sqlite3, sql: [:0]const u8) !void {
    if (c.sqlite3_exec(h, sql.ptr, null, null, null) != c.SQLITE_OK) return error.Sqlite;
}

/// First column of every row, as text.
fn column(a: Allocator, h: *c.sqlite3, sql: [:0]const u8) ![]const []const u8 {
    var st: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(h, sql.ptr, -1, &st, null) != c.SQLITE_OK) return error.Sqlite;
    defer _ = c.sqlite3_finalize(st);
    var out: std.ArrayList([]const u8) = .empty;
    while (c.sqlite3_step(st) == c.SQLITE_ROW) {
        const p = c.sqlite3_column_text(st, 0);
        try out.append(a, try a.dupe(u8, p[0..@intCast(c.sqlite3_column_bytes(st, 0))]));
    }
    return out.items;
}

/// items.Single(i => i.Id == id).
fn item(list: []const BrowserItem, id: []const u8) !*const BrowserItem {
    var hit: ?*const BrowserItem = null;
    for (list) |*i| {
        if (!std.mem.eql(u8, i.id, id)) continue;
        if (hit != null) return error.NotSingle;
        hit = i;
    }
    return hit orelse error.NotFound;
}

fn expectStrings(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| try testing.expectEqualStrings(x, y);
}

test "Chromium_profiles_and_defaults" {
    var f = try Fx.init();
    defer f.deinit();
    const b = try f.chromium();
    try expectStrings(&.{ "Default", "Profile 1" }, try f.profileNames(&b));

    const items = try browsers.items(f.arena(), f.io, &b);
    for ([_][]const u8{ "cache", "history", "downloads", "lastdownload", "cookies" }) |id| try testing.expect((try item(items, id)).default);
    for ([_][]const u8{ "session", "forms", "passwords" }) |id| {
        try testing.expect(!(try item(items, id)).default);
        try testing.expect((try item(items, id)).warning != null);
    }
    for (items) |*i| {
        const k = try i.key(f.gpa);
        defer f.gpa.free(k);
        try testing.expect(std.mem.startsWith(u8, k, "Fake Chrome: "));
    }
}

test "Chromium_cache_is_files_of_every_profile" {
    var f = try Fx.init();
    defer f.deinit();
    const items = try browsers.items(f.arena(), f.io, &try f.chromium());
    const cache = try f.found(try item(items, "cache"));
    try testing.expectEqual(4, cache.len);
    for (cache) |p| try testing.expect(std.mem.find(u8, p, "System Profile") == null);

    const files = try engine.analyze(f.arena(), f.io, &(try item(items, "cache")).files, &.{}, null);
    try testing.expectEqual(4, engine.clean(f.gpa, f.io, files, 0).deleted);
    _ = try Io.Dir.cwd().statFile(f.io, try f.at("Chrome\\User Data\\Default\\Bookmarks", .{}), .{}); // nothing outside the item
}

test "Chromium_download_history_deletes_rows_not_the_history_file" {
    var f = try Fx.init();
    defer f.deinit();
    const items = try browsers.items(f.arena(), f.io, &try f.chromium());
    const downloads = try item(items, "downloads");
    try testing.expectEqual(0, downloads.files.file_keys.items.len);
    try testing.expectEqual(8, downloads.preview(f.gpa, f.io)); // (3 downloads + 1 chain) x 2 profiles
    try testing.expectEqual(8, downloads.run(f.gpa, f.io));
    const history = try f.at("Chrome\\User Data\\Default\\History", .{});
    try testing.expectEqual(0, try f.count(history, "downloads"));
    try testing.expectEqual(2, try f.count(history, "urls"));
    try testing.expectEqual(0, downloads.preview(f.gpa, f.io));
}

test "Chromium_forms_clear_autofill_but_keep_search_engines" {
    var f = try Fx.init();
    defer f.deinit();
    const forms = try item(try browsers.items(f.arena(), f.io, &try f.chromium()), "forms");
    try testing.expectEqual(2, forms.run(f.gpa, f.io));
    const web_data = try f.at("Chrome\\User Data\\Profile 1\\Web Data", .{});
    try testing.expectEqual(0, try f.count(web_data, "autofill"));
    try testing.expectEqual(1, try f.count(web_data, "keywords"));
}

test "Chromium_last_download_location_drops_only_that_key" {
    var f = try Fx.init();
    defer f.deinit();
    const last = try item(try browsers.items(f.arena(), f.io, &try f.chromium()), "lastdownload");
    try testing.expectEqual(2, last.preview(f.gpa, f.io));
    try testing.expectEqual(2, last.run(f.gpa, f.io));
    const prefs = try f.read(try f.at("Chrome\\User Data\\Default\\Preferences", .{}));
    try testing.expect(std.mem.find(u8, prefs, "default_directory") == null);
    try testing.expect(std.mem.find(u8, prefs, "homepage") != null);
    try testing.expect(std.mem.find(u8, prefs, "\"type\":1") != null);
    try testing.expectEqual(0, last.preview(f.gpa, f.io));
}

test "Opera_profile_in_root_with_cache_on_the_local_side" {
    var f = try Fx.init();
    defer f.deinit();
    try f.put(try f.at("Roaming\\Opera Stable\\Preferences", .{}), "{}");
    try f.db(try f.at("Roaming\\Opera Stable\\Network\\Cookies", .{}), Fx.chrome_cookies);
    try f.put(try f.at("Local\\Opera Stable\\Cache\\Cache_Data\\f_000001", .{}), "x");
    const b: Browser = .{ .name = "Fake Opera", .kind = .chromium, .root = try f.at("Roaming\\Opera Stable", .{}), .local_root = try f.at("Local\\Opera Stable", .{}), .process = "mc-no-such-process" };

    const items = try browsers.items(f.arena(), f.io, &b);
    try testing.expectEqual(1, (try b.profiles(f.arena(), f.io)).len);
    try expectStrings(&.{try f.at("Local\\Opera Stable\\Cache\\Cache_Data\\f_000001", .{})}, try f.found(try item(items, "cache")));
    try testing.expectEqual(5, (try item(items, "cookies")).preview(f.gpa, f.io));
}

test "Firefox_profiles_come_from_profiles_ini_relative_and_absolute" {
    var f = try Fx.init();
    defer f.deinit();
    const b = try f.firefox();
    try expectStrings(&.{ "ElsewhereProfile", "abc.default-release" }, try f.profileNames(&b));
    const items = try browsers.items(f.arena(), f.io, &b);
    try expectStrings(&.{try f.at("Local\\Firefox\\Profiles\\abc.default-release\\cache2\\entries\\E1", .{})}, try f.found(try item(items, "cache")));
    try testing.expectEqual(2, (try browsers.cookieDbs(f.arena(), f.io, &b)).len);
    try testing.expectEqual(2, (try f.found(try item(items, "session"))).len);
    try testing.expectEqual(2, (try f.found(try item(items, "passwords"))).len);
}

test "Firefox_history_keeps_bookmarks" {
    var f = try Fx.init();
    defer f.deinit();
    const items = try browsers.items(f.arena(), f.io, &try f.firefox());
    const history = try item(items, "history");
    try testing.expectEqual(4, history.preview(f.gpa, f.io)); // 2 visits x 2 profiles
    _ = history.run(f.gpa, f.io);
    const places = try f.at("Roaming\\Firefox\\Profiles\\abc.default-release\\places.sqlite", .{});
    try testing.expectEqual(0, try f.count(places, "moz_historyvisits"));
    try testing.expectEqual(0, try f.count(places, "moz_inputhistory"));
    try testing.expectEqual(1, try f.count(places, "moz_places")); // the bookmarked one stays
    try testing.expectEqual(2, try f.count(places, "moz_bookmarks"));

    const downloads = try item(items, "downloads");
    try testing.expectEqual(2, downloads.run(f.gpa, f.io));
    try testing.expectEqual(1, try f.count(places, "moz_annos"));
}

test "Firefox_last_download_location_removes_only_that_pref" {
    var f = try Fx.init();
    defer f.deinit();
    const last = try item(try browsers.items(f.arena(), f.io, &try f.firefox()), "lastdownload");
    try testing.expectEqual(2, last.run(f.gpa, f.io));
    const prefs = try f.read(try f.at("ElsewhereProfile\\prefs.js", .{}));
    try testing.expect(std.mem.find(u8, prefs, "lastDir") == null);
    try testing.expectEqualStrings("user_pref(\"browser.startup.page\", 3);\n", prefs); // the rest byte for byte
}

test "Cookies_are_rows_and_keep_list_domains_survive_in_chromium_and_firefox" {
    var f = try Fx.init();
    defer f.deinit();
    const chrome = try browsers.items(f.arena(), f.io, &try f.chromium());
    const firefox = try browsers.items(f.arena(), f.io, &try f.firefox());
    const chrome_db = try f.at("Chrome\\User Data\\Default\\Network\\Cookies", .{});
    const firefox_db = try f.at("ElsewhereProfile\\cookies.sqlite", .{});

    try testing.expectEqual(0, (try item(chrome, "cookies")).files.file_keys.items.len); // the database file itself is never deleted
    try testing.expectEqual(10, (try item(chrome, "cookies")).preview(f.gpa, f.io)); // empty keep-list: every cookie, 5 x 2 profiles

    var s: Settings = .{ .gpa = f.gpa, .path = try f.gpa.dupe(u8, "unused.ini") };
    defer s.deinit();
    try s.setList(cookies.keep_prefix, &.{ "www.example.com", "google.com" });
    cookies.keep_settings = &s;
    defer cookies.keep_settings = null;
    try testing.expectEqual(4, (try item(chrome, "cookies")).preview(f.gpa, f.io)); // badexample.com + tracker.net, x 2
    try testing.expectEqual(5, try f.count(chrome_db, "cookies")); // preview changed nothing
    try testing.expectEqual(4, (try item(chrome, "cookies")).run(f.gpa, f.io));
    try testing.expectEqual(2, (try item(firefox, "cookies")).run(f.gpa, f.io)); // tracker.net x 2 profiles

    const h = try f.open(chrome_db);
    defer _ = c.sqlite3_close_v2(h);
    try expectStrings(&.{ ".example.com", "mail.google.com", "www.example.com" }, try column(f.arena(), h, "SELECT host_key FROM cookies ORDER BY host_key"));
    try testing.expectEqual(2, try f.count(firefox_db, "moz_cookies"));
}

/// Directory.GetDirectories(Path.GetTempPath(), "mc-cookies-*").Length
fn tempCopies(f: *Fx) !usize {
    var dir = try Io.Dir.cwd().openDir(f.io, Io.Dir.path.dirname(f.tmp.path).?, .{ .iterate = true });
    defer dir.close(f.io);
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(f.io)) |e| {
        if (e.kind == .directory and std.mem.startsWith(u8, e.name, "mc-cookies-")) n += 1;
    }
    return n;
}

test "Cookie_domains_are_listed_normalized_even_from_a_locked_database" {
    var f = try Fx.init();
    defer f.deinit();
    const b = try f.chromium();
    const ff = try f.firefox();
    const db = try f.at("Chrome\\User Data\\Default\\Network\\Cookies", .{});
    const before = try tempCopies(&f);
    {
        // what a running browser does: hold an exclusive lock so other connections cannot read
        const hold = try f.open(db);
        defer _ = c.sqlite3_close_v2(hold);
        try exec(hold, "PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE;");

        const t0: Io.Timestamp = .now(f.io, .awake);
        const domains = try browsers.cookieDomains(f.arena(), f.io, &.{ b, ff });
        try expectStrings(&.{ "accounts.google.com", "badexample.com", "example.com", "mail.google.com", "tracker.net" }, domains);
        const ms = t0.untilNow(f.io, .awake).toMilliseconds();
        try testing.expect(ms < 10000); // locked db: 1 s busy timeout, not 30 s
    }
    try testing.expectEqual(before, try tempCopies(&f)); // temp copies cleaned up
}

test "Compact_vacuums_databases" {
    var f = try Fx.init();
    defer f.deinit();
    const compact = try item(try browsers.items(f.arena(), f.io, &try f.firefox()), "compact");
    try testing.expectEqual(4, compact.preview(f.gpa, f.io)); // places.sqlite + cookies.sqlite, x 2 profiles
    _ = compact.run(f.gpa, f.io);
}

test "Missing_browser_shows_nothing_and_is_not_running" {
    var f = try Fx.init();
    defer f.deinit();
    const b: Browser = .{ .name = "Nope", .kind = .chromium, .root = try f.at("nothing", .{}), .local_root = null, .process = "mc-no-such-process" };
    try testing.expectEqual(0, (try browsers.detect(f.arena(), f.io, &.{b})).len);
    const pids = try b.running(f.gpa);
    defer f.gpa.free(pids);
    try testing.expectEqual(0, pids.len);
    try testing.expect(browsers.closeGracefully(&.{}, 10000));
    try testing.expect((try browsers.detect(f.arena(), f.io, &.{try f.chromium()})).len > 0);
}

/// AppContext.BaseDirectory\rules\Winapp2.ini: rules\ under the cwd (zig build from the repo root), else under
/// the nearest parent of the test exe that has one (<repo>\.zig-cache\o\<hash>\ -> <repo>), so a run from an IDE
/// or another directory finds it too.
fn bundledWinapp2(a: Allocator, io: Io) ![]const u8 {
    const rel = "rules\\Winapp2.ini";
    if (Io.Dir.cwd().readFileAlloc(io, rel, a, .limited(64 << 20))) |t| return t else |_| {}
    var dir: ?[]const u8 = try std.process.executableDirPathAlloc(io, a);
    while (dir) |d| : (dir = Io.Dir.path.dirname(d)) {
        if (Io.Dir.cwd().readFileAlloc(io, try Io.Dir.path.join(a, &.{ d, rel }), a, .limited(64 << 20))) |t| return t else |_| {}
    }
    return error.FileNotFound;
}

test "Replaced_winapp2_sections_exist_in_the_bundled_file" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try bundledWinapp2(arena, testing.io);
    const parsed = try rules.parseIni(arena, text);
    for (browsers.replaced_winapp2_sections) |want| {
        for (parsed) |r| {
            if (r.section) |s| if (common.eqlIgnoreCase(s, want)) break;
        } else {
            std.debug.print("missing section: {s}\n", .{want});
            return error.TestExpectedEqual;
        }
    }
}

// Not in the C# suite: the process side of Running/CloseGracefully, on a child this test starts (no window).
test "Running_matches_the_process_name_ignoring_case_and_CloseGracefully_reports_one_that_stays" {
    const io = testing.io;
    const gpa = testing.allocator;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "ping.exe", "-n", "30", "127.0.0.1" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    });
    defer child.kill(io);
    const pid = w.GetProcessId(child.id.?);
    const b: Browser = .{ .name = "Ping", .kind = .chromium, .root = "", .local_root = null, .process = "PING" };
    const pids = try b.running(gpa);
    defer gpa.free(pids);
    try testing.expect(std.mem.findScalar(u32, pids, pid) != null);
    try testing.expect(!browsers.closeGracefully(&.{pid}, 300)); // nothing to close: still running after the wait
}

// Not in the C# suite: the positive close path. A small PowerShell WinForms window on DISPLAY1
// stands in for a browser; WM_CLOSE to its main window ends the process.
test "CloseGracefully_closes_the_main_window_and_waits_for_the_exit" {
    const io = testing.io;
    // one line: -Command runs only the first line of a multi-line argument
    const script = "Add-Type -AssemblyName System.Windows.Forms; " ++
        "$s = [Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq '\\\\.\\DISPLAY1' } | Select-Object -First 1; " ++
        "if (-not $s) { $s = [Windows.Forms.Screen]::PrimaryScreen }; " ++
        // (ShowInTaskbar=$false would make the form owned by a hidden window: not a main window any more)
        "$f = New-Object Windows.Forms.Form; $f.Text = 'mc-close-test'; $f.StartPosition = 'Manual'; " ++
        "$f.Location = $s.WorkingArea.Location; $f.Size = New-Object Drawing.Size(240, 120); " ++
        "[Windows.Forms.Application]::Run($f)";
    var child = std.process.spawn(io, .{
        .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch return error.SkipZigTest; // no Windows PowerShell here
    defer child.kill(io); // only if the test failed: does nothing after wait
    const pid = w.GetProcessId(child.id.?);
    var waited: u32 = 0;
    while (browsers.mainWindow(pid) == null) : (waited += 1) {
        if (waited == 300) return error.NoWindowWithin30s;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
    try testing.expect(browsers.closeGracefully(&.{pid}, 10000));
    _ = try child.wait(io);
}

test "Preview_never_writes_and_a_missing_database_is_never_created" {
    var f = try Fx.init();
    defer f.deinit();
    const ff = try browsers.items(f.arena(), f.io, &try f.firefox());
    const files = [_][]const u8{ try f.at("ElsewhereProfile\\places.sqlite", .{}), try f.at("ElsewhereProfile\\cookies.sqlite", .{}), try f.at("ElsewhereProfile\\prefs.js", .{}) };
    var before: [files.len][]const u8 = undefined;
    for (&before, files) |*b, p| b.* = try f.read(p);
    for ([_][]const u8{ "history", "downloads", "cookies", "lastdownload", "compact" }) |id| try testing.expect((try item(ff, id)).preview(f.gpa, f.io) > 0);
    for (before, files) |b, p| try testing.expectEqualSlices(u8, b, try f.read(p));

    // a profile whose databases are gone: preview and run leave them gone
    const chrome = try f.chromium();
    const gone = [_][]const u8{ try f.at("Chrome\\User Data\\Profile 1\\History", .{}), try f.at("Chrome\\User Data\\Profile 1\\Web Data", .{}), try f.at("Chrome\\User Data\\Profile 1\\Network\\Cookies", .{}) };
    for (gone) |p| try Io.Dir.cwd().deleteFile(f.io, p);
    const items = try browsers.items(f.arena(), f.io, &chrome);
    for ([_][]const u8{ "downloads", "forms", "cookies", "compact" }) |id| {
        _ = (try item(items, id)).preview(f.gpa, f.io);
        _ = (try item(items, id)).run(f.gpa, f.io);
    }
    for (gone) |p| try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(f.io, p, .{}));
}

test "Locked_database_counts_as_zero_for_preview_and_run" {
    var f = try Fx.init();
    defer f.deinit();
    const downloads = try item(try browsers.items(f.arena(), f.io, &try f.chromium()), "downloads");
    const history = try f.at("Chrome\\User Data\\Default\\History", .{});
    {
        const hold = try f.open(history); // the running browser
        defer _ = c.sqlite3_close_v2(hold);
        try exec(hold, "PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE;");
        try testing.expectEqual(4, downloads.preview(f.gpa, f.io)); // Profile 1 only
        try testing.expectEqual(4, downloads.run(f.gpa, f.io));
    }
    try testing.expectEqual(3, try f.count(history, "downloads")); // untouched
    try testing.expectEqual(0, try f.count(try f.at("Chrome\\User Data\\Profile 1\\History", .{}), "downloads"));
}

test "Non_SQLite_History_counts_as_zero_and_is_not_compacted" {
    var f = try Fx.init();
    defer f.deinit();
    const chrome = try f.chromium();
    const history = try f.at("Chrome\\User Data\\Default\\History", .{});
    try f.put(history, "not a database, just text that is long enough");
    const items = try browsers.items(f.arena(), f.io, &chrome);
    try testing.expectEqual(4, (try item(items, "downloads")).preview(f.gpa, f.io));
    try testing.expectEqual(4, (try item(items, "downloads")).run(f.gpa, f.io));
    // Default: Web Data; Profile 1: History + Web Data (Login Data is "x", not SQLite either)
    try testing.expectEqual(3, (try item(items, "compact")).preview(f.gpa, f.io));
    _ = (try item(items, "compact")).run(f.gpa, f.io);
    try testing.expectEqualStrings("not a database, just text that is long enough", try f.read(history));
}

test "Firefox_history_delete_is_all_or_nothing" {
    var f = try Fx.init();
    defer f.deinit();
    const history = try item(try browsers.items(f.arena(), f.io, &try f.firefox()), "history");
    const places = try f.at("ElsewhereProfile\\places.sqlite", .{});
    try f.db(places, "DROP TABLE moz_bookmarks;"); // the third DELETE fails here
    try testing.expectEqual(4, history.preview(f.gpa, f.io));
    try testing.expectEqual(2, history.run(f.gpa, f.io)); // the other profile only
    try testing.expectEqual(2, try f.count(places, "moz_historyvisits")); // rolled back, not half-deleted
    try testing.expectEqual(1, try f.count(places, "moz_inputhistory"));
    try testing.expectEqual(0, try f.count(try f.at("Roaming\\Firefox\\Profiles\\abc.default-release\\places.sqlite", .{}), "moz_historyvisits"));
}

test "Chromium_last_download_location_keeps_every_other_value_and_leaves_no_temp_file" {
    var f = try Fx.init();
    defer f.deinit();
    const chrome = try f.chromium();
    const prefs = try f.at("Chrome\\User Data\\Default\\Preferences", .{});
    try f.put(prefs, "\xEF\xBB\xBF{\"savefile\":{\"default_directory\":\"C:\\\\Old\",\"type\":1},\"big\":12345678901234567890,\"f\":1.50," ++
        "\"u\":\"\u{0407}<&\",\"e\":\"\\u00e9\",\"a\":[1,{\"b\":null}],\"t\":true}");
    const profile = try f.at("Chrome\\User Data\\Default", .{});
    const n0 = try entries(&f, profile);
    try testing.expectEqual(2, (try item(try browsers.items(f.arena(), f.io, &chrome), "lastdownload")).run(f.gpa, f.io));
    try testing.expectEqualStrings("{\"savefile\":{\"type\":1},\"big\":12345678901234567890,\"f\":1.50," ++
        "\"u\":\"\u{0407}<&\",\"e\":\"\u{e9}\",\"a\":[1,{\"b\":null}],\"t\":true}", try f.read(prefs));
    try testing.expectEqual(n0, try entries(&f, profile)); // temp file renamed over Preferences, nothing left
}

fn entries(f: *Fx, path: []const u8) !usize {
    var dir = try Io.Dir.cwd().openDir(f.io, path, .{ .iterate = true });
    defer dir.close(f.io);
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(f.io)) |_| n += 1;
    return n;
}

test "Chromium_profile_behind_a_junction_counts" {
    var f = try Fx.init();
    defer f.deinit();
    const b = try f.chromium();
    const target = try f.at("Elsewhere\\Profile 2", .{});
    try f.put(try f.at("Elsewhere\\Profile 2\\Preferences", .{}), "{}");
    const link = try f.at("Chrome\\User Data\\Profile 2", .{});
    const r = try std.process.run(f.gpa, f.io, .{ .argv = &.{ "cmd.exe", "/c", "mklink", "/J", link, target } });
    f.gpa.free(r.stdout);
    f.gpa.free(r.stderr);
    if (!r.term.success()) return error.SkipZigTest; // junctions unavailable here (FAT, policy)
    defer Io.Dir.cwd().deleteDir(f.io, link) catch {}; // the link only, before the fixture goes
    try expectStrings(&.{ "Default", "Profile 1", "Profile 2" }, try f.profileNames(&b));
}

test "Arc_root_wildcard_finds_the_package_folder" {
    var f = try Fx.init();
    defer f.deinit();
    try f.put(try f.at("Packages\\TheBrowserCompany.Arc_ttt1ap7aakyb4\\LocalCache\\Local\\Arc\\User Data\\Default\\Preferences", .{}), "{}");
    try f.put(try f.at("Packages\\Other.App_x\\LocalCache\\Local\\Arc\\User Data\\Default\\Preferences", .{}), "{}");
    const b: Browser = .{ .name = "Fake Arc", .kind = .chromium, .root = try f.at("Packages\\TheBrowserCompany.Arc_*\\LocalCache\\Local\\Arc\\User Data", .{}), .local_root = null, .process = "mc-no-such-process" };
    const ps = try b.profiles(f.arena(), f.io);
    try expectStrings(&.{try f.at("Packages\\TheBrowserCompany.Arc_ttt1ap7aakyb4\\LocalCache\\Local\\Arc\\User Data\\Default", .{})}, ps);
}

test "Firefox_profiles_ini_with_BOM_CRLF_lone_CR_and_an_absolute_path_with_spaces" {
    var f = try Fx.init();
    defer f.deinit();
    const abs = try f.at("Else where\\Pro file", .{});
    try Io.Dir.cwd().createDirPath(f.io, abs);
    try Io.Dir.cwd().createDirPath(f.io, try f.at("FF\\Profiles\\x.y", .{}));
    try f.put(try f.at("FF\\profiles.ini", .{}), try f.arena().print(
        "\xEF\xBB\xBF[Profile0]\r\nIsRelative=0\r\nPath = {s} \r\n\r\n[Profile1]\rPath=Profiles/x.y\rIsRelative=1\r",
        .{abs},
    ));
    const b: Browser = .{ .name = "Fake FF", .kind = .firefox, .root = try f.at("FF", .{}), .local_root = null, .process = "mc-no-such-process" };
    try expectStrings(&.{ abs, try f.at("FF\\Profiles\\x.y", .{}) }, try b.profiles(f.arena(), f.io));
}

test "Cookie_domains_skip_a_database_held_without_any_sharing" {
    var f = try Fx.init();
    defer f.deinit();
    const b = try f.chromium();
    const db = try f.at("Chrome\\User Data\\Default\\Network\\Cookies", .{});
    try f.db(db, "INSERT INTO cookies VALUES('only-in-default.test','z');");
    const before = try tempCopies(&f);
    {
        const wpath = try @import("kit").win.toW(f.arena(), db);
        const h = w.CreateFileW(wpath.ptr, w.GENERIC_READ, 0, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
        try testing.expect(h != w.INVALID_HANDLE_VALUE);
        defer _ = w.CloseHandle(h);
        // neither SQLite nor the copy can open it: skipped, Profile 1 still lists its domains
        try expectStrings(&.{ "badexample.com", "example.com", "mail.google.com", "tracker.net" }, try browsers.cookieDomains(f.arena(), f.io, &.{b}));
    }
    try testing.expectEqual(before, try tempCopies(&f)); // the failed copy left nothing behind
    try expectStrings(&.{ "badexample.com", "example.com", "mail.google.com", "only-in-default.test", "tracker.net" }, try browsers.cookieDomains(f.arena(), f.io, &.{b}));
}

test "isReplacedSection ignores case" {
    try testing.expect(browsers.isReplacedSection("google chrome WEB BROWSER"));
    try testing.expect(!browsers.isReplacedSection("Google Chrome"));
}
