//! Tools > Duplicate Finder (legacy DuplicatesView): setup form -> grouped results (Back returns to the form).
//! Search runs on a job and doubles as Cancel; the file count is sampled every 200 ms.
const std = @import("std");
const kit = @import("kit");
const Ctx = @import("ctx.zig").Ctx;
const ui = @import("tools_ui.zig");
const rules_fs = @import("../core/rules_fs.zig");
const duplicates = @import("../core/duplicates.zig");
const engine = @import("../core/engine.zig");
const bytes = @import("../core/bytes.zig");
const FileInfo = @import("../core/common.zig").FileInfo;
const T = @import("../i18n/tr.zig");
const tr = T.tr;

const im = kit.im;
const max_groups = 2000;
const tag_delete = 1;

/// One list line: a group header or a file of that group.
const Row = struct { group: u32, file: ?u32 };

pub const View = struct {
    io: std.Io,
    job: kit.jobs.Job = .{},
    // form
    by_name: bool = true,
    by_size: bool = true,
    by_date: bool = true,
    by_content: bool = false,
    no_empty: bool = true,
    no_system: bool = true,
    no_hidden: bool = true,
    no_read_only: bool = false,
    min_mb: ui.Buf(16) = .{},
    max_mb: ui.Buf(16) = .{},
    include: ui.Buf(2048) = .{},
    exclude: ui.Buf(2048) = .{},
    // job in/out (worker-owned while running)
    opts: duplicates.DupOptions = .{},
    next_arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
    next_groups: []const []const FileInfo = &.{},
    // results
    arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
    groups: []const []const FileInfo = &.{},
    rows: std.ArrayList(Row) = .empty,
    checked: std.ArrayList(bool) = .empty, // per row (headers unused)
    sel: ?usize = null,
    results: bool = false,
    status: ui.Text(256) = .{},
    seen: u64 = 0,
    seen_at: u64 = 0,
    // Delete Selected on the job (gpa-owned while it runs)
    deleting: bool = false,
    del_files: []FileInfo = &.{},
    gone: []bool = &.{},
    del_result: engine.CleanResult = .{},
    dlg: ui.Dialog = .{},

    pub fn create(ctx: *Ctx) !*View {
        const v = try ctx.gpa.create(View);
        v.* = .{ .io = ctx.io };
        v.min_mb.set("0");
        v.max_mb.set("0");
        if (kit.win.getEnv(ctx.gpa, "USERPROFILE") catch null) |p| {
            defer ctx.gpa.free(p);
            v.include.set(p);
        }
        if (kit.win.knownFolder(ctx.gpa, &kit.w.FOLDERID_Windows) catch null) |p| {
            defer ctx.gpa.free(p);
            v.exclude.set(p);
        }
        return v;
    }

    pub fn destroy(v: *View, ctx: *Ctx) void {
        v.job.cancel();
        v.job.join();
        v.freeDelete(ctx.gpa);
        v.arena.deinit();
        v.next_arena.deinit();
        v.rows.deinit(ctx.gpa);
        v.checked.deinit(ctx.gpa);
        ctx.gpa.destroy(v);
    }

    fn mb(b: anytype) u64 {
        const n = std.fmt.parseInt(i64, b.trimmed(), 10) catch return 0;
        return if (n > 0) @as(u64, @intCast(n)) << 20 else 0;
    }

    /// Reads the form into `opts` (strings copied into next_arena) and starts the job.
    fn search(v: *View) void {
        if (v.job.thread != null) return;
        _ = v.next_arena.reset(.free_all);
        const a = v.next_arena.allocator();
        const inc = a.dupe(u8, v.include.slice()) catch return;
        const exc = a.dupe(u8, v.exclude.slice()) catch return;
        const max = mb(&v.max_mb);
        v.opts = .{
            .include = duplicates.scan.splitPaths(a, inc) catch return,
            .exclude = duplicates.scan.splitPaths(a, exc) catch return,
            .by_name = v.by_name,
            .by_size = v.by_size,
            .by_date = v.by_date,
            .by_content = v.by_content,
            .ignore_empty = v.no_empty,
            .ignore_system = v.no_system,
            .ignore_hidden = v.no_hidden,
            .ignore_read_only = v.no_read_only,
            .min_size = mb(&v.min_mb),
            .max_size = if (max > 0) max else std.math.maxInt(u64),
        };
        v.seen = 0;
        v.seen_at = kit.w.GetTickCount64();
        v.status.set("{s}", .{tr().common.scanning});
        v.job.start(v, worker) catch {};
    }

    fn worker(job: *kit.jobs.Job) anyerror!void {
        const v = job.ctx(View);
        const r = try duplicates.find(v.next_arena.allocator(), v.io, v.opts, &job.cancel_flag, ui.jobProgress(job));
        v.next_groups = r.groups;
    }

    fn waste(g: []const FileInfo) u64 {
        return g[0].size * (g.len - 1);
    }

    fn show(v: *View, gpa: std.mem.Allocator) void {
        std.mem.swap(std.heap.ArenaAllocator, &v.arena, &v.next_arena);
        _ = v.next_arena.reset(.free_all);
        const all = v.next_groups;
        var total_files: usize = 0;
        var wasted: u64 = 0;
        for (all) |g| {
            total_files += g.len;
            wasted += waste(g);
        }
        // ponytail: capped at 2000 groups, biggest waste first; paging if someone has more
        const sorted = v.arena.allocator().dupe([]const FileInfo, all) catch all;
        std.mem.sort([]const FileInfo, @constCast(sorted), {}, struct {
            fn more(_: void, a: []const FileInfo, b: []const FileInfo) bool {
                return waste(a) > waste(b);
            }
        }.more);
        v.groups = sorted[0..@min(sorted.len, max_groups)];
        v.rows.clearRetainingCapacity();
        for (v.groups, 0..) |g, gi| {
            v.rows.append(gpa, .{ .group = @intCast(gi), .file = null }) catch {};
            for (0..g.len) |fi| v.rows.append(gpa, .{ .group = @intCast(gi), .file = @intCast(fi) }) catch {};
        }
        v.checked.resize(gpa, v.rows.items.len) catch {};
        @memset(v.checked.items, false);
        v.sel = null;
        var b1: [96]u8 = undefined;
        var b2: [64]u8 = undefined;
        v.status.tset(tr().dupes.found, .{ T.n(&b1, tr().dupes.groups, all.len, all.len), T.n(&b2, tr().common.files, total_files, total_files), bytes.fmt(wasted) });
        v.results = true;
    }

    fn file(v: *View, r: Row) FileInfo {
        return v.groups[r.group][r.file.?];
    }

    fn selectAllButFirst(v: *View) void {
        for (v.rows.items, v.checked.items) |r, *c| c.* = if (r.file) |f| f > 0 else false;
    }

    fn picked(v: *View, gpa: std.mem.Allocator) []FileInfo {
        var out: std.ArrayList(FileInfo) = .empty;
        for (v.rows.items, v.checked.items) |r, c| if (c and r.file != null) out.append(gpa, v.file(r)) catch {};
        return out.toOwnedSlice(gpa) catch &.{};
    }

    /// Delete Selected: Engine.Clean on the ticked files on the job (C# did it on the UI thread); `deleted` then
    /// drops the rows whose file is gone.
    fn delete(v: *View, gpa: std.mem.Allocator) void {
        if (v.job.thread != null) return;
        v.del_files = v.picked(gpa);
        v.gone = gpa.alloc(bool, v.rows.items.len) catch return v.freeDelete(gpa);
        v.deleting = true;
        v.status.tset(kit.i18n.pick(tr().common.deleting_files, v.del_files.len), .{v.del_files.len});
        v.job.start(v, delWorker) catch {
            v.deleting = false;
            v.freeDelete(gpa);
        };
    }

    fn delWorker(job: *kit.jobs.Job) anyerror!void {
        const v = job.ctx(View);
        v.del_result = engine.clean(std.heap.smp_allocator, v.io, v.del_files, 0);
        for (v.rows.items, v.gone) |row, *g| g.* = row.file != null and !rules_fs.exists(v.file(row).path);
    }

    fn freeDelete(v: *View, gpa: std.mem.Allocator) void {
        gpa.free(v.del_files);
        gpa.free(v.gone);
        v.del_files = &.{};
        v.gone = &.{};
    }

    /// Rows whose file is gone leave the list (headers stay, as the ListCollectionView group headers did until
    /// their group emptied).
    fn deleted(v: *View, gpa: std.mem.Allocator) void {
        defer v.freeDelete(gpa);
        const r = v.del_result;
        var n: usize = 0;
        for (v.rows.items, v.checked.items, v.gone) |row, c, g| {
            if (g) continue;
            v.rows.items[n] = row;
            v.checked.items[n] = c;
            n += 1;
        }
        // drop headers left without files
        var m: usize = 0;
        for (0..n) |i| {
            const row = v.rows.items[i];
            if (row.file == null and (i + 1 >= n or v.rows.items[i + 1].file == null)) continue;
            v.rows.items[m] = row;
            v.checked.items[m] = v.checked.items[i];
            m += 1;
        }
        v.rows.shrinkRetainingCapacity(m);
        v.checked.shrinkRetainingCapacity(m);
        v.sel = null;
        var fb: [64]u8 = undefined;
        v.status.tset(tr().common.deleted, .{ T.n(&fb, tr().common.files, r.deleted, r.deleted), bytes.fmt(r.bytes_freed), r.skipped });
    }

    pub fn draw(v: *View, ctx: *Ctx) void {
        const s = ui.scale();
        if (v.job.takeFinished()) {
            var eb: [512]u8 = undefined;
            if (v.deleting) {
                v.deleting = false;
                v.deleted(ctx.gpa);
            } else if (v.job.cancelled()) {
                v.status.set("{s}", .{tr().common.cancelled});
            } else if (v.job.errorText(&eb)) |e| {
                v.status.tset(tr().common.failed, .{e});
            } else v.show(ctx.gpa);
        }
        if (v.job.isRunning() and !v.deleting) {
            const now = kit.w.GetTickCount64();
            if (now -% v.seen_at >= 200) {
                v.seen = v.job.done.load(.acquire);
                v.seen_at = now;
                var nb: [32]u8 = undefined;
                var fb: [64]u8 = undefined;
                v.status.tset(tr().common.scanning_n, .{T.n(&fb, tr().common.files, v.seen, ui.n0(&nb, v.seen))});
            }
            ctx.app.requestFrames(2);
        }
        if (v.dlg.draw()) |ans| if (ans.tag == tag_delete and ans.button == 0) v.delete(ctx.gpa);

        const avail = im.ImGui_GetContentRegionAvail();
        const status_h = im.ImGui_GetFontSize() * 2 + ui.sp() + 2 * s;
        if (im.ImGui_BeginChild("##dupBody", .{ .x = 0, .y = avail.y - status_h }, 0, im.ImGuiWindowFlags_NoBackground)) {
            if (v.results) v.drawResults(ctx) else v.drawSetup(ctx);
        }
        im.ImGui_EndChild();
        ui.status("dupStatus", v.status.slice(), ui.pal.text);
    }

    fn drawSetup(v: *View, ctx: *Ctx) void {
        const s = ui.scale();
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ChildBg, ui.col(ui.pal.surface));
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Border, ui.col(ui.pal.line));
        im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_WindowPadding, .{ .x = 16 * s, .y = 12 * s });
        im.ImGui_PushStyleVar(im.ImGuiStyleVar_ChildRounding, 4 * s);
        if (im.ImGui_BeginChild("##dupForm", .{ .x = 0, .y = 0 }, im.ImGuiChildFlags_Borders | im.ImGuiChildFlags_AutoResizeY, 0)) { // as tall as the form, Search right under it
            const col2 = 110 * s;
            const busy = v.job.isRunning();
            const d = &tr().dupes;
            var lb: [128]u8 = undefined;
            im.ImGui_BeginDisabled(busy);
            const wrap_x = im.ImGui_GetCursorPosX() + col2; // a checkbox that does not fit wraps under the first one
            head(d.match_by, col2);
            check(&lb, d.by_name, "byName", &v.by_name, null);
            check(&lb, d.by_size, "bySize", &v.by_size, wrap_x);
            check(&lb, d.by_date, "byDate", &v.by_date, wrap_x);
            check(&lb, d.by_content, "byContent", &v.by_content, wrap_x);

            head(d.ignore, col2);
            check(&lb, d.zero_byte, "noEmpty", &v.no_empty, null);
            check(&lb, d.system, "noSystem", &v.no_system, wrap_x);
            check(&lb, d.hidden, "noHidden", &v.no_hidden, wrap_x);
            check(&lb, d.read_only, "noReadOnly", &v.no_read_only, wrap_x);

            head(d.size_mb, col2);
            ui.label(d.from);
            im.ImGui_SameLine();
            _ = v.min_mb.input("##dupMinMb", 70 * s);
            im.ImGui_SameLineEx(0, 10 * s);
            ui.label(d.to);
            im.ImGui_SameLine();
            _ = v.max_mb.input("##dupMaxMb", 70 * s);
            im.ImGui_SameLineEx(0, 10 * s);
            im.ImGui_AlignTextToFramePadding();
            ui.muted(d.no_limit);

            const browse_w = 100 * s;
            head(d.search_in, col2);
            _ = v.include.input("##dupInclude", im.ImGui_GetContentRegionAvail().x - browse_w - 8 * s);
            im.ImGui_SameLineEx(0, 8 * s);
            if (im.ImGui_ButtonEx(ui.idLabel(&lb, tr().common.browse, "dupIncludeBrowse", .{}).ptr, .{ .x = browse_w, .y = 0 })) ui.pickFolder(ctx, 2048, &v.include, true);

            head(d.skip, col2);
            _ = v.exclude.input("##dupExclude", im.ImGui_GetContentRegionAvail().x - browse_w - 8 * s);
            im.ImGui_SameLineEx(0, 8 * s);
            if (im.ImGui_ButtonEx(ui.idLabel(&lb, tr().common.browse, "dupExcludeBrowse", .{}).ptr, .{ .x = browse_w, .y = 0 })) ui.pickFolder(ctx, 2048, &v.exclude, true);
            im.ImGui_EndDisabled();

            im.ImGui_Dummy(.{ .x = 0, .y = 10 * s });
            ui.mutedWrapped(d.hint, im.ImGui_GetContentRegionAvail().x);
        }
        im.ImGui_EndChild();
        im.ImGui_PopStyleVarEx(2);
        im.ImGui_PopStyleColorEx(2);

        var sb: [128]u8 = undefined;
        const label = ui.idLabel(&sb, if (v.job.isRunning()) tr().common.cancel else tr().dupes.search, "dupSearch", .{});
        im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + im.ImGui_GetContentRegionAvail().x - 90 * s);
        if (ui.primary(label.ptr, true)) {
            if (v.job.isRunning()) v.job.cancel() else v.search();
        }
    }

    /// A form checkbox "text##id"; `wrap_x` != null: after the previous one, on the same line if it fits.
    fn check(lb: []u8, text: []const u8, comptime id: []const u8, val: *bool, wrap_x: ?f32) void {
        const l = ui.idLabel(lb, text, id, .{});
        if (wrap_x) |x| ui.sameLineOrWrap(ui.checkboxW(l), 18 * ui.scale(), x);
        _ = kit.ui.checkbox(l.ptr, val);
        kit.ui.checkboxTooltip(l.ptr, null); // still cut on a very narrow window: full text on hover
    }

    /// Bold row caption in the 110 px label column.
    fn head(text: [*:0]const u8, width: f32) void {
        im.ImGui_Dummy(.{ .x = 0, .y = 2 * ui.scale() });
        const x = im.ImGui_GetCursorPosX();
        im.ImGui_AlignTextToFramePadding();
        im.ImGui_PushFontFloat(kit.app.current().?.fonts.bold, 0);
        im.ImGui_TextUnformatted(text);
        im.ImGui_PopFont();
        im.ImGui_SameLineEx(x + width, 0);
    }

    fn drawResults(v: *View, ctx: *Ctx) void {
        const s = ui.scale();
        const avail = im.ImGui_GetContentRegionAvail();
        if (im.ImGui_BeginTableEx("##dupList", 5, ui.table_flags, .{ .x = avail.x - ui.colWidth(), .y = avail.y }, 0)) {
            im.ImGui_TableSetupScrollFreeze(0, 1);
            im.ImGui_TableSetupColumnEx("##chk", im.ImGuiTableColumnFlags_WidthFixed | im.ImGuiTableColumnFlags_NoResize, 26 * s, 0);
            const c = &tr().common;
            im.ImGui_TableSetupColumnEx(c.col_name, 0, 160 * s, 0);
            im.ImGui_TableSetupColumnEx(c.col_size, im.ImGuiTableColumnFlags_WidthFixed, 72 * s, 0);
            im.ImGui_TableSetupColumnEx(c.col_modified, im.ImGuiTableColumnFlags_WidthFixed, 118 * s, 0);
            im.ImGui_TableSetupColumnEx(c.col_folder, 0, 420 * s, 0);
            im.ImGui_TableHeadersRow();
            var clip = std.mem.zeroes(im.ImGuiListClipper);
            im.ImGuiListClipper_Begin(&clip, @intCast(v.rows.items.len), -1);
            while (im.ImGuiListClipper_Step(&clip)) {
                var i: usize = @intCast(clip.DisplayStart);
                while (i < clip.DisplayEnd) : (i += 1) v.drawRow(ctx, i);
            }
            im.ImGuiListClipper_End(&clip);
            im.ImGui_EndTable();
        }
        im.ImGui_SameLineEx(0, 12 * s);
        im.ImGui_BeginGroup();
        const idle = !v.job.isRunning();
        const d = &tr().dupes;
        var lb: [128]u8 = undefined;
        if (ui.colButton(ui.idLabel(&lb, d.select_but_first, "dupSelect", .{}).ptr, idle)) v.selectAllButFirst();
        if (ui.colButton(ui.idLabel(&lb, d.delete_selected, "dupDelete", .{}).ptr, idle)) {
            var n: usize = 0;
            for (v.rows.items, v.checked.items) |r, ck| n += @intFromBool(ck and r.file != null);
            const c = &tr().common;
            if (n > 0) v.dlg.showT(tag_delete, c.delete_files_title, .danger, &.{ c.delete, c.cancel }, kit.i18n.pick(c.delete_files_q, n), .{n});
        }
        if (ui.colButton(ui.idLabel(&lb, d.back, "dupBack", .{}).ptr, idle)) v.results = false;
        im.ImGui_EndGroup();
    }

    fn drawRow(v: *View, ctx: *Ctx, i: usize) void {
        const r = v.rows.items[i];
        im.ImGui_TableNextRow();
        _ = im.ImGui_TableNextColumn();
        var lb: [1100]u8 = undefined;
        if (r.file == null) {
            const g = v.groups[r.group];
            _ = im.ImGui_TableNextColumn();
            var hb: [96]u8 = undefined;
            const h = ui.z(&hb, "#{d}: {d} x {f}", .{ r.group + 1, g.len, bytes.fmt(g[0].size) });
            // automation item "#1: 2 x 48.83 KB##dupGroup0"; the text spans the row: widen the clip past the Name
            // column (own draw cmd, so the table does not merge this column's clip rect away)
            const p = im.ImGui_GetCursorScreenPos();
            _ = im.ImGui_InvisibleButton(ui.idLabel(&lb, h, "dupGroup{d}", .{r.group}).ptr, .{ .x = @max(1, im.ImGui_GetContentRegionAvail().x), .y = im.ImGui_GetTextLineHeight() }, 0);
            const right = im.ImGui_GetWindowPos().x + im.ImGui_GetWindowWidth();
            im.ImGui_PushClipRect(p, .{ .x = right, .y = p.y + im.ImGui_GetFontSize() + 4 }, false);
            im.ImDrawList_AddTextImFontPtr(im.ImGui_GetWindowDrawList(), ctx.app.fonts.bold, im.ImGui_GetFontSize(), p, kit.app.colorU32(ui.pal.muted), h.ptr);
            im.ImGui_PopClipRect();
            return;
        }
        const f = v.file(r);
        // "##<full path>##dupChk<i>": no visible text, the path tells a test which file the box belongs to
        // (WPF: AutomationProperties.Name)
        lb[0] = '#';
        lb[1] = '#';
        const chk = ui.idLabel(lb[2..], f.path, "dupChk{d}", .{i});
        im.ImGui_BeginDisabled(v.job.isRunning());
        _ = kit.ui.checkbox(lb[0 .. chk.len + 2 :0], &v.checked.items[i]);
        im.ImGui_EndDisabled();
        _ = im.ImGui_TableNextColumn();
        const name = std.fs.path.basename(f.path);
        const cw = im.ImGui_GetContentRegionAvail().x;
        if (im.ImGui_SelectableEx(ui.idLabel(&lb, name, "dupRow{d}", .{i}).ptr, v.sel == i, im.ImGuiSelectableFlags_SpanAllColumns | im.ImGuiSelectableFlags_AllowDoubleClick, .{ .x = 0, .y = 0 })) {
            v.sel = i;
            if (im.ImGui_IsMouseDoubleClicked(0)) ui.openFolder(ctx.gpa, f.path);
        }
        ui.rowTip(name, cw);
        var sb: [32]u8 = undefined;
        var db: [64]u8 = undefined;
        // cells "<text>##dupRow<i><s|m|f>" (Size, Modified, Folder)
        inline for (.{ std.mem.print(&sb, "{f}", .{bytes.fmt(f.size)}) catch "", ui.fmtStamp(&db, f.mtime), std.fs.path.dirname(f.path) orelse "" }, .{ "s", "m", "f" }) |c, id| {
            _ = im.ImGui_TableNextColumn();
            ui.cell(c, "dupRow{d}" ++ id, .{i});
        }
    }
};
