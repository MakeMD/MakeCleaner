//! zig build test-ui: the `test` blocks of src/ui (pure logic; nothing opens a window).
const std = @import("std");

test {
    _ = @import("ui/g1_common.zig");
    _ = @import("ui/tools_ui.zig");
    _ = @import("ui/cleaner.zig");
    std.testing.refAllDecls(@import("ui/tools_wiper.zig").View);
    std.testing.refAllDecls(@import("ui/options_cookies.zig").View);
}
