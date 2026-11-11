//! MC-G1 shared GUI helpers: the progress strip of Cleaner/Registry, buttons (Theme.xaml: flat, min 110 wide,
//! Primary = accent) and the settings snapshot handed to workers. The Dialog, N0 and colours live in tools_ui.zig.
const std = @import("std");
const kit = @import("kit");
const settings_mod = @import("../core/settings.zig");
const ui = @import("tools_ui.zig");

const im = kit.im;
const pal = kit.app.palettes.carbon;
const scale = ui.scale;
const col = ui.col;

/// Theme.xaml button: min 110 wide, `buttonHeight` tall, Primary = mint fill + anthracite text (kit.ui.primaryButtonEx); disabled = faded.
pub fn button(lbl: [*:0]const u8, enabled: bool, primary: bool) bool {
    return buttonMin(lbl, enabled, primary, 110);
}

pub fn buttonMin(lbl: [*:0]const u8, enabled: bool, primary: bool, min_w: f32) bool {
    const s = scale();
    const tw = im.ImGui_CalcTextSizeEx(lbl, null, true, -1).x;
    if (!enabled) im.ImGui_BeginDisabled(true);
    const size: im.ImVec2 = .{ .x = @max(min_w * s, tw + 32 * s), .y = buttonHeight() };
    const pressed = if (primary) kit.ui.primaryButtonEx(lbl, size) else im.ImGui_ButtonEx(lbl, size);
    if (!enabled) im.ImGui_EndDisabled();
    return pressed and enabled;
}

/// Page action buttons (Analyze, Run Cleaner, Scan...): one step above the kit's frame height (24 + 4 at 96 DPI).
pub fn buttonHeight() f32 {
    return im.ImGui_GetFrameHeight() + 4 * scale();
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
        kit.ui.text(status_id, status, pal.text, @max(40, avail - bw - 12 * s));
        im.ImGui_PopFont();
        const y1 = im.ImGui_GetCursorPosY();
        im.ImGui_SetCursorPos(.{ .x = im.ImGui_GetCursorPosX() + avail - bw, .y = y0 });
        if (!can_cancel) im.ImGui_BeginDisabled(true);
        if (im.ImGui_ButtonEx(cancel_label, .{ .x = bw, .y = 0 }) and can_cancel) cancelled = true;
        if (!can_cancel) im.ImGui_EndDisabled();
        im.ImGui_SetCursorPosY(@max(y1, y0 + im.ImGui_GetFrameHeight() + im.ImGui_GetStyle().*.ItemSpacing.y) + 8 * s - im.ImGui_GetStyle().*.ItemSpacing.y);
        const tw = 110 * s;
        // idle, nothing analyzed/scanned yet: status line only; the bar row is drawn fully transparent so the
        // strip keeps its height (ponytail: alpha 0 instead of measuring the row)
        const idle = total == 0 and !can_cancel;
        if (idle) im.ImGui_PushStyleVar(im.ImGuiStyleVar_Alpha, 0);
        defer if (idle) im.ImGui_PopStyleVar();
        const frac: f32 = if (total == 0) 0 else @as(f32, @floatFromInt(@min(done, total))) / @as(f32, @floatFromInt(total));
        im.ImGui_ProgressBar(frac, .{ .x = avail - tw - 10 * s, .y = 10 * s }, "");
        im.ImGui_SameLineEx(0, 10 * s);
        im.ImGui_PushFontFloat(null, im.ImGui_GetStyle().*.FontSizeBase * 0.8);
        // centred on the bar; the text line inherits the bar's FramePadding.y baseline offset, hence the minus
        im.ImGui_SetCursorPosY(im.ImGui_GetCursorPosY() + (10 * s - im.ImGui_GetFontSize()) / 2 - im.ImGui_GetStyle().*.FramePadding.y);
        const pw = im.ImGui_CalcTextSizeEx(pct_text.ptr, pct_text.ptr + pct_text.len, false, -1).x;
        im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + @max(0, tw - pw));
        kit.ui.text(text_id, pct_text, pal.muted, 0);
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
