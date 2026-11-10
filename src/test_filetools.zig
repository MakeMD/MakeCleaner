//! zig build test-filetools: Duplicate Finder, Disk Analyzer, Secure Delete, Drive Wiper. Owner: MC-E.
//! Spec tests: legacy DuplicatesTests, SecureDeleteTests (restore-point cases are MC-D's). The test blocks live
//! in the core files; the two that go through Engine.Clean (MC-A) are here.
const std = @import("std");
const common = @import("core/common.zig");
const duplicates = @import("core/duplicates.zig");
const securedelete = @import("core/securedelete.zig");
const engine = @import("core/engine.zig");
const refAll = common.refAll;

const testing = std.testing;
const Io = std.Io;

test {
    _ = @import("core/duplicates.zig");
    _ = @import("core/diskanalyzer.zig");
    _ = @import("core/securedelete.zig");
    _ = @import("core/drivewiper.zig");
    _ = @import("core/filetools_win.zig");
    refAll(@import("core/duplicates.zig"));
    refAll(@import("core/diskanalyzer.zig"));
    refAll(@import("core/securedelete.zig"));
    refAll(@import("core/drivewiper.zig"));
    refAll(@import("core/filetools_win.zig"));
}

test "Secure_clean_deletes_file_and_leaves_nothing_behind" {
    const gpa = testing.allocator;
    const io = testing.io;
    const t = try common.TempDir.create(gpa, io, "sd");
    defer t.cleanup(gpa, io);
    const p = try securedelete.secret(gpa, io, t.path, 5000);
    defer gpa.free(p);
    const r = engine.clean(gpa, io, &.{.{ .path = p, .size = 5000, .mtime = .fromNanoseconds(0) }}, 3);
    try testing.expectEqual(engine.CleanResult{ .deleted = 1, .bytes_freed = 5000, .skipped = 0 }, r);
    var d = try Io.Dir.cwd().openDir(io, t.path, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    try testing.expectEqual(null, try it.next(io));
}

test "Delete_selection_keeps_one_copy_per_group" {
    var f: duplicates.Fixture = try .init("dup");
    defer f.deinit();
    const paths = [_][]const u8{ try f.put("a.txt", "dup"), try f.put("s\\b.txt", "dup"), try f.put("t\\c.txt", "dup") };
    const r = try duplicates.find(f.arena.allocator(), testing.io, f.contentOnly(), null, null);
    const res = engine.clean(testing.allocator, testing.io, try duplicates.allButFirst(f.arena.allocator(), r.groups), 0);
    try testing.expectEqual(2, res.deleted);
    var left: usize = 0;
    for (paths) |p| left += @intFromBool(if (Io.Dir.cwd().statFile(testing.io, p, .{})) |_| true else |_| false);
    try testing.expectEqual(1, left);
}

test "Paths longer than MAX_PATH: scan, hash, Engine.Clean (plain and secure) delete all but one copy" {
    var f: duplicates.Fixture = try .init("dup");
    defer f.deinit();
    const a = f.arena.allocator();
    const segs: [8][]const u8 = @splat("a-folder-name-of-forty-characters-long-x");
    const deep = try std.mem.join(a, "\\", &segs); // 8 * 41 > 300 chars below the temp dir
    var paths: [3][]const u8 = undefined;
    for (&paths, [_][]const u8{ "1.bin", "2.bin", "3.bin" }) |*p, n| p.* = try f.put(try std.fs.path.join(a, &.{ deep, n }), "long-path copy");
    try testing.expect(paths[0].len > 300);
    const r = try duplicates.find(a, testing.io, f.contentOnly(), null, null);
    try testing.expectEqual(3, r.hashed);
    try testing.expectEqualStrings("1.bin|2.bin|3.bin", try f.names(r));
    const sel = try duplicates.allButFirst(a, r.groups);
    try testing.expectEqual(1, engine.clean(testing.allocator, testing.io, sel[0..1], 0).deleted);
    try testing.expectEqual(1, engine.clean(testing.allocator, testing.io, sel[1..], 3).deleted);
    var left: usize = 0;
    for (paths) |p| left += @intFromBool(if (Io.Dir.cwd().statFile(testing.io, p, .{})) |_| true else |_| false);
    try testing.expectEqual(1, left);
}
