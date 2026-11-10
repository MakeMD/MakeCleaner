//! tools page. Stub: the GUI phase fills it. Contract (do not change the signatures):
//! init once after the window exists, draw every frame while the page is selected, deinit on exit.
const std = @import("std");
const kit = @import("kit");
const Ctx = @import("ctx.zig").Ctx;

pub const Page = struct {
    pub fn init(ctx: *Ctx) !Page {
        _ = ctx;
        return .{};
    }
    pub fn deinit(self: *Page, ctx: *Ctx) void {
        _ = self;
        _ = ctx;
    }
    pub fn draw(self: *Page, ctx: *Ctx) void {
        _ = self;
        _ = ctx;
        kit.im.ImGui_TextUnformatted("tools");
    }
};
