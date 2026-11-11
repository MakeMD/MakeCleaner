//! CleanPass.cs: one Analyze -> Clean pass over the ticked items, shared by the GUI and /auto so both clean
//! exactly the same way. Also the body of Schedule.Auto (`auto`), which schedule.zig delegates to.
const std = @import("std");
const kit = @import("kit");
const common = @import("common.zig");
const rules = @import("rules.zig");
const engine = @import("engine.zig");
const special = @import("special.zig");
const browsers = @import("browsers.zig");
const securedelete = @import("securedelete.zig");
const custom = @import("custom.zig");
const bytes = @import("bytes.zig");
const fs = @import("rules_fs.zig");
const Settings = @import("settings.zig").Settings;
/// Status lines come from tr(): the GUI's language; /auto never applies one, so its log stays English.
const T = @import("../i18n/tr.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const FileInfo = common.FileInfo;
const Rule = rules.Rule;

/// record ResultRow(Name, Items, Bytes): one row of the results Summary view.
pub const ResultRow = struct { name: []const u8, items: usize, bytes: u64 };

/// (BrowserItem Item, int Count). `item` is a copy in the pass arena.
pub const BrowserRow = struct { item: *const browsers.BrowserItem, count: usize };

/// CleanPass.Saved result: the ticks saved by the GUI.
pub const Saved = struct { rules: []Rule, browser: []browsers.BrowserItem };

/// CleanPass.IsWipe: the rule has SpecialKey WIPEFREESPACE.
pub fn isWipe(r: *const Rule) bool {
    return r.hasSpecial(special.wipe_free_space);
}

/// CleanPass.WindowsRules: what the Windows tab lists (detected engine.built_in_rules + "Custom Files and Folders"
/// in section "Advanced").
pub fn windowsRules(arena: Allocator, io: Io) ![]Rule {
    var out: std.ArrayList(Rule) = .fromOwnedSlice(try rules.detected(arena, io, try rules.parseIni(arena, engine.built_in_rules)));
    try out.append(arena, .{ .name = custom.rule_name, .section = "Advanced" });
    return out.toOwnedSlice(arena);
}

/// CleanPass.AppRules: rules.loadApplications(exe_dir) minus the Winapp2 sections the Browsers tab replaces.
/// (C# read AppContext.BaseDirectory; here the exe folder is passed in.)
pub fn appRules(arena: Allocator, io: Io, exe_dir: []const u8) ![]Rule {
    var out: std.ArrayList(Rule) = .empty;
    for (try rules.loadApplications(arena, io, exe_dir)) |r| {
        if (!browsers.isReplacedSection(r.section orelse "")) try out.append(arena, r);
    }
    return out.toOwnedSlice(arena);
}

/// CleanPass.Saved: ticked rules (Windows + Applications, never Wipe Free Space) and ticked browser items.
pub fn saved(arena: Allocator, io: Io, s: *const Settings, exe_dir: []const u8) !Saved {
    var picked: std.ArrayList(Rule) = .empty;
    for ([_][]Rule{ try windowsRules(arena, io), try appRules(arena, io, exe_dir) }) |set| for (set) |r| {
        if (!isWipe(&r) and s.getBool(r.name, r.default)) try picked.append(arena, r);
    };
    var items: std.ArrayList(browsers.BrowserItem) = .empty;
    for (try browsers.detect(arena, io, null)) |i| {
        if (s.getBool(try i.key(arena), i.default)) try items.append(arena, i);
    }
    return .{ .rules = try picked.toOwnedSlice(arena), .browser = try items.toOwnedSlice(arena) };
}

/// class CleanPass(Settings).
pub const CleanPass = struct {
    gpa: Allocator,
    settings: *Settings,
    /// Owns everything below; replaced by every analyze.
    arena: std.heap.ArenaAllocator,
    scanned: []Rule = &.{},
    files: []FileInfo = &.{},
    reg_keys: []rules.RegKey = &.{},
    actions: []special.Pending = &.{},
    browser_rows: []BrowserRow = &.{},
    summary: []ResultRow = &.{},
    /// Cap of the free-space wipe in clean. Tests only (they must never fill a real disk); the app wipes it all.
    wipe_limit: u64 = std.math.maxInt(u64),

    pub fn init(gpa: Allocator, settings: *Settings) CleanPass {
        return .{ .gpa = gpa, .settings = settings, .arena = .init(gpa) };
    }

    pub fn deinit(p: *CleanPass) void {
        p.arena.deinit();
    }

    /// CleanPass.Wipe: some scanned rule wipes free space.
    pub fn wipe(p: *const CleanPass) bool {
        for (p.scanned) |*r| if (isWipe(r)) return true;
        return false;
    }

    /// CleanPass.Any: something to clean.
    pub fn any(p: *const CleanPass) bool {
        return p.files.len + p.reg_keys.len + p.actions.len + p.browser_rows.len > 0 or p.wipe();
    }

    /// CleanPass.Analyze: rebuilds Custom from Options > Include, applies AgeOption (24 h), counts a shared file
    /// once, reports (done, total) per item. A cancelled run returns error.Canceled and leaves nothing armed.
    /// `rule_list` / `browser_items` must not point into this pass's own results (a successful run frees them).
    pub fn analyze(p: *CleanPass, io: Io, rule_list: []const Rule, browser_items: []const browsers.BrowserItem, progress: ?common.Progress(common.Count), cancel: ?*const common.Cancel) !void {
        p.scanned = &.{};
        p.files = &.{};
        p.reg_keys = &.{};
        p.actions = &.{};
        p.browser_rows = &.{};
        p.summary = &.{};
        var next: std.heap.ArenaAllocator = .init(p.gpa);
        errdefer next.deinit(); // the old arena stays until deinit (its results are already unhooked)
        const arena = next.allocator();

        var scanned: std.ArrayList(Rule) = .empty;
        // the Custom entry is rebuilt from Options > Include each time, so list edits apply without a restart
        for (rule_list) |r| try scanned.append(arena, if (std.mem.eql(u8, r.name, custom.rule_name)) try custom.includeRule(arena, p.settings) else r);
        for (browser_items) |i| if (i.files.file_keys.items.len > 0) try scanned.append(arena, i.files);
        for (scanned.items) |*r| r.older_than_hours = if (r.age_option != null and p.settings.getBool(r.age_option.?, false)) 24 else null;
        const ex = try custom.excludes(arena, p.settings);
        var action_items: std.ArrayList(browsers.BrowserItem) = .empty;
        for (browser_items) |i| if (i.action != null) try action_items.append(arena, i);

        var done: usize = 0;
        const total = scanned.items.len + action_items.items.len;
        var seen: common.IgnoreCaseMap(void) = .empty;
        var files: std.ArrayList(FileInfo) = .empty;
        var reg_keys: std.ArrayList(rules.RegKey) = .empty;
        var actions: std.ArrayList(special.Pending) = .empty;
        var summary: std.ArrayList(ResultRow) = .empty;
        for (scanned.items) |*r| {
            try common.check(cancel);
            if (progress) |pr| pr.report(.{ .done = done, .total = total });
            done += 1;
            var n: usize = 0;
            var size: u64 = 0;
            for (try engine.analyze(arena, io, r, ex, cancel)) |f| { // a file two rules share counts once
                if ((try seen.getOrPut(arena, f.path)).found_existing) continue;
                try files.append(arena, f);
                n += 1;
                size += f.size;
            }
            next_key: for (try engine.analyzeRegistry(arena, r, ex)) |k| {
                for (reg_keys.items) |x| if (x.eql(k)) continue :next_key;
                try reg_keys.append(arena, k);
                n += 1;
            }
            for (try engine.analyzeActions(arena, io, r)) |a| {
                try actions.append(arena, a);
                n += 1;
                size += a.bytes;
            }
            if (n > 0) try summary.append(arena, .{ .name = r.name, .items = n, .bytes = size });
        }
        var rows: std.ArrayList(BrowserRow) = .empty;
        for (action_items.items) |*i| {
            try common.check(cancel);
            if (progress) |pr| pr.report(.{ .done = done, .total = total });
            done += 1;
            const n = i.preview(p.gpa, io);
            if (n > 0) {
                try rows.append(arena, .{ .item = i, .count = n });
                try summary.append(arena, .{ .name = try i.key(arena), .items = n, .bytes = 0 });
            }
        }
        if (progress) |pr| pr.report(.{ .done = total, .total = total });

        p.arena.deinit();
        p.arena = next;
        p.scanned = scanned.items;
        p.files = files.items;
        p.reg_keys = reg_keys.items;
        p.actions = actions.items;
        p.browser_rows = rows.items;
        p.summary = summary.items;
    }

    /// CleanPass.AnalyzeSummary: "Analysis complete: N files, X to be removed, M registry entries..." (caller frees).
    pub fn analyzeSummary(p: *const CleanPass, gpa: Allocator) ![]u8 {
        var total: u64 = 0;
        for (p.files) |f| total += f.size;
        const t = &T.tr().pass;
        var b: [3][128]u8 = undefined;
        var line: [512]u8 = undefined;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, T.fmt(&line, t.analysis_complete, .{
            T.n(&b[0], T.tr().common.files, p.files.len, p.files.len), bytes.fmt(total), T.n(&b[1], t.reg_entries, p.reg_keys.len, p.reg_keys.len),
        }));
        if (p.actions.len > 0) try out.appendSlice(gpa, T.n(&b[2], t.other_items, p.actions.len, p.actions.len));
        if (p.browser_rows.len > 0) {
            var n: usize = 0;
            for (p.browser_rows) |r| n += r.count;
            try out.appendSlice(gpa, T.n(&b[2], t.browser_entries, n, n));
        }
        if (p.wipe()) try out.appendSlice(gpa, t.plus_wipe);
        return out.toOwnedSlice(gpa);
    }

    /// CleanPass.RunningBrowsers: analyzed browsers that are running right now (caller frees the slice).
    pub fn runningBrowsers(p: *const CleanPass, gpa: Allocator) ![]const *const browsers.Browser {
        var out: std.ArrayList(*const browsers.Browser) = .empty;
        errdefer out.deinit(gpa);
        for (&browsers.known) |*b| {
            if (!p.analyzed(b.name)) continue;
            const pids = try b.running(gpa);
            defer gpa.free(pids);
            if (pids.len > 0) try out.append(gpa, b);
        }
        return out.toOwnedSlice(gpa);
    }

    fn analyzed(p: *const CleanPass, browser: []const u8) bool {
        for (p.scanned) |r| if (browserRule(r.name, browser)) return true;
        for (p.browser_rows) |r| if (std.mem.eql(u8, r.item.browser, browser)) return true;
        return false;
    }

    /// CleanPass.Clean(skip, wipeProgress): skip = browser names left untouched (still running). Secure-delete
    /// passes from Settings; wipes free space through %TEMP% when a scanned rule asks. Returns the status line
    /// "Cleaning complete: ..." (caller frees).
    pub fn clean(p: *CleanPass, gpa: Allocator, io: Io, skip: []const []const u8, wipe_progress: ?common.Progress([]const u8)) ![]u8 {
        const arena = p.arena.allocator();
        const passes: u8 = @intCast(std.math.clamp(p.settings.getInt(securedelete.setting_key, 0), 0, 255));
        // a skipped browser keeps its files; everything else goes as analyzed
        var keep: common.IgnoreCaseMap(void) = .empty;
        for (p.scanned) |*r| if (skipped(skip, r.name)) {
            for (try engine.analyze(arena, io, r, &.{}, null)) |f| try keep.put(arena, f.path, {});
        };
        var go: std.ArrayList(FileInfo) = .empty;
        for (p.files) |f| if (!keep.contains(f.path)) try go.append(arena, f);
        const r = engine.clean(gpa, io, go.items, passes);
        const rr = engine.cleanRegistry(p.reg_keys);
        const ra = engine.runActions(p.actions);
        var rb: usize = 0;
        for (p.browser_rows) |row| if (!contains(skip, row.item.browser)) {
            rb += row.item.run(gpa, io);
        };
        for (p.scanned) |*rule| if (!skipped(skip, rule.name)) {
            _ = engine.removeEmptyDirs(gpa, io, rule);
        };
        const t = &T.tr().pass;
        var wiped: []const u8 = "";
        var wb: [600]u8 = undefined;
        if (p.wipe()) {
            // %TEMP% lives on the system drive and is writable without admin; other drives: Tools > Drive Wiper
            const tmp = try common.tempPath(arena);
            if (securedelete.wipeFreeSpace(io, tmp, @max(1, passes), wipe_progress, null, p.wipe_limit)) |_| {
                wiped = t.wiped;
            } else |e| {
                wiped = T.fmt(&wb, t.wipe_failed, .{kit.win.errText(e)});
            }
        }
        p.files = &.{};
        p.reg_keys = &.{};
        p.actions = &.{};
        p.browser_rows = &.{};
        p.summary = &.{};

        var b: [2][128]u8 = undefined;
        var line: [600]u8 = undefined;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, T.fmt(&line, t.cleaning_complete, .{
            T.n(&b[0], T.tr().common.files, r.deleted, r.deleted), bytes.fmt(r.bytes_freed), r.skipped,
            T.n(&b[1], t.reg_entries, rr.deleted, rr.deleted),                                  rr.skipped,
        }));
        if (ra.deleted + ra.skipped > 0) {
            try out.appendSlice(gpa, T.n(&b[0], t.other_done, ra.deleted, ra.deleted));
            if (ra.skipped > 0) try out.appendSlice(gpa, T.fmt(&b[0], t.other_failed, .{ra.skipped}));
        }
        if (rb > 0) try out.appendSlice(gpa, T.n(&b[0], t.browser_removed, rb, rb));
        if (skip.len > 0) {
            const names = try std.mem.join(arena, ", ", skip);
            try out.appendSlice(gpa, T.fmt(&line, t.skipped_running, .{names}));
        }
        try out.appendSlice(gpa, wiped);
        return out.toOwnedSlice(gpa);
    }
};

/// Rule "<browser>: <item>" belongs to that browser (ordinal).
fn browserRule(rule_name: []const u8, browser: []const u8) bool {
    return std.mem.startsWith(u8, rule_name, browser) and std.mem.startsWith(u8, rule_name[browser.len..], ": ");
}

fn skipped(skip: []const []const u8, rule_name: []const u8) bool {
    for (skip) |b| if (browserRule(rule_name, b)) return true;
    return false;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

// ---------------------------------------------------------------- /auto (Schedule.Auto)

/// Schedule.LogName (schedule.log_name points here; the pass does not import the Task Scheduler code).
pub const auto_log_name = "MakeCleaner-auto.log";

/// Schedule.Auto: "MakeCleaner.exe /auto [/shutdown]": the GUI's saved ticks, no window, no dialogs.
/// 0 = cleaned (files in use are skipped, not an error), 1 = failed. Never wipes free space (`saved` drops it),
/// never touches a running browser. Appends one line to <settings dir>\MakeCleaner-auto.log; with `shutdown`
/// starts "shutdown /s /t 60" (60 s grace so the user can still run "shutdown /a").
pub fn auto(gpa: Allocator, io: Io, settings: *Settings, exe_dir: []const u8, shutdown: bool) u8 {
    const dir = Io.Dir.path.dirname(settings.path) orelse ".";
    const log = Io.Dir.path.join(gpa, &.{ dir, auto_log_name }) catch return 1;
    defer gpa.free(log);
    autoRun(gpa, io, settings, exe_dir, log, shutdown) catch |e| {
        var buf: [1600]u8 = undefined;
        const msg: []const u8 = std.mem.print(&buf, "FAILED: {f}", .{kit.win.errText(e)}) catch "FAILED";
        appendLog(io, log, msg) catch {};
        return 1;
    };
    return 0;
}

fn autoRun(gpa: Allocator, io: Io, settings: *Settings, exe_dir: []const u8, log: []const u8, shutdown: bool) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pass: CleanPass = .init(gpa, settings);
    defer pass.deinit();
    const s = try saved(arena, io, settings, exe_dir);
    try pass.analyze(io, s.rules, s.browser, null, null);
    const running = try pass.runningBrowsers(gpa);
    defer gpa.free(running);
    const skip = try arena.alloc([]const u8, running.len);
    for (running, skip) |b, *n| n.* = b.name; // Browsers.known names are distinct
    // The log is machine-readable English: /auto never calls kit.i18n.apply, so tr() is the English table here.
    const analyzed_line = try pass.analyzeSummary(gpa);
    defer gpa.free(analyzed_line);
    const cleaned = try pass.clean(gpa, io, skip, null);
    defer gpa.free(cleaned);
    try appendLog(io, log, try arena.print("{s} | {s}", .{ analyzed_line, cleaned }));
    if (shutdown) _ = try kit.win.shellExecute(gpa, .{ .file = "shutdown.exe", .params = "/s /t 60 /c \"MakeCleaner: scheduled cleaning finished\"", .hidden = true });
}

/// Schedule.Log: "yyyy-MM-dd HH:mm:ss /auto: <line>\r\n" (local time) appended to `path`, folder created.
pub fn appendLog(io: Io, path: []const u8, line: []const u8) !void {
    if (Io.Dir.path.dirname(path)) |d| try Io.Dir.cwd().createDirPath(io, d);
    var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const end = try file.length(io);
    var buf: [1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    try fw.seekTo(end);
    const t = common.DateTime.nowLocal();
    try fw.interface.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} /auto: {s}\r\n", .{ t.year, t.month, t.day, t.hour, t.minute, t.second, line });
    try fw.interface.flush();
}
