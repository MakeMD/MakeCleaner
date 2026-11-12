//! Updates (MakeKit kit.update, notes K11). MakeCleaner never goes online itself: it spawns MakeUpdate.exe (next to
//! the exe, the only networked binary) hidden and reads one JSON line. Options > Settings "UpdateCheck" (default
//! on): one background check after startup, at most once per 24 h (UpdateLastCheck = unix s, saved after every
//! attempt). Options > About: "Check for updates" (also when the setting is off). A newer release -> a slim banner
//! above the page: Update now (installed: MakeUpdate installs silently and restarts us; portable: the release page),
//! Release notes, Later (= skip that version: UpdateSkip). MAKEKIT_NO_UPDATE=1 (every test script) = no check at
//! all; MAKEKIT_UPDATE_API (tests) is read by MakeUpdate itself.
const std = @import("std");
const kit = @import("kit");
const ctx_mod = @import("ctx.zig");
const Ctx = ctx_mod.Ctx;
const ui = @import("tools_ui.zig");
const T = @import("../i18n/tr.zig");
const tr = T.tr;

const im = kit.im;

pub const repo = "MakeMD/MakeCleaner";
pub const enabled_key = "UpdateCheck";
const last_key = "UpdateLastCheck";
const skip_key = "UpdateSkip";

// ponytail: one window per process, so the update state is module state (main and Options both reach it).
var checker: kit.update.Checker = .{};
var updater: []u8 = "";
var found: ?std.json.Parsed(kit.update.Result) = null;
var manual = false;
/// The About page's line under "Check for updates".
var status: ui.Text(300) = .{};

/// UpdateCheck: on unless "False" / "0".
pub fn enabled(ctx: *Ctx) bool {
    const v = std.mem.trim(u8, ctx.settings.get(enabled_key, "True"), " \t");
    return !(std.ascii.eqlIgnoreCase(v, "false") or std.mem.eql(u8, v, "0"));
}

fn now(ctx: *Ctx) i64 {
    return std.Io.Timestamp.now(ctx.io, .real).toSeconds();
}

/// After startup: the background check, when it is on and due.
pub fn startup(ctx: *Ctx) void {
    if (!enabled(ctx) or kit.update.disabled()) return;
    const last = std.fmt.parseInt(i64, ctx.settings.get(last_key, "0"), 10) catch 0;
    if (kit.update.due(last, now(ctx))) start(ctx, false);
}

fn start(ctx: *Ctx, by_user: bool) void {
    if (checker.running()) return;
    if (updater.len == 0) updater = kit.update.updaterPath(ctx.gpa, ctx.io) catch return;
    manual = by_user;
    checker.start(ctx.gpa, ctx.io, updater, repo, ctx_mod.version) catch |e| {
        if (by_user) status.tset(tr().update.failed, .{kit.win.errText(e)});
        return;
    };
    if (by_user) status.set("{s}", .{tr().update.checking});
}

pub fn deinit(gpa: std.mem.Allocator) void {
    checker.deinit();
    if (found) |*r| r.deinit();
    found = null;
    if (updater.len > 0) gpa.free(updater);
    updater = "";
}

/// Every frame, at the top of the page area: takes a finished check, draws the banner while a release is offered.
pub fn frame(ctx: *Ctx) void {
    if (checker.poll()) |res| took(ctx, res);
    const r = found orelse return;
    const u = &tr().update;
    var tb: [160]u8 = undefined;
    const action = kit.update.banner(.{ .text = T.fmt(&tb, u.available, .{r.value.latest}), .update = u.update_now, .notes = u.notes, .later = u.later });
    im.ImGui_Dummy(.{ .x = 0, .y = 6 * ui.scale() });
    switch (action orelse return) {
        .update => if (kit.update.isPortable(ctx.gpa, ctx.io)) openPage(ctx, r.value.page) else install(ctx, r.value.tag),
        .notes => openPage(ctx, r.value.page),
        .later => {
            ctx.settings.set(skip_key, r.value.latest) catch {};
            ctx.settings.save(ctx.io) catch {};
            drop();
        },
    }
}

fn took(ctx: *Ctx, res: anyerror!std.json.Parsed(kit.update.Result)) void {
    var nb: [24]u8 = undefined;
    ctx.settings.set(last_key, std.mem.print(&nb, "{d}", .{now(ctx)}) catch "0") catch {};
    ctx.settings.save(ctx.io) catch {};
    const u = &tr().update;
    const r = res catch |e| {
        if (manual) status.tset(u.failed, .{kit.win.errText(e)});
        return;
    };
    // offline / GitHub errors on a background check stay quiet; the updater's English `error` is never shown
    if (!r.value.ok) {
        if (manual) status.set("{s}", .{if (std.mem.eql(u8, r.value.reason, "offline")) u.offline else u.try_later});
        return r.deinit();
    }
    if (!r.value.newer) {
        if (manual) status.tset(u.up_to_date, .{ctx_mod.version});
        return r.deinit();
    }
    // "Later" skips that version for the daily check; asking by hand shows it again
    if (!manual and std.mem.eql(u8, r.value.latest, ctx.settings.get(skip_key, ""))) return r.deinit();
    status.tset(u.available, .{r.value.latest});
    drop();
    found = r;
}

fn drop() void {
    if (found) |*f| f.deinit();
    found = null;
}

fn openPage(ctx: *Ctx, page: []const u8) void {
    if (std.mem.startsWith(u8, page, "https://") or std.mem.startsWith(u8, page, "http://")) {
        _ = kit.win.shellExecute(ctx.gpa, .{ .file = page }) catch null;
    }
}

/// MakeUpdate downloads + verifies the setup, waits for this PID, installs silently and starts us again.
fn install(ctx: *Ctx, tag: []const u8) void {
    const self = std.process.executablePathAlloc(ctx.io, ctx.gpa) catch |e| return status.tset(tr().update.start_failed, .{kit.win.errText(e)});
    defer ctx.gpa.free(self);
    kit.update.install(ctx.io, updater, repo, tag, self) catch |e| return status.tset(tr().update.start_failed, .{kit.win.errText(e)});
    // WM_CLOSE, not app.quit(): the normal close path (saves the Cleaner ticks)
    _ = kit.w.PostMessageW(ctx.app.hwnd, kit.w.WM_CLOSE, 0, 0);
}

/// Options > Settings: the automatic-check toggle.
pub fn settingRow(ctx: *Ctx) void {
    var on = enabled(ctx);
    var lb: [256]u8 = undefined;
    if (kit.ui.checkbox(ui.idLabel(&lb, tr().update.auto, "{s}", .{enabled_key}).ptr, &on)) {
        ctx.settings.set(enabled_key, on) catch {};
        ctx.settings.save(ctx.io) catch {};
    }
}

/// Options > About: "Check for updates" + the result line.
pub fn aboutRow(ctx: *Ctx) void {
    var lb: [128]u8 = undefined;
    if (ui.button(ui.idLabel(&lb, tr().update.check, "updCheck", .{}).ptr, !checker.running())) start(ctx, true);
    if (status.len > 0) ui.status("updStatus", status.slice(), ui.pal.muted);
}
