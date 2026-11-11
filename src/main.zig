//! MakeCleaner entry. "/auto" [+ "/shutdown"] (any case) -> headless schedule.auto, exit code 0/1, no window.
//! Otherwise the GUI: left rail (Cleaner / Registry / Tools / Options), page on the right, thin footer.
const std = @import("std");
const kit = @import("kit");
const settings_mod = @import("core/settings.zig");
const cookies = @import("core/cookies.zig");
const schedule = @import("core/schedule.zig");
const ctx_mod = @import("ui/ctx.zig");
const Ctx = ctx_mod.Ctx;
const tools_ui = @import("ui/tools_ui.zig");
const ui_cleaner = @import("ui/cleaner.zig");
const ui_registry = @import("ui/registry.zig");
const ui_tools = @import("ui/tools.zig");
const ui_options = @import("ui/options.zig");

const im = kit.im;
const App = kit.app.App;
const pal = kit.app.palettes.carbon;

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

    const app = try App.init(gpa, .{ .title = "MakeCleaner", .size = .{ 1000, 680 }, .min_size = .{ 820, 560 }, .palette = pal, .icon_id = 1 });
    defer app.deinit();
    var state: State = .{ .ctx = .{ .gpa = gpa, .io = io, .app = app, .settings = &settings, .exe_dir = exe_dir } };
    state.cleaner = try ui_cleaner.Page.init(&state.ctx);
    defer state.cleaner.deinit(&state.ctx);
    state.registry = try ui_registry.Page.init(&state.ctx);
    defer state.registry.deinit(&state.ctx);
    state.tools = try ui_tools.Page.init(&state.ctx);
    defer state.tools.deinit(&state.ctx);
    state.options = try ui_options.Page.init(&state.ctx);
    defer state.options.deinit(&state.ctx);
    app.run(.{ .user = &state, .frame = frame, .close_requested = closeRequested });
    return 0;
}

fn has(args: []const []const u8, flag: []const u8) bool {
    for (args) |a| if (std.ascii.eqlIgnoreCase(a, flag)) return true;
    return false;
}

const Page = enum { cleaner, registry, tools, options };

/// Rail tiles: kit icon + label (= automation label).
const tiles = [_]struct { page: Page, icon: kit.icons.Name, label: [:0]const u8 }{
    .{ .page = .cleaner, .icon = .cleaner, .label = "Cleaner" },
    .{ .page = .registry, .icon = .registry, .label = "Registry" },
    .{ .page = .tools, .icon = .tools, .label = "Tools" },
    .{ .page = .options, .icon = .options, .label = "Options" },
};

const State = struct {
    page: Page = .cleaner,
    ctx: Ctx,
    cleaner: ui_cleaner.Page = undefined,
    registry: ui_registry.Page = undefined,
    tools: ui_tools.Page = undefined,
    options: ui_options.Page = undefined,
    about: tools_ui.Dialog = .{},
};

/// MainWindow.Closing: the Cleaner ticks are saved on close.
fn closeRequested(app: *App) bool {
    const s = app.userData(State);
    s.cleaner.saveChecks(&s.ctx);
    return true;
}

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
    text(dl, app.fonts.bold, 14 * sc, cx, logo.y + 17 * sc, .middle, pal.bg, "MC");
    text(dl, app.fonts.bold, 11 * sc, cx, logo.y + 38 * sc, .top, pal.text, "MakeCleaner");

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
        if (kit.icons.get(t.icon, 28)) |tex| {
            const px = kit.icons.pixels(28);
            const ix = @round(cx - px / 2); // whole pixels: the texture maps 1:1
            const iy = @round(y + 10 * sc);
            im.ImDrawList_AddImage(dl, tex, .{ .x = ix, .y = iy }, .{ .x = ix + px, .y = iy + px });
        }
        text(dl, app.fonts.regular, 12 * sc, cx, y + 42 * sc, .top, if (selected) pal.text else pal.rail_text, t.label);
        y += tile_h;
    }

    // ---- page
    im.ImGui_SetCursorScreenPos(.{ .x = pos.x + rail_w + 16 * sc, .y = pos.y + 14 * sc });
    if (im.ImGui_BeginChild("##page", .{ .x = size.x - rail_w - 32 * sc, .y = body_h - 26 * sc }, 0, im.ImGuiWindowFlags_NoBackground)) {
        switch (s.page) {
            .cleaner => s.cleaner.draw(&s.ctx),
            .registry => s.registry.draw(&s.ctx),
            .tools => s.tools.draw(&s.ctx),
            .options => s.options.draw(&s.ctx),
        }
    }
    im.ImGui_EndChild();

    // ---- footer: version + promise
    const top = pos.y + body_h;
    im.ImDrawList_AddRectFilled(dl, .{ .x = pos.x, .y = top }, .{ .x = pos.x + size.x, .y = pos.y + size.y }, kit.app.colorU32(pal.surface));
    im.ImDrawList_AddLine(dl, .{ .x = pos.x, .y = top }, .{ .x = pos.x + size.x, .y = top }, kit.app.colorU32(pal.line));
    const footer = "MakeCleaner " ++ ctx_mod.version ++ "  \u{00B7}  no telemetry, no ads, no network access";
    im.ImDrawList_AddTextImFontPtr(dl, app.fonts.regular, 12 * sc, .{ .x = pos.x + 12 * sc, .y = top + 6 * sc }, kit.app.colorU32(pal.muted), footer);
    // About link on the right -> themed info dialog
    const about_w = im.ImGui_CalcTextSize("About").x;
    im.ImGui_SetCursorScreenPos(.{ .x = pos.x + size.x - about_w - 12 * sc, .y = top + 4 * sc });
    if (im.ImGui_TextLink("About##about")) s.about.info(0, "About MakeCleaner", "{s}", .{ctx_mod.about_text});
    _ = s.about.draw();
}

/// Draws `s` horizontally centered on `cx`; `y` is its top (or its middle for `.middle`).
fn text(dl: *im.ImDrawList, font: *im.ImFont, px: f32, cx: f32, y: f32, anchor: enum { top, middle }, rgb: u32, s: [*:0]const u8) void {
    const sz = im.ImFont_CalcTextSizeA(font, px, std.math.floatMax(f32), 0, s);
    const top = if (anchor == .middle) y - sz.y / 2 else y;
    im.ImDrawList_AddTextImFontPtr(dl, font, px, .{ .x = cx - sz.x / 2, .y = top }, kit.app.colorU32(rgb), s);
}
