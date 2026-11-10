//! Options > Cookies (legacy OptionsPages.CookiesPage). Left: every cookie domain the browsers hold (read on a
//! job, automatically on first show); right: the keep-list. Kept domains survive every Cookies clean.
const std = @import("std");
const kit = @import("kit");
const Ctx = @import("ctx.zig").Ctx;
const ui = @import("tools_ui.zig");
const cookies = @import("../core/cookies.zig");
const browsers = @import("../core/browsers.zig");

const im = kit.im;
const Sel = std.AutoHashMapUnmanaged(usize, void);

pub const View = struct {
    io: std.Io,
    job: kit.jobs.Job = .{},
    next_arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
    next_found: []const []const u8 = &.{},
    arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
    found: []const []const u8 = &.{},
    sel_all: Sel = .empty,
    sel_keep: Sel = .empty,
    anchor_all: ?usize = null,
    anchor_keep: ?usize = null,
    domain: ui.Buf(256) = .{},
    st_buf: [300]u8 = undefined,
    st_len: usize = 0,

    pub fn create(ctx: *Ctx) !*View {
        const v = try ctx.gpa.create(View);
        v.* = .{ .io = ctx.io };
        v.scan(); // page.Loaded: first show scans
        return v;
    }

    pub fn destroy(v: *View, ctx: *Ctx) void {
        v.job.cancel();
        v.job.join();
        v.arena.deinit();
        v.next_arena.deinit();
        v.sel_all.deinit(ctx.gpa);
        v.sel_keep.deinit(ctx.gpa);
        ctx.gpa.destroy(v);
    }

    fn setStatus(v: *View, comptime fmt: []const u8, args: anytype) void {
        const t: []const u8 = std.mem.print(&v.st_buf, fmt, args) catch &v.st_buf;
        v.st_len = t.len;
    }

    fn scan(v: *View) void {
        if (v.job.thread != null) return;
        _ = v.next_arena.reset(.free_all);
        v.setStatus("Reading cookies from browsers...", .{});
        v.job.start(v, worker) catch {};
    }

    fn worker(job: *kit.jobs.Job) anyerror!void {
        const v = job.ctx(View);
        v.next_found = try browsers.cookieDomains(v.next_arena.allocator(), v.io, null);
    }

    fn clearSel(v: *View) void {
        v.sel_all.clearRetainingCapacity();
        v.sel_keep.clearRetainingCapacity();
        v.anchor_all = null;
        v.anchor_keep = null;
    }

    /// Save(domains): normalized, distinct, sorted keep-list -> Settings (saved now).
    fn saveList(v: *View, ctx: *Ctx, domains: []const []const u8) usize {
        const text = std.mem.join(ctx.gpa, "\n", domains) catch return 0;
        defer ctx.gpa.free(text);
        const parsed = cookies.parse(ctx.gpa, text) catch return 0;
        defer cookies.freeList(ctx.gpa, parsed);
        ctx.settings.setList(cookies.keep_prefix, @ptrCast(parsed)) catch return 0;
        ctx.settings.save(ctx.io) catch {};
        v.clearSel();
        // the scan's status line, kept current (C# left it stale after Keep / Remove)
        if (!v.job.isRunning()) v.setStatus("{d} domains with cookies, {d} kept", .{ v.found.len, parsed.len });
        return parsed.len;
    }

    /// A host name as cookies store it (after Cookies.Normalize): labels of letters, digits, '-' or '_' (bytes >= 0x80
    /// let an IDN through) joined by single dots, at least two labels. Rejects "http://x.com/path", "a b.com",
    /// "*.baz.net", "nodot". Stricter than legacy, which stored any normalized line.
    pub fn validDomain(d: []const u8) bool {
        if (std.mem.findScalar(u8, d, '.') == null) return false;
        var labels = std.mem.splitScalar(u8, d, '.');
        while (labels.next()) |l| {
            if (l.len == 0 or l.len > 63 or l[0] == '-' or l[l.len - 1] == '-') return false;
            for (l) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c >= 0x80)) return false;
        }
        return d.len <= 253;
    }

    test validDomain {
        for ([_][]const u8{ "example.com", "mail.google.com", "xn--80ak6aa92e.com", "my_host.local" }) |d| try std.testing.expect(validDomain(d));
        for ([_][]const u8{ "http://www.foo.com/path", "a b.com", "*.baz.net", "nodot", "a..b", ".a.b", "a.b.", "-a.b" }) |d| try std.testing.expect(!validDomain(d));
    }

    fn kept(ctx: *Ctx) [][]const u8 {
        return ctx.settings.getList(ctx.gpa, cookies.keep_prefix) catch &.{};
    }

    /// found minus kept (cookieDomains is already normalized + sorted).
    fn visible(v: *View, gpa: std.mem.Allocator, keep: []const []const u8) std.ArrayList([]const u8) {
        var out: std.ArrayList([]const u8) = .empty;
        for (v.found) |d| if (!cookies.isKept(d, keep)) out.append(gpa, d) catch break;
        return out;
    }

    pub fn draw(v: *View, ctx: *Ctx) void {
        const s = ui.scale();
        if (ui.jobDone(&v.job)) {
            var eb: [256]u8 = undefined;
            if (v.job.errorText(&eb)) |e| {
                v.setStatus("Could not read cookies: {s}", .{e});
            } else {
                std.mem.swap(std.heap.ArenaAllocator, &v.arena, &v.next_arena);
                _ = v.next_arena.reset(.free_all);
                v.found = v.next_found;
                v.clearSel();
                const k = kept(ctx);
                defer ctx.gpa.free(k);
                v.setStatus("{d} domains with cookies, {d} kept", .{ v.found.len, k.len });
            }
        }

        ui.title(ctx, "Cookies");
        ui.muted("Domains to keep when browser cookies are cleaned (subdomains included).");
        im.ImGui_Dummy(.{ .x = 0, .y = 6 * s });

        // lists + arrows (buttons act before the lists are read, so the lists below are always current)
        const list_h = 220 * s;
        const top = im.ImGui_GetCursorPosY();
        const x0 = im.ImGui_GetCursorPosX();
        im.ImGui_SetCursorPos(.{ .x = x0 + 250 * s + 10 * s, .y = top + im.ImGui_GetFontSize() + list_h / 2 - im.ImGui_GetFrameHeight() });
        im.ImGui_BeginGroup();
        if (im.ImGui_ButtonEx("Keep >##cookieToKeep", .{ .x = 90 * s, .y = 0 })) {
            const k = kept(ctx);
            defer ctx.gpa.free(k);
            var all = v.visible(ctx.gpa, k);
            defer all.deinit(ctx.gpa);
            var more: std.ArrayList([]const u8) = .empty;
            defer more.deinit(ctx.gpa);
            more.appendSlice(ctx.gpa, k) catch {};
            for (all.items, 0..) |d, i| if (v.sel_all.contains(i)) more.append(ctx.gpa, d) catch {};
            _ = v.saveList(ctx, more.items);
        }
        im.ImGui_Dummy(.{ .x = 0, .y = 4 * s });
        if (im.ImGui_ButtonEx("< Remove##cookieRemove", .{ .x = 90 * s, .y = 0 })) {
            const k = kept(ctx);
            defer ctx.gpa.free(k);
            var rest: std.ArrayList([]const u8) = .empty;
            defer rest.deinit(ctx.gpa);
            for (k, 0..) |d, i| if (!v.sel_keep.contains(i)) rest.append(ctx.gpa, d) catch {};
            _ = v.saveList(ctx, rest.items);
        }
        im.ImGui_EndGroup();

        const k = kept(ctx);
        defer ctx.gpa.free(k);
        var all = v.visible(ctx.gpa, k);
        defer all.deinit(ctx.gpa);
        im.ImGui_SetCursorPos(.{ .x = x0, .y = top });
        column(ctx, "Cookies on computer", "##cookieAll", "ca", all.items, &v.sel_all, &v.anchor_all, list_h);
        im.ImGui_SetCursorPos(.{ .x = x0 + 250 * s + 10 * s + 90 * s + 10 * s, .y = top });
        column(ctx, "Cookies to keep", "##cookieKeep", "ck", k, &v.sel_keep, &v.anchor_keep, list_h);
        im.ImGui_Dummy(.{ .x = 0, .y = 8 * s });

        _ = v.domain.input("##cookieDomain", 200 * s);
        im.ImGui_SameLineEx(0, 8 * s);
        if (ui.button("Add##cookieAdd", true)) v.add(ctx);
        im.ImGui_SameLineEx(0, 8 * s);
        if (ui.button("Rescan##cookieScan", !v.job.isRunning())) v.scan();
        im.ImGui_SameLineEx(0, 8 * s);
        if (ui.button("Import...##cookieImport", true)) v.import(ctx);
        im.ImGui_SameLineEx(0, 8 * s);
        if (ui.button("Export...##cookieExport", true)) v.exportList(ctx);
        im.ImGui_Dummy(.{ .x = 0, .y = 4 * s });
        im.ImGui_PushFontFloat(ctx.app.fonts.bold, 0);
        ui.status("cookieStatus", v.st_buf[0..v.st_len], ui.pal.text);
        im.ImGui_PopFont();
    }

    fn column(ctx: *Ctx, caption: []const u8, id: [*:0]const u8, row_id: []const u8, items: []const []const u8, sel: *Sel, anchor: *?usize, h: f32) void {
        const s = ui.scale();
        im.ImGui_BeginGroup();
        ui.muted(caption);
        if (im.ImGui_BeginListBox(id, .{ .x = 250 * s, .y = h })) {
            const io = im.ImGui_GetIO();
            for (items, 0..) |d, i| {
                var lb: [300]u8 = undefined;
                if (im.ImGui_SelectableEx(ui.idLabel(&lb, d, "{s}{d}", .{ row_id, i }).ptr, sel.contains(i), 0, .{ .x = 0, .y = 0 })) {
                    // SelectionMode.Extended: click = one, Ctrl = toggle, Shift = range
                    if (io.*.KeyShift and anchor.* != null) {
                        sel.clearRetainingCapacity();
                        for (@min(anchor.*.?, i)..@max(anchor.*.?, i) + 1) |j| sel.put(ctx.gpa, j, {}) catch {};
                    } else if (io.*.KeyCtrl) {
                        if (!sel.remove(i)) sel.put(ctx.gpa, i, {}) catch {};
                        anchor.* = i;
                    } else {
                        sel.clearRetainingCapacity();
                        sel.put(ctx.gpa, i, {}) catch {};
                        anchor.* = i;
                    }
                }
            }
            im.ImGui_EndListBox();
        }
        im.ImGui_EndGroup();
    }

    fn add(v: *View, ctx: *Ctx) void {
        const parsed = cookies.parse(ctx.gpa, v.domain.slice()) catch return;
        defer cookies.freeList(ctx.gpa, parsed);
        if (parsed.len != 1 or !validDomain(parsed[0])) return v.setStatus("Enter a domain like example.com.", .{});
        const k = kept(ctx);
        defer ctx.gpa.free(k);
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(ctx.gpa);
        list.appendSlice(ctx.gpa, k) catch return;
        list.append(ctx.gpa, parsed[0]) catch return;
        _ = v.saveList(ctx, list.items);
        v.domain.set("");
        v.setStatus("Keeping cookies of {s} and its subdomains.", .{parsed[0]});
    }

    fn import(v: *View, ctx: *Ctx) void {
        const files = (kit.win.openFiles(ctx.gpa, ctx.app.hwnd, false, .{ .filters = &.{
            .{ .name = "Text files (*.txt)", .spec = "*.txt" },
            .{ .name = "All files (*.*)", .spec = "*.*" },
        } }) catch null) orelse return;
        defer kit.win.freeList(ctx.gpa, files);
        if (files.len == 0) return;
        const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, files[0], ctx.gpa, .limited(16 << 20)) catch |e| return v.setStatus("Could not read the file: {t}", .{e});
        defer ctx.gpa.free(text);
        const added = cookies.parse(ctx.gpa, text) catch return;
        defer cookies.freeList(ctx.gpa, added);
        const k = kept(ctx);
        defer ctx.gpa.free(k);
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(ctx.gpa);
        list.appendSlice(ctx.gpa, k) catch return;
        var bad: usize = 0;
        for (added) |d| {
            if (validDomain(d)) list.append(ctx.gpa, d) catch return else bad += 1;
        }
        _ = v.saveList(ctx, list.items);
        if (bad == 0) v.setStatus("Imported {d} domains.", .{added.len}) else v.setStatus("Imported {d} domains, {d} invalid lines skipped.", .{ added.len - bad, bad });
    }

    fn exportList(v: *View, ctx: *Ctx) void {
        const path = (kit.win.saveFile(ctx.gpa, ctx.app.hwnd, .{
            .file_name = "cookies-to-keep.txt",
            .filters = &.{.{ .name = "Text files (*.txt)", .spec = "*.txt" }},
            .default_ext = "txt",
        }) catch null) orelse return;
        defer ctx.gpa.free(path);
        const k = kept(ctx);
        defer ctx.gpa.free(k);
        ui.writeLines(ctx.io, path, k) catch |e| return v.setStatus("Could not write the file: {t}", .{e});
        v.setStatus("Exported {d} domains.", .{k.len});
    }
};
