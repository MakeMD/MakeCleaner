//! Port of legacy/src/MakeCleaner.Core/DiskAnalyzer.cs (Tools > Disk Analyzer).
const std = @import("std");
const w = @import("kit").w;
const common = @import("common.zig");
const duplicates = @import("duplicates.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const FileInfo = common.FileInfo;

pub const other = "Other";

/// ponytail (C#): extension table only; content sniffing if users complain about misfiled types.
const table = [_]struct { cat: []const u8, exts: []const u8 }{
    .{ .cat = "Pictures", .exts = "jpg jpeg png gif bmp tif tiff webp heic heif raw cr2 nef arw dng ico svg psd" },
    .{ .cat = "Music", .exts = "mp3 wav flac aac ogg oga wma m4a aif aiff opus mid midi ape alac" },
    .{ .cat = "Documents", .exts = "doc docx xls xlsx ppt pptx pdf txt rtf odt ods odp csv md epub djvu" },
    .{ .cat = "Video", .exts = "mp4 mkv avi mov wmv flv webm m4v mpg mpeg 3gp ts vob" },
    .{ .cat = "Compressed", .exts = "zip rar 7z tar gz tgz bz2 xz zst iso cab" },
    .{ .cat = "Email", .exts = "eml msg pst ost mbox" },
};

/// DiskAnalyzer.Categories: Pictures, Music, Documents, Video, Compressed, Email, Other.
pub const categories = blk: {
    var c: [table.len + 1][]const u8 = undefined;
    for (table, 0..) |t, i| c[i] = t.cat;
    c[table.len] = other;
    const final = c;
    break :blk final;
};

/// record DiskReport(ByCategory): files per category, indexed like `categories`.
pub const DiskReport = struct {
    by_category: [categories.len][]const FileInfo,

    /// DiskReport.Bytes(cat): 0 for an unknown category (names compare ordinal, like the C# Dictionary).
    pub fn bytes(r: *const DiskReport, cat: []const u8) u64 {
        for (categories, r.by_category) |c, l| if (std.mem.eql(u8, c, cat)) return sum(l);
        return 0;
    }

    /// DiskReport.Total.
    pub fn total(r: *const DiskReport) u64 {
        var n: u64 = 0;
        for (r.by_category) |l| n += sum(l);
        return n;
    }

    fn sum(l: []const FileInfo) u64 {
        var n: u64 = 0;
        for (l) |f| n += f.size;
        return n;
    }
};

/// DiskAnalyzer.CategoryOf: by extension (Path.GetExtension, case-insensitive), else "Other".
pub fn categoryOf(path: []const u8) []const u8 {
    return categories[categoryIndex(path)];
}

fn categoryIndex(path: []const u8) usize {
    const name = std.fs.path.basename(path);
    const dot = std.mem.findScalarLast(u8, name, '.') orelse return table.len;
    const ext = name[dot + 1 ..]; // "file." has no extension
    if (ext.len > 0) for (table, 0..) |t, i| {
        var it = std.mem.tokenizeScalar(u8, t.exts, ' ');
        while (it.next()) |e| if (std.ascii.eqlIgnoreCase(e, ext)) return i;
    };
    return table.len;
}

/// DiskAnalyzer.Analyze: duplicates.scan.files over `roots` (reparse points skipped), bucketed by category.
/// Everything returned lives in `arena`.
pub fn analyze(arena: Allocator, io: Io, roots: []const []const u8, cancel: ?*const common.Cancel, progress: ?common.Progress(usize)) !DiskReport {
    var lists: [categories.len]std.ArrayList(FileInfo) = @splat(.empty);
    for (try duplicates.scan.files(arena, io, roots, &.{}, w.FILE_ATTRIBUTE_REPARSE_POINT, cancel, progress)) |f|
        try lists[categoryIndex(f.name())].append(arena, f);
    var r: DiskReport = undefined;
    for (&r.by_category, lists) |*out, l| out.* = l.items;
    return r;
}

/// DiskAnalyzer.ToText: "cat\tN files\tB bytes" lines, a Total line, a blank line, then every file
/// "cat\tsize\tpath" by size descending (stable), CRLF-joined. Caller frees.
pub fn toText(gpa: Allocator, r: *const DiskReport) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var files: usize = 0;
    for (categories, r.by_category) |c, l| {
        try out.print(gpa, "{s}\t{d} files\t{d} bytes\r\n", .{ c, l.len, r.bytes(c) });
        files += l.len;
    }
    try out.print(gpa, "Total\t{d} files\t{d} bytes\r\n", .{ files, r.total() });
    for (categories, r.by_category) |c, l| {
        const sorted = try gpa.dupe(FileInfo, l);
        defer gpa.free(sorted);
        std.mem.sort(FileInfo, sorted, {}, struct {
            fn bigger(_: void, a: FileInfo, b: FileInfo) bool {
                return a.size > b.size;
            }
        }.bigger);
        for (sorted) |f| try out.print(gpa, "\r\n{s}\t{d}\t{s}", .{ c, f.size, f.path });
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------- tests (legacy DuplicatesTests: analyzer part)

const testing = std.testing;

test "Disk_analyzer_sums_by_category" {
    var f: duplicates.Fixture = try .init("disk");
    defer f.deinit();
    _ = try f.put("photo.JPG", "12345");
    _ = try f.put("m\\song.mp3", "123");
    _ = try f.put("m\\song2.flac", "12");
    _ = try f.put("notes.docx", "1");
    _ = try f.put("mail.eml", "1234");
    _ = try f.put("thing.xyz", "12345678");
    const r = try analyze(f.arena.allocator(), testing.io, &.{f.dir.path}, null, null);
    try testing.expectEqual(5, r.bytes("Pictures"));
    try testing.expectEqual(5, r.bytes("Music"));
    try testing.expectEqual(1, r.bytes("Documents"));
    try testing.expectEqual(4, r.bytes("Email"));
    try testing.expectEqual(8, r.bytes(other));
    try testing.expectEqual(23, r.total());
    const text = try toText(testing.allocator, &r);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.find(u8, text, "thing.xyz") != null);
    try testing.expect(std.mem.startsWith(u8, text, "Pictures\t1 files\t5 bytes\r\nMusic\t2 files\t5 bytes\r\n"));
    try testing.expect(std.mem.find(u8, text, "Total\t6 files\t23 bytes\r\n\r\nPictures\t5\t") != null);
    try testing.expect(std.mem.find(u8, text, "Music\t3\t").? < std.mem.find(u8, text, "Music\t2\t").?); // size desc
}

test "Cancel_stops_scan (DiskAnalyzer.Analyze)" {
    var f: duplicates.Fixture = try .init("disk");
    defer f.deinit();
    _ = try f.put("a.txt", "x");
    var c: common.Cancel = .init(true);
    try testing.expectError(error.Canceled, analyze(f.arena.allocator(), testing.io, &.{f.dir.path}, &c, null));
}

test "CategoryOf follows Path.GetExtension" {
    try testing.expectEqualStrings("Music", categoryOf("C:\\x\\.mp3")); // dot-file: GetExtension = ".mp3"
    try testing.expectEqualStrings(other, categoryOf("C:\\x.mp3\\file."));
    try testing.expectEqualStrings("Compressed", categoryOf("a.tar.GZ"));
    try testing.expectEqualStrings(other, categoryOf("README"));
}
