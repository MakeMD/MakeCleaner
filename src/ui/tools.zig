//! Tools page: sub-menu on the left (SubNavPage), the selected tool on the right. Tools are built on first
//! open (lazy), like `new SubNavPage("Tools").Add(...)` in the legacy MainWindow.
const std = @import("std");
const kit = @import("kit");
const Ctx = @import("ctx.zig").Ctx;
const ui = @import("tools_ui.zig");

const im = kit.im;

const views = .{
    @import("tools_uninstall.zig").View,
    @import("tools_startup.zig").View,
    @import("tools_dup.zig").View,
    @import("tools_disk.zig").View,
    @import("tools_wiper.zig").View,
    @import("tools_restore.zig").View,
};

pub const Page = struct {
    sel: usize = 0,
    made: [views.len]?*anyopaque = @splat(null),

    pub fn init(ctx: *Ctx) !Page {
        _ = ctx;
        return .{};
    }

    pub fn deinit(self: *Page, ctx: *Ctx) void {
        inline for (views, 0..) |V, i| if (self.made[i]) |p| @as(*V, @ptrCast(@alignCast(p))).destroy(ctx);
    }

    pub fn draw(self: *Page, ctx: *Ctx) void {
        const avail = im.ImGui_GetContentRegionAvail();
        const t = &@import("../i18n/tr.zig").tr().tools;
        const titles = [_]ui.NavItem{
            .{ t.nav_uninstall, .uninstall }, .{ t.nav_startup, .startup }, .{ t.nav_dupes, .duplicates },
            .{ t.nav_disk, .disk_analyzer },  .{ t.nav_wiper, .wipe },      .{ t.nav_restore, .restore },
        };
        ui.subNav("tools", &titles, &self.sel, avail.y);
        im.ImGui_SameLineEx(0, 16 * ui.scale());
        if (im.ImGui_BeginChild("##toolsHost", .{ .x = 0, .y = avail.y }, 0, im.ImGuiWindowFlags_NoBackground)) {
            inline for (views, 0..) |V, i| if (self.sel == i) {
                if (self.made[i] == null) self.made[i] = V.create(ctx) catch null;
                if (self.made[i]) |p| @as(*V, @ptrCast(@alignCast(p))).draw(ctx);
            };
        }
        im.ImGui_EndChild();
    }
};
