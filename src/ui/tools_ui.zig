//! Shared helpers for the Tools and Options pages (legacy ToolsUi.cs + SubNavPage.cs + Dialog.cs bits):
//! sub-navigation list, labelled status lines (automation items), modal dialogs as a small state machine,
//! "Save to text file", open-folder, folder picker, local date formatting, fixed text buffers.
const std = @import("std");
const kit = @import("kit");
const Ctx = @import("ctx.zig").Ctx;
const elevated = @import("../core/elevated.zig");

const im = kit.im;
const w = kit.w;
pub const pal = kit.app.palettes.cleaner;

pub fn col(rgb: u32) im.ImVec4 {
    return kit.app.color(rgb, 1);
}

pub fn scale() f32 {
    return if (kit.app.current()) |a| a.scale() else 1.0;
}

/// printSentinel into `buf`; "" when it does not fit (for widget labels use `idLabel`).
pub fn z(buf: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    return std.mem.printSentinel(buf, fmt, args, 0) catch "";
}

/// "text##id" in `buf`; a text too long for `buf` is cut (at a UTF-8 boundary) so the "##id" part always fits
/// and the ImGui id stays unique.
pub fn idLabel(buf: []u8, text: []const u8, comptime id_fmt: []const u8, args: anytype) [:0]const u8 {
    var ib: [128]u8 = undefined;
    const id: []const u8 = std.mem.print(&ib, "##" ++ id_fmt, args) catch "##?";
    var n = @min(text.len, buf.len -| (id.len + 1));
    if (n < text.len) while (n > 0 and text[n] & 0xC0 == 0x80) : (n -= 1) {};
    @memcpy(buf[0..n], text[0..n]);
    @memcpy(buf[n..][0..id.len], id);
    buf[n + id.len] = 0;
    return buf[0 .. n + id.len :0];
}

test idLabel {
    var small: [16]u8 = undefined;
    try std.testing.expectEqualStrings("abc##r7", idLabel(&small, "abc", "r{d}", .{7}));
    // 11 bytes of room: the 2-byte "Ї" at bytes 10..11 must not be split
    try std.testing.expectEqualStrings("aaaaaaaaaa##r7", idLabel(&small, "aaaaaaaaaaЇ", "r{d}", .{7}));
    try std.testing.expectEqualStrings("aaaaaaaaaЇ##r7", idLabel(&small, "aaaaaaaaaЇЇ", "r{d}", .{7}));
}

// ---------------------------------------------------------------- tables (WPF GridView look)

/// Legacy GridView columns: the user can drag the widths (legacy widths are the initial weights), cut-off cells
/// show their full text as a tooltip (`cell` / `rowTip`), no lines in the body.
/// ponytail: no ScrollX - with it, columns scrolled out of view submit no items (automation cannot read them) and a
/// SpanAllColumns row's centre (where automation clicks) can fall outside the table.
pub const table_flags = im.ImGuiTableFlags_ScrollY | im.ImGuiTableFlags_Resizable | im.ImGuiTableFlags_NoBordersInBody |
    im.ImGuiTableFlags_BordersOuter | im.ImGuiTableFlags_SizingStretchProp;

/// Full `text` as a tooltip (wrapped at 600 px) on hover of the last item.
pub fn tip(text: []const u8) void {
    if (!im.ImGui_IsItemHovered(im.ImGuiHoveredFlags_ForTooltip) or !im.ImGui_BeginTooltip()) return;
    im.ImGui_PushTextWrapPos(600 * scale());
    im.ImGui_TextUnformattedEx(text.ptr, text.ptr + text.len);
    im.ImGui_PopTextWrapPos();
    im.ImGui_EndTooltip();
}

/// Text width (no wrap).
pub fn textW(text: []const u8) f32 {
    return im.ImGui_CalcTextSizeEx(text.ptr, text.ptr + text.len, false, -1).x;
}

/// Tooltip for the row Selectable just submitted (it spans every column): only over its own cell, only when
/// `avail` (cell width before the Selectable) cut the text off.
pub fn rowTip(text: []const u8, avail: f32) void {
    if (textW(text) > avail and im.ImGui_TableGetHoveredColumn() == im.ImGui_TableGetColumnIndex()) tip(text);
}

/// Table cell: `text` drawn over an InvisibleButton labelled "text##id", so automation can read the value. The row
/// Selectable must be submitted earlier in the row: it then keeps hover and clicks (ItemHoverable lets the first
/// hovered item win). The full text shows as a tooltip when the column cuts it off.
pub fn cell(text: []const u8, comptime id_fmt: []const u8, args: anytype) void {
    var buf: [1100]u8 = undefined;
    const avail = im.ImGui_GetContentRegionAvail().x;
    const tw = textW(text);
    const pos = im.ImGui_GetCursorScreenPos();
    _ = im.ImGui_InvisibleButton(idLabel(&buf, text, id_fmt, args).ptr, .{ .x = std.math.clamp(@min(tw, avail), 1, 100000), .y = im.ImGui_GetTextLineHeight() }, 0);
    if (text.len > 0) im.ImDrawList_AddTextEx(im.ImGui_GetWindowDrawList(), pos, im.ImGui_GetColorU32(im.ImGuiCol_Text), text.ptr, text.ptr + text.len);
    if (tw > avail) tip(text);
}

// ---------------------------------------------------------------- fixed text buffers (InputText)

pub fn Buf(comptime n: usize) type {
    return struct {
        b: [n:0]u8 = @splat(0),

        pub fn slice(self: *const @This()) []const u8 {
            return std.mem.sliceTo(&self.b, 0);
        }
        pub fn trimmed(self: *const @This()) []const u8 {
            return std.mem.trim(u8, self.slice(), &std.ascii.whitespace);
        }
        pub fn set(self: *@This(), s: []const u8) void {
            const len = @min(s.len, n);
            @memcpy(self.b[0..len], s[0..len]);
            @memset(self.b[len..], 0);
        }
        /// InputText with this buffer; returns true when edited.
        pub fn input(self: *@This(), lbl: [*:0]const u8, width: f32) bool {
            if (width != 0) im.ImGui_SetNextItemWidth(width);
            return im.ImGui_InputText(lbl, &self.b, n + 1, 0);
        }
    };
}

pub fn initBuf(comptime n: usize, comptime s: []const u8) Buf(n) {
    var b: Buf(n) = .{};
    @memcpy(b.b[0..s.len], s);
    return b;
}

// ---------------------------------------------------------------- layout bits

/// Page title (FontSize 18, SemiBold) like OptionsPages.Page.
pub fn title(ctx: *Ctx, text: [*:0]const u8) void {
    im.ImGui_PushFontFloat(ctx.app.fonts.bold, 18);
    im.ImGui_TextUnformatted(text);
    im.ImGui_PopFont();
    im.ImGui_Dummy(.{ .x = 0, .y = 4 * scale() });
}

pub fn muted(text: []const u8) void {
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Text, col(pal.muted));
    im.ImGui_TextUnformattedEx(text.ptr, text.ptr + text.len);
    im.ImGui_PopStyleColor();
}

pub fn mutedWrapped(text: []const u8, width: f32) void {
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Text, col(pal.muted));
    im.ImGui_PushTextWrapPos(im.ImGui_GetCursorPosX() + width);
    im.ImGui_TextUnformattedEx(text.ptr, text.ptr + text.len);
    im.ImGui_PopTextWrapPos();
    im.ImGui_PopStyleColor();
}

/// Text aligned with framed widgets on the same line.
pub fn label(text: [*:0]const u8) void {
    im.ImGui_AlignTextToFramePadding();
    im.ImGui_TextUnformatted(text);
}

/// Button of the right-hand button column (160 px wide, ButtonColumn style).
pub fn colButton(text: [*:0]const u8, enabled: bool) bool {
    im.ImGui_BeginDisabled(!enabled);
    defer im.ImGui_EndDisabled();
    return im.ImGui_ButtonEx(text, .{ .x = 160 * scale(), .y = 0 });
}

pub fn button(text: [*:0]const u8, enabled: bool) bool {
    im.ImGui_BeginDisabled(!enabled);
    defer im.ImGui_EndDisabled();
    return im.ImGui_ButtonEx(text, .{ .x = @max(90 * scale(), im.ImGui_CalcTextSizeEx(text, null, true, -1).x + im.ImGui_GetStyle().*.FramePadding.x * 2), .y = 0 });
}

/// Checkbox with the compact box of kit.ui.triCheckbox (~20 px, not button-tall).
pub fn check(lbl: [*:0]const u8, v: *bool) bool {
    const pad = im.ImGui_GetStyle().*.FramePadding;
    im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_FramePadding, .{ .x = pad.x, .y = @max(1, pad.y * 0.35) });
    defer im.ImGui_PopStyleVar();
    return im.ImGui_Checkbox(lbl, v);
}

/// Accent colours of the "Primary" button style; pair with popPrimary.
pub fn pushPrimary() void {
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Button, col(pal.accent));
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ButtonHovered, col(pal.accent_dark));
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ButtonActive, col(pal.accent_dark));
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Text, col(0xFFFFFF));
}

pub fn popPrimary() void {
    im.ImGui_PopStyleColorEx(4);
}

/// Primary (accent) button, like the "Primary" style.
pub fn primary(text: [*:0]const u8, enabled: bool) bool {
    pushPrimary();
    defer popPrimary();
    return button(text, enabled);
}

/// style.ItemSpacing.y (vertical gap ImGui adds after every item).
pub fn sp() f32 {
    return im.ImGui_GetStyle().*.ItemSpacing.y;
}

/// Width of the button column incl. its left margin.
pub fn colWidth() f32 {
    return (160 + 12) * scale();
}

/// Text that automation can read: an invisible item "text##id" with the text drawn over it (plain TextUnformatted
/// is not an item, notes K8). `wrap_w` > 0 wraps at that width; `full_width` makes the item exactly `wrap_w` wide
/// (so widgets can follow on the same line), else it hugs the text.
pub fn textItem(id: []const u8, text: []const u8, rgb: u32, wrap_w: f32, full_width: bool) void {
    var buf: [1100]u8 = undefined;
    const end = text.ptr + text.len;
    var size = im.ImGui_CalcTextSizeEx(text.ptr, end, false, if (wrap_w > 0) wrap_w else -1);
    if (full_width) size.x = wrap_w;
    size.x = @max(1, size.x);
    size.y = @max(size.y, im.ImGui_GetFontSize());
    const pos = im.ImGui_GetCursorScreenPos();
    _ = im.ImGui_InvisibleButton(idLabel(&buf, text, "{s}", .{id}).ptr, size, 0);
    if (text.len > 0) im.ImDrawList_AddTextImFontPtrEx(im.ImGui_GetWindowDrawList(), im.ImGui_GetFont(), im.ImGui_GetFontSize(), pos, kit.app.colorU32(rgb), text.ptr, end, @max(0, wrap_w), null);
}

/// Labelled status line ("text##id") wrapped to the available width.
pub fn status(id: []const u8, text: []const u8, rgb: u32) void {
    statusIn(id, text, rgb, im.ImGui_GetContentRegionAvail().x);
}

/// `status` occupying exactly `width` (text wrapped to it), so widgets can follow on the same line.
pub fn statusIn(id: []const u8, text: []const u8, rgb: u32, width: f32) void {
    textItem(id, text, rgb, @max(50, width), true);
}

/// Fixed-size text of a view's status line: `set` formats into it (cut when too long), `slice` reads it.
pub fn Text(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,

        pub fn set(t: *@This(), comptime fmt: []const u8, args: anytype) void {
            const out: []const u8 = std.mem.print(&t.buf, fmt, args) catch &t.buf;
            t.len = out.len;
        }
        pub fn slice(t: *const @This()) []const u8 {
            return t.buf[0..t.len];
        }
    };
}

// ---------------------------------------------------------------- sub-navigation (SubNavPage)

/// Left sub-menu (180 px, Surface background, AccentSoft selection). Items are "Title##<id><i>".
/// Draws inside its own child; returns nothing, `sel` changes on click.
pub fn subNav(id: []const u8, titles: []const [:0]const u8, sel: *usize, height: f32) void {
    const s = scale();
    var buf: [64]u8 = undefined;
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ChildBg, col(pal.surface));
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Border, col(pal.line));
    im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });
    defer {
        im.ImGui_PopStyleVar();
        im.ImGui_PopStyleColorEx(2);
    }
    if (im.ImGui_BeginChild(z(&buf, "##{s}Nav", .{id}).ptr, .{ .x = 180 * s, .y = height }, im.ImGuiChildFlags_Borders, 0)) {
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Header, col(pal.accent_soft));
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_HeaderHovered, col(pal.bg));
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_HeaderActive, col(pal.accent_soft));
        im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_ItemSpacing, .{ .x = 0, .y = 0 });
        im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_SelectableTextAlign, .{ .x = 0, .y = 0.5 });
        for (titles, 0..) |t, i| {
            var lb: [96]u8 = undefined;
            im.ImGui_SetCursorPosX(0);
            const pos = im.ImGui_GetCursorScreenPos();
            const h = im.ImGui_GetFontSize() + 18 * s;
            // the Selectable's own text is transparent so the drawn text can carry the 14 px left padding;
            // its label "Title##<id>Nav<i>" stays the automation handle
            // (the selected item keeps AccentSoft under the mouse, like the WPF IsSelected trigger)
            im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Text, kit.app.color(0, 0));
            im.ImGui_PushStyleColorImVec4(im.ImGuiCol_HeaderHovered, col(if (sel.* == i) pal.accent_soft else pal.bg));
            if (im.ImGui_SelectableEx(z(&lb, "{s}##{s}Nav{d}", .{ t, id, i }).ptr, sel.* == i, 0, .{ .x = 180 * s, .y = h })) sel.* = i;
            im.ImGui_PopStyleColorEx(2);
            im.ImDrawList_AddText(im.ImGui_GetWindowDrawList(), .{ .x = pos.x + 14 * s, .y = pos.y + 9 * s }, kit.app.colorU32(pal.text), t.ptr);
        }
        im.ImGui_PopStyleVarEx(2);
        im.ImGui_PopStyleColorEx(3);
    }
    im.ImGui_EndChild();
}

/// Combo box: a frame-styled button "<current>##<id>" opening a popup of "<item>##<id><i>" selectables.
/// Returns true when the selection changed.
/// ponytail: local instead of ImGui BeginCombo - it has no test-engine ITEM_INFO hook in this ImGui, so kit
/// automation cannot find a combo by label; move to the kit if another app needs it.
pub fn combo(id: []const u8, items: []const [*:0]const u8, cur: *c_int, width: f32) bool {
    const s = scale();
    var lb: [256]u8 = undefined;
    var pb: [64]u8 = undefined;
    const idx: usize = @intCast(std.math.clamp(cur.*, 0, @as(c_int, @intCast(items.len)) - 1));
    const popup = z(&pb, "##{s}Popup", .{id});
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Button, im.ImGui_GetStyle().*.Colors[@intCast(im.ImGuiCol_FrameBg)]);
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ButtonHovered, im.ImGui_GetStyle().*.Colors[@intCast(im.ImGuiCol_FrameBgHovered)]);
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ButtonActive, im.ImGui_GetStyle().*.Colors[@intCast(im.ImGuiCol_FrameBgActive)]);
    im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_ButtonTextAlign, .{ .x = 0, .y = 0.5 });
    const pos = im.ImGui_GetCursorScreenPos();
    if (im.ImGui_ButtonEx(z(&lb, "{s}##{s}", .{ std.mem.span(items[idx]), id }).ptr, .{ .x = width, .y = 0 })) _ = im.ImGui_OpenPopup(popup.ptr, 0);
    im.ImGui_PopStyleVar();
    im.ImGui_PopStyleColorEx(3);
    const h = im.ImGui_GetFrameHeight();
    const arrow = kit.ui.glyph(0xE70D); // ChevronDown
    im.ImDrawList_AddTextImFontPtr(im.ImGui_GetWindowDrawList(), im.ImGui_GetFont(), im.ImGui_GetFontSize() * 0.7, .{ .x = pos.x + width - h * 0.75, .y = pos.y + h * 0.3 }, kit.app.colorU32(pal.muted), &arrow);
    var changed = false;
    im.ImGui_SetNextWindowPos(.{ .x = pos.x, .y = pos.y + h }, 0);
    im.ImGui_SetNextWindowSizeConstraints(.{ .x = width, .y = 0 }, .{ .x = 10000 * s, .y = 10000 * s }, null, null);
    if (im.ImGui_BeginPopup(popup.ptr, 0)) {
        for (items, 0..) |it, i| {
            if (im.ImGui_SelectableEx(z(&lb, "{s}##{s}{d}", .{ std.mem.span(it), id, i }).ptr, i == idx, 0, .{ .x = 0, .y = 0 })) {
                changed = cur.* != @as(c_int, @intCast(i));
                cur.* = @intCast(i);
            }
        }
        im.ImGui_EndPopup();
    }
    return changed;
}

/// Tab strip ("Title##id" per tab, underline on the selected one).
/// ponytail: local instead of ImGui TabBar - Dear ImGui's TabItemEx has no test-engine ITEM_INFO hook, so
/// kit automation cannot see tab labels; move to the kit if another app needs it.
pub fn tabs(titles: []const [:0]const u8, ids: []const []const u8, cur: *usize) void {
    const s = scale();
    const dl = im.ImGui_GetWindowDrawList();
    const pad = 12 * s;
    const h = im.ImGui_GetFontSize() + 12 * s;
    const start = im.ImGui_GetCursorScreenPos();
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Header, col(pal.surface));
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_HeaderHovered, col(pal.accent_soft));
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_HeaderActive, col(pal.accent_soft));
    im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_SelectableTextAlign, .{ .x = 0.5, .y = 0.5 });
    for (titles, ids, 0..) |t, id, i| {
        if (i > 0) im.ImGui_SameLineEx(0, 2 * s);
        var lb: [96]u8 = undefined;
        const tw = im.ImGui_CalcTextSize(t.ptr).x + pad * 2;
        const pos = im.ImGui_GetCursorScreenPos();
        if (im.ImGui_SelectableEx(z(&lb, "{s}##{s}", .{ t, id }).ptr, cur.* == i, 0, .{ .x = tw, .y = h })) cur.* = i;
        if (cur.* == i) im.ImDrawList_AddRectFilled(dl, .{ .x = pos.x, .y = pos.y + h - 2 * s }, .{ .x = pos.x + tw, .y = pos.y + h }, kit.app.colorU32(pal.accent));
    }
    im.ImGui_PopStyleVar();
    im.ImGui_PopStyleColorEx(3);
    const y = start.y + h;
    im.ImDrawList_AddLine(dl, .{ .x = start.x, .y = y }, .{ .x = start.x + im.ImGui_GetContentRegionAvail().x, .y = y }, kit.app.colorU32(pal.line));
    im.ImGui_Dummy(.{ .x = 0, .y = 4 * s });
}

// ---------------------------------------------------------------- modal dialog (Dialog.cs) as a state machine

pub const Answer = struct { tag: u8, button: usize };

/// One pending message box per page. `show` arms it (from anywhere in the frame); `draw` must be called
/// once per frame from a fixed place of the page and returns the answer once.
pub const Dialog = struct {
    want_open: bool = false,
    title_buf: [96:0]u8 = @splat(0),
    kind: kit.ui.MsgKind = .info,
    text_buf: [1024]u8 = undefined,
    text_len: usize = 0,
    buttons: [2][*:0]const u8 = .{ "OK", "Cancel" },
    n_buttons: usize = 1,
    tag: u8 = 0,

    /// title = window title (also the automation window name); buttons[0] = default action.
    pub fn show(d: *Dialog, tag: u8, ttl: []const u8, kind: kit.ui.MsgKind, buttons: []const [*:0]const u8, comptime fmt: []const u8, args: anytype) void {
        _ = std.mem.printSentinel(&d.title_buf, "{s}##dlg", .{ttl}, 0) catch {};
        const t: []const u8 = std.mem.print(&d.text_buf, fmt, args) catch &d.text_buf;
        d.text_len = t.len;
        d.kind = kind;
        for (buttons, 0..) |b, i| d.buttons[i] = b;
        d.n_buttons = buttons.len;
        d.tag = tag;
        d.want_open = true;
    }

    /// ToolsUi.Confirm: the title doubles as the action button.
    pub fn confirm(d: *Dialog, tag: u8, ttl: [*:0]const u8, comptime fmt: []const u8, args: anytype) void {
        d.show(tag, std.mem.span(ttl), .warning, &.{ ttl, "Cancel" }, fmt, args);
    }

    pub fn info(d: *Dialog, tag: u8, ttl: []const u8, comptime fmt: []const u8, args: anytype) void {
        d.show(tag, ttl, .info, &.{"OK"}, fmt, args);
    }

    pub fn draw(d: *Dialog) ?Answer {
        const id: [*:0]const u8 = &d.title_buf;
        if (d.want_open) {
            kit.ui.openMessage(id);
            d.want_open = false;
        }
        const b = kit.ui.messageBox(id, d.kind, d.text_buf[0..d.text_len], d.buttons[0..d.n_buttons]) orelse return null;
        return .{ .tag = d.tag, .button = b };
    }
};

/// ToolsUi.RequireAdmin: true when already elevated; else asks (answer with `tag`) and returns false.
/// On a "Restart as administrator" answer call `restartAsAdmin`.
pub fn requireAdmin(d: *Dialog, tag: u8, what: []const u8) bool {
    if (elevated.isAdmin()) return true;
    d.show(tag, "Administrator rights", .question, &.{ "Restart as administrator", "Cancel" }, "{s} requires administrator rights. Restart MakeCleaner as administrator?", .{what});
    return false;
}

pub fn restartAsAdmin(ctx: *Ctx) void {
    if (elevated.relaunchAsAdmin()) ctx.app.quit();
}

// ---------------------------------------------------------------- shell helpers

/// ToolsUi.OpenFolder: explorer /select,"file".
pub fn openFolder(gpa: std.mem.Allocator, file: []const u8) void {
    const params = gpa.print("/select,\"{s}\"", .{file}) catch return;
    defer gpa.free(params);
    _ = kit.win.shellExecute(gpa, .{ .file = "explorer.exe", .params = params }) catch {};
}

/// ToolsUi.PickFolder: appends the picked folder to a "; "-separated box (or replaces it when `append` is false).
pub fn pickFolder(ctx: *Ctx, comptime n: usize, box: *Buf(n), append: bool) void {
    const picked = (kit.win.pickFolder(ctx.gpa, ctx.app.hwnd, .{}) catch null) orelse return;
    defer ctx.gpa.free(picked);
    const cur = box.slice();
    if (!append or cur.len == 0) return box.set(picked);
    var tmp: [n + 1]u8 = undefined;
    box.set(std.mem.print(&tmp, "{s}; {s}", .{ cur, picked }) catch return);
}

/// Dialog tag of the "could not write" message (pages ignore its answer).
pub const tag_write_error = 0xFF;

/// ToolsUi.SaveText: "MakeCleaner <name>.txt", text files filter; `lines` written CRLF-terminated (WriteAllLines).
/// A write failure (no permission, disk full) is reported through `dlg` (C# showed the exception dialog).
pub fn saveText(ctx: *Ctx, dlg: *Dialog, name: []const u8, lines: []const []const u8) void {
    var nb: [128]u8 = undefined;
    const file_name: []const u8 = std.mem.print(&nb, "MakeCleaner {s}.txt", .{name}) catch "MakeCleaner.txt";
    const path = (kit.win.saveFile(ctx.gpa, ctx.app.hwnd, .{
        .file_name = file_name,
        .filters = &.{.{ .name = "Text files (*.txt)", .spec = "*.txt" }},
        .default_ext = "txt",
    }) catch null) orelse return;
    defer ctx.gpa.free(path);
    writeLines(ctx.io, path, lines) catch |e| dlg.show(tag_write_error, "Save to text file", .err, &.{"OK"}, "Could not write {s}:\n{t}", .{ path, e });
}

pub fn writeLines(io: std.Io, path: []const u8, lines: []const []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var fw = f.writer(io, &buf);
    for (lines) |l| {
        try fw.interface.writeAll(l);
        try fw.interface.writeAll("\r\n");
    }
    try fw.interface.flush();
}

// ---------------------------------------------------------------- dates (user locale, like ToString("g"))

fn fmtSystemTime(buf: []u8, st: *const w.SYSTEMTIME, with_time: bool) []const u8 {
    var wb: [128]u16 = undefined;
    var n: usize = @intCast(@max(0, w.GetDateFormatEx(null, @intCast(w.DATE_SHORTDATE), st, null, &wb, 64, null)));
    if (n > 0) n -= 1; // drop the NUL
    if (with_time) {
        wb[n] = ' ';
        const m: usize = @intCast(@max(0, w.GetTimeFormatEx(null, @intCast(w.TIME_NOSECONDS), st, null, wb[n + 1 ..].ptr, @intCast(wb.len - n - 1))));
        n = if (m > 0) n + m else n;
    }
    const len = std.unicode.wtf16LeToWtf8(buf, wb[0..n]);
    return buf[0..len];
}

/// UTC Io.Timestamp (file mtime) -> local short date + short time.
pub fn fmtStamp(buf: []u8, ts: std.Io.Timestamp) []const u8 {
    const ticks: i96 = @divFloor(ts.nanoseconds, 100) + 116444736000000000;
    if (ticks < 0) return "";
    const t: u64 = @intCast(ticks);
    const ft: w.FILETIME = .{ .dwLowDateTime = @truncate(t), .dwHighDateTime = @truncate(t >> 32) };
    var utc: w.SYSTEMTIME = undefined;
    var local: w.SYSTEMTIME = undefined;
    if (w.FileTimeToSystemTime(&ft, &utc) == 0) return "";
    if (w.SystemTimeToTzSpecificLocalTime(null, &utc, &local) == 0) return "";
    return fmtSystemTime(buf, &local, true);
}

pub fn systemTime(y: u16, mo: u8, d: u8, h: u8, mi: u8) w.SYSTEMTIME {
    var st = std.mem.zeroes(w.SYSTEMTIME);
    st.wYear = y;
    st.wMonth = mo;
    st.wDay = d;
    st.wHour = h;
    st.wMinute = mi;
    return st;
}

/// UTC civil time -> local "g".
pub fn fmtUtc(buf: []u8, y: u16, mo: u8, d: u8, h: u8, mi: u8) []const u8 {
    const utc = systemTime(y, mo, d, h, mi);
    var local: w.SYSTEMTIME = undefined;
    if (w.SystemTimeToTzSpecificLocalTime(null, &utc, &local) == 0) return "";
    return fmtSystemTime(buf, &local, true);
}

/// Registry InstallDate -> short date in the user's locale (UninstallView.FmtDate); unparsable text unchanged.
pub fn fmtInstallDate(buf: []u8, s: []const u8) []const u8 {
    const y, const m, const d = parseInstallDate(s) orelse return s;
    if (m < 1 or m > 12 or d < 1 or d > 31 or y < 1601) return s;
    const st = systemTime(y, @intCast(m), @intCast(d), 0, 0);
    var ft: w.FILETIME = undefined;
    if (w.SystemTimeToFileTime(&st, &ft) == 0) return s; // 20240231 etc.
    const out = fmtSystemTime(buf, &st, false);
    return if (out.len == 0) s else out;
}

/// y, m, d of "yyyyMMdd" (the documented form) or of what some installers write instead: "yyyy-M-d",
/// "M/d/yyyy", "d.M.yyyy". The C# FmtDate took only yyyyMMdd and showed the rest raw, so one list mixed formats.
fn parseInstallDate(s: []const u8) ?[3]u16 {
    const i = std.mem.findAny(u8, s, "-/.") orelse
        return if (s.len == 8) .{ num(s[0..4]) orelse return null, num(s[4..6]) orelse return null, num(s[6..8]) orelse return null } else null;
    const sep = s[i];
    var f: [3]u16 = undefined;
    var it = std.mem.splitScalar(u8, s, sep);
    for (&f) |*x| x.* = num(it.next() orelse return null) orelse return null;
    if (it.next() != null) return null;
    return switch (sep) {
        '-' => f,
        '/' => .{ f[2], f[0], f[1] },
        else => .{ f[2], f[1], f[0] },
    };
}

fn num(s: []const u8) ?u16 {
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return if (s.len == 0 or s.len > 4) null else std.fmt.parseInt(u16, s, 10) catch null;
}

test parseInstallDate {
    const t = std.testing;
    try t.expectEqual([3]u16{ 2025, 5, 7 }, parseInstallDate("20250507").?);
    try t.expectEqual([3]u16{ 2025, 5, 7 }, parseInstallDate("5/7/2025").?);
    try t.expectEqual([3]u16{ 2025, 5, 7 }, parseInstallDate("07.05.2025").?);
    try t.expectEqual([3]u16{ 2025, 5, 7 }, parseInstallDate("2025-05-07").?);
    try t.expectEqual(null, parseInstallDate("2025050"));
    try t.expectEqual(null, parseInstallDate("5/7"));
    try t.expectEqual(null, parseInstallDate("1/2/3/4"));
    try t.expectEqual(null, parseInstallDate("+5/7/2025"));
}

/// .NET "N0" (en-US): 1234567 -> "1,234,567".
pub fn n0(buf: []u8, n: u64) []const u8 {
    var tmp: [32]u8 = undefined;
    const digits = std.mem.print(&tmp, "{d}", .{n}) catch return "";
    var o: usize = 0;
    for (digits, 0..) |c, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) {
            if (o >= buf.len) return buf[0..o];
            buf[o] = ',';
            o += 1;
        }
        if (o >= buf.len) return buf[0..o];
        buf[o] = c;
        o += 1;
    }
    return buf[0..o];
}

test n0 {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", n0(&b, 0));
    try std.testing.expectEqualStrings("999", n0(&b, 999));
    try std.testing.expectEqualStrings("1,000", n0(&b, 1000));
    try std.testing.expectEqualStrings("12,345,678", n0(&b, 12345678));
}

/// .NET "0.#": one decimal, "12" rather than "12.0".
pub fn fmt01(buf: []u8, x: f64) []const u8 {
    const r = @round(x * 10) / 10;
    return (if (r == @trunc(r)) std.mem.print(buf, "{d}", .{@as(i64, @intFromFloat(r))}) else std.mem.print(buf, "{d:.1}", .{r})) catch "";
}

test fmt01 {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12", fmt01(&b, 12.04));
    try std.testing.expectEqualStrings("12.5", fmt01(&b, 12.46));
    try std.testing.expectEqualStrings("0", fmt01(&b, 0));
}

/// Case-insensitive "contains" in the user's locale (CurrentCultureIgnoreCase). Empty needle = true.
pub fn containsCi(hay: []const u8, needle: []const u16) bool {
    if (needle.len == 0) return true;
    var hb: [1024]u16 = undefined;
    const hn = std.unicode.wtf8ToWtf16Le(&hb, hay[0..@min(hay.len, hb.len / 2)]) catch return false;
    return w.FindNLSStringEx(null, @intCast(w.FIND_FROMSTART | w.LINGUISTIC_IGNORECASE), &hb, @intCast(hn), needle.ptr, @intCast(needle.len), null, null, null, 0) >= 0;
}

/// Worker-side progress adapter: core `common.Progress(usize)` -> job.setDone.
pub fn jobProgress(job: *kit.jobs.Job) @import("../core/common.zig").Progress(usize) {
    return .{ .ctx = job, .func = struct {
        fn f(c: ?*anyopaque, v: usize) void {
            const j: *kit.jobs.Job = @ptrCast(@alignCast(c.?));
            j.setDone(v);
        }
    }.f };
}

/// UI: true once a started job finished; joins it (isFinished alone stays true after the join).
pub fn jobDone(job: *kit.jobs.Job) bool {
    if (job.thread == null or !job.isFinished()) return false;
    job.join();
    return true;
}
