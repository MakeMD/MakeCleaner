//! MakeCleaner entry. "/auto" [+ "/shutdown"] (any case) -> headless schedule.auto, exit code 0/1, no window.
//! Otherwise the GUI: left rail (Cleaner / Registry / Tools / Options), page on the right, thin footer.
//! GUI phase: placeholder pages only.
const std = @import("std");
const kit = @import("kit");
const settings_mod = @import("core/settings.zig");
const cookies = @import("core/cookies.zig");
const schedule = @import("core/schedule.zig");

const im = kit.im;
const App = kit.app.App;
const pal = kit.app.palettes.cleaner;

pub const version = "2.0.0";

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const exe_dir = try std.process.executableDirPathAlloc(io, arena);
    var settings = try settings_mod.Settings.load(gpa, io, try settings_mod.resolveDir(arena, io, exe_dir));
    defer settings.deinit();
    cookies.keep_settings = &settings; // before /auto: it must honour the keep-list too

    const args = try init.minimal.args.toSlice(arena);
    if (has(args[1..], "/auto")) return schedule.auto(gpa, io, &settings, exe_dir, has(args[1..], "/shutdown"));

    var state: State = .{};
    const app = try App.init(gpa, .{ .title = "MakeCleaner", .size = .{ 1000, 680 }, .min_size = .{ 820, 560 }, .palette = pal });
    defer app.deinit();
    app.run(.{ .user = &state, .frame = frame });
    return 0;
}

fn has(args: []const []const u8, flag: []const u8) bool {
    for (args) |a| if (std.ascii.eqlIgnoreCase(a, flag)) return true;
    return false;
}

const Page = enum { cleaner, registry, tools, options };

/// Rail tiles: Segoe Fluent glyph + label (= automation label).
const tiles = [_]struct { page: Page, icon: u21, label: [:0]const u8 }{
    .{ .page = .cleaner, .icon = 0xE74D, .label = "Cleaner" },
    .{ .page = .registry, .icon = 0xE8F1, .label = "Registry" },
    .{ .page = .tools, .icon = 0xE90F, .label = "Tools" },
    .{ .page = .options, .icon = 0xE713, .label = "Options" },
};

const State = struct { page: Page = .cleaner };

fn frame(app: *App) void {
    const s = app.userData(State);
    const sc = app.scale();
    const vp = im.ImGui_GetMainViewport();
    const pos = vp.*.WorkPos;
    const size = vp.*.WorkSize;
    im.ImGui_SetNextWindowPos(pos, 0);
    im.ImGui_SetNextWindowSize(size, 0);
    im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });
    im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_ItemSpacing, .{ .x = 0, .y = 0 });
    _ = im.ImGui_Begin("MakeCleaner##main", null, im.ImGuiWindowFlags_NoDecoration | im.ImGuiWindowFlags_NoMove | im.ImGuiWindowFlags_NoSavedSettings | im.ImGuiWindowFlags_NoBringToFrontOnFocus);
    im.ImGui_PopStyleVarEx(2);
    defer im.ImGui_End();
    const dl = im.ImGui_GetWindowDrawList();

    const rail_w = 92 * sc;
    const footer_h = 26 * sc;
    const body_h = size.y - footer_h;

    // ---- left rail: logo, then one tile per section
    im.ImDrawList_AddRectFilled(dl, pos, .{ .x = pos.x + rail_w, .y = pos.y + body_h }, kit.app.colorU32(pal.rail));
    const cx = pos.x + rail_w / 2;
    const logo: im.ImVec2 = .{ .x = cx - 17 * sc, .y = pos.y + 14 * sc };
    im.ImDrawList_AddRectFilledEx(dl, logo, .{ .x = logo.x + 34 * sc, .y = logo.y + 34 * sc }, kit.app.colorU32(pal.accent), 8 * sc, 0);
    text(dl, app.fonts.bold, 14 * sc, cx, logo.y + 17 * sc, .middle, 0xFFFFFF, "MC");
    text(dl, app.fonts.bold, 11 * sc, cx, logo.y + 38 * sc, .top, 0xFFFFFF, "MakeCleaner");

    var y = pos.y + 84 * sc;
    for (tiles) |t| {
        const tile_h = 70 * sc;
        im.ImGui_SetCursorScreenPos(.{ .x = pos.x, .y = y });
        if (im.ImGui_InvisibleButton(t.label.ptr, .{ .x = rail_w, .y = tile_h }, 0)) s.page = t.page;
        const selected = s.page == t.page;
        const max: im.ImVec2 = .{ .x = pos.x + rail_w, .y = y + tile_h };
        if (selected) {
            im.ImDrawList_AddRectFilled(dl, .{ .x = pos.x, .y = y }, max, kit.app.colorU32(pal.rail_selected));
            im.ImDrawList_AddRectFilled(dl, .{ .x = pos.x, .y = y }, .{ .x = pos.x + 3 * sc, .y = max.y }, kit.app.colorU32(pal.accent));
        } else if (im.ImGui_IsItemHovered(0)) {
            im.ImDrawList_AddRectFilled(dl, .{ .x = pos.x, .y = y }, max, kit.app.colorU32(pal.rail_hover));
        }
        const fg: u32 = if (selected) 0xFFFFFF else pal.rail_text;
        const g = kit.ui.glyph(t.icon);
        text(dl, app.fonts.regular, 22 * sc, cx, y + 12 * sc, .top, fg, &g);
        text(dl, app.fonts.regular, 12 * sc, cx, y + 41 * sc, .top, fg, t.label);
        y += tile_h;
    }

    // ---- page (placeholder until the GUI phase)
    im.ImGui_SetCursorScreenPos(.{ .x = pos.x + rail_w + 16 * sc, .y = pos.y + 14 * sc });
    if (im.ImGui_BeginChild("##page", .{ .x = size.x - rail_w - 32 * sc, .y = body_h - 26 * sc }, 0, im.ImGuiWindowFlags_NoBackground)) {
        im.ImGui_PushFontFloat(app.fonts.bold, 20);
        im.ImGui_TextUnformatted(tiles[@backingInt(s.page)].label.ptr);
        im.ImGui_PopFont();
    }
    im.ImGui_EndChild();

    // ---- footer: version + promise
    const top = pos.y + body_h;
    im.ImDrawList_AddRectFilled(dl, .{ .x = pos.x, .y = top }, .{ .x = pos.x + size.x, .y = pos.y + size.y }, kit.app.colorU32(pal.surface));
    im.ImDrawList_AddLine(dl, .{ .x = pos.x, .y = top }, .{ .x = pos.x + size.x, .y = top }, kit.app.colorU32(pal.line));
    const footer = "MakeCleaner " ++ version ++ " \u{00B7} no telemetry, no ads, no network access";
    im.ImDrawList_AddTextImFontPtr(dl, app.fonts.regular, 12 * sc, .{ .x = pos.x + 12 * sc, .y = top + 6 * sc }, kit.app.colorU32(pal.muted), footer);
}

/// Draws `s` horizontally centered on `cx`; `y` is its top (or its middle for `.middle`).
fn text(dl: *im.ImDrawList, font: *im.ImFont, px: f32, cx: f32, y: f32, anchor: enum { top, middle }, rgb: u32, s: [*:0]const u8) void {
    const sz = im.ImFont_CalcTextSizeA(font, px, std.math.floatMax(f32), 0, s);
    const top = if (anchor == .middle) y - sz.y / 2 else y;
    im.ImDrawList_AddTextImFontPtr(dl, font, px, .{ .x = cx - sz.x / 2, .y = top }, kit.app.colorU32(rgb), s);
}
