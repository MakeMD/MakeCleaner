//! zig build test-base: the shared core (common, bytes, settings, cookies, elevated, reg, custom). Owner: skeleton.
const refAll = @import("core/common.zig").refAll;

test {
    _ = @import("core/common.zig");
    _ = @import("core/bytes.zig");
    _ = @import("core/settings.zig");
    _ = @import("core/cookies.zig");
    _ = @import("core/elevated.zig");
    _ = @import("core/reg.zig");
    _ = @import("core/custom.zig");
    refAll(@import("core/common.zig"));
    refAll(@import("core/bytes.zig"));
    refAll(@import("core/settings.zig"));
    refAll(@import("core/cookies.zig"));
    refAll(@import("core/elevated.zig"));
    refAll(@import("core/reg.zig"));
    refAll(@import("core/custom.zig")); // includeRule / excludes call into rules.zig (MC-A)
}

test "sqlite module: the bundled amalgamation links and runs" {
    const std = @import("std");
    const c = @import("sqlite");
    try std.testing.expectEqualStrings("3.54.1", std.mem.span(c.sqlite3_libversion()));
    try std.testing.expectEqual(1, c.sqlite3_threadsafe());
    var db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(":memory:", &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null));
    defer _ = c.sqlite3_close_v2(db);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, "CREATE TABLE t(x); INSERT INTO t VALUES (1), (2);", null, null, null));
    var st: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM t", -1, &st, null));
    defer _ = c.sqlite3_finalize(st);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(st));
    try std.testing.expectEqual(2, c.sqlite3_column_int(st, 0));
}
