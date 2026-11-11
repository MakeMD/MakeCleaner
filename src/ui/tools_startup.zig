//! Tools > Startup (legacy StartupView): tabs Windows / Scheduled Tasks / Context Menu / Windows Services,
//! columns Enabled / Name / Location / Command; Enable / Disable / Delete (confirm) / Refresh / Save to text file.
//! Reads and actions run on a job (an action is followed by a full reload, as in C#).
const std = @import("std");
const kit = @import("kit");
const Ctx = @import("ctx.zig").Ctx;
const ui = @import("tools_ui.zig");
const startup = @import("../core/startup.zig");

const im = kit.im;
const Item = startup.StartupItem;

const tab_titles = [_][:0]const u8{ "Windows", "Scheduled Tasks", "Context Menu", "Windows Services" };
const tab_ids = [_][]const u8{ "startupWindows", "startupTasks", "startupContext", "startupServices" };
const tag_delete = 1;
const tag_info = 2;

const Act = enum { none, enable, disable, delete };

const Tab = struct {
    items: []const Item = &.{},
    err: ?[]const u8 = null,
};

pub const View = struct {
    job: kit.jobs.Job = .{},
    io: std.Io,
    arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
    tabs: [4]Tab = @splat(.{}),
    next_arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
    next_tabs: [4]Tab = @splat(.{}),
    // pending action, read by the worker
    act: Act = .none,
    act_item: ?*const Item = null,
    act_ok: bool = true,
    act_name: [256]u8 = undefined,
    act_name_len: usize = 0,
    cur: usize = 0,
    sel: [4]?usize = @splat(null),
    loaded: bool = false,
    dlg: ui.Dialog = .{},

    pub fn create(ctx: *Ctx) !*View {
        const v = try ctx.gpa.create(View);
        v.* = .{ .io = ctx.io };
        v.start(.none, null);
        return v;
    }

    pub fn destroy(v: *View, ctx: *Ctx) void {
        v.job.cancel();
        v.job.join();
        v.arena.deinit();
        v.next_arena.deinit();
        ctx.gpa.destroy(v);
    }

    fn start(v: *View, act: Act, it: ?*const Item) void {
        if (v.job.thread != null) return;
        v.act = act;
        v.act_item = it;
        if (it) |i| {
            v.act_name_len = @min(i.name.len, v.act_name.len);
            @memcpy(v.act_name[0..v.act_name_len], i.name[0..v.act_name_len]);
        }
        _ = v.next_arena.reset(.free_all);
        v.job.start(v, worker) catch {};
    }

    fn worker(job: *kit.jobs.Job) anyerror!void {
        const v = job.ctx(View);
        const gpa = std.heap.smp_allocator;
        v.act_ok = true;
        if (v.act_item) |it| v.act_ok = switch (v.act) {
            .enable => startup.setEnabled(gpa, it, true) catch false,
            .disable => startup.setEnabled(gpa, it, false) catch false,
            .delete => startup.delete(gpa, v.io, it) catch false,
            .none => true,
        };
        const a = v.next_arena.allocator();
        for (&v.next_tabs, 0..) |*t, i| {
            const r = switch (i) {
                0 => startup.readWindows(a, v.io),
                1 => startup.readTasks(a),
                2 => startup.readContextMenu(a, "HKCR", startup.blocked_key),
                else => startup.readServices(a, startup.services_key),
            };
            t.* = if (r) |items| .{ .items = items } else |e| .{ .err = try a.print("Error: {f}", .{kit.win.errText(e)}) };
            job.addDone(1); // first load: the UI shows next_tabs[0..done] while the rest is read (as C# did)
        }
    }

    /// Tab `t` as shown: on the first load the tabs already read by the running worker, else the last result.
    fn shown(v: *View, t: usize) ?*const Tab {
        if (v.loaded) return &v.tabs[t];
        return if (t < v.job.done.load(.acquire)) &v.next_tabs[t] else null;
    }

    fn selected(v: *View) ?*const Item {
        const i = v.sel[v.cur] orelse return null;
        const items = v.tabs[v.cur].items;
        return if (i < items.len) &items[i] else null;
    }

    fn enabledText(it: *const Item) []const u8 {
        return if (it.info.len > 0) it.info else if (it.enabled) "Yes" else "No";
    }

    fn save(v: *View, ctx: *Ctx) void {
        var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var lines: std.ArrayList([]const u8) = .empty;
        lines.append(a, "Enabled\tName\tLocation\tCommand") catch return;
        const t = &v.tabs[v.cur];
        if (t.err) |e| lines.append(a, a.print("\t{s}\t\t", .{e}) catch return) catch return;
        for (t.items) |*it| lines.append(a, a.print("{s}\t{s}\t{s}\t{s}", .{ enabledText(it), it.name, it.location, it.command }) catch return) catch return;
        var nb: [64]u8 = undefined;
        ui.saveText(ctx, &v.dlg, std.mem.print(&nb, "startup {s}", .{tab_titles[v.cur]}) catch "startup", lines.items);
    }

    pub fn draw(v: *View, ctx: *Ctx) void {
        const s = ui.scale();
        if (v.job.takeFinished()) {
            std.mem.swap(std.heap.ArenaAllocator, &v.arena, &v.next_arena);
            v.tabs = v.next_tabs;
            _ = v.next_arena.reset(.free_all);
            v.sel = @splat(null);
            v.loaded = true;
            if (!v.act_ok) v.dlg.info(tag_info, v.act_name[0..v.act_name_len], "The change was not applied.", .{});
            v.act = .none;
            v.act_item = null;
        }
        if (v.dlg.draw()) |ans| if (ans.tag == tag_delete and ans.button == 0) {
            if (v.selected()) |it| v.start(.delete, it);
        };

        const busy = v.job.isRunning();
        const avail = im.ImGui_GetContentRegionAvail();
        if (im.ImGui_BeginChild("##startupMain", .{ .x = avail.x - ui.colWidth(), .y = avail.y }, 0, im.ImGuiWindowFlags_NoBackground)) {
            if (im.ImGui_BeginTabBar("##startupTabs", im.ImGuiTabBarFlags_DrawSelectedOverline)) { // the kit tab look: mint overline
                for (tab_titles, tab_ids, 0..) |t, id, i| {
                    var lb: [96]u8 = undefined;
                    if (!im.ImGui_BeginTabItem(ui.z(&lb, "{s}##{s}", .{ t, id }).ptr, null, 0)) continue;
                    v.cur = i;
                    im.ImGui_EndTabItem();
                }
                im.ImGui_EndTabBar();
            }
            v.list(v.cur);
        }
        im.ImGui_EndChild();

        im.ImGui_SameLineEx(0, 12 * s);
        im.ImGui_BeginGroup();
        const it = v.selected();
        if (ui.colButton("Enable##startupEnable", !busy and it != null and !it.?.enabled)) v.start(.enable, it);
        if (ui.colButton("Disable##startupDisable", !busy and it != null and it.?.enabled)) v.start(.disable, it);
        const can_delete = it != null and !(it.?.kind == .service and startup.isSystemService(it.?));
        if (ui.colButton("Delete##startupDelete", !busy and can_delete))
            v.dlg.confirm(tag_delete, "Delete", "Delete \"{s}\"?\nThis cannot be undone.", .{it.?.name});
        im.ImGui_Dummy(.{ .x = 0, .y = 8 * s });
        if (ui.colButton("Refresh##startupRefresh", !busy)) v.start(.none, null);
        if (ui.colButton("Save to text file##startupSave", true)) v.save(ctx);
        im.ImGui_EndGroup();
    }

    fn list(v: *View, t: usize) void {
        const s = ui.scale();
        var lb: [64]u8 = undefined;
        if (!im.ImGui_BeginTableEx(ui.z(&lb, "##{s}", .{tab_ids[t]}).ptr, 4, ui.table_flags | im.ImGuiTableFlags_RowBg, .{ .x = 0, .y = 0 }, 0)) return;
        defer im.ImGui_EndTable();
        im.ImGui_TableSetupScrollFreeze(0, 1);
        im.ImGui_TableSetupColumnEx("Enabled", im.ImGuiTableColumnFlags_WidthFixed, 70 * s, 0);
        im.ImGui_TableSetupColumnEx("Name", 0, 230 * s, 0);
        im.ImGui_TableSetupColumnEx("Location", 0, 250 * s, 0);
        im.ImGui_TableSetupColumnEx("Command", 0, 380 * s, 0);
        im.ImGui_TableHeadersRow();
        const tab = v.shown(t) orelse {
            im.ImGui_TableNextRow();
            _ = im.ImGui_TableSetColumnIndex(1);
            ui.cell("Loading...", "{s}Loading", .{tab_ids[t]});
            return;
        };
        if (tab.err) |e| {
            im.ImGui_TableNextRow();
            _ = im.ImGui_TableSetColumnIndex(1);
            var eb: [512]u8 = undefined;
            _ = im.ImGui_Selectable(ui.idLabel(&eb, e, "{s}Err", .{tab_ids[t]}).ptr);
            return;
        }
        var clip = std.mem.zeroes(im.ImGuiListClipper);
        im.ImGuiListClipper_Begin(&clip, @intCast(tab.items.len), -1);
        defer im.ImGuiListClipper_End(&clip);
        while (im.ImGuiListClipper_Step(&clip)) {
            var r: usize = @intCast(clip.DisplayStart);
            while (r < clip.DisplayEnd) : (r += 1) {
                const it = &tab.items[r];
                im.ImGui_TableNextRow();
                // the row selectable (Name cell, automation label "name##st<tab>_<row>") goes first so it keeps the
                // mouse over the whole row; then the other cells "<text>##st<tab>_<row><en|loc|cmd>"
                _ = im.ImGui_TableSetColumnIndex(1);
                var nb: [1100]u8 = undefined;
                const cw = im.ImGui_GetContentRegionAvail().x;
                if (im.ImGui_SelectableEx(ui.idLabel(&nb, it.name, "st{d}_{d}", .{ t, r }).ptr, v.loaded and v.sel[t] == r, im.ImGuiSelectableFlags_SpanAllColumns, .{ .x = 0, .y = 0 }) and v.loaded) v.sel[t] = r;
                ui.rowTip(it.name, cw);
                _ = im.ImGui_TableSetColumnIndex(0);
                ui.cell(enabledText(it), "st{d}_{d}en", .{ t, r });
                _ = im.ImGui_TableSetColumnIndex(2);
                ui.cell(it.location, "st{d}_{d}loc", .{ t, r });
                _ = im.ImGui_TableSetColumnIndex(3);
                ui.cell(it.command, "st{d}_{d}cmd", .{ t, r });
            }
        }
    }
};
