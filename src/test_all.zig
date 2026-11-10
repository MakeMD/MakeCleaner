//! zig build test: every package.
test {
    _ = @import("test_base.zig");
    _ = @import("test_rules.zig");
    _ = @import("test_browsers.zig");
    _ = @import("test_registry.zig");
    _ = @import("test_systools.zig");
    _ = @import("test_filetools.zig");
}
