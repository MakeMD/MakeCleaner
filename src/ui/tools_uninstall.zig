//! Tools > Uninstall (legacy UninstallView): search + count, Program/Publisher/Installed On/Size/Version,
//! Run Uninstaller / Repair / Change / Delete entry (confirm) / Refresh / Save to text file.
const std = @import("std");
const kit = @import("kit");
const Ctx = @import("ctx.zig").Ctx;
const ui = @import("tools_ui.zig");
const uninstall = @import("../core/uninstall.zig");
const bytes = @import("../core/bytes.zig");
const T = @import("../i18n/tr.zig");
const tr = T.tr;

const im = kit.im;
const InstalledApp = uninstall.InstalledApp;

const tag_delete = 1;
const tag_info = 2;

pub const View = struct {
    job: kit.jobs.Job = .{},
    /// Owns `apps`; replaced as a whole when a reload finishes.
    arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
    apps: []InstalledApp = &.{},
    next_arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
    next_apps: []InstalledApp = &.{},
    err: ?[]const u8 = null,
    err_buf: [512]u8 = undefined,
    search: ui.Buf(256) = .{},
    shown: std.ArrayList(u32) = .empty,
    sel: ?u32 = null,
    can: [3]bool = .{ false, false, false },
    dlg: ui.Dialog = .{},

    pub fn create(ctx: *Ctx) !*View {
        const v = try ctx.gpa.create(View);
        v.* = .{};
        v.reload();
        return v;
    }

    pub fn destroy(v: *View, ctx: *Ctx) void {
        v.job.cancel();
        v.job.join();
        v.arena.deinit();
        v.next_arena.deinit();
        v.shown.deinit(ctx.gpa);
        ctx.gpa.destroy(v);
    }

    fn reload(v: *View) void {
        if (v.job.thread != null) return;
        _ = v.next_arena.reset(.free_all);
        v.job.start(v, worker) catch {};
    }

    fn worker(job: *kit.jobs.Job) anyerror!void {
        const v = job.ctx(View);
        v.next_apps = try uninstall.read(v.next_arena.allocator(), &uninstall.roots);
    }

    fn fill(v: *View, gpa: std.mem.Allocator) void {
        v.shown.clearRetainingCapacity();
        v.sel = null;
        var nb: [256]u16 = undefined;
        const q = v.search.trimmed();
        const qn = std.unicode.wtf8ToWtf16Le(&nb, q[0..@min(q.len, 128)]) catch 0;
        for (v.apps, 0..) |*a, i| {
            if (ui.containsCi(a.name, nb[0..qn]) or ui.containsCi(a.publisher, nb[0..qn])) v.shown.append(gpa, @intCast(i)) catch {};
        }
        v.updateButtons(gpa);
    }

    fn selected(v: *View) ?*const InstalledApp {
        return if (v.sel) |i| &v.apps[i] else null;
    }

    fn updateButtons(v: *View, gpa: std.mem.Allocator) void {
        const a = v.selected() orelse {
            v.can = .{ false, false, false };
            return;
        };
        inline for (.{ InstalledApp.uninstallCommand, InstalledApp.repairCommand, InstalledApp.changeCommand }, 0..) |f, i| {
            const c = f(a, gpa) catch null;
            v.can[i] = c != null;
            if (c) |s| gpa.free(s);
        }
    }

    fn run(v: *View, ctx: *Ctx, which: usize) void {
        const a = v.selected() orelse return;
        const cmd = (switch (which) {
            0 => a.uninstallCommand(ctx.gpa),
            1 => a.repairCommand(ctx.gpa),
            else => a.changeCommand(ctx.gpa),
        } catch null) orelse return;
        defer ctx.gpa.free(cmd);
        uninstall.launch(ctx.gpa, cmd) catch |e| v.dlg.info(tag_info, a.name, "{0}", .{kit.win.errText(e)});
    }

    fn save(v: *View, ctx: *Ctx) void {
        var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var lines: std.ArrayList([]const u8) = .empty;
        const u = &tr().uninstall;
        lines.append(a, a.print("{s}\t{s}\t{s}\t{s}\t{s}", .{ u.col_program, u.col_publisher, u.col_installed, tr().common.col_size, u.col_version }) catch return) catch return;
        for (v.shown.items) |i| {
            const app = &v.apps[i];
            var db: [64]u8 = undefined;
            var sb: [32]u8 = undefined;
            lines.append(a, a.print("{s}\t{s}\t{s}\t{s}\t{s}", .{ app.name, app.publisher, ui.fmtInstallDate(&db, app.install_date), sizeText(&sb, app.size_kb), app.version }) catch return) catch return;
        }
        ui.saveText(ctx, &v.dlg, "programs", lines.items);
    }

    /// EstimatedSize (KB) as Bytes.Fmt ("512 KB", "1.5 GB"); the C# column was always "0.# MB".
    fn sizeText(buf: []u8, kb: i64) []const u8 {
        if (kb <= 0) return "";
        return std.mem.print(buf, "{f}", .{bytes.fmt(@as(u64, @intCast(kb)) * 1024)}) catch "";
    }

    pub fn draw(v: *View, ctx: *Ctx) void {
        const s = ui.scale();
        if (v.job.takeFinished()) {
            std.mem.swap(std.heap.ArenaAllocator, &v.arena, &v.next_arena);
            v.err = if (v.job.errorText(&v.err_buf)) |e| e else null;
            v.apps = if (v.err == null) v.next_apps else &.{};
            _ = v.next_arena.reset(.free_all);
            v.fill(ctx.gpa);
        }
        if (v.dlg.draw()) |ans| if (ans.tag == tag_delete and ans.button == 0) {
            if (v.selected()) |a| {
                const ok = uninstall.deleteEntry(ctx.gpa, a) catch false;
                if (!ok) v.dlg.info(tag_info, tr().uninstall.delete_entry, tr().uninstall.not_deleted, .{});
                v.reload();
            }
        };

        const avail = im.ImGui_GetContentRegionAvail();
        const list_w = avail.x - ui.colWidth();
        if (im.ImGui_BeginChild("##uninstallMain", .{ .x = list_w, .y = avail.y }, 0, im.ImGuiWindowFlags_NoBackground)) {
            // search row: "Search" [box] count
            ui.label(tr().uninstall.search);
            im.ImGui_SameLine();
            var cb: [96]u8 = undefined;
            var eb: [600]u8 = undefined;
            const n = v.shown.items.len;
            const count: []const u8 = if (v.err) |e| T.fmt(&eb, tr().common.err, .{e}) else if (v.job.isRunning() and v.apps.len == 0) tr().common.loading else T.n(&cb, tr().uninstall.programs, n, n);
            const count_w = @max(110 * s, im.ImGui_CalcTextSizeEx(count.ptr, count.ptr + count.len, false, -1).x) + 12 * s;
            if (v.search.input("##uninstallSearch", im.ImGui_GetContentRegionAvail().x - count_w)) v.fill(ctx.gpa);
            im.ImGui_SameLineEx(0, 12 * s);
            ui.status("uninstallCount", count, ui.pal.muted);
            im.ImGui_Dummy(.{ .x = 0, .y = 2 * s });
            v.table(ctx);
        }
        im.ImGui_EndChild();

        im.ImGui_SameLineEx(0, 12 * s);
        im.ImGui_BeginGroup();
        const has = v.sel != null;
        const u = &tr().uninstall;
        var lb: [128]u8 = undefined;
        if (ui.colButton(ui.idLabel(&lb, u.run, "uninstallRun", .{}).ptr, v.can[0])) v.run(ctx, 0);
        if (ui.colButton(ui.idLabel(&lb, u.repair, "uninstallRepair", .{}).ptr, v.can[1])) v.run(ctx, 1);
        if (ui.colButton(ui.idLabel(&lb, u.change, "uninstallChange", .{}).ptr, v.can[2])) v.run(ctx, 2);
        if (ui.colButton(ui.idLabel(&lb, u.delete_entry, "uninstallDelete", .{}).ptr, has)) if (v.selected()) |a|
            v.dlg.confirm(tag_delete, u.delete_entry, u.delete_entry_q, .{a.name});
        im.ImGui_Dummy(.{ .x = 0, .y = 8 * s });
        if (ui.colButton(ui.idLabel(&lb, tr().common.refresh, "uninstallRefresh", .{}).ptr, !v.job.isRunning())) v.reload();
        if (ui.colButton(ui.idLabel(&lb, tr().common.save_text, "uninstallSave", .{}).ptr, true)) v.save(ctx);
        im.ImGui_EndGroup();
    }

    fn table(v: *View, ctx: *Ctx) void {
        if (!im.ImGui_BeginTableEx("##uninstallList", 5, ui.table_flags | im.ImGuiTableFlags_RowBg, .{ .x = 0, .y = 0 }, 0)) return;
        defer im.ImGui_EndTable();
        const s = ui.scale();
        im.ImGui_TableSetupScrollFreeze(0, 1);
        const u = &tr().uninstall;
        im.ImGui_TableSetupColumnEx(u.col_program, 0, 300 * s, 0);
        im.ImGui_TableSetupColumnEx(u.col_publisher, 0, 190 * s, 0);
        im.ImGui_TableSetupColumnEx(u.col_installed, im.ImGuiTableColumnFlags_WidthFixed, 82 * s, 0);
        im.ImGui_TableSetupColumnEx(tr().common.col_size, im.ImGuiTableColumnFlags_WidthFixed, 72 * s, 0);
        im.ImGui_TableSetupColumnEx(u.col_version, im.ImGuiTableColumnFlags_WidthFixed, 82 * s, 0);
        im.ImGui_TableHeadersRow();
        var clip = std.mem.zeroes(im.ImGuiListClipper);
        im.ImGuiListClipper_Begin(&clip, @intCast(v.shown.items.len), -1);
        defer im.ImGuiListClipper_End(&clip);
        while (im.ImGuiListClipper_Step(&clip)) {
            var r: usize = @intCast(clip.DisplayStart);
            while (r < clip.DisplayEnd) : (r += 1) {
                const idx = v.shown.items[r];
                const a = &v.apps[idx];
                im.ImGui_TableNextRow();
                _ = im.ImGui_TableNextColumn();
                var lb: [1100]u8 = undefined;
                const cw = im.ImGui_GetContentRegionAvail().x;
                if (im.ImGui_SelectableEx(ui.idLabel(&lb, a.name, "u{d}", .{idx}).ptr, v.sel == idx, im.ImGuiSelectableFlags_SpanAllColumns, .{ .x = 0, .y = 0 })) {
                    v.sel = idx;
                    v.updateButtons(ctx.gpa);
                }
                ui.rowTip(a.name, cw);
                var db: [64]u8 = undefined;
                var sb: [32]u8 = undefined;
                // cell labels "<text>##u<idx><p|d|s|v>" (Publisher, Installed On, Size, Version)
                inline for (.{ a.publisher, ui.fmtInstallDate(&db, a.install_date), sizeText(&sb, a.size_kb), a.version }, .{ "p", "d", "s", "v" }) |t, c| {
                    _ = im.ImGui_TableNextColumn();
                    ui.cell(t, "u{d}" ++ c, .{idx});
                }
            }
        }
    }
};
