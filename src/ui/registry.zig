//! Registry page (legacy RegistryView.xaml): category checklist -> Scan for Issues (a category at a time on a job,
//! progress, Cancel; read-only) -> tick issues -> Review: silent mandatory .reg backup of every ticked issue, then
//! the n/N "Fix registry issues" dialog (g1_regfix.zig) that fixes them one by one or all at once.
const std = @import("std");
const kit = @import("kit");
const Ctx = @import("ctx.zig").Ctx;
const g = @import("g1_common.zig");
const ui = @import("tools_ui.zig");
const regfix = @import("g1_regfix.zig");
const common = @import("../core/common.zig");
const regcleaner = @import("../core/regcleaner.zig");
const custom = @import("../core/custom.zig");

const im = kit.im;
const pal = kit.app.palettes.cleaner;
const Allocator = std.mem.Allocator;
const Job = kit.jobs.Job;
const Tri = kit.ui.Tri;
const RegIssue = regcleaner.RegIssue;
const cats = &regcleaner.categories;

const intro = "Pick the categories on the left, then press Scan for Issues. Scanning changes nothing.";

/// One issue line; the box is the user's pick for Review. Strings live in scan_arena.
const Row = struct { issue: RegIssue, target: []const u8, on: bool = true };

const Phase = enum { idle, scanning, backup, fixing };

pub const Page = struct {
    gpa: Allocator,
    io: std.Io,
    cat_on: [cats.len]bool = @splat(true),

    work: Job = .{},
    phase: Phase = .idle,
    /// issues, targets and excludes of the last scan
    scan_arena: std.heap.ArenaAllocator,
    excluded: []const []const u8 = &.{},
    chosen: [cats.len]usize = undefined,
    n_chosen: usize = 0,
    found: std.ArrayList(RegIssue) = .empty, // worker -> UI (scan_arena)
    scan_ok: bool = false,
    rows: std.ArrayList(Row) = .empty,

    status: std.ArrayList(u8) = .empty,
    bar_done: u64 = 0,
    bar_total: u64 = 0,
    selected: ?usize = null,
    dialog: ui.Dialog = .{},

    backup_path: []u8 = &.{},
    review_rows: []usize = &.{},
    review_issues: []RegIssue = &.{},
    fix: regfix.Fix,

    pub fn init(ctx: *Ctx) !Page {
        var p: Page = .{ .gpa = ctx.gpa, .io = ctx.io, .scan_arena = .init(ctx.gpa), .fix = .init(ctx.gpa, ctx.io) };
        // same "Reg:" keys as the classic window
        for (cats, &p.cat_on) |c, *on| {
            var kb: [96]u8 = undefined;
            on.* = ctx.settings.getBool(std.mem.print(&kb, "Reg:{s}", .{c.name}) catch c.name, true);
        }
        try p.status.appendSlice(ctx.gpa, intro);
        return p;
    }

    pub fn deinit(self: *Page, ctx: *Ctx) void {
        _ = ctx;
        self.work.cancel();
        self.work.join();
        self.fix.deinit();
        self.rows.deinit(self.gpa);
        self.status.deinit(self.gpa);
        self.freeReview();
        self.scan_arena.deinit();
    }

    fn freeReview(p: *Page) void {
        p.gpa.free(p.backup_path);
        p.gpa.free(p.review_rows);
        p.gpa.free(p.review_issues);
        p.backup_path = &.{};
        p.review_rows = &.{};
        p.review_issues = &.{};
    }

    fn say(p: *Page, comptime fmt: []const u8, args: anytype) void {
        p.status.clearRetainingCapacity();
        p.status.print(p.gpa, fmt, args) catch {};
    }

    pub fn draw(self: *Page, ctx: *Ctx) void {
        const p = self;
        if (p.work.takeFinished()) p.finishWork();
        if (p.work.isRunning()) {
            p.bar_done = p.work.done.load(.acquire);
            p.bar_total = p.work.total.load(.acquire);
        }
        if (p.phase == .scanning) g.waitCursor(); // RunScan: Cursor = Cursors.Wait
        const s = ui.scale();
        const avail = im.ImGui_GetContentRegionAvail();
        const left_w = 300 * s;
        if (g.beginPanel("##regLeft", .{ .x = left_w, .y = avail.y }, .{ .x = 12 * s, .y = 10 * s }, false)) p.drawCategories(ctx);
        g.endPanel();
        im.ImGui_SameLineEx(0, 16 * s);
        if (im.ImGui_BeginChild("##regRight", .{ .x = avail.x - left_w - 16 * s, .y = avail.y }, 0, im.ImGuiWindowFlags_NoBackground)) p.drawRight(ctx);
        im.ImGui_EndChild();

        if (p.dialog.draw()) |_| {}
        if (p.phase == .fixing and p.fix.draw()) p.afterFix();
    }

    // ------------------------------------------------------------ categories

    fn drawCategories(p: *Page, ctx: *Ctx) void {
        var n: usize = 0;
        for (p.cat_on) |on| n += @intFromBool(on);
        var all: Tri = if (n == 0) .off else if (n == cats.len) .on else .mixed;
        im.ImGui_PushFontFloat(g.boldFont(), 0);
        const changed_all = kit.ui.triCheckbox("All categories##regall", &all);
        im.ImGui_PopFont();
        im.ImGui_Dummy(.{ .x = 0, .y = 2 * ui.scale() });
        if (changed_all) {
            // CheckNode group without warnings: tick all when some are off, else untick all
            const on = all == .on and n < cats.len;
            for (0..cats.len) |i| p.setCat(ctx, i, on);
        }
        for (cats, 0..) |c, i| {
            var buf: [96]u8 = undefined;
            const lbl = std.mem.printSentinel(&buf, "{s}##regcat:{s}", .{ c.name, c.name }, 0) catch continue;
            var v: Tri = if (p.cat_on[i]) .on else .off;
            if (kit.ui.triCheckbox(lbl.ptr, &v)) p.setCat(ctx, i, v == .on);
        }
    }

    fn setCat(p: *Page, ctx: *Ctx, i: usize, on: bool) void {
        if (p.cat_on[i] == on) return;
        p.cat_on[i] = on;
        var kb: [96]u8 = undefined;
        const key = std.mem.print(&kb, "Reg:{s}", .{cats[i].name}) catch return;
        ctx.settings.set(key, on) catch {};
        ctx.settings.save(ctx.io) catch |e| p.say("Could not save the settings: {t}", .{e});
    }

    // ------------------------------------------------------------ right side

    fn drawRight(p: *Page, ctx: *Ctx) void {
        const s = ui.scale();
        var sbuf: [256]u8 = undefined;
        const job_status = if (p.work.isRunning() and p.phase == .scanning) p.work.status(&sbuf) else "";
        const shown = if (job_status.len > 0) job_status else p.status.items;
        var pbuf: [64]u8 = undefined;
        const pct = g.pctText(&pbuf, p.bar_done, p.bar_total);
        if (g.progressStrip("##regstrip", shown, "regstatus", "Cancel##regcancel", p.phase == .scanning, p.bar_done, p.bar_total, pct, "regprogress")) {
            p.work.cancel();
            p.say("Cancelling...", .{});
        }

        const btn_h = 32 * s + 12 * s;
        im.ImGui_Dummy(.{ .x = 0, .y = 6 * s });
        const table_h = @max(60 * s, im.ImGui_GetContentRegionAvail().y - btn_h);
        const top = im.ImGui_GetCursorScreenPos();
        p.drawList(ctx, im.ImGui_GetContentRegionAvail().x, table_h);
        im.ImGui_SetCursorScreenPos(.{ .x = top.x, .y = top.y + table_h + 12 * s });

        // Scan left, Review right
        const idle = p.phase == .idle;
        if (g.button("Scan for Issues##regscan", idle, false)) p.startScan(ctx);
        im.ImGui_SameLine();
        g.alignRight(g.buttonWidth("Review selected Issues...##regfix"));
        if (g.button("Review selected Issues...##regfix", idle and p.rows.items.len > 0, true)) p.startReview(ctx);
    }

    fn drawList(p: *Page, ctx: *Ctx, w: f32, h: f32) void {
        const s = ui.scale();
        const flags = g.list_flags | (if (p.rows.items.len == 0) im.ImGuiTableFlags_NoBordersInBody else 0);
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_TableRowBg, ui.col(pal.surface));
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_TableRowBgAlt, ui.col(pal.surface));
        defer im.ImGui_PopStyleColorEx(2);
        if (!im.ImGui_BeginTableEx("##reglist", 4, flags, .{ .x = w, .y = h }, 0)) return;
        defer im.ImGui_EndTable();
        im.ImGui_TableSetupScrollFreeze(0, 1);
        im.ImGui_TableSetupColumnEx("##check", im.ImGuiTableColumnFlags_WidthFixed, 34 * s, 0);
        im.ImGui_TableSetupColumnEx("Problem", im.ImGuiTableColumnFlags_WidthFixed, 170 * s, 0);
        im.ImGui_TableSetupColumnEx("Data", im.ImGuiTableColumnFlags_WidthStretch, 0.45, 0);
        im.ImGui_TableSetupColumnEx("Registry key", im.ImGuiTableColumnFlags_WidthStretch, 0.55, 0);
        im.ImGui_TableHeadersRow();

        const rows = p.rows.items;
        var clipper: im.ImGuiListClipper = std.mem.zeroes(im.ImGuiListClipper);
        im.ImGuiListClipper_Begin(&clipper, @intCast(rows.len), -1);
        var row_hovered = false;
        while (im.ImGuiListClipper_Step(&clipper)) {
            var i: usize = @intCast(clipper.DisplayStart);
            while (i < @as(usize, @intCast(clipper.DisplayEnd))) : (i += 1) {
                const r = &rows[i];
                var buf: [1200]u8 = undefined;
                im.ImGui_TableNextRow();
                _ = im.ImGui_TableNextColumn();
                const sel_label = std.mem.printSentinel(&buf, "##row{d}", .{i}, 0) catch continue;
                if (im.ImGui_SelectableEx(sel_label.ptr, p.selected == i, im.ImGuiSelectableFlags_SpanAllColumns | im.ImGuiSelectableFlags_AllowOverlap, .{ .x = 0, .y = 0 })) p.selected = i;
                if (im.ImGui_IsItemHovered(0)) row_hovered = true;
                if (im.ImGui_IsItemClickedEx(im.ImGuiMouseButton_Right)) {
                    p.selected = i;
                    _ = im.ImGui_OpenPopup("##regctx", 0);
                }
                im.ImGui_SameLineEx(0, 0);
                const chk = std.mem.printSentinel(&buf, "##rc{d}:{s}", .{ i, r.target[0..@min(r.target.len, 1000)] }, 0) catch continue;
                var v: Tri = if (r.on) .on else .off;
                if (kit.ui.triCheckbox(chk.ptr, &v)) r.on = v == .on;
                _ = im.ImGui_TableNextColumn();
                cell(r.issue.problem);
                _ = im.ImGui_TableNextColumn();
                cell(r.issue.data);
                _ = im.ImGui_TableNextColumn();
                cell(r.target);
            }
        }
        // right-click on the empty part of the list: the menu without a row
        if (!row_hovered and im.ImGui_IsWindowHovered(0) and im.ImGui_IsMouseClicked(im.ImGuiMouseButton_Right)) {
            p.selected = null;
            _ = im.ImGui_OpenPopup("##regctx", 0);
        }
        if (im.ImGui_BeginPopup("##regctx", 0)) {
            defer im.ImGui_EndPopup();
            const idle = p.phase == .idle;
            const sel: ?*const RegIssue = if (p.selected) |i| (if (i < rows.len) &rows[i].issue else null) else null;
            if (im.ImGui_MenuItemEx("Select all", null, false, idle)) p.tick(null, true);
            if (im.ImGui_MenuItemEx("Select none", null, false, idle)) p.tick(null, false);
            if (im.ImGui_MenuItemEx("Select all of this type", null, false, idle and sel != null)) p.tick(sel.?.category, true);
            if (im.ImGui_MenuItemEx("Deselect all of this type", null, false, idle and sel != null)) p.tick(sel.?.category, false);
            im.ImGui_Separator();
            if (im.ImGui_MenuItemEx("Open in RegEdit", null, false, sel != null)) p.openInRegedit(sel.?.key_path);
            if (im.ImGui_MenuItemEx("Add to Exclude list", null, false, idle and sel != null)) p.exclude(ctx, p.selected.?);
        }
    }

    /// A cell whose text may be cut at the column edge: full text as a tooltip when it is.
    fn cell(s: []const u8) void {
        const avail = im.ImGui_GetContentRegionAvail().x;
        im.ImGui_TextUnformattedEx(s.ptr, s.ptr + s.len);
        if (ui.textW(s) > avail) ui.tip(s);
    }

    fn tick(p: *Page, category: ?[]const u8, on: bool) void {
        for (p.rows.items) |*r| {
            if (category == null or std.mem.eql(u8, r.issue.category, category.?)) r.on = on;
        }
    }

    // ------------------------------------------------------------ scan

    fn startScan(p: *Page, ctx: *Ctx) void {
        p.n_chosen = 0;
        for (p.cat_on, 0..) |on, i| if (on) {
            p.chosen[p.n_chosen] = i;
            p.n_chosen += 1;
        };
        if (p.n_chosen == 0) return p.say("Tick at least one category on the left.", .{});
        p.rows.clearRetainingCapacity(); // rows point into scan_arena
        p.selected = null;
        _ = p.scan_arena.reset(.retain_capacity);
        p.found = .empty;
        p.excluded = custom.registryExcludes(p.scan_arena.allocator(), ctx.settings) catch &.{};
        p.scan_ok = false;
        p.phase = .scanning;
        p.say("Scanning...", .{});
        p.work.start(p, scanWorker) catch |e| {
            p.phase = .idle;
            p.say("Scan failed: {t}", .{e});
        };
    }

    /// A category at a time, so the bar moves and Cancel lands quickly.
    fn scanWorker(job: *Job) anyerror!void {
        const p = job.ctx(Page);
        const a = p.scan_arena.allocator();
        const scanner = regcleaner.RegScanner.forThisPc();
        job.setTotal(p.n_chosen);
        for (p.chosen[0..p.n_chosen], 0..) |ci, i| {
            job.setDone(i);
            job.setStatus("Scanning: {s}...", .{cats[ci].name});
            try p.found.appendSlice(a, try scanner.scan(a, cats[ci .. ci + 1], p.excluded, &job.cancel_flag));
        }
        job.setDone(p.n_chosen);
        p.scan_ok = true;
    }

    fn finishWork(p: *Page) void {
        p.work.join();
        var ebuf: [128]u8 = undefined;
        const err = p.work.errorText(&ebuf);
        switch (p.phase) {
            .scanning => {
                p.phase = .idle;
                if (p.scan_ok) {
                    const a = p.scan_arena.allocator();
                    for (p.found.items) |i| {
                        const t = i.target(a) catch continue;
                        p.rows.append(p.gpa, .{ .issue = i, .target = t }) catch break;
                    }
                    p.bar_done = p.n_chosen;
                    p.bar_total = p.n_chosen;
                    p.say("Scan complete: {d} issues found", .{p.rows.items.len});
                } else {
                    p.bar_done = 0;
                    p.bar_total = 0;
                    if (err) |e| p.say("Scan failed: {s}", .{e}) else p.say("Scan cancelled. Nothing was changed.", .{});
                }
            },
            .backup => {
                if (err) |e| {
                    p.phase = .idle;
                    var buf: [700]u8 = undefined;
                    const msg: []const u8 = std.mem.print(&buf, "The backup could not be written, so nothing was changed.\n{s}", .{e}) catch "The backup could not be written, so nothing was changed.";
                    p.dialog.show(0, "Registry backup", .err, &.{"OK"}, "{s}", .{msg});
                    p.freeReview();
                } else {
                    p.phase = .fixing;
                    p.fix.start(p.review_issues) catch |e| {
                        p.phase = .idle;
                        p.say("Could not open the fix dialog: {t}", .{e});
                    };
                }
            },
            .idle, .fixing => {},
        }
    }

    // ------------------------------------------------------------ review / fix

    fn startReview(p: *Page, ctx: *Ctx) void {
        var idx: std.ArrayList(usize) = .empty;
        for (p.rows.items, 0..) |r, i| if (r.on) idx.append(p.gpa, i) catch {};
        if (idx.items.len == 0) {
            idx.deinit(p.gpa);
            return p.say("Tick the issues to fix first.", .{});
        }
        p.freeReview();
        p.review_rows = idx.toOwnedSlice(p.gpa) catch return;
        p.review_issues = p.gpa.alloc(RegIssue, p.review_rows.len) catch return p.freeReview();
        for (p.review_rows, p.review_issues) |ri, *x| x.* = p.rows.items[ri].issue;
        // Backup is mandatory but silent: always next to the settings, never asked for (no backup -> no fix).
        const dir = std.Io.Dir.path.dirname(ctx.settings.path) orelse ".";
        const name = regcleaner.defaultBackupName(p.gpa, common.DateTime.nowLocal()) catch return p.freeReview();
        defer p.gpa.free(name);
        p.backup_path = std.Io.Dir.path.join(p.gpa, &.{ dir, "RegistryBackups", name }) catch return p.freeReview();
        p.phase = .backup;
        p.work.start(p, backupWorker) catch |e| {
            p.phase = .idle;
            p.freeReview();
            p.say("Backup failed: {t}", .{e});
        };
    }

    fn backupWorker(job: *Job) anyerror!void {
        const p = job.ctx(Page);
        if (std.Io.Dir.path.dirname(p.backup_path)) |d| try std.Io.Dir.cwd().createDirPath(p.io, d);
        try regcleaner.writeBackup(p.gpa, p.io, p.review_issues, p.backup_path);
    }

    fn afterFix(p: *Page) void {
        p.phase = .idle;
        var fixed: usize = 0;
        // drop fixed rows, highest index first so the others keep their place
        var k = p.review_rows.len;
        while (k > 0) {
            k -= 1;
            if (!p.fix.fixed[k]) continue;
            _ = p.rows.orderedRemove(p.review_rows[k]);
            fixed += 1;
        }
        p.selected = null;
        const failed = p.fix.failedCount();
        var fbuf: [48]u8 = undefined;
        const not_fixed: []const u8 = if (failed > 0) std.mem.print(&fbuf, ", {d} not fixed", .{failed}) catch "" else "";
        p.say("Fixed {d} issues{s}. Backup: {s}", .{ fixed, not_fixed, p.backup_path });
        p.freeReview();
    }

    /// Writes the same Exclude list Options shows (REG entries) and drops the key's issues from the list.
    fn exclude(p: *Page, ctx: *Ctx, i: usize) void {
        const target = p.rows.items[i].target; // scan_arena: survives the removal below
        var buf: [1100]u8 = undefined;
        const entry = std.mem.print(&buf, "REG|{s}", .{target}) catch return;
        custom.addExclude(p.gpa, p.io, ctx.settings, entry) catch |e| return p.say("Could not save the Exclude list: {t}", .{e});
        var n: usize = 0;
        for (p.rows.items) |r| {
            if (std.mem.eql(u8, r.target, target)) continue;
            p.rows.items[n] = r;
            n += 1;
        }
        p.rows.shrinkRetainingCapacity(n);
        p.selected = null;
        p.say("Excluded: {s}", .{target});
    }

    /// Regedit opens at the key stored in its own LastKey setting.
    fn openInRegedit(p: *Page, key_path: []const u8) void {
        const k = kit.win.createKey(.hkcu, "Software\\Microsoft\\Windows\\CurrentVersion\\Applets\\Regedit", .default) catch |e| return p.say("Could not open RegEdit: {t}", .{e});
        defer k.close();
        var buf: [1100]u8 = undefined;
        const v = std.mem.print(&buf, "Computer\\{s}", .{key_path}) catch return;
        k.writeString("LastKey", v) catch |e| return p.say("Could not open RegEdit: {t}", .{e});
        _ = kit.win.shellExecute(p.gpa, .{ .file = "regedit.exe", .params = "/m" }) catch |e| p.say("Could not open RegEdit: {t}", .{e});
    }
};
