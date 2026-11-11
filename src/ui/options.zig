//! Options page (legacy OptionsPages.cs): sub-menu Settings / Include / Exclude / Cookies / Schedule / About.
//! Settings keys are the v1.0 ones; every change is saved immediately. Pages are built on first open.
const std = @import("std");
const kit = @import("kit");
const ctx_mod = @import("ctx.zig");
const Ctx = ctx_mod.Ctx;
const ui = @import("tools_ui.zig");
const lists = @import("options_lists.zig");
const update = @import("update.zig");
const cookies_page = @import("options_cookies.zig");
const securedelete = @import("../core/securedelete.zig");
const schedule = @import("../core/schedule.zig");
const common = @import("../core/common.zig");
const T = @import("../i18n/tr.zig");
const tr = T.tr;

const im = kit.im;
const w = kit.w;

/// MakeCleaner.ini key of the UI language: "auto" (Windows UI language) or a kit.i18n.Lang code.
pub const language_key = "Language";

pub const Page = struct {
    sel: usize = 0,
    include: lists.Include = .{},
    exclude: lists.Exclude = .{},
    cookies: ?*cookies_page.View = null,
    sched: ?*Schedule = null,

    pub fn init(ctx: *Ctx) !Page {
        _ = ctx;
        return .{};
    }

    pub fn deinit(self: *Page, ctx: *Ctx) void {
        if (self.cookies) |c| c.destroy(ctx);
        if (self.sched) |p| {
            p.job.cancel();
            p.job.join();
            ctx.gpa.destroy(p);
        }
    }

    pub fn draw(self: *Page, ctx: *Ctx) void {
        const avail = im.ImGui_GetContentRegionAvail();
        const o = &tr().options;
        const titles = [_]ui.NavItem{
            .{ o.nav_settings, .settings }, .{ o.nav_include, .folder_add }, .{ o.nav_exclude, .folder_remove },
            .{ o.nav_cookies, .cookies },   .{ o.nav_schedule, .schedule }, .{ o.nav_about, .info },
        };
        ui.subNav("options", &titles, &self.sel, avail.y);
        im.ImGui_SameLineEx(0, 16 * ui.scale());
        // legacy wrapped each page in a ScrollViewer: the host child scrolls both ways when the window is small
        if (im.ImGui_BeginChild("##optionsHost", .{ .x = 0, .y = avail.y }, 0, im.ImGuiWindowFlags_NoBackground | im.ImGuiWindowFlags_HorizontalScrollbar)) {
            switch (self.sel) {
                0 => settingsPage(ctx),
                1 => self.include.draw(ctx),
                2 => self.exclude.draw(ctx),
                3 => {
                    if (self.cookies == null) self.cookies = cookies_page.View.create(ctx) catch null;
                    if (self.cookies) |c| c.draw(ctx);
                },
                4 => {
                    if (self.sched == null) self.sched = Schedule.create(ctx) catch null;
                    if (self.sched) |p| p.draw(ctx);
                },
                else => {
                    ui.title(ctx, o.nav_about);
                    var ab: [2048]u8 = undefined;
                    ui.mutedWrapped(T.fmt(&ab, tr().main.about_text, .{ctx_mod.version}), @min(640 * ui.scale(), im.ImGui_GetContentRegionAvail().x));
                    im.ImGui_Dummy(.{ .x = 0, .y = 8 * ui.scale() });
                    update.aboutRow(ctx);
                },
            }
        }
        im.ImGui_EndChild();
    }
};

fn save(ctx: *Ctx) void {
    ctx.settings.save(ctx.io) catch {};
}

// ---------------------------------------------------------------- Settings

/// Settings key + the tr().options field of its label.
const age_options = [_]struct { key: []const u8, text: []const u8 }{
    .{ .key = "TempOlderThan24h", .text = "temp_24h" },
    .{ .key = "RecycleBinOlderThan24h", .text = "recycle_24h" },
};

/// securedelete.methods labels in the current language (combo items).
fn methodLabels() [securedelete.methods.len][*:0]const u8 {
    var out: [securedelete.methods.len][*:0]const u8 = undefined;
    for (securedelete.methods, &out) |m, *o| o.* = T.lookup("method", m.label) orelse "?";
    return out;
}

fn settingsPage(ctx: *Ctx) void {
    const s = ui.scale();
    const o = &tr().options;
    ui.title(ctx, o.nav_settings);
    // language: applies at once (kit.i18n.combo calls apply), saved as Language=auto|en|uk|...
    ui.label(o.language);
    im.ImGui_SameLineEx(0, 8 * s);
    var pref = kit.i18n.Lang.parse(ctx.settings.get(language_key, "auto"));
    im.ImGui_SetNextItemWidth(200 * s);
    if (kit.i18n.combo("##language", o.lang_auto, &pref)) {
        ctx.settings.set(language_key, if (pref) |l| l.code() else "auto") catch {};
        save(ctx);
    }
    im.ImGui_Dummy(.{ .x = 0, .y = 6 * s });
    ui.muted(o.secure_deletion);
    const passes = ctx.settings.getInt(securedelete.setting_key, 0);
    var cur: c_int = 0;
    for (securedelete.methods, 0..) |m, i| if (m.passes == passes) {
        cur = @intCast(i);
    };
    const labels = methodLabels();
    if (ui.combo("secureDelete", &labels, &cur, 320 * s)) {
        ctx.settings.set(securedelete.setting_key, securedelete.methods[@intCast(cur)].passes) catch {};
        save(ctx);
    }
    im.ImGui_Dummy(.{ .x = 0, .y = 6 * s });
    inline for (age_options) |a| {
        var on = ctx.settings.getBool(a.key, false);
        var lb: [256]u8 = undefined;
        if (kit.ui.checkbox(ui.idLabel(&lb, @field(o, a.text), "{s}", .{a.key}).ptr, &on)) {
            ctx.settings.set(a.key, on) catch {};
            save(ctx);
        }
    }
    update.settingRow(ctx);
}

// ---------------------------------------------------------------- Schedule

/// The only way MakeCleaner runs by itself: a task the user creates here and removes here. Task Scheduler (COM)
/// calls run on a job (C# made them on the UI thread); the job ends with the task's description as status.
const Schedule = struct {
    kind: c_int = 1,
    at: ui.Buf(32) = .{},
    shutdown: bool = false,
    status: ui.Text(300) = .{},
    job: kit.jobs.Job = .{},
    // job input
    op: enum { describe, create, delete } = .describe,
    run_kind: schedule.ScheduleKind = .daily,
    run_at: common.DateTime = undefined,
    run_shutdown: bool = false,

    fn create(ctx: *Ctx) !*Schedule {
        const p = try ctx.gpa.create(Schedule);
        p.* = .{};
        // DateTime.Today.AddDays(1).AddHours(12)
        var st: w.SYSTEMTIME = undefined;
        w.GetLocalTime(&st);
        var ft: w.FILETIME = undefined;
        var t = ui.systemTime(st.wYear, @intCast(st.wMonth), @intCast(st.wDay), 0, 0);
        if (w.SystemTimeToFileTime(&t, &ft) != 0) {
            const day: u64 = 864_000_000_000;
            const v = (@as(u64, ft.dwHighDateTime) << 32 | ft.dwLowDateTime) + day;
            ft = .{ .dwLowDateTime = @truncate(v), .dwHighDateTime = @truncate(v >> 32) };
            _ = w.FileTimeToSystemTime(&ft, &t);
        }
        var b: [32]u8 = undefined;
        p.at.set(std.mem.print(&b, "{d:0>4}-{d:0>2}-{d:0>2} 12:00", .{ t.wYear, t.wMonth, t.wDay }) catch "");
        p.start(.describe);
        return p;
    }

    fn start(p: *Schedule, op: @FieldType(Schedule, "op")) void {
        if (p.job.thread != null) return;
        p.op = op;
        p.job.start(p, worker) catch {};
    }

    /// Worker: the operation, then the status text (job.setStatus; the UI copies it when the job is done).
    fn worker(job: *kit.jobs.Job) anyerror!void {
        const p = job.ctx(Schedule);
        const gpa = std.heap.smp_allocator;
        const t = &tr().schedule;
        var sb: [300]u8 = undefined;
        switch (p.op) {
            .create => schedule.create(gpa, p.run_kind, p.run_at, p.run_shutdown, schedule.task_name, null) catch |e| {
                return job.setStatus("{s}", .{T.fmt(&sb, t.create_failed, .{kit.win.errText(e)})});
            },
            .delete => schedule.delete(schedule.task_name) catch {},
            .describe => {},
        }
        const d = schedule.describe(gpa, schedule.task_name) catch |e| return job.setStatus("{s}", .{T.fmt(&sb, t.read_failed, .{kit.win.errText(e)})});
        if (d) |text| {
            defer gpa.free(text);
            job.setStatus("{s}", .{text});
        } else job.setStatus("{s}", .{t.none});
    }

    fn draw(p: *Schedule, ctx: *Ctx) void {
        const s = ui.scale();
        if (p.job.takeFinished()) {
            var sb: [256]u8 = undefined;
            p.status.set("{s}", .{p.job.status(&sb)});
        }
        const busy = p.job.isRunning();
        const t = &tr().schedule;
        ui.title(ctx, tr().options.nav_schedule);
        ui.mutedWrapped(t.intro, @min(640 * s, im.ImGui_GetContentRegionAvail().x));
        im.ImGui_Dummy(.{ .x = 0, .y = 6 * s });
        const kinds = [_][*:0]const u8{ t.once, t.daily, t.weekly, t.at_logon };
        _ = ui.combo("schedKind", &kinds, &p.kind, 190 * s);
        im.ImGui_SameLineEx(0, 8 * s);
        ui.label(t.start);
        im.ImGui_SameLineEx(0, 8 * s);
        im.ImGui_BeginDisabled(p.kind == @backingInt(schedule.ScheduleKind.at_logon));
        _ = p.at.input("##schedAt", 150 * s);
        im.ImGui_EndDisabled();
        im.ImGui_SameLineEx(0, 8 * s);
        var lb: [128]u8 = undefined;
        _ = kit.ui.checkbox(ui.idLabel(&lb, t.shutdown, "schedShutdown", .{}).ptr, &p.shutdown);
        im.ImGui_Dummy(.{ .x = 0, .y = 4 * s });
        if (ui.button(ui.idLabel(&lb, t.create, "schedCreate", .{}).ptr, !busy)) p.createTask();
        im.ImGui_SameLineEx(0, 8 * s);
        if (ui.button(ui.idLabel(&lb, t.remove, "schedRemove", .{}).ptr, !busy)) p.start(.delete);
        im.ImGui_Dummy(.{ .x = 0, .y = 6 * s });
        im.ImGui_PushFontFloat(ctx.app.fonts.bold, 0);
        ui.status("schedStatus", p.status.slice(), ui.pal.text);
        im.ImGui_PopFont();
    }

    fn createTask(p: *Schedule) void {
        p.run_at = parseAt(p.at.trimmed()) orelse return p.status.set("{s}", .{tr().schedule.bad_format});
        p.run_kind = @fromBackingInt(@as(u2, @intCast(p.kind)));
        p.run_shutdown = p.shutdown;
        p.start(.create);
    }
};

/// DateTime.TryParseExact(s, "yyyy-MM-dd HH:mm"): exact shape, real calendar date.
pub fn parseAt(s: []const u8) ?common.DateTime {
    if (s.len != 16 or s[4] != '-' or s[7] != '-' or s[10] != ' ' or s[13] != ':') return null;
    for (s, 0..) |c, i| if (i != 4 and i != 7 and i != 10 and i != 13 and !std.ascii.isDigit(c)) return null;
    const y = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const h = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    if (y < 1 or mo < 1 or mo > 12 or d < 1 or h > 23 or mi > 59) return null;
    const leap = (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
    const days = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (d > days[mo - 1]) return null;
    return .{ .year = y, .month = mo, .day = d, .hour = h, .minute = mi };
}
