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
        v.status.set("Scanning...", .{});
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
        v.status.set("Found {d} duplicate groups, {d} files, {f} reclaimable", .{ all.len, total_files, bytes.fmt(wasted) });
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
        v.status.set("Deleting {d} files...", .{v.del_files.len});
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
        v.status.set("Deleted {d} files, {f} freed, {d} skipped", .{ r.deleted, bytes.fmt(r.bytes_freed), r.skipped });
    }

    pub fn draw(v: *View, ctx: *Ctx) void {
        const s = ui.scale();
        if (ui.jobDone(&v.job)) {
            var eb: [256]u8 = undefined;
            if (v.deleting) {
                v.deleting = false;
                v.deleted(ctx.gpa);
            } else if (v.job.cancelled()) {
                v.status.set("Cancelled", .{});
            } else if (v.job.errorText(&eb)) |e| {
                v.status.set("Failed: {s}", .{e});
            } else v.show(ctx.gpa);
        }
        if (v.job.isRunning() and !v.deleting) {
            const now = kit.w.GetTickCount64();
            if (now -% v.seen_at >= 200) {
                v.seen = v.job.done.load(.acquire);
                v.seen_at = now;
                var nb: [32]u8 = undefined;
                v.status.set("Scanning... {s} files", .{ui.n0(&nb, v.seen)});
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
        const avail = im.ImGui_GetContentRegionAvail();
        const btn_h = im.ImGui_GetFrameHeight() + ui.sp();
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ChildBg, ui.col(ui.pal.surface));
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Border, ui.col(ui.pal.line));
        im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_WindowPadding, .{ .x = 16 * s, .y = 12 * s });
        im.ImGui_PushStyleVar(im.ImGuiStyleVar_ChildRounding, 4 * s);
        if (im.ImGui_BeginChild("##dupForm", .{ .x = 0, .y = avail.y - btn_h }, im.ImGuiChildFlags_Borders, 0)) {
            const col2 = 110 * s;
            const busy = v.job.isRunning();
            im.ImGui_BeginDisabled(busy);
            head("Match by", col2);
            _ = ui.check("Name##byName", &v.by_name);
            im.ImGui_SameLineEx(0, 18 * s);
            _ = ui.check("Size##bySize", &v.by_size);
            im.ImGui_SameLineEx(0, 18 * s);
            _ = ui.check("Modified date##byDate", &v.by_date);
            im.ImGui_SameLineEx(0, 18 * s);
            _ = ui.check("Content##byContent", &v.by_content);

            head("Ignore", col2);
            _ = ui.check("Zero-byte files##noEmpty", &v.no_empty);
            im.ImGui_SameLineEx(0, 18 * s);
            _ = ui.check("System files##noSystem", &v.no_system);
            im.ImGui_SameLineEx(0, 18 * s);
            _ = ui.check("Hidden files##noHidden", &v.no_hidden);
            im.ImGui_SameLineEx(0, 18 * s);
            _ = ui.check("Read-only files##noReadOnly", &v.no_read_only);

            head("Size (MB)", col2);
            ui.label("from");
            im.ImGui_SameLine();
            _ = v.min_mb.input("##dupMinMb", 70 * s);
            im.ImGui_SameLineEx(0, 10 * s);
            ui.label("to");
            im.ImGui_SameLine();
            _ = v.max_mb.input("##dupMaxMb", 70 * s);
            im.ImGui_SameLineEx(0, 10 * s);
            im.ImGui_AlignTextToFramePadding();
            ui.muted("0 = no limit");

            const browse_w = 100 * s;
            head("Search in", col2);
            _ = v.include.input("##dupInclude", im.ImGui_GetContentRegionAvail().x - browse_w - 8 * s);
            im.ImGui_SameLineEx(0, 8 * s);
            if (im.ImGui_ButtonEx("Browse...##dupIncludeBrowse", .{ .x = browse_w, .y = 0 })) ui.pickFolder(ctx, 2048, &v.include, true);

            head("Skip", col2);
            _ = v.exclude.input("##dupExclude", im.ImGui_GetContentRegionAvail().x - browse_w - 8 * s);
            im.ImGui_SameLineEx(0, 8 * s);
            if (im.ImGui_ButtonEx("Browse...##dupExcludeBrowse", .{ .x = browse_w, .y = 0 })) ui.pickFolder(ctx, 2048, &v.exclude, true);
            im.ImGui_EndDisabled();

            im.ImGui_Dummy(.{ .x = 0, .y = 10 * s });
            ui.mutedWrapped("Several folders: separate them with ';'. Content compares the bytes of files that already share a size.", im.ImGui_GetContentRegionAvail().x);
        }
        im.ImGui_EndChild();
        im.ImGui_PopStyleVarEx(2);
        im.ImGui_PopStyleColorEx(2);

        const label: [*:0]const u8 = if (v.job.isRunning()) "Cancel##dupSearch" else "Search##dupSearch";
        im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + im.ImGui_GetContentRegionAvail().x - 90 * s);
        if (ui.primary(label, true)) {
            if (v.job.isRunning()) v.job.cancel() else v.search();
        }
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
            im.ImGui_TableSetupColumnEx("Name", 0, 160 * s, 0);
            im.ImGui_TableSetupColumnEx("Size", im.ImGuiTableColumnFlags_WidthFixed, 72 * s, 0);
            im.ImGui_TableSetupColumnEx("Modified", im.ImGuiTableColumnFlags_WidthFixed, 118 * s, 0);
            im.ImGui_TableSetupColumnEx("Folder", 0, 420 * s, 0);
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
        if (ui.colButton("Select all but first##dupSelect", idle)) v.selectAllButFirst();
        if (ui.colButton("Delete Selected##dupDelete", idle)) {
            var n: usize = 0;
            for (v.rows.items, v.checked.items) |r, c| n += @intFromBool(c and r.file != null);
            if (n > 0) v.dlg.show(tag_delete, "Delete files", .warning, &.{ "Delete", "Cancel" }, "Delete {d} file(s)? This cannot be undone.", .{n});
        }
        if (ui.colButton("Back##dupBack", idle)) v.results = false;
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
        _ = ui.check(lb[0 .. chk.len + 2 :0], &v.checked.items[i]);
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
