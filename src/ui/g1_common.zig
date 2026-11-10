//! MC-G1 shared GUI helpers: the themed Dialog (legacy Dialog.cs), the progress strip of Cleaner/Registry,
//! buttons (Theme.xaml: flat, min 110x32, Primary = accent) and the settings snapshot handed to workers.
//! Text items, N0, colours and job polling live in tools_ui.zig.
const std = @import("std");
const kit = @import("kit");
const settings_mod = @import("../core/settings.zig");
const ui = @import("tools_ui.zig");

const im = kit.im;
const pal = kit.app.palettes.cleaner;
const scale = ui.scale;
const col = ui.col;

/// Theme.xaml button: min 110 x 32, Primary = accent fill + white bold text; disabled = faded.
pub fn button(lbl: [*:0]const u8, enabled: bool, primary: bool) bool {
    return buttonMin(lbl, enabled, primary, 110);
}

pub fn buttonMin(lbl: [*:0]const u8, enabled: bool, primary: bool, min_w: f32) bool {
    const s = scale();
    const tw = im.ImGui_CalcTextSizeEx(lbl, null, true, -1).x;
    if (!enabled) im.ImGui_BeginDisabled(true);
    if (primary) ui.pushPrimary();
    const pressed = im.ImGui_ButtonEx(lbl, .{ .x = @max(min_w * s, tw + 32 * s), .y = 32 * s });
    if (primary) ui.popPrimary();
    if (!enabled) im.ImGui_EndDisabled();
    return pressed and enabled;
}

pub fn buttonWidth(lbl: [*:0]const u8) f32 {
    const s = scale();
    return @max(110 * s, im.ImGui_CalcTextSizeEx(lbl, null, true, -1).x + 32 * s);
}

/// Places the cursor so a `w`-wide item ends at the right edge of the content region (same line).
pub fn alignRight(w: f32) void {
    const avail = im.ImGui_GetContentRegionAvail().x;
    if (avail > w) im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + avail - w);
}

/// Bordered surface panel (the WPF Border with Surface/Line/CornerRadius 4); pair with endPanel.
pub fn beginPanel(id: [*:0]const u8, size: im.ImVec2, pad: im.ImVec2, auto_y: bool) bool {
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ChildBg, col(pal.surface));
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Border, col(pal.line));
    im.ImGui_PushStyleVar(im.ImGuiStyleVar_ChildRounding, 4 * scale());
    im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_WindowPadding, pad);
    const flags = im.ImGuiChildFlags_Borders | im.ImGuiChildFlags_AlwaysUseWindowPadding | (if (auto_y) im.ImGuiChildFlags_AutoResizeY else 0);
    const open = im.ImGui_BeginChild(id, size, flags, 0);
    im.ImGui_PopStyleVarEx(2);
    im.ImGui_PopStyleColorEx(2);
    return open;
}

pub fn endPanel() void {
    im.ImGui_EndChild();
}

/// Progress strip of Cleaner/Registry: status line (bold, wraps) + Cancel on the right; bar + "NN% (x of y)".
/// Labels: "<status>##<status_id>", "Cancel##<cancel_id>", "<pct text>##<text_id>". Returns true on Cancel.
pub fn progressStrip(panel_id: [*:0]const u8, status: []const u8, status_id: []const u8, cancel_label: [*:0]const u8, can_cancel: bool, done: u64, total: u64, pct_text: []const u8, text_id: []const u8) bool {
    const s = scale();
    var cancelled = false;
    if (beginPanel(panel_id, .{ .x = 0, .y = 0 }, .{ .x = 14 * s, .y = 10 * s }, true)) {
        const bw = 80 * s;
        const avail = im.ImGui_GetContentRegionAvail().x;
        const y0 = im.ImGui_GetCursorPosY();
        im.ImGui_PushFontFloat(boldFont(), 0);
        ui.textItem(status_id, status, pal.text, @max(40, avail - bw - 12 * s), false);
        im.ImGui_PopFont();
        const y1 = im.ImGui_GetCursorPosY();
        im.ImGui_SetCursorPos(.{ .x = im.ImGui_GetCursorPosX() + avail - bw, .y = y0 });
        if (!can_cancel) im.ImGui_BeginDisabled(true);
        if (im.ImGui_ButtonEx(cancel_label, .{ .x = bw, .y = 26 * s }) and can_cancel) cancelled = true;
        if (!can_cancel) im.ImGui_EndDisabled();
        im.ImGui_SetCursorPosY(@max(y1, y0 + 26 * s + im.ImGui_GetStyle().*.ItemSpacing.y) + 8 * s - im.ImGui_GetStyle().*.ItemSpacing.y);
        const tw = 110 * s;
        const frac: f32 = if (total == 0) 0 else @as(f32, @floatFromInt(@min(done, total))) / @as(f32, @floatFromInt(total));
        im.ImGui_ProgressBar(frac, .{ .x = avail - tw - 10 * s, .y = 10 * s }, "");
        im.ImGui_SameLineEx(0, 10 * s);
        im.ImGui_SetCursorPosY(im.ImGui_GetCursorPosY() - 3 * s);
        im.ImGui_PushFontFloat(null, im.ImGui_GetStyle().*.FontSizeBase * 0.8);
        const pw = im.ImGui_CalcTextSizeEx(pct_text.ptr, pct_text.ptr + pct_text.len, false, -1).x;
        im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + @max(0, tw - pw));
        ui.textItem(text_id, pct_text, pal.muted, 0, false);
        im.ImGui_PopFont();
    }
    endPanel();
    return cancelled;
}

/// Results/issue list tables (the WPF ListView + GridView).
pub const list_flags = im.ImGuiTableFlags_Borders | im.ImGuiTableFlags_RowBg | im.ImGuiTableFlags_ScrollY | im.ImGuiTableFlags_Resizable;

/// WPF `Cursor = Cursors.Wait` on a busy view: call from the page's draw (current window = the page).
pub fn waitCursor() void {
    if (im.ImGui_IsWindowHovered(im.ImGuiHoveredFlags_ChildWindows)) im.ImGui_SetMouseCursor(im.ImGuiMouseCursor_Wait);
}

pub fn boldFont() ?*im.ImFont {
    return if (kit.app.current()) |a| a.fonts.bold else null;
}

/// "{done*100/total}% ({done} of {total})", "" when total == 0 (CleanerView's progressText).
pub fn pctText(buf: []u8, done: u64, total: u64) []const u8 {
    if (total == 0) return "";
    return std.mem.print(buf, "{d}% ({d} of {d})", .{ @min(done, total) * 100 / total, done, total }) catch "";
}

/// Copy of `s` for a worker thread (Settings is not thread-safe; the UI keeps writing the original).
pub fn snapshot(s: *const settings_mod.Settings) !settings_mod.Settings {
    var c: settings_mod.Settings = .{ .gpa = s.gpa, .path = try s.gpa.dupe(u8, s.path) };
    errdefer c.deinit();
    for (s.values.keys(), s.values.values()) |k, v| try c.set(k, v);
    return c;
}

// ---------------------------------------------------------------- Dialog (Dialog.cs)

pub const Kind = enum { info, question, warning, err };

pub const Answer = struct { tag: u32, index: usize };

/// Themed modal: icon glyph, text, buttons (buttons[0] primary; Enter = 0, Esc = last). Immediate mode:
/// `show` once, then `draw` every frame in the same window context; `draw` returns the answer once.
/// Automation labels: "<text>##dialogButton<i>", "<text>##dialogText".
pub const Dialog = struct {
    tag: u32 = 0,
    kind: Kind = .info,
    title: [200:0]u8 = @splat(0),
    text: [1200]u8 = undefined,
    text_len: usize = 0,
    buttons: [3][100:0]u8 = @splat(@splat(0)),
    n: usize = 0,
    open: bool = false,
    want_open: bool = false,

    pub fn show(d: *Dialog, tag: u32, kind: Kind, title: []const u8, text: []const u8, buttons: []const []const u8) void {
        d.tag = tag;
        d.kind = kind;
        _ = std.mem.printSentinel(&d.title, "{s}###g1dialog", .{title[0..@min(title.len, 180)]}, 0) catch {};
        d.text_len = @min(text.len, d.text.len);
        @memcpy(d.text[0..d.text_len], text[0..d.text_len]);
        d.n = @min(buttons.len, 3);
        for (buttons[0..d.n], 0..) |b, i| _ = std.mem.printSentinel(&d.buttons[i], "{s}##dialogButton{d}", .{ b[0..@min(b.len, 80)], i }, 0) catch {};
        d.open = true;
        d.want_open = true;
    }

    pub fn draw(d: *Dialog) ?Answer {
        if (!d.open) return null;
        const s = scale();
        if (d.want_open) {
            _ = im.ImGui_OpenPopup(&d.title, 0);
            d.want_open = false;
        }
        const vp = im.ImGui_GetMainViewport();
        im.ImGui_SetNextWindowPosEx(im.ImGuiViewport_GetCenter(vp), im.ImGuiCond_Appearing, .{ .x = 0.5, .y = 0.5 });
        im.ImGui_SetNextWindowSizeConstraints(.{ .x = 480 * s, .y = 0 }, .{ .x = 480 * s, .y = 10000 }, null, null);
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_PopupBg, col(pal.surface));
        im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_WindowPadding, .{ .x = 22 * s, .y = 22 * s });
        const visible = im.ImGui_BeginPopupModal(&d.title, null, im.ImGuiWindowFlags_AlwaysAutoResize | im.ImGuiWindowFlags_NoSavedSettings);
        im.ImGui_PopStyleVar();
        im.ImGui_PopStyleColor();
        if (!visible) {
            // closed behind our back (should not happen: no X, Esc handled below)
            if (!im.ImGui_IsPopupOpen(&d.title, 0)) d.open = false;
            return null;
        }
        defer im.ImGui_EndPopup();

        const icon: u21, const icol: u32 = switch (d.kind) {
            .warning => .{ kit.ui.icons.warning, pal.danger },
            .err => .{ kit.ui.icons.err, pal.danger },
            .question => .{ kit.ui.icons.question, pal.accent },
            .info => .{ kit.ui.icons.info, pal.accent },
        };
        const g = kit.ui.glyph(icon);
        im.ImGui_PushFontFloat(null, 28);
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Text, col(icol));
        im.ImGui_TextUnformatted(&g);
        im.ImGui_PopStyleColor();
        im.ImGui_PopFont();
        im.ImGui_SameLineEx(0, 16 * s);
        im.ImGui_PushFontFloat(null, 14 * 16.0 / 13.0); // FontSize 14 of a 13 px WPF base
        ui.textItem("dialogText", d.text[0..d.text_len], pal.text, im.ImGui_GetContentRegionAvail().x, false);
        im.ImGui_PopFont();

        // footer band: Bg + top line, buttons right-aligned
        const win_pos = im.ImGui_GetWindowPos();
        const win_size = im.ImGui_GetWindowSize();
        const y = im.ImGui_GetCursorScreenPos().y + 4 * s;
        const dl = im.ImGui_GetWindowDrawList();
        im.ImDrawList_PushClipRect(dl, win_pos, .{ .x = win_pos.x + win_size.x, .y = win_pos.y + win_size.y }, false);
        im.ImDrawList_AddRectFilled(dl, .{ .x = win_pos.x, .y = y }, .{ .x = win_pos.x + win_size.x, .y = win_pos.y + win_size.y }, kit.app.colorU32(pal.bg));
        im.ImDrawList_AddLine(dl, .{ .x = win_pos.x, .y = y }, .{ .x = win_pos.x + win_size.x, .y = y }, kit.app.colorU32(pal.line));
        im.ImDrawList_PopClipRect(dl);
        im.ImGui_SetCursorScreenPos(.{ .x = im.ImGui_GetCursorScreenPos().x, .y = y + 12 * s });

        var row_w: f32 = 0;
        for (d.buttons[0..d.n]) |*b| row_w += buttonWidth(b) + 8 * s;
        alignRight(row_w - 8 * s);
        var result: ?usize = null;
        for (d.buttons[0..d.n], 0..) |*b, i| {
            if (i > 0) im.ImGui_SameLineEx(0, 8 * s);
            if (button(b, true, i == 0)) result = i;
            if (i == 0) im.ImGui_SetItemDefaultFocus();
        }
        if (result == null and d.n > 0 and !im.ImGui_IsWindowAppearing()) {
            if (im.ImGui_IsKeyPressed(im.ImGuiKey_Enter) or im.ImGui_IsKeyPressed(im.ImGuiKey_KeypadEnter)) result = 0;
            if (im.ImGui_IsKeyPressed(im.ImGuiKey_Escape)) result = d.n - 1;
        }
        const r = result orelse return null;
        im.ImGui_CloseCurrentPopup();
        d.open = false;
        return .{ .tag = d.tag, .index = r };
    }
};
