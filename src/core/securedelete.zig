//! Port of legacy/src/MakeCleaner.Core/SecureDelete.cs: overwrite-before-delete and free-space wiping.
//! Pass patterns (null = random bytes):
//!   1 pass zeros; 3 passes DoD 5220.22-M: 0x00, 0xFF, random; 7 passes DoD 5220.22-M ECE: 0x00, 0xFF, random,
//!   random, 0x00, 0xFF, random; 35 passes Gutmann: 4 random, 27 fixed MFM/RLL patterns, 4 random.
//! ponytail (C#): in-place overwrite only; SSD wear-levelling, NTFS compressed/sparse files, VSS snapshots and
//! MFT-resident tiny files can keep old copies; MFT free space and cluster tips are not wiped.
const std = @import("std");
const w = @import("kit").w;
const common = @import("common.zig");
const fw = @import("filetools_win.zig");
const T = @import("../i18n/tr.zig");

const Io = std.Io;
const Handle = fw.Handle;

/// Settings key: passes for every clean, 0 = normal delete.
pub const setting_key = "SecureDeletePasses";
pub const wipe_dir_prefix = "MakeCleanerWipe.";

/// 768 KB: multiple of 3 (3-byte Gutmann patterns stay in phase) and of 4 KB.
const buf_size = 3 << 18;
/// Wipe fill files stay under the FAT32 4 GB limit.
const file_cap: u64 = 1 << 30;

pub const Method = struct { passes: u8, label: []const u8 };

/// SecureDelete.Methods (Options combo).
pub const methods = [_]Method{
    .{ .passes = 0, .label = "Normal file deletion" },
    .{ .passes = 1, .label = "Secure: 1 pass" },
    .{ .passes = 3, .label = "Secure: 3 passes" },
    .{ .passes = 7, .label = "Secure: 7 passes" },
    .{ .passes = 35, .label = "Secure: 35 passes" },
};

const P = ?[]const u8;
fn b(comptime v: []const u8) P {
    return v;
}
const rnd: P = null;
const p1 = [_]P{b("\x00")};
const p3 = [_]P{ b("\x00"), b("\xFF"), rnd };
const p7 = [_]P{ b("\x00"), b("\xFF"), rnd, rnd, b("\x00"), b("\xFF"), rnd };
const p35 = [_]P{
    rnd,               rnd,               rnd,               rnd,
    b("\x55"),         b("\xAA"),         b("\x92\x49\x24"), b("\x49\x24\x92"),
    b("\x24\x92\x49"), b("\x00"),         b("\x11"),         b("\x22"),
    b("\x33"),         b("\x44"),         b("\x55"),         b("\x66"),
    b("\x77"),         b("\x88"),         b("\x99"),         b("\xAA"),
    b("\xBB"),         b("\xCC"),         b("\xDD"),         b("\xEE"),
    b("\xFF"),         b("\x92\x49\x24"), b("\x49\x24\x92"), b("\x24\x92\x49"),
    b("\x6D\xB6\xDB"), b("\xB6\xDB\x6D"), b("\xDB\x6D\xB6"), rnd,
    rnd,               rnd,               rnd,
};

/// SecureDelete.Patterns: one entry per pass, null = random. passes other than 1/3/7/35 -> error.InvalidPasses.
pub fn patterns(passes: u8) error{InvalidPasses}![]const ?[]const u8 {
    return switch (passes) {
        1 => &p1,
        3 => &p3,
        7 => &p7,
        35 => &p35,
        else => error.InvalidPasses,
    };
}

/// SecureDelete.Delete: passes 0 = plain delete (a missing file is not an error, like File.Delete); else
/// overwrite every byte, rename to a random name in the same folder (never over an existing file), truncate,
/// unlink.
pub fn delete(io: Io, path: []const u8, passes: u8) !void {
    if (passes == 0) return Io.Dir.cwd().deleteFile(io, path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
    try overwrite(io, path, passes);
    const gpa = std.heap.page_allocator;
    const name = randomName(io);
    const tmp = if (std.fs.path.dirname(path)) |d| try std.fs.path.join(gpa, &.{ d, &name }) else try gpa.dupe(u8, &name);
    defer gpa.free(tmp);
    {
        const from = try fw.winPath(path);
        const to = try fw.winPath(tmp);
        if (w.MoveFileExW(from.span().ptr, to.span().ptr, 0) == 0) return error.RenameFailed; // File.Move: no overwrite
    }
    (try Handle.open(tmp, w.TRUNCATE_EXISTING, 0)).close();
    try Io.Dir.cwd().deleteFile(io, tmp);
}

/// SecureDelete.Overwrite: every pass over the whole file (opened exclusively), flushed to disk.
pub fn overwrite(io: Io, path: []const u8, passes: u8) !void {
    const pats = try patterns(passes);
    const f = try Handle.open(path, w.OPEN_EXISTING, 0);
    defer f.close();
    const buf = try std.heap.page_allocator.alloc(u8, buf_size);
    defer std.heap.page_allocator.free(buf);
    const len = try f.len();
    for (pats) |p| try writePass(io, f, len, p, buf);
}

/// SecureDelete.WipeFreeSpace: fills the volume of `dir` with pass patterns through temp files in
/// dir\MakeCleanerWipe.<random> (stale ones removed first), opened delete-on-close so a crash or kill leaves no
/// filled disk; 1 GB per file (FAT32), 768 KB writes shrinking to 4 KB once the disk is full. `limit_bytes` caps
/// the fill (tests MUST pass a small one). Cancel still removes everything. Returns bytes written in the first
/// pass. The progress string is valid only during the call.
pub fn wipeFreeSpace(io: Io, dir: []const u8, passes: u8, progress: ?common.Progress([]const u8), cancel: ?*const common.Cancel, limit_bytes: u64) !u64 {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    { // leftovers of a killed run
        var d = try Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
        defer d.close(io);
        var stale: std.ArrayList(Io.Dir.Entry) = .empty;
        var it = d.iterate();
        while (try it.next(io)) |e| {
            if ((e.kind == .directory or e.kind == .sym_link) and common.startsWithIgnoreCase(e.name, wipe_dir_prefix))
                try stale.append(arena, .{ .name = try arena.dupe(u8, e.name), .kind = e.kind, .inode = e.inode });
        }
        // a junction/symlink with our prefix: only the link is removed (deleteDir opens it as a reparse point),
        // never followed, like Directory.Delete on a link
        for (stale.items) |s| (if (s.kind == .sym_link) d.deleteDir(io, s.name) else d.deleteTree(io, s.name)) catch {};
    }

    const pats = try patterns(@max(passes, 1)); // before creating the folder (C# leaked it on bad passes)
    const name = randomName(io);
    const root = try std.fs.path.join(arena, &.{ dir, try std.mem.concat(arena, u8, &.{ wipe_dir_prefix, &name }) });
    try Io.Dir.cwd().createDirPath(io, root);
    var files: std.ArrayList(Handle) = .empty;
    defer {
        for (files.items) |f| f.close(); // delete-on-close removes the fill files
        Io.Dir.cwd().deleteTree(io, root) catch {};
    }
    const buf = try arena.alloc(u8, buf_size);
    var msg_buf: [160]u8 = undefined; // translated texts are longer than the English ones
    var total: u64 = 0;
    if (pats[0]) |first| fill(buf, first);
    var full = false;
    while (!full and total < limit_bytes) {
        try files.ensureUnusedCapacity(arena, 1);
        const f = try Handle.open(try arena.print("{s}\\{d}", .{ root, files.items.len }), w.CREATE_NEW, w.FILE_FLAG_DELETE_ON_CLOSE);
        files.appendAssumeCapacity(f);
        var chunk: usize = buf.len;
        var pos: u64 = 0;
        while (pos < file_cap and total < limit_bytes) {
            try common.check(cancel);
            const n: usize = @intCast(@min(chunk, limit_bytes - total));
            if (pats[0] == null) io.random(buf[0..n]);
            f.write(buf[0..n]) catch |e| switch (e) {
                error.DiskFull => {
                    if (chunk == 4096) {
                        full = true;
                        break;
                    }
                    chunk = 4096; // squeeze the last few MB in small blocks
                    continue;
                },
                else => return e,
            };
            total += n;
            pos += n;
        }
        try f.flush();
        if (progress) |p| p.report(T.fmt(&msg_buf, T.tr().wiper.pass_written, .{ pats.len, total >> 20 }));
    }
    for (pats[1..], 2..) |pat, num| {
        for (files.items) |f| {
            try common.check(cancel);
            try writePass(io, f, try f.len(), pat, buf);
        }
        if (progress) |p| p.report(T.fmt(&msg_buf, T.tr().wiper.pass_done, .{ num, pats.len }));
    }
    return total;
}

fn writePass(io: Io, f: Handle, len: u64, pattern: ?[]const u8, buf: []u8) !void {
    if (pattern) |p| fill(buf, p);
    try f.rewind();
    var left = len;
    while (left > 0) {
        const n: usize = @intCast(@min(buf.len, left));
        if (pattern == null) io.random(buf[0..n]);
        try f.write(buf[0..n]);
        left -= n;
    }
    try f.flush();
}

fn fill(buf: []u8, pattern: []const u8) void {
    for (buf, 0..) |*x, i| x.* = pattern[i % pattern.len];
}

/// Path.GetRandomFileName: 8.3 name from [a-z0-5].
fn randomName(io: Io) [12]u8 {
    const chars = "abcdefghijklmnopqrstuvwxyz012345";
    var r: [12]u8 = undefined;
    io.random(&r);
    for (&r) |*c| c.* = chars[c.* & 31];
    r[8] = '.';
    return r;
}

// ---------------------------------------------------------------- tests (legacy SecureDeleteTests)
// Restore-point tests of SecureDeleteTests belong to MC-D (restorepoints.zig); Secure_clean_... (Engine.Clean)
// lives in src/test_filetools.zig.

const testing = std.testing;

/// SecureDeleteTests.Secret: dir\secret.txt with `bytes` letters A..Z repeated.
pub fn secret(gpa: std.mem.Allocator, io: Io, dir: []const u8, bytes: usize) ![]u8 {
    const p = try std.fs.path.join(gpa, &.{ dir, "secret.txt" });
    errdefer gpa.free(p);
    const data = try gpa.alloc(u8, bytes);
    defer gpa.free(data);
    for (data, 0..) |*x, i| x.* = @intCast('A' + i % 26);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = data });
    return p;
}

fn isEmptyDir(io: Io, dir: []const u8) !bool {
    var d = try Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    return try it.next(io) == null;
}

fn overwriteCase(passes: u8, last_byte: ?u8) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    const t = try common.TempDir.create(gpa, io, "sd");
    defer t.cleanup(gpa, io);
    const p = try secret(gpa, io, t.path, 5000);
    defer gpa.free(p);
    const before = try Io.Dir.cwd().readFileAlloc(io, p, gpa, .unlimited);
    defer gpa.free(before);
    try overwrite(io, p, passes);
    const after = try Io.Dir.cwd().readFileAlloc(io, p, gpa, .unlimited);
    defer gpa.free(after);
    try testing.expectEqual(before.len, after.len);
    if (last_byte) |lb| {
        for (after) |x| try testing.expectEqual(lb, x);
    } else {
        var same: usize = 0; // random: ~1/256 coincidences
        for (before, after) |x, y| same += @intFromBool(x == y);
        try testing.expect(same < before.len / 20);
    }
}

test "Overwrite_replaces_every_byte_and_keeps_length(1, 0x00)" {
    try overwriteCase(1, 0x00);
}
test "Overwrite_replaces_every_byte_and_keeps_length(3, -1) last DoD pass is random" {
    try overwriteCase(3, null);
}
test "Overwrite_replaces_every_byte_and_keeps_length(7, -1)" {
    try overwriteCase(7, null);
}
test "Overwrite_replaces_every_byte_and_keeps_length(35, -1)" {
    try overwriteCase(35, null);
}

test "Pass_counts_match_methods" {
    for (methods) |m| if (m.passes > 0) try testing.expectEqual(m.passes, (try patterns(m.passes)).len);
    try testing.expectError(error.InvalidPasses, patterns(2));
}

test "Wipe_free_space_writes_and_removes_its_files" {
    const gpa = testing.allocator;
    const io = testing.io;
    const t = try common.TempDir.create(gpa, io, "sd");
    defer t.cleanup(gpa, io);
    const stale = try t.join(gpa, wipe_dir_prefix ++ "stale"); // leftover of a killed run
    defer gpa.free(stale);
    try Io.Dir.cwd().createDirPath(io, stale);
    const keep = try common.TempDir.create(gpa, io, "sd-keep"); // a stale-named junction: link removed, target kept
    defer keep.cleanup(gpa, io);
    const kept = try secret(gpa, io, keep.path, 10);
    defer gpa.free(kept);
    const link = try t.join(gpa, wipe_dir_prefix ++ "link");
    defer gpa.free(link);
    try fw.testJunction(gpa, io, link, keep.path);
    const Rec = struct {
        buf: [64]u8 = undefined,
        len: usize = 0,
        fn report(ctx: ?*anyopaque, s: []const u8) void {
            const r: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(r.buf[0..s.len], s);
            r.len = s.len;
        }
    };
    var rec: Rec = .{};
    const written = try wipeFreeSpace(io, t.path, 3, .{ .ctx = &rec, .func = Rec.report }, null, 3 << 20);
    try testing.expectEqual(3 << 20, written);
    try testing.expectEqualStrings("Pass 3/3 done", rec.buf[0..rec.len]);
    try testing.expect(try isEmptyDir(io, t.path));
    _ = try Io.Dir.cwd().statFile(io, kept, .{});
}

test "Wipe_cancel_still_cleans_up" {
    const gpa = testing.allocator;
    const io = testing.io;
    const t = try common.TempDir.create(gpa, io, "sd");
    defer t.cleanup(gpa, io);
    var c: common.Cancel = .init(true);
    try testing.expectError(error.Canceled, wipeFreeSpace(io, t.path, 1, null, &c, 1 << 20));
    try testing.expect(try isEmptyDir(io, t.path));
}

test "Delete with passes renames, truncates and unlinks; passes 0 tolerates a missing file" {
    const gpa = testing.allocator;
    const io = testing.io;
    const t = try common.TempDir.create(gpa, io, "sd");
    defer t.cleanup(gpa, io);
    const p = try secret(gpa, io, t.path, 5000);
    defer gpa.free(p);
    try delete(io, p, 1);
    try testing.expect(try isEmptyDir(io, t.path));
    try delete(io, p, 0); // File.Delete: no error when missing
    try testing.expectError(error.FileNotFound, delete(io, p, 3)); // FileMode.Open
}
