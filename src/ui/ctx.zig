//! Shared GUI context handed to every page. Owned by MC-G1; other pages only read it
//! (they may call settings.set/save for their own keys).
const std = @import("std");
const kit = @import("kit");
const settings_mod = @import("../core/settings.zig");

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: *kit.app.App,
    settings: *settings_mod.Settings,
    exe_dir: []const u8,
};

pub const version = "2.0.0";
// The About text (footer dialog and Options > About) is tr().main.about_text with {0} = version.
