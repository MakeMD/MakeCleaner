//! Cleaner page (legacy CleanerView.xaml + CheckNode.cs): Windows / Browsers / Applications check trees ->
//! Analyze (progress, Cancel) -> results -> Run Cleaner. All cleaning goes through cleanpass.CleanPass, the same
//! pass /auto runs. Long work (detection, analyze, closing a browser, clean + wipe) runs on kit.jobs.
const std = @import("std");
const kit = @import("kit");
const Ctx = @import("ctx.zig").Ctx;
const g = @import("g1_common.zig");
const ui = @import("tools_ui.zig");
const common = @import("../core/common.zig");
const rules = @import("../core/rules.zig");
const cleanpass = @import("../core/cleanpass.zig");
const browsers = @import("../core/browsers.zig");
const custom = @import("../core/custom.zig");
const bytes = @import("../core/bytes.zig");
const settings_mod = @import("../core/settings.zig");

const im = kit.im;
const pal = kit.app.palettes.cleaner;
const Allocator = std.mem.Allocator;
const Job = kit.jobs.Job;
const Tri = kit.ui.Tri;
const Settings = settings_mod.Settings;

/// ponytail: a plain list; Summary holds the totals when there are more files.
const max_file_lines = 5000;
const hint_text = "Tick what to clean on the left, then press Analyze. Nothing is deleted until Run Cleaner.";

// Dialog tags
const tag_warn = 1;
const tag_browser = 2;
const tag_not_closed = 3;

/// One checkbox of a tree (CheckNode item): a Rule (Windows/Applications) or a BrowserItem (Browsers).
const Node = struct {
    label: [:0]const u8, // "<name>##<tab>i:<name>"
    name: []const u8,
    key: []const u8, // Settings key
    warning: ?[:0]const u8,
    idx: usize, // into the tree's source list
    on: bool,
    wipe: bool, // Wipe Free Space always starts off: never saved
};

/// CheckNode group: tri-state, derived from its items.
const Group = struct {
    check_label: [:0]const u8, // "<group>##<tab>g:<group>"
    tree_label: [:0]const u8, // "##<tab>t:<group>"
    expanded: bool,
    items: []Node,

    fn state(gr: *const Group) Tri {
        var n: usize = 0;
        for (gr.items) |it| n += @intFromBool(it.on);
        return if (n == 0) .off else if (n == gr.items.len) .on else .mixed;
    }

    /// CheckNode.IsChecked setter of a group: ticking ticks the safe items only (risky ones need their own tick and
    /// warning); when that changes nothing (all safe ones already on) the click means "untick all".
    fn set(gr: *Group, value: bool) void {
        var tick = false;
        if (value) for (gr.items) |it| {
            if (it.warning == null and !it.on) tick = true;
        };
        for (gr.items) |*it| if (!tick or it.warning == null) {
            it.on = tick;
        };
    }
};

const Tree = struct { groups: []Group = &.{} };

/// One results line; `path` is set for a file (context menu: open folder, exclude). Strings live in lines_arena.
const Line = struct { label: [:0]const u8, found: [:0]const u8, size: [:0]const u8, path: ?[:0]const u8 = null };

const Phase = enum { idle, analyzing, asking, closing, cleaning };

pub const Page = struct {
    gpa: Allocator,
    io: std.Io,
    exe_dir: []const u8,
    /// windows rules + all trees
    arena: std.heap.ArenaAllocator,
    /// browser items + application rules (written by the lists job)
    lists_arena: std.heap.ArenaAllocator,
    /// ticked rules / items / skip list of the current run
    run_arena: std.heap.ArenaAllocator,
    /// results lines (copies, so the worker may replace the pass meanwhile)
    lines_arena: std.heap.ArenaAllocator,

    windows_rules: []rules.Rule = &.{},
    app_rules: []rules.Rule = &.{},
    browser_items: []browsers.BrowserItem = &.{},
    tab: u2 = 0,
    win_tree: Tree = .{},
    brw_tree: Tree = .{},
    app_tree: Tree = .{},

    lists_job: Job = .{},
    lists_started: bool = false,

    work: Job = .{},
    phase: Phase = .idle,
    pass: cleanpass.CleanPass,
    snap: ?Settings = null,
    job_rules: []const rules.Rule = &.{},
    job_items: []const browsers.BrowserItem = &.{},
    skip: std.ArrayList([]const u8) = .empty,
    /// worker -> UI: summary line of a finished analyze/clean (gpa)
    result_text: ?[]u8 = null,
    close_ok: bool = false,
    running: []const *const browsers.Browser = &.{},
    ask_idx: usize = 0,

    status: std.ArrayList(u8) = .empty,
    bar_done: u64 = 0,
    bar_total: u64 = 0,
    view_files: bool = false,
    lines: []Line = &.{},
    selected: ?usize = null,
    clean_enabled: bool = false,
    dialog: g.Dialog = .{},
    pending_warn: ?*Node = null,

    pub fn init(ctx: *Ctx) !Page {
        var p: Page = .{
            .gpa = ctx.gpa,
            .io = ctx.io,
            .exe_dir = ctx.exe_dir,
            .arena = .init(ctx.gpa),
            .lists_arena = .init(ctx.gpa),
            .run_arena = .init(ctx.gpa),
            .lines_arena = .init(ctx.gpa),
            .pass = .init(ctx.gpa, ctx.settings),
        };
        errdefer p.freeAll();
        const a = p.arena.allocator();
        p.windows_rules = try cleanpass.windowsRules(a, ctx.io);
        p.win_tree = try ruleTree(a, ctx.settings, "w", p.windows_rules, true);
        try p.setStatus("Detecting installed applications...", .{});
        return p;
    }

    pub fn deinit(self: *Page, ctx: *Ctx) void {
        _ = ctx;
        self.lists_job.cancel();
        self.lists_job.join();
        // CleanPass.clean has no cancel and a wipe can fill the drive for hours. The legacy ran it on a background
        // Task, so closing the window ended the process at once: do the same. The ticks were saved in
        // close_requested and the other pages are already torn down (this page is the last). The wipe's fill files
        // are delete-on-close (the OS removes them), the empty MakeCleanerWipe.* folder goes on the next wipe.
        if (self.phase == .cleaning and self.work.isRunning()) std.process.exit(0);
        self.work.cancel();
        self.work.join(); // analyze polls cancel; closing a browser is bounded (10 s)
        self.freeAll();
    }

    fn freeAll(p: *Page) void {
        p.pass.deinit();
        if (p.snap) |*s| s.deinit();
        if (p.result_text) |t| p.gpa.free(t);
        p.gpa.free(p.running);
        p.skip.deinit(p.gpa);
        p.status.deinit(p.gpa);
        p.arena.deinit();
        p.lists_arena.deinit();
        p.run_arena.deinit();
        p.lines_arena.deinit();
    }

    /// CleanerView.SaveChecks: called by the window on close.
    pub fn saveChecks(self: *Page, ctx: *Ctx) void {
        for ([_]*const Tree{ &self.win_tree, &self.app_tree, &self.brw_tree }) |t| for (t.groups) |gr| for (gr.items) |n| {
            if (!n.wipe) ctx.settings.set(n.key, n.on) catch {};
        };
        ctx.settings.save(ctx.io) catch |e| std.log.warn("saving the ticks failed: {t}", .{e});
    }

    fn setStatus(p: *Page, comptime fmt: []const u8, args: anytype) !void {
        p.status.clearRetainingCapacity();
        try p.status.print(p.gpa, fmt, args);
    }

    fn say(p: *Page, comptime fmt: []const u8, args: anytype) void {
        p.setStatus(fmt, args) catch {};
    }

    // ------------------------------------------------------------ frame

    pub fn draw(self: *Page, ctx: *Ctx) void {
        const p = self;
        if (!p.lists_started) {
            p.lists_started = true; // Page sits at its final address now: safe to hand it to a worker
            p.lists_job.start(p, listsWorker) catch |e| p.say("Detecting applications failed: {t}", .{e});
        }
        if (ui.jobDone(&p.lists_job)) p.finishLists(ctx);
        if (ui.jobDone(&p.work)) p.finishWork(ctx);
        if (p.work.isRunning() and p.phase == .analyzing) {
            p.bar_done = p.work.done.load(.acquire);
            p.bar_total = p.work.total.load(.acquire);
        }
        if (p.phase == .analyzing or p.phase == .cleaning) g.waitCursor(); // SetBusy: Cursor = Cursors.Wait

        const s = ui.scale();
        const avail = im.ImGui_GetContentRegionAvail();
        const left_w = 300 * s;
        if (g.beginPanel("##cleanLeft", .{ .x = left_w, .y = avail.y }, .{ .x = 6 * s, .y = 6 * s }, false)) p.drawTabs(ctx);
        g.endPanel();
        im.ImGui_SameLineEx(0, 16 * s);
        if (im.ImGui_BeginChild("##cleanRight", .{ .x = avail.x - left_w - 16 * s, .y = avail.y }, 0, im.ImGuiWindowFlags_NoBackground)) p.drawRight(ctx);
        im.ImGui_EndChild();

        if (p.dialog.draw()) |ans| p.answer(ctx, ans);
    }

    fn drawTabs(p: *Page, ctx: *Ctx) void {
        _ = ctx;
        // ponytail: hand-made tab strip, not ImGui_BeginTabItem: imgui's TabItemEx reports its label to the test
        // engine before ItemAdd, so MakeKit automation never sees tab labels. Move back when the kit hooks catch it.
        const tabs = [_]struct { [*:0]const u8, [*:0]const u8, *Tree }{
            .{ "Windows##tabWindows", "##windows", &p.win_tree },
            .{ "Browsers##tabBrowsers", "##browsers", &p.brw_tree },
            .{ "Applications##tabApps", "##apps", &p.app_tree },
        };
        const s = ui.scale();
        const dl = im.ImGui_GetWindowDrawList();
        for (tabs, 0..) |t, i| {
            if (i > 0) im.ImGui_SameLineEx(0, 2 * s);
            const sel = p.tab == i;
            im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Button, if (sel) ui.col(pal.accent_soft) else kit.app.color(0, 0));
            im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Text, ui.col(if (sel) pal.accent_dark else pal.text));
            if (im.ImGui_Button(t[0])) p.tab = @intCast(i);
            im.ImGui_PopStyleColorEx(2);
            if (sel) {
                const mn = im.ImGui_GetItemRectMin();
                const mx = im.ImGui_GetItemRectMax();
                im.ImDrawList_AddRectFilled(dl, .{ .x = mn.x, .y = mx.y - 2 * s }, mx, kit.app.colorU32(pal.accent));
            }
        }
        const t = tabs[p.tab];
        if (im.ImGui_BeginChild(t[1], .{ .x = 0, .y = 0 }, 0, 0)) p.drawTree(t[2]);
        im.ImGui_EndChild();
    }

    fn drawTree(p: *Page, tree: *Tree) void {
        for (tree.groups) |*gr| {
            im.ImGui_SetNextItemOpen(gr.expanded, im.ImGuiCond_Once);
            const open = im.ImGui_TreeNodeEx(gr.tree_label.ptr, im.ImGuiTreeNodeFlags_AllowOverlap);
            im.ImGui_SameLineEx(0, 2);
            var st = gr.state();
            if (kit.ui.triCheckbox(gr.check_label.ptr, &st)) gr.set(st == .on);
            if (!open) continue;
            for (gr.items) |*n| {
                var v: Tri = if (n.on) .on else .off;
                if (kit.ui.triCheckbox(n.label.ptr, &v)) {
                    const want = v == .on;
                    if (want and n.warning != null and !n.on) {
                        // the box stays off until the user confirms (CheckNode.Confirm)
                        p.pending_warn = n;
                        p.dialog.show(tag_warn, .warning, n.name, n.warning.?, &.{ "Turn on", "Cancel" });
                    } else n.on = want;
                }
                if (n.warning) |w| im.ImGui_SetItemTooltipUnformatted(w.ptr);
            }
            im.ImGui_TreePop();
        }
    }

    fn drawRight(p: *Page, ctx: *Ctx) void {
        const s = ui.scale();
        // progress strip
        var sbuf: [256]u8 = undefined;
        const job_status = if (p.work.isRunning()) p.work.status(&sbuf) else "";
        const shown = if (job_status.len > 0) job_status else p.status.items;
        var pbuf: [64]u8 = undefined;
        const pct = g.pctText(&pbuf, p.bar_done, p.bar_total);
        if (g.progressStrip("##strip", shown, "status", "Cancel##cancel", p.phase == .analyzing, p.bar_done, p.bar_total, pct, "progressText")) {
            p.work.cancel();
            p.say("Cancelling...", .{});
        }

        // Summary / Files
        im.ImGui_Dummy(.{ .x = 0, .y = 6 * s });
        // WPF-sized radio (circle = font + 2 px, like kit.ui's checkbox) with a visible grey ring
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_CheckMark, ui.col(pal.accent)); // the theme's white mark is for filled boxes
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Border, ui.col(pal.muted));
        im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_FramePadding, .{ .x = im.ImGui_GetStyle().*.FramePadding.x, .y = 1 });
        if (im.ImGui_RadioButton("Summary##viewSummary", !p.view_files) and p.view_files) {
            p.view_files = false;
            p.showResults();
        }
        im.ImGui_SameLineEx(0, 16 * s);
        if (im.ImGui_RadioButton("Files##viewFiles", p.view_files) and !p.view_files) {
            p.view_files = true;
            p.showResults();
        }
        im.ImGui_PopStyleVar();
        im.ImGui_PopStyleColorEx(2);
        im.ImGui_Dummy(.{ .x = 0, .y = 2 * s });

        // results
        const btn_h = 32 * s + 12 * s;
        const table_h = @max(60 * s, im.ImGui_GetContentRegionAvail().y - btn_h);
        const table_w = im.ImGui_GetContentRegionAvail().x;
        const top = im.ImGui_GetCursorScreenPos();
        p.drawResults(ctx, table_w, table_h);
        if (p.lines.len == 0) {
            const wrap = @min(360 * s, table_w - 20 * s);
            const ts = im.ImGui_CalcTextSizeEx(hint_text, null, false, wrap);
            im.ImGui_SetCursorScreenPos(.{ .x = top.x + (table_w - ts.x) / 2, .y = top.y + (table_h - ts.y) / 2 });
            ui.textItem("hint", hint_text, pal.muted, wrap, false);
        }
        im.ImGui_SetCursorScreenPos(.{ .x = top.x, .y = top.y + table_h + 12 * s });

        // Analyze left, Run Cleaner right
        const idle = p.phase == .idle;
        if (g.button("Analyze##analyze", idle, false)) p.startAnalyze(ctx);
        im.ImGui_SameLine();
        g.alignRight(g.buttonWidth("Run Cleaner##clean"));
        if (g.button("Run Cleaner##clean", idle and p.clean_enabled, true)) p.startRunCleaner();
    }

    fn drawResults(p: *Page, ctx: *Ctx, w: f32, h: f32) void {
        const s = ui.scale();
        const flags = g.list_flags | (if (p.lines.len == 0) im.ImGuiTableFlags_NoBordersInBody else 0); // hint sits on a clean area
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_TableRowBg, ui.col(pal.surface));
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_TableRowBgAlt, ui.col(pal.surface));
        defer im.ImGui_PopStyleColorEx(2);
        if (!im.ImGui_BeginTableEx("##results", 3, flags, .{ .x = w, .y = h }, 0)) return;
        defer im.ImGui_EndTable();
        im.ImGui_TableSetupScrollFreeze(0, 1);
        im.ImGui_TableSetupColumnEx("Item", im.ImGuiTableColumnFlags_WidthStretch, 0, 0);
        im.ImGui_TableSetupColumnEx("Found", im.ImGuiTableColumnFlags_WidthFixed, 110 * s, 0);
        im.ImGui_TableSetupColumnEx("Size", im.ImGuiTableColumnFlags_WidthFixed, 100 * s, 0);
        im.ImGui_TableHeadersRow();

        var clipper: im.ImGuiListClipper = std.mem.zeroes(im.ImGuiListClipper);
        im.ImGuiListClipper_Begin(&clipper, @intCast(p.lines.len), -1);
        if (p.selected) |sel| if (sel < p.lines.len) im.ImGuiListClipper_IncludeItemByIndex(&clipper, @intCast(sel));
        while (im.ImGuiListClipper_Step(&clipper)) {
            var i: usize = @intCast(clipper.DisplayStart);
            while (i < @as(usize, @intCast(clipper.DisplayEnd))) : (i += 1) {
                const l = &p.lines[i];
                im.ImGui_TableNextRow();
                _ = im.ImGui_TableNextColumn();
                if (im.ImGui_SelectableEx(l.label.ptr, p.selected == i, im.ImGuiSelectableFlags_SpanAllColumns, .{ .x = 0, .y = 0 })) p.selected = i;
                if (l.path) |path| im.ImGui_SetItemTooltipUnformatted(path.ptr);
                if (im.ImGui_IsItemClickedEx(im.ImGuiMouseButton_Right)) {
                    p.selected = i;
                    _ = im.ImGui_OpenPopup("##filectx", 0);
                }
                _ = im.ImGui_TableNextColumn();
                im.ImGui_TextUnformatted(l.found.ptr);
                _ = im.ImGui_TableNextColumn();
                im.ImGui_TextUnformatted(l.size.ptr);
            }
        }
        if (im.ImGui_BeginPopup("##filectx", 0)) {
            defer im.ImGui_EndPopup();
            const file = p.phase == .idle and p.selected != null and p.selected.? < p.lines.len and p.lines[p.selected.?].path != null;
            if (im.ImGui_MenuItemEx("Open containing folder", null, false, file)) p.openFolder();
            if (im.ImGui_MenuItemEx("Add file to Exclude", null, false, file)) p.exclude(ctx, false);
            if (im.ImGui_MenuItemEx("Add folder to Exclude", null, false, file)) p.exclude(ctx, true);
        }
    }

    // ------------------------------------------------------------ lists (Loaded -> LoadLists)

    fn listsWorker(job: *Job) anyerror!void {
        const p = job.ctx(Page);
        const a = p.lists_arena.allocator();
        p.browser_items = try browsers.detect(a, p.io, null);
        p.app_rules = try cleanpass.appRules(a, p.io, p.exe_dir);
    }

    fn finishLists(p: *Page, ctx: *Ctx) void {
        p.lists_job.join();
        var ebuf: [128]u8 = undefined;
        const err = p.lists_job.errorText(&ebuf);
        const a = p.arena.allocator();
        p.brw_tree = browserTree(a, ctx.settings, p.browser_items) catch .{};
        p.app_tree = ruleTree(a, ctx.settings, "a", p.app_rules, false) catch .{};
        // an Analyze/Clean started meanwhile owns the status line; don't overwrite its result
        if (std.mem.startsWith(u8, p.status.items, "Detecting")) {
            if (err) |e| p.say("Detecting applications failed: {s}", .{e}) else p.say("{d} applications detected", .{p.app_rules.len});
        }
    }

    // ------------------------------------------------------------ analyze

    fn startAnalyze(p: *Page, ctx: *Ctx) void {
        _ = p.run_arena.reset(.retain_capacity);
        const a = p.run_arena.allocator();
        var picked: std.ArrayList(rules.Rule) = .empty;
        var items: std.ArrayList(browsers.BrowserItem) = .empty;
        collect: {
            for (p.win_tree.groups) |gr| for (gr.items) |n| if (n.on) picked.append(a, p.windows_rules[n.idx]) catch break :collect;
            for (p.app_tree.groups) |gr| for (gr.items) |n| if (n.on) picked.append(a, p.app_rules[n.idx]) catch break :collect;
            for (p.brw_tree.groups) |gr| for (gr.items) |n| if (n.on) items.append(a, p.browser_items[n.idx]) catch break :collect;
        }
        p.job_rules = picked.items;
        p.job_items = items.items;
        if (!p.useSnapshot(ctx)) return;
        p.phase = .analyzing;
        p.clean_enabled = false;
        p.say("Analyzing...", .{});
        p.work.start(p, analyzeWorker) catch |e| {
            p.phase = .idle;
            p.dropSnapshot(ctx);
            p.say("Analysis failed: {t}", .{e});
        };
    }

    fn analyzeWorker(job: *Job) anyerror!void {
        const p = job.ctx(Page);
        const report: common.Progress(common.Count) = .{ .ctx = job, .func = reportCount };
        try p.pass.analyze(p.io, p.job_rules, p.job_items, report, &job.cancel_flag);
        p.result_text = try p.pass.analyzeSummary(p.gpa);
    }

    fn reportCount(c: ?*anyopaque, v: common.Count) void {
        const job: *Job = @ptrCast(@alignCast(c.?));
        job.setTotal(v.total);
        job.setDone(v.done);
    }

    /// The worker reads a private copy of the settings (Settings is not thread-safe; other pages write it).
    fn useSnapshot(p: *Page, ctx: *Ctx) bool {
        p.snap = g.snapshot(ctx.settings) catch |e| {
            p.say("Not enough memory: {t}", .{e});
            return false;
        };
        p.pass.settings = &p.snap.?;
        return true;
    }

    fn dropSnapshot(p: *Page, ctx: *Ctx) void {
        p.pass.settings = ctx.settings;
        if (p.snap) |*s| s.deinit();
        p.snap = null;
    }

    fn finishWork(p: *Page, ctx: *Ctx) void {
        p.work.join();
        var ebuf: [128]u8 = undefined;
        const err = p.work.errorText(&ebuf);
        const text = p.result_text;
        p.result_text = null;
        defer if (text) |t| p.gpa.free(t);
        switch (p.phase) {
            .analyzing => {
                p.dropSnapshot(ctx);
                if (text) |t| {
                    p.say("{s}", .{t});
                    p.bar_done = p.work.done.load(.acquire);
                    p.bar_total = p.work.total.load(.acquire);
                } else {
                    if (err) |e| p.say("Analysis failed: {s}", .{e}) else p.say("Analysis cancelled. Nothing will be cleaned.", .{});
                    p.bar_done = 0;
                    p.bar_total = 0;
                }
                p.phase = .idle;
                p.showResults();
                p.clean_enabled = p.pass.any();
            },
            .closing => {
                p.phase = .asking;
                const b = p.running[p.ask_idx];
                if (p.close_ok) {
                    p.ask_idx += 1;
                    p.askNext(ctx);
                } else {
                    var buf: [256]u8 = undefined;
                    const msg: []const u8 = std.mem.print(&buf, "{s} did not close (maybe an unsaved dialog). Skipping it.", .{b.name}) catch "The browser did not close. Skipping it.";
                    p.dialog.show(tag_not_closed, .info, b.name, msg, &.{"OK"});
                }
            },
            .cleaning => {
                p.dropSnapshot(ctx);
                if (text) |t| p.say("{s}", .{t}) else p.say("Cleaning failed: {s}", .{err orelse "unknown error"});
                p.phase = .idle;
                p.showResults();
                p.clean_enabled = false;
            },
            .idle, .asking => {},
        }
    }

    // ------------------------------------------------------------ clean

    fn startRunCleaner(p: *Page) void {
        p.gpa.free(p.running);
        p.running = p.pass.runningBrowsers(p.gpa) catch &.{};
        p.skip.clearRetainingCapacity();
        p.ask_idx = 0;
        p.phase = .asking;
        p.askNext(null);
    }

    /// Running browser: close it gracefully (no kill) or leave its items out of this clean.
    fn askNext(p: *Page, ctx: ?*Ctx) void {
        _ = ctx;
        if (p.ask_idx < p.running.len) {
            const b = p.running[p.ask_idx];
            var tbuf: [300]u8 = undefined;
            const text: []const u8 = std.mem.print(&tbuf, "{s} is running, so its files are locked. Close it now, or leave it out of this clean?", .{b.name}) catch b.name;
            var cbuf: [80]u8 = undefined;
            const close: []const u8 = std.mem.print(&cbuf, "Close {s}", .{b.name}) catch "Close";
            p.dialog.show(tag_browser, .question, b.name, text, &.{ close, "Skip", "Cancel" });
            return;
        }
        p.startClean();
    }

    fn startClean(p: *Page) void {
        const ctx_settings = p.pass.settings;
        p.snap = g.snapshot(ctx_settings) catch |e| {
            p.phase = .idle;
            p.say("Not enough memory: {t}", .{e});
            return;
        };
        p.pass.settings = &p.snap.?;
        p.phase = .cleaning;
        p.clean_enabled = false;
        p.say("Cleaning...", .{});
        p.work.start(p, cleanWorker) catch |e| {
            p.pass.settings = ctx_settings;
            p.snap.?.deinit();
            p.snap = null;
            p.phase = .idle;
            p.say("Cleaning failed: {t}", .{e});
        };
    }

    fn cleanWorker(job: *Job) anyerror!void {
        const p = job.ctx(Page);
        const wipe: common.Progress([]const u8) = .{ .ctx = job, .func = reportWipe };
        p.result_text = try p.pass.clean(p.gpa, p.io, p.skip.items, wipe);
    }

    fn reportWipe(c: ?*anyopaque, v: []const u8) void {
        const job: *Job = @ptrCast(@alignCast(c.?));
        job.setStatus("Wiping free space... {s}", .{v});
    }

    fn closeWorker(job: *Job) anyerror!void {
        const p = job.ctx(Page);
        const pids = try p.running[p.ask_idx].running(p.gpa);
        defer p.gpa.free(pids);
        p.close_ok = browsers.closeGracefully(pids, 10_000);
    }

    fn answer(p: *Page, ctx: *Ctx, a: g.Answer) void {
        switch (a.tag) {
            tag_warn => {
                if (a.index == 0) if (p.pending_warn) |n| {
                    n.on = true;
                };
                p.pending_warn = null;
            },
            tag_browser => switch (a.index) {
                0 => {
                    p.phase = .closing;
                    p.say("Closing {s}...", .{p.running[p.ask_idx].name});
                    p.work.start(p, closeWorker) catch {
                        p.phase = .asking;
                        p.skipCurrent(ctx);
                    };
                },
                1 => p.skipCurrent(ctx),
                else => {
                    p.phase = .idle; // Cancel: nothing cleaned
                },
            },
            tag_not_closed => p.skipCurrent(ctx),
            else => {},
        }
    }

    fn skipCurrent(p: *Page, ctx: *Ctx) void {
        p.skip.append(p.gpa, p.running[p.ask_idx].name) catch {};
        p.ask_idx += 1;
        p.askNext(ctx);
    }

    // ------------------------------------------------------------ results

    /// ShowResults: rebuilds the lines from the pass (UI thread, only while no worker owns the pass).
    fn showResults(p: *Page) void {
        _ = p.lines_arena.reset(.retain_capacity);
        p.selected = null;
        p.lines = p.buildLines(p.lines_arena.allocator()) catch &.{};
    }

    fn buildLines(p: *Page, a: Allocator) ![]Line {
        var out: std.ArrayList(Line) = .empty;
        var nb: [32]u8 = undefined;
        if (!p.view_files) {
            for (p.pass.summary) |r| try add(a, &out, r.name, try a.printSentinel("{s} items", .{ui.n0(&nb, r.items)}, 0), r.bytes, null);
            if (p.pass.wipe()) try add(a, &out, "Wipe Free Space", "free space", 0, null);
            return out.items;
        }
        const files = p.pass.files;
        for (files[0..@min(files.len, max_file_lines)]) |f| try add(a, &out, f.path, "", f.size, try a.dupeSentinel(u8, f.path, 0));
        if (files.len > max_file_lines) try add(a, &out, try a.print("... and {s} more files (see Summary for totals)", .{ui.n0(&nb, files.len - max_file_lines)}), "", 0, null);
        for (p.pass.reg_keys[0..@min(p.pass.reg_keys.len, max_file_lines)]) |k| try add(a, &out, try a.print("{f}", .{k}), "registry", 0, null);
        for (p.pass.actions) |x| try add(a, &out, x.label, "", x.bytes, null);
        for (p.pass.browser_rows) |r| try add(a, &out, try r.item.key(a), try a.printSentinel("{s} entries", .{ui.n0(&nb, r.count)}, 0), 0, null);
        return out.items;
    }

    /// `size` 0 = empty Size cell, except for file lines, which always show it (Bytes.Fmt(0) = "0 B").
    fn add(a: Allocator, out: *std.ArrayList(Line), name: []const u8, found: [:0]const u8, size: u64, path: ?[:0]const u8) !void {
        const i = out.items.len;
        const sz: [:0]const u8 = if (path != null or size > 0) try a.printSentinel("{f}", .{bytes.fmt(size)}, 0) else "";
        try out.append(a, .{
            .label = try a.printSentinel("{s}##l{d}", .{ name, i }, 0),
            .found = try a.dupeSentinel(u8, found, 0),
            .size = sz,
            .path = path,
        });
    }

    fn openFolder(p: *Page) void {
        const path = p.lines[p.selected.?].path.?;
        var buf: [2100]u8 = undefined;
        const args = std.mem.print(&buf, "/select,\"{s}\"", .{path}) catch return;
        _ = kit.win.shellExecute(p.gpa, .{ .file = "explorer.exe", .params = args }) catch |e| p.say("Could not open Explorer: {t}", .{e});
    }

    /// Writes the same Exclude list Options shows, and drops the file(s) from this run so Run Cleaner leaves them alone.
    fn exclude(p: *Page, ctx: *Ctx, folder: bool) void {
        const file = p.lines[p.selected.?].path.?;
        const dir = std.Io.Dir.path.dirname(file) orelse return;
        var ebuf: [2100]u8 = undefined;
        const entry: []const u8 = (if (folder)
            std.mem.print(&ebuf, "PATH|{s}", .{dir})
        else
            std.mem.print(&ebuf, "FILE|{s}|{s}", .{ dir, std.Io.Dir.path.basename(file) })) catch return;
        custom.addExclude(p.gpa, p.io, ctx.settings, entry) catch |e| return p.say("Could not save the Exclude list: {t}", .{e});
        var n: usize = 0;
        for (p.pass.files) |f| {
            const drop = if (folder)
                common.startsWithIgnoreCase(f.path, dir) and f.path.len > dir.len and f.path[dir.len] == '\\'
            else
                common.eqlIgnoreCase(f.path, file);
            if (drop) continue;
            p.pass.files[n] = f;
            n += 1;
        }
        p.pass.files = p.pass.files[0..n];
        p.say("Added to Exclude: {s}. Analyze again to refresh the totals.", .{if (folder) dir else file});
        p.showResults(); // after the status: `file` lives in lines_arena
        p.clean_enabled = p.pass.any();
    }
};

// ---------------------------------------------------------------- trees

fn ruleTree(a: Allocator, s: *const Settings, tab: []const u8, list: []const rules.Rule, expanded: bool) !Tree {
    var groups: std.array_hash_map.String(std.ArrayList(Node)) = .empty;
    for (list, 0..) |*r, i| {
        const gop = try groups.getOrPut(a, r.group());
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, try node(a, tab, r.name, r.name, r.warning, i, s.getBool(r.name, r.default), cleanpass.isWipe(r)));
    }
    return finish(a, tab, &groups, expanded);
}

fn browserTree(a: Allocator, s: *const Settings, list: []const browsers.BrowserItem) !Tree {
    var groups: std.array_hash_map.String(std.ArrayList(Node)) = .empty;
    for (list, 0..) |*it, i| {
        const gop = try groups.getOrPut(a, it.browser);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const key = try it.key(a);
        try gop.value_ptr.append(a, try node(a, "b", it.name, key, it.warning, i, s.getBool(key, it.default), false));
    }
    return finish(a, "b", &groups, true);
}

fn node(a: Allocator, tab: []const u8, name: []const u8, key: []const u8, warning: ?[]const u8, idx: usize, on: bool, wipe: bool) !Node {
    return .{
        .label = try a.printSentinel("{s}##{s}i:{s}", .{ name, tab, key }, 0),
        .name = name,
        .key = key,
        .warning = if (warning) |w| try a.dupeSentinel(u8, w, 0) else null,
        .idx = idx,
        .on = on,
        .wipe = wipe,
    };
}

fn finish(a: Allocator, tab: []const u8, groups: *std.array_hash_map.String(std.ArrayList(Node)), expanded: bool) !Tree {
    const out = try a.alloc(Group, groups.count());
    for (groups.keys(), groups.values(), out) |name, items, *gr| gr.* = .{
        .check_label = try a.printSentinel("{s}##{s}g:{s}", .{ name, tab, name }, 0),
        .tree_label = try a.printSentinel("##{s}t:{s}", .{ tab, name }, 0),
        .expanded = expanded,
        .items = items.items,
    };
    return .{ .groups = out };
}

test "group click: safe items only, then untick all" {
    var items = [_]Node{
        .{ .label = "a", .name = "a", .key = "a", .warning = null, .idx = 0, .on = false, .wipe = false },
        .{ .label = "b", .name = "b", .key = "b", .warning = "risky", .idx = 1, .on = false, .wipe = false },
    };
    var gr: Group = .{ .check_label = "g", .tree_label = "t", .expanded = true, .items = &items };
    gr.set(true); // off -> tick the safe one only
    try std.testing.expect(items[0].on and !items[1].on and gr.state() == .mixed);
    gr.set(true); // mixed click with all safe on = untick all
    try std.testing.expect(!items[0].on and !items[1].on and gr.state() == .off);
    items[1].on = true;
    items[0].on = true;
    gr.set(false); // on -> off
    try std.testing.expect(gr.state() == .off);
}
