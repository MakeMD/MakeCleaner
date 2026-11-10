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

/// OptionsPages.AboutText: the one About text (footer dialog and the Options > About page).
pub const about_text = "MakeCleaner " ++ version ++ "\n\n" ++
    "No telemetry, no ads, no network access.\n\n" ++
    "Applications rules: Winapp2.ini by the Winapp2 project (github.com/MoscaDotTo/Winapp2), " ++
    "licensed CC BY-SA 4.0, shipped unmodified in rules\\Winapp2.ini.\n\n" ++
    "Third-party components: see THIRD-PARTY-NOTICES.txt next to the program.";
