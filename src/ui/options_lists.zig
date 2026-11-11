//! Options > Include and Options > Exclude (legacy OptionsPages.IncludePage / ExcludePage). The lists are read
//! from Settings every frame, so Cleaner / Registry "Add to Exclude" shows up as soon as the page is shown.
const std = @import("std");
const kit = @import("kit");
const Ctx = @import("ctx.zig").Ctx;
const ui = @import("tools_ui.zig");
const custom = @import("../core/custom.zig");
const rules_fs = @import("../core/rules_fs.zig");
const common = @import("../core/common.zig");
const T = @import("../i18n/tr.zig");
const tr = T.tr;

const im = kit.im;

/// Status line of both pages (bold).
fn drawStatus(st: *const ui.Text(400), ctx: *Ctx, id: []const u8) void {
    im.ImGui_PushFontFloat(ctx.app.fonts.bold, 0);
    ui.status(id, st.slice(), ui.pal.text);
    im.ImGui_PopFont();
}

/// The settings list `prefix` as a single-selection list box (640 x 160). Returns nothing; `sel` is the index.
fn listBox(ctx: *Ctx, id: [*:0]const u8, row_id: []const u8, prefix: []const u8, sel: *?usize) void {
    const s = ui.scale();
    const items = ctx.settings.getList(ctx.gpa, prefix) catch return;
    defer ctx.gpa.free(items);
    if (sel.*) |i| if (i >= items.len) {
        sel.* = null;
    };
    if (im.ImGui_BeginListBox(id, .{ .x = @min(640 * s, im.ImGui_GetContentRegionAvail().x), .y = 160 * s })) {
        for (items, 0..) |e, i| {
            var lb: [1100]u8 = undefined;
            const cw = im.ImGui_GetContentRegionAvail().x;
            if (im.ImGui_SelectableEx(ui.idLabel(&lb, e, "{s}{d}", .{ row_id, i }).ptr, sel.* == i, 0, .{ .x = 0, .y = 0 })) sel.* = i;
            if (ui.textW(e) > cw) ui.tip(e);
        }
        im.ImGui_EndListBox();
    }
}

/// RemoveSelected: drops the selected entry (ordinal compare, like `e != sel`) and saves.
fn removeSelected(ctx: *Ctx, prefix: []const u8, sel: *?usize) void {
    const i = sel.* orelse return;
    const items = ctx.settings.getList(ctx.gpa, prefix) catch return;
    defer ctx.gpa.free(items);
    if (i >= items.len) return;
    var keep: std.ArrayList([]const u8) = .empty;
    defer keep.deinit(ctx.gpa);
    for (items) |e| if (!std.mem.eql(u8, e, items[i])) keep.append(ctx.gpa, e) catch return;
    ctx.settings.setList(prefix, keep.items) catch return;
    ctx.settings.save(ctx.io) catch {};
    sel.* = null;
}

fn fullyQualified(p: []const u8) bool {
    if (p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/')) return true;
    return p.len >= 2 and (p[0] == '\\' or p[0] == '/') and (p[1] == '\\' or p[1] == '/');
}

// ---------------------------------------------------------------- Include

pub const Include = struct {
    path: ui.Buf(1024) = .{},
    mode: c_int = 1,
    pattern: ui.Buf(128) = ui.initBuf(128, "*.*"),
    age: ui.Buf(16) = ui.initBuf(16, "0"),
    sel: ?usize = null,
    st: ui.Text(400) = .{},

    pub fn draw(p: *Include, ctx: *Ctx) void {
        const s = ui.scale();
        const t = &tr().include;
        const c = &tr().common;
        var lb: [128]u8 = undefined;
        ui.title(ctx, tr().options.nav_include);
        ui.muted(t.intro);
        im.ImGui_Dummy(.{ .x = 0, .y = 4 * s });
        _ = p.path.input("##incPath", 300 * s);
        im.ImGui_SameLineEx(0, 8 * s);
        if (ui.button(ui.idLabel(&lb, c.browse, "incPathBrowse", .{}).ptr, true)) ui.pickFolder(ctx, 1024, &p.path, false);
        im.ImGui_SameLineEx(0, 8 * s);
        if (ui.button(ui.idLabel(&lb, c.add, "incAdd", .{}).ptr, true)) p.add(ctx);
        im.ImGui_SameLineEx(0, 8 * s);
        if (ui.button(ui.idLabel(&lb, c.remove, "incRemove", .{}).ptr, true)) removeSelected(ctx, custom.include_prefix, &p.sel);

        ui.label(t.mode);
        im.ImGui_SameLineEx(0, 8 * s);
        const include_modes = [_][*:0]const u8{ t.files_only, t.files_sub, t.files_sub_self };
        _ = ui.combo("incMode", &include_modes, &p.mode, 230 * s);
        im.ImGui_SameLineEx(0, 8 * s);
        ui.label(t.mask);
        im.ImGui_SameLineEx(0, 8 * s);
        _ = p.pattern.input("##incPattern", 100 * s);
        ui.sameLineOrWrap(ui.textW(t.hours) + 8 * s + 60 * s, 8 * s, 0); // label + box wrap together (es/fr are long)
        ui.label(t.hours);
        im.ImGui_SameLineEx(0, 8 * s);
        _ = p.age.input("##incAge", 60 * s);
        im.ImGui_Dummy(.{ .x = 0, .y = 4 * s });
        listBox(ctx, "##incList", "inc", custom.include_prefix, &p.sel);
        im.ImGui_Dummy(.{ .x = 0, .y = 4 * s });
        drawStatus(&p.st, ctx, "incStatus");
    }

    fn add(p: *Include, ctx: *Ctx) void {
        var arena_state: std.heap.ArenaAllocator = .init(ctx.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const raw = p.path.trimmed();
        const t = &tr().include;
        if (custom.reject(a, raw) catch null) |why| return p.st.set("{s}", .{why});
        const hours = std.fmt.parseInt(i32, p.age.trimmed(), 10) catch -1;
        if (hours < 0) return p.st.set("{s}", .{t.hours_bad});
        const expanded = kit.win.expandEnv(a, raw) catch return;
        const full = (rules_fs.fullPath(a, expanded) catch null) orelse return p.st.set("{s}", .{t.not_found});
        var entry: []const u8 = undefined;
        if (rules_fs.isFile(full)) {
            entry = a.print("{s}|{s}", .{ std.fs.path.dirname(full) orelse full, std.fs.path.basename(full) }) catch return;
        } else if (rules_fs.isDir(full)) {
            const mask = p.pattern.trimmed();
            const suffix: []const u8 = switch (p.mode) {
                1 => "|RECURSE",
                2 => "|REMOVESELF",
                else => "",
            };
            entry = a.print("{s}|{s}{s}", .{ full, if (mask.len > 0) mask else "*.*", suffix }) catch return;
        } else return p.st.set("{s}", .{t.not_found});
        if (hours > 0) entry = a.print("{s}|OLDER={d}", .{ entry, hours }) catch return;

        // GetList().Append(entry).Distinct(OrdinalIgnoreCase)
        const old = ctx.settings.getList(a, custom.include_prefix) catch return;
        var list: std.ArrayList([]const u8) = .empty;
        outer: for (old) |e| {
            for (list.items) |x| if (common.eqlIgnoreCase(x, e)) continue :outer;
            list.append(a, e) catch return;
        }
        for (list.items) |x| {
            if (common.eqlIgnoreCase(x, entry)) break;
        } else list.append(a, entry) catch return;
        ctx.settings.setList(custom.include_prefix, list.items) catch return;
        ctx.settings.save(ctx.io) catch {};
        p.path.set("");
        p.st.tset(t.added, .{tr().rule.custom});
    }
};

// ---------------------------------------------------------------- Exclude

pub const Exclude = struct {
    path: ui.Buf(1024) = .{},
    kind: c_int = 0,
    sel: ?usize = null,
    st: ui.Text(400) = .{},

    pub fn draw(p: *Exclude, ctx: *Ctx) void {
        const s = ui.scale();
        const t = &tr().exclude;
        const c = &tr().common;
        var lb: [128]u8 = undefined;
        ui.title(ctx, tr().options.nav_exclude);
        ui.muted(t.intro);
        im.ImGui_Dummy(.{ .x = 0, .y = 4 * s });
        _ = p.path.input("##excPath", 170 * s);
        im.ImGui_SameLineEx(0, 8 * s);
        const exclude_kinds = [_][*:0]const u8{ t.folder, t.file, t.reg_key };
        _ = ui.combo("excKind", &exclude_kinds, &p.kind, 130 * s);
        im.ImGui_SameLineEx(0, 8 * s);
        if (ui.button(ui.idLabel(&lb, c.browse, "excPathBrowse", .{}).ptr, true)) ui.pickFolder(ctx, 1024, &p.path, false);
        im.ImGui_SameLineEx(0, 8 * s);
        if (ui.button(ui.idLabel(&lb, c.add, "excAdd", .{}).ptr, true)) p.add(ctx);
        im.ImGui_SameLineEx(0, 8 * s);
        if (ui.button(ui.idLabel(&lb, c.remove, "excRemove", .{}).ptr, true)) removeSelected(ctx, custom.exclude_prefix, &p.sel);
        im.ImGui_Dummy(.{ .x = 0, .y = 4 * s });
        listBox(ctx, "##excList", "exc", custom.exclude_prefix, &p.sel);
        im.ImGui_Dummy(.{ .x = 0, .y = 4 * s });
        drawStatus(&p.st, ctx, "excStatus");
    }

    fn add(p: *Exclude, ctx: *Ctx) void {
        var arena_state: std.heap.ArenaAllocator = .init(ctx.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const raw = p.path.trimmed();
        const x = kit.win.expandEnv(a, raw) catch return;
        const full = fullyQualified(x);
        const entry: ?[]const u8 = switch (p.kind) {
            0 => if (full and rules_fs.isDir(x)) blk: {
                const f = (rules_fs.fullPath(a, x) catch null) orelse break :blk null;
                break :blk a.print("PATH|{s}", .{std.mem.trimEnd(u8, f, "\\")}) catch null;
            } else null,
            1 => if (full and rules_fs.isFile(x)) blk: {
                const f = (rules_fs.fullPath(a, x) catch null) orelse break :blk null;
                break :blk a.print("FILE|{s}|{s}", .{ std.fs.path.dirname(f) orelse f, std.fs.path.basename(x) }) catch null;
            } else null,
            else => if (std.ascii.startsWithIgnoreCase(raw, "HK") and std.mem.findScalar(u8, raw, '\\') != null)
                a.print("REG|{s}", .{raw}) catch null
            else
                null,
        };
        const e = entry orelse {
            p.st.set("{s}", .{if (p.kind == 2) tr().exclude.reg_hint else tr().exclude.not_found});
            return;
        };
        custom.addExclude(ctx.gpa, ctx.io, ctx.settings, e) catch return;
        p.path.set("");
        p.st.set("{s}", .{tr().exclude.added});
    }
};
