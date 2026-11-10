//! Shared by every core package: cancellation, progress callbacks, file info, OrdinalIgnoreCase string
//! compare, a civil date-time, and test helpers (fresh temp dirs, throwaway HKCU keys).
//! Core rule: no ImGui here or anywhere under src/core (kit.win / kit.w only).
const std = @import("std");
const kit = @import("kit");
const win = kit.win;
const w = kit.w;

const Allocator = std.mem.Allocator;
const Io = std.Io;

// ---------------------------------------------------------------- cancellation / progress

/// CancellationToken. Same type as `kit.jobs.Job.cancel_flag`, so the GUI passes `&job.cancel_flag`.
pub const Cancel = std.atomic.Value(bool);

/// ct.ThrowIfCancellationRequested(): `try common.check(cancel);` -> error.Canceled.
pub fn check(cancel: ?*const Cancel) error{Canceled}!void {
    if (cancel) |c| if (c.load(.acquire)) return error.Canceled;
}

/// .NET string.Trim(). ponytail: ASCII whitespace only (all that occurs in ini/registry data).
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, &std.ascii.whitespace);
}

/// Path.GetTempPath (with its trailing backslash), allocated with `a`.
pub fn tempPath(a: std.mem.Allocator) ![]u8 {
    var buf: [kit.w.MAX_PATH + 2]u16 = undefined;
    const n = kit.w.GetTempPathW(buf.len, &buf);
    if (n == 0 or n > buf.len) return error.Unexpected;
    return kit.win.fromW(a, buf[0..n]);
}

/// IProgress<T>. Call as `if (progress) |p| p.report(v);`.
pub fn Progress(comptime T: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        func: *const fn (ctx: ?*anyopaque, value: T) void,

        pub fn report(p: @This(), value: T) void {
            p.func(p.ctx, value);
        }
    };
}

/// IProgress<(int Done, int Total)> payload.
pub const Count = struct { done: usize, total: usize };

// ---------------------------------------------------------------- files

/// FileInfo as the scanners return it. `path` is absolute (WTF-8); memory belongs to whoever built the list
/// (core functions document it: usually an arena passed in).
pub const FileInfo = struct {
    path: []const u8,
    size: u64,
    /// LastWriteTimeUtc.
    mtime: Io.Timestamp,

    pub fn name(f: FileInfo) []const u8 {
        return Io.Dir.path.basename(f.path);
    }
};

// ---------------------------------------------------------------- StringComparison.OrdinalIgnoreCase

/// OrdinalIgnoreCase equality (paths, rule names, registry names). ASCII fast path; anything else goes
/// through CompareStringOrdinal, so "C:\Users\Євген" == "c:\users\євген" (a path guard must not miss that).
pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (isAscii(a) and isAscii(b)) return std.ascii.eqlIgnoreCase(a, b);
    return foldCompare(a, b, false);
}

/// OrdinalIgnoreCase StartsWith.
pub fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    if (isAscii(s) and isAscii(prefix)) return std.ascii.startsWithIgnoreCase(s, prefix);
    return foldCompare(s, prefix, true);
}

fn isAscii(s: []const u8) bool {
    for (s) |c| if (c >= 0x80) return false;
    return true;
}

fn foldCompare(a: []const u8, b: []const u8, prefix: bool) bool {
    var stack: [4096]u8 = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(&stack, std.heap.page_allocator);
    const al = bfa.allocator();
    const a16 = std.unicode.wtf8ToWtf16LeAlloc(al, a) catch return false;
    defer al.free(a16);
    const b16 = std.unicode.wtf8ToWtf16LeAlloc(al, b) catch return false;
    defer al.free(b16);
    if (if (prefix) a16.len < b16.len else a16.len != b16.len) return false;
    const n: c_int = @intCast(b16.len); // OrdinalIgnoreCase maps UTF-16 unit to unit: the prefix has b16.len units
    return w.CompareStringOrdinal(a16.ptr, n, b16.ptr, n, 1) == w.CSTR_EQUAL;
}

// ---------------------------------------------------------------- date-time

/// Civil date-time (DateTime without a Kind: the caller knows whether it is local or UTC).
pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,

    pub fn nowLocal() DateTime {
        var st: w.SYSTEMTIME = undefined;
        w.GetLocalTime(&st);
        return fromSystemTime(st);
    }

    pub fn nowUtc() DateTime {
        var st: w.SYSTEMTIME = undefined;
        w.GetSystemTime(&st);
        return fromSystemTime(st);
    }

    fn fromSystemTime(st: w.SYSTEMTIME) DateTime {
        return .{ .year = st.wYear, .month = @intCast(st.wMonth), .day = @intCast(st.wDay), .hour = @intCast(st.wHour), .minute = @intCast(st.wMinute), .second = @intCast(st.wSecond) };
    }

    /// System.DayOfWeek: 0 = Sunday .. 6 = Saturday (Sakamoto).
    pub fn dayOfWeek(d: DateTime) u3 {
        const t = [_]u16{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
        const y: u32 = d.year - @intFromBool(d.month < 3);
        return @intCast((y + y / 4 - y / 100 + y / 400 + t[d.month - 1] + d.day) % 7);
    }
};

// ---------------------------------------------------------------- test helpers

/// Semantic analysis of every pub decl of `T` and of the structs declared inside it, so contract signatures
/// (and stub bodies) are type-checked before anything calls them. Generic fns are skipped.
pub fn refAll(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |name| {
        const D = @TypeOf(@field(T, name));
        if (D == type) {
            const Inner = @field(T, name);
            if (comptime @typeInfo(Inner) == .@"struct" and std.mem.startsWith(u8, @typeName(Inner), @typeName(T) ++ ".")) refAll(Inner);
        } else if (comptime !(@typeInfo(D) == .@"fn" and @typeInfo(D).@"fn".is_generic)) {
            _ = &@field(T, name);
        }
    }
}

/// A fresh `%TEMP%\makecleaner-test-<tag>-<random>` folder. Destructive tests work only inside one.
pub const TempDir = struct {
    path: []u8,

    pub fn create(gpa: Allocator, io: Io, tag: []const u8) !TempDir {
        var buf: [w.MAX_PATH + 1]u16 = undefined;
        const n = w.GetTempPathW(buf.len, &buf);
        if (n == 0 or n > buf.len) return error.Unexpected;
        const tmp = try win.fromW(gpa, buf[0..n]);
        defer gpa.free(tmp);
        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        const path = try gpa.print("{s}\\makecleaner-test-{s}-{x}", .{ std.mem.trimEnd(u8, tmp, "\\"), tag, &rnd });
        errdefer gpa.free(path);
        try Io.Dir.cwd().createDirPath(io, path);
        return .{ .path = path };
    }

    /// Absolute path of `rel` inside the folder (caller frees).
    pub fn join(t: TempDir, gpa: Allocator, rel: []const u8) ![]u8 {
        return Io.Dir.path.join(gpa, &.{ t.path, rel });
    }

    /// Removes the folder and everything in it.
    pub fn cleanup(t: TempDir, gpa: Allocator, io: Io) void {
        std.debug.assert(std.mem.find(u8, t.path, "\\makecleaner-test-") != null); // never anything else
        Io.Dir.cwd().deleteTree(io, t.path) catch {};
        gpa.free(t.path);
    }
};

/// A throwaway `HKCU\Software\MakeCleanerTest-<tag>-<random>` key: its own top-level branch per test, so
/// parallel or failing tests never race over a shared parent (see legacy RegistryTests.branch).
pub const TestKey = struct {
    /// Relative to HKCU: "Software\MakeCleanerTest-...".
    sub: []u8,
    /// "HKCU\Software\MakeCleanerTest-...".
    full: []u8,

    pub fn create(gpa: Allocator, io: Io, tag: []const u8) !TestKey {
        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        const sub = try gpa.print("Software\\MakeCleanerTest-{s}-{x}", .{ tag, &rnd });
        errdefer gpa.free(sub);
        const full = try gpa.print("HKCU\\{s}", .{sub});
        errdefer gpa.free(full);
        const k = try win.createKey(.hkcu, sub, .default);
        k.close();
        return .{ .sub = sub, .full = full };
    }

    pub fn cleanup(k: TestKey, gpa: Allocator) void {
        std.debug.assert(std.mem.startsWith(u8, k.sub, "Software\\MakeCleanerTest-"));
        win.deleteKeyTree(.hkcu, k.sub, .default) catch {};
        gpa.free(k.sub);
        gpa.free(k.full);
    }
};

test "OrdinalIgnoreCase compare, ASCII and Cyrillic" {
    try std.testing.expect(eqlIgnoreCase("C:\\Windows", "c:\\WINDOWS"));
    try std.testing.expect(eqlIgnoreCase("C:\\Users\\Євген", "c:\\users\\євген"));
    try std.testing.expect(!eqlIgnoreCase("C:\\Users\\Євген", "C:\\Users\\Євгена"));
    try std.testing.expect(startsWithIgnoreCase("C:\\USERS\\ЄВГЕН\\Downloads", "c:\\users\\євген\\"));
    try std.testing.expect(!startsWithIgnoreCase("C:\\Use", "C:\\Users"));
}

test "DateTime.dayOfWeek" {
    try std.testing.expectEqual(3, (DateTime{ .year = 2031, .month = 3, .day = 5 }).dayOfWeek()); // Wednesday
    try std.testing.expectEqual(0, (DateTime{ .year = 2026, .month = 11, .day = 8 }).dayOfWeek()); // Sunday
    try std.testing.expectEqual(1, (DateTime{ .year = 2024, .month = 1, .day = 1 }).dayOfWeek()); // Monday
}

test "TempDir and TestKey clean up after themselves" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const t = try TempDir.create(gpa, io, "common");
    const p = try t.join(gpa, "a\\b.txt");
    defer gpa.free(p);
    try Io.Dir.cwd().createDirPath(io, Io.Dir.path.dirname(p).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "x" });
    const kept = try gpa.dupe(u8, t.path);
    defer gpa.free(kept);
    t.cleanup(gpa, io);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, kept, .{}));

    const k = try TestKey.create(gpa, io, "common");
    const sub = try gpa.dupe(u8, k.sub);
    defer gpa.free(sub);
    (try win.openKey(.hkcu, sub, .{})).close();
    k.cleanup(gpa);
    try std.testing.expectError(error.NotFound, win.openKey(.hkcu, sub, .{}));
}
