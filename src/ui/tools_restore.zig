//! Tools > System Restore (legacy RestoreView): list restore points (newest first), remove any but the most
//! recent one. WMI denies both without admin: "Restart as admin" appears on access denied.
const std = @import("std");
const kit = @import("kit");
const Ctx = @import("ctx.zig").Ctx;
const ui = @import("tools_ui.zig");
const rp = @import("../core/restorepoints.zig");

const im = kit.im;
const Point = rp.RestorePoint;

const tag_confirm = 1;
const tag_admin = 2;

pub const View = struct {
    job: kit.jobs.Job = .{},
    next_arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
    next_points: []Point = &.{},
    arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
    points: []Point = &.{},
    sel: ?usize = null,
    show_admin: bool = false,
    status: ui.Text(300) = .{},
    /// Remove: the worker removes `remove_seq` (WMI/srclient, can be slow) before listing again; `remove_rc` is
    /// shown after the reload (Reload overwrites the status first, as in C#).
    remove_seq: ?u32 = null,
    remove_rc: u32 = 0,
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
        ctx.gpa.destroy(v);
    }

    fn reload(v: *View) void {
        if (v.job.thread != null) return;
        v.sel = null;
        _ = v.next_arena.reset(.free_all);
        v.job.start(v, worker) catch {};
    }

    fn worker(job: *kit.jobs.Job) anyerror!void {
        const v = job.ctx(View);
        if (v.remove_seq) |seq| v.remove_rc = rp.remove(seq);
        v.remove_seq = null;
        const pts = try rp.list(v.next_arena.allocator());
        std.mem.sort(Point, pts, {}, struct {
            fn newer(_: void, a: Point, b: Point) bool {
                return a.seq > b.seq;
            }
        }.newer);
        v.next_points = pts;
    }

    fn picked(v: *View) ?*const Point {
        return if (v.sel) |i| &v.points[i] else null;
    }

    pub fn draw(v: *View, ctx: *Ctx) void {
        const s = ui.scale();
        if (v.job.takeFinished()) {
            var eb: [256]u8 = undefined;
            if (v.job.errorText(&eb)) |e| {
                v.points = &.{};
                if (std.mem.eql(u8, e, "AccessDenied")) {
                    v.status.set("Administrator rights are required to list restore points.", .{});
                    v.show_admin = true;
                } else v.status.set("System Restore unavailable: {s}", .{e});
            } else {
                std.mem.swap(std.heap.ArenaAllocator, &v.arena, &v.next_arena);
                _ = v.next_arena.reset(.free_all);
                v.points = v.next_points;
                if (v.points.len == 0) v.status.set("No restore points.", .{}) else v.status.set("{d} restore point(s). The most recent one cannot be removed.", .{v.points.len});
                if (v.remove_rc != 0) v.status.set("Removing failed (error {d}).", .{v.remove_rc});
            }
            v.remove_rc = 0;
        }
        if (v.dlg.draw()) |ans| switch (ans.tag) {
            tag_confirm => if (ans.button == 0) {
                if (ui.requireAdmin(&v.dlg, tag_admin, "Removing a restore point")) if (v.picked()) |p| {
                    if (v.job.thread == null) {
                        v.remove_seq = p.seq;
                        v.status.set("Removing restore point...", .{});
                        v.reload();
                    }
                };
            },
            tag_admin => if (ans.button == 0) ui.restartAsAdmin(ctx),
            else => {},
        };

        const avail = im.ImGui_GetContentRegionAvail();
        const status_h = im.ImGui_GetFontSize() * 2 + ui.sp() + 2 * s;
        const flags = ui.table_flags | im.ImGuiTableFlags_RowBg;
        if (im.ImGui_BeginTableEx("##restorePoints", 2, flags, .{ .x = avail.x - ui.colWidth(), .y = avail.y - status_h }, 0)) {
            im.ImGui_TableSetupScrollFreeze(0, 1);
            im.ImGui_TableSetupColumnEx("Description", 0, 380 * s, 0);
            im.ImGui_TableSetupColumnEx("Date", im.ImGuiTableColumnFlags_WidthFixed, 150 * s, 0);
            im.ImGui_TableHeadersRow();
            for (v.points, 0..) |p, i| {
                im.ImGui_TableNextRow();
                _ = im.ImGui_TableNextColumn();
                var lb: [1100]u8 = undefined;
                if (im.ImGui_SelectableEx(ui.idLabel(&lb, p.description, "rp{d}", .{p.seq}).ptr, v.sel == i, im.ImGuiSelectableFlags_SpanAllColumns, .{ .x = 0, .y = 0 })) v.sel = i;
                _ = im.ImGui_TableNextColumn();
                var db: [64]u8 = undefined;
                const c = p.created;
                const d = ui.fmtUtc(&db, c.year, c.month, c.day, c.hour, c.minute);
                im.ImGui_TextUnformattedEx(d.ptr, d.ptr + d.len);
            }
            im.ImGui_EndTable();
        }
        im.ImGui_SameLineEx(0, 12 * s);
        im.ImGui_BeginGroup();
        const p = v.picked();
        if (ui.colButton("Remove##rpRemove", p != null and rp.canRemove(p.?, v.points) and !v.job.isRunning()))
            v.dlg.show(tag_confirm, "System Restore", .danger, &.{ "Remove", "Cancel" }, "Remove restore point \"{s}\"?", .{p.?.description});
        if (v.show_admin) {
            if (ui.colButton("Restart as admin##rpAdmin", true)) ui.restartAsAdmin(ctx);
            im.ImGui_SetItemTooltipUnformatted("Restart MakeCleaner as administrator");
        }
        im.ImGui_EndGroup();
        ui.status("rpStatus", if (v.job.isRunning() and v.status.len == 0) "Loading..." else v.status.slice(), ui.pal.text);
    }
};
