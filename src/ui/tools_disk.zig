//! Tools > Disk Analyzer (legacy DiskAnalyzerView): space by file type over the chosen locations; the category
//! list doubles as the bar chart (longest bar 200 px); biggest 5000 files of the selected category.
const std = @import("std");
const kit = @import("kit");
const Ctx = @import("ctx.zig").Ctx;
const ui = @import("tools_ui.zig");
const rules_fs = @import("../core/rules_fs.zig");
const duplicates = @import("../core/duplicates.zig");
const disk = @import("../core/diskanalyzer.zig");
const engine = @import("../core/engine.zig");
const bytes = @import("../core/bytes.zig");
const FileInfo = @import("../core/common.zig").FileInfo;

const im = kit.im;
const w = kit.w;
const bar_max = 200;
const max_files = 5000;
const tag_delete = 1;

pub const View = struct {
    io: std.Io,
    job: kit.jobs.Job = .{},
    roots: ui.Buf(1024) = .{},
    where: []const []const u8 = &.{},
    next_arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
    next_report: disk.DiskReport = undefined,
    arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
    report: ?disk.DiskReport = null,
    cat: usize = 0,
    /// Biggest files of `cat`, sorted by size descending (indices into report.by_category[cat]).
    files: std.ArrayList(u32) = .empty,
    picked: std.AutoHashMapUnmanaged(u32, void) = .empty,
    anchor: ?usize = null,
    status: ui.Text(256) = .{},
    seen_at: u64 = 0,
    /// Bytes per category of `report` (summed once per analyze/delete, not every frame).
    cat_bytes: [disk.categories.len]u64 = @splat(0),
    // Delete Selected on the job: the worker cleans `del_files` (gpa) and rebuilds the lists into `arena`
    deleting: bool = false,
    del_files: []FileInfo = &.{},
    del_result: engine.CleanResult = .{},
    del_lists: [disk.categories.len][]const FileInfo = undefined,
    dlg: ui.Dialog = .{},

    pub fn create(ctx: *Ctx) !*View {
        const v = try ctx.gpa.create(View);
        v.* = .{ .io = ctx.io };
        v.defaultRoots();
        return v;
    }

    pub fn destroy(v: *View, ctx: *Ctx) void {
        v.job.cancel();
        v.job.join();
        ctx.gpa.free(v.del_files);
        v.arena.deinit();
        v.next_arena.deinit();
        v.files.deinit(ctx.gpa);
        v.picked.deinit(ctx.gpa);
        ctx.gpa.destroy(v);
    }

    /// Fixed, ready drives: "C:\; D:\".
    fn defaultRoots(v: *View) void {
        var buf: [256]u8 = undefined;
        var n: usize = 0;
        const mask = w.GetLogicalDrives();
        for (0..26) |i| {
            if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
            const letter: u16 = 'A' + @as(u16, @intCast(i));
            const root = [_:0]u16{ letter, ':', '\\' };
            if (w.GetDriveTypeW(&root) != w.DRIVE_FIXED) continue;
            if (w.GetVolumeInformationW(&root, null, 0, null, null, null, null, 0) == 0) continue; // IsReady
            const part = std.mem.print(buf[n..], "{s}{c}:\\", .{ if (n > 0) "; " else "", @as(u8, @intCast(letter)) }) catch break;
            n += part.len;
        }
        v.roots.set(buf[0..n]);
    }

    fn analyze(v: *View) void {
        if (v.job.thread != null) return;
        _ = v.next_arena.reset(.free_all);
        const a = v.next_arena.allocator();
        const text = a.dupe(u8, v.roots.slice()) catch return;
        v.where = duplicates.scan.splitPaths(a, text) catch return;
        v.seen_at = kit.w.GetTickCount64();
        v.status.set("Scanning...", .{});
        v.job.start(v, worker) catch {};
    }

    fn worker(job: *kit.jobs.Job) anyerror!void {
        const v = job.ctx(View);
        v.next_report = try disk.analyze(v.next_arena.allocator(), v.io, v.where, &job.cancel_flag, ui.jobProgress(job));
    }

    fn fileCount(r: *const disk.DiskReport) usize {
        var n: usize = 0;
        for (r.by_category) |l| n += l.len;
        return n;
    }

    fn showFiles(v: *View, gpa: std.mem.Allocator) void {
        v.files.clearRetainingCapacity();
        v.picked.clearRetainingCapacity();
        v.anchor = null;
        const r = v.report orelse return;
        const l = r.by_category[v.cat];
        for (0..l.len) |i| v.files.append(gpa, @intCast(i)) catch return;
        std.mem.sort(u32, v.files.items, l, struct {
            fn bigger(list: []const FileInfo, a: u32, b: u32) bool {
                return list[a].size > list[b].size;
            }
        }.bigger);
        // ponytail: biggest 5000 per type; paging if the full list is ever needed
        v.files.shrinkRetainingCapacity(@min(v.files.items.len, max_files));
    }

    fn fileAt(v: *View, row: usize) FileInfo {
        return v.report.?.by_category[v.cat][v.files.items[row]];
    }

    fn delete(v: *View, gpa: std.mem.Allocator) void {
        if (v.job.thread != null) return;
        var list: std.ArrayList(FileInfo) = .empty;
        var it = v.picked.keyIterator();
        while (it.next()) |k| list.append(gpa, v.report.?.by_category[v.cat][k.*]) catch return list.deinit(gpa);
        v.del_files = list.toOwnedSlice(gpa) catch return list.deinit(gpa);
        v.deleting = true;
        v.status.set("Deleting {d} files...", .{v.del_files.len});
        v.job.start(v, delWorker) catch {
            v.deleting = false;
            gpa.free(v.del_files);
            v.del_files = &.{};
        };
    }

    /// Engine.Clean of the picked files, then report.ByCategory.RemoveAll(gone) into new lists (C# did both on the
    /// UI thread). The UI only reads `report` and never allocates from `arena` while this runs.
    fn delWorker(job: *kit.jobs.Job) anyerror!void {
        const v = job.ctx(View);
        const gpa = std.heap.smp_allocator;
        v.del_result = engine.clean(gpa, v.io, v.del_files, 0);
        var gone: std.StringHashMapUnmanaged(void) = .empty;
        defer gone.deinit(gpa);
        for (v.del_files) |f| if (!rules_fs.exists(f.path)) try gone.put(gpa, f.path, {});
        const a = v.arena.allocator();
        for (v.report.?.by_category, &v.del_lists) |l, *out| {
            var keep: std.ArrayList(FileInfo) = .empty;
            for (l) |f| if (!gone.contains(f.path)) try keep.append(a, f);
            out.* = keep.items;
        }
    }

    fn deleted(v: *View, gpa: std.mem.Allocator) void {
        defer {
            gpa.free(v.del_files);
            v.del_files = &.{};
        }
        var eb: [512]u8 = undefined;
        if (v.job.errorText(&eb)) |e| return v.status.set("Failed: {s}", .{e});
        v.report.?.by_category = v.del_lists;
        v.sumCats();
        v.showFiles(gpa);
        const r = v.del_result;
        v.status.set("Deleted {d} files, {f} freed, {d} skipped", .{ r.deleted, bytes.fmt(r.bytes_freed), r.skipped });
    }

    fn sumCats(v: *View) void {
        const r = &(v.report orelse return);
        for (disk.categories, &v.cat_bytes) |c, *n| n.* = r.bytes(c);
    }

    fn openSelected(v: *View, gpa: std.mem.Allocator) void {
        const row = v.anchor orelse return;
        if (row < v.files.items.len) ui.openFolder(gpa, v.fileAt(row).path);
    }

    fn saveReport(v: *View, ctx: *Ctx) void {
        const r = v.report orelse return;
        const text = disk.toText(ctx.gpa, &r) catch return;
        defer ctx.gpa.free(text);
        ui.saveText(ctx, &v.dlg, "Disk Analyzer", &.{text});
    }

    pub fn draw(v: *View, ctx: *Ctx) void {
        const s = ui.scale();
        if (v.job.takeFinished()) {
            var eb: [512]u8 = undefined;
            if (v.deleting) {
                v.deleting = false;
                v.deleted(ctx.gpa);
            } else if (v.job.cancelled()) {
                v.status.set("Cancelled", .{});
            } else if (v.job.errorText(&eb)) |e| {
                v.status.set("Failed: {s}", .{e});
            } else {
                std.mem.swap(std.heap.ArenaAllocator, &v.arena, &v.next_arena);
                _ = v.next_arena.reset(.free_all);
                v.report = v.next_report;
                v.cat = 0;
                v.sumCats();
                v.showFiles(ctx.gpa);
                var nb: [32]u8 = undefined;
                v.status.set("Analysis complete: {s} files, {f}", .{ ui.n0(&nb, fileCount(&v.report.?)), bytes.fmt(v.report.?.total()) });
            }
        }
        if (v.job.isRunning() and !v.deleting) {
            const now = kit.w.GetTickCount64();
            if (now -% v.seen_at >= 200) {
                v.seen_at = now;
                var nb: [32]u8 = undefined;
                v.status.set("Scanning... {s} files", .{ui.n0(&nb, v.job.done.load(.acquire))});
            }
            ctx.app.requestFrames(2);
        }
        if (v.dlg.draw()) |ans| if (ans.tag == tag_delete and ans.button == 0) v.delete(ctx.gpa);

        // where to look
        const busy = v.job.isRunning();
        const scanning = busy and !v.deleting;
        im.ImGui_PushFontFloat(ctx.app.fonts.bold, 0);
        ui.label("Locations");
        im.ImGui_PopFont();
        im.ImGui_SameLineEx(0, 10 * s);
        const right = 100 * s + 8 * s + 90 * s + 8 * s;
        im.ImGui_BeginDisabled(busy);
        _ = v.roots.input("##daRoots", im.ImGui_GetContentRegionAvail().x - right);
        im.ImGui_SameLineEx(0, 8 * s);
        if (im.ImGui_ButtonEx("Browse...##daBrowse", .{ .x = 100 * s, .y = 0 })) ui.pickFolder(ctx, 1024, &v.roots, true);
        im.ImGui_EndDisabled();
        im.ImGui_SameLineEx(0, 8 * s);
        if (ui.primary(if (scanning) "Cancel##daScan" else "Analyze##daScan", !v.deleting)) {
            if (scanning) v.job.cancel() else v.analyze();
        }
        im.ImGui_Dummy(.{ .x = 0, .y = 6 * s });

        const avail = im.ImGui_GetContentRegionAvail();
        const status_h = im.ImGui_GetFontSize() + ui.sp();
        const body_h = avail.y - status_h;
        v.drawCats(ctx, body_h);
        im.ImGui_SameLineEx(0, 12 * s);
        im.ImGui_BeginGroup();
        const btn_h = im.ImGui_GetFrameHeight() + ui.sp();
        v.drawFiles(ctx, body_h - btn_h);
        const has = v.report != null and !busy;
        const bw = 120 * s + 140 * s + 120 * s + 16 * s;
        im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + @max(0, im.ImGui_GetContentRegionAvail().x - bw));
        if (im.ImGui_ButtonEx("Open Folder##daOpen", .{ .x = 120 * s, .y = 0 })) v.openSelected(ctx.gpa);
        im.ImGui_SameLineEx(0, 8 * s);
        im.ImGui_BeginDisabled(busy);
        const del = im.ImGui_ButtonEx("Delete Selected##daDelete", .{ .x = 140 * s, .y = 0 });
        im.ImGui_EndDisabled();
        if (del) {
            if (has and v.picked.count() > 0) v.dlg.show(tag_delete, "Delete files", .danger, &.{ "Delete", "Cancel" }, "Delete {d} file(s)? This cannot be undone.", .{v.picked.count()});
        }
        im.ImGui_SameLineEx(0, 8 * s);
        if (im.ImGui_ButtonEx("Save Report...##daSave", .{ .x = 120 * s, .y = 0 })) v.saveReport(ctx);
        im.ImGui_EndGroup();

        ui.status("daStatus", v.status.slice(), ui.pal.text);
    }

    fn drawCats(v: *View, ctx: *Ctx, h: f32) void {
        const s = ui.scale();
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ChildBg, ui.col(ui.pal.surface));
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Border, ui.col(ui.pal.line));
        defer im.ImGui_PopStyleColorEx(2);
        if (im.ImGui_BeginChild("##daCats", .{ .x = 240 * s, .y = h }, im.ImGuiChildFlags_Borders, 0)) {
            if (v.report) |*r| {
                var top: u64 = 0;
                var total: u64 = 0;
                for (v.cat_bytes) |n| {
                    top = @max(top, n);
                    total += n;
                }
                const dl = im.ImGui_GetWindowDrawList();
                const line_h = im.ImGui_GetFontSize();
                const item_h = line_h * 2 + 6 * s + 10 * s + 8 * s;
                for (disk.categories, 0..) |c, i| {
                    const b = v.cat_bytes[i];
                    var sb: [32]u8 = undefined;
                    var pb: [16]u8 = undefined;
                    var db: [96]u8 = undefined;
                    var nb: [32]u8 = undefined;
                    const size = ui.z(&sb, "{f}", .{bytes.fmt(b)});
                    const n = ui.n0(&nb, r.by_category[i].len);
                    const detail = if (total == 0)
                        ui.z(&db, "{s} files", .{n})
                    else
                        ui.z(&db, "{s} files  \u{00B7}  {s}%", .{ n, ui.fmt01(&pb, 100 * @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(total))) });
                    const pos = im.ImGui_GetCursorScreenPos();
                    const width = im.ImGui_GetContentRegionAvail().x;
                    // the label carries what is drawn: "Pictures  48.83 KB  1 files  33.3%###daCat0" (stable id)
                    var lb: [192]u8 = undefined;
                    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Text, kit.app.color(0, 0));
                    if (im.ImGui_SelectableEx(ui.z(&lb, "{s}  {s}  {s}###daCat{d}", .{ c, size, detail, i }).ptr, v.cat == i, 0, .{ .x = width, .y = item_h })) {
                        v.cat = i;
                        v.showFiles(ctx.gpa);
                    }
                    im.ImGui_PopStyleColor();
                    const x = pos.x + 4 * s;
                    var y = pos.y + 4 * s;
                    im.ImDrawList_AddTextImFontPtr(dl, ctx.app.fonts.bold, line_h, .{ .x = x, .y = y }, kit.app.colorU32(ui.pal.text), c.ptr);
                    const sw = im.ImGui_CalcTextSize(size.ptr).x;
                    im.ImDrawList_AddText(dl, .{ .x = pos.x + width - sw - 4 * s, .y = y }, kit.app.colorU32(ui.pal.muted), size.ptr);
                    y += line_h + 5 * s;
                    const bar_w = width - 8 * s;
                    im.ImDrawList_AddRectFilledEx(dl, .{ .x = x, .y = y }, .{ .x = x + bar_w, .y = y + 10 * s }, kit.app.colorU32(ui.pal.line), 2 * s, 0);
                    const fill: f32 = if (top == 0) 0 else @min(bar_w, bar_max * s * @as(f32, @floatFromInt(b)) / @as(f32, @floatFromInt(top)));
                    if (fill > 0) im.ImDrawList_AddRectFilledEx(dl, .{ .x = x, .y = y }, .{ .x = x + fill, .y = y + 10 * s }, kit.app.colorU32(ui.pal.accent), 2 * s, 0);
                    y += 13 * s;
                    im.ImDrawList_AddTextImFontPtr(dl, im.ImGui_GetFont(), 11 * s, .{ .x = x, .y = y }, kit.app.colorU32(ui.pal.muted), detail.ptr);
                }
            } else ui.mutedWrapped("Pick a drive or folder and press Analyze to see what takes the space.", im.ImGui_GetContentRegionAvail().x);
        }
        im.ImGui_EndChild();
    }

    fn drawFiles(v: *View, ctx: *Ctx, h: f32) void {
        const s = ui.scale();
        if (!im.ImGui_BeginTableEx("##daFiles", 4, ui.table_flags | im.ImGuiTableFlags_RowBg, .{ .x = im.ImGui_GetContentRegionAvail().x, .y = h }, 0)) return;
        defer im.ImGui_EndTable();
        im.ImGui_TableSetupScrollFreeze(0, 1);
        im.ImGui_TableSetupColumnEx("Name", 0, 170 * s, 0);
        im.ImGui_TableSetupColumnEx("Size", im.ImGuiTableColumnFlags_WidthFixed, 72 * s, 0);
        im.ImGui_TableSetupColumnEx("Modified", im.ImGuiTableColumnFlags_WidthFixed, 118 * s, 0);
        im.ImGui_TableSetupColumnEx("Folder", 0, 420 * s, 0);
        im.ImGui_TableHeadersRow();
        const io = im.ImGui_GetIO();
        var clip = std.mem.zeroes(im.ImGuiListClipper);
        im.ImGuiListClipper_Begin(&clip, @intCast(v.files.items.len), -1);
        defer im.ImGuiListClipper_End(&clip);
        while (im.ImGuiListClipper_Step(&clip)) {
            var row: usize = @intCast(clip.DisplayStart);
            while (row < clip.DisplayEnd) : (row += 1) {
                const idx = v.files.items[row];
                const f = v.fileAt(row);
                im.ImGui_TableNextRow();
                _ = im.ImGui_TableNextColumn();
                var lb: [1100]u8 = undefined;
                const name = std.fs.path.basename(f.path);
                const cw = im.ImGui_GetContentRegionAvail().x;
                if (im.ImGui_SelectableEx(ui.idLabel(&lb, name, "daFile{d}", .{row}).ptr, v.picked.contains(idx), im.ImGuiSelectableFlags_SpanAllColumns | im.ImGuiSelectableFlags_AllowDoubleClick, .{ .x = 0, .y = 0 }) and !v.deleting) {
                    // Extended selection: click = one, Ctrl = toggle, Shift = range from the anchor
                    if (io.*.KeyShift and v.anchor != null) {
                        v.picked.clearRetainingCapacity();
                        const a = v.anchor.?;
                        for (@min(a, row)..@max(a, row) + 1) |k| v.picked.put(ctx.gpa, v.files.items[k], {}) catch {};
                    } else if (io.*.KeyCtrl) {
                        if (!v.picked.remove(idx)) v.picked.put(ctx.gpa, idx, {}) catch {};
                        v.anchor = row;
                    } else {
                        v.picked.clearRetainingCapacity();
                        v.picked.put(ctx.gpa, idx, {}) catch {};
                        v.anchor = row;
                    }
                    if (im.ImGui_IsMouseDoubleClicked(0)) ui.openFolder(ctx.gpa, f.path);
                }
                ui.rowTip(name, cw);
                var sb: [32]u8 = undefined;
                var db: [64]u8 = undefined;
                // cells "<text>##daFile<row><s|m|f>" (Size, Modified, Folder)
                inline for (.{ std.mem.print(&sb, "{f}", .{bytes.fmt(f.size)}) catch "", ui.fmtStamp(&db, f.mtime), std.fs.path.dirname(f.path) orelse "" }, .{ "s", "m", "f" }) |c, id| {
                    _ = im.ImGui_TableNextColumn();
                    ui.cell(c, "daFile{d}" ++ id, .{row});
                }
            }
        }
    }
};
