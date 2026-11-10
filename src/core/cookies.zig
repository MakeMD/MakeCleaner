//! Cookies.cs: cookie keep-list (Options > Cookies) = domains whose cookies every browser clean leaves alone.
const std = @import("std");
const Settings = @import("settings.zig").Settings;

const Allocator = std.mem.Allocator;

pub const keep_prefix = "KeepCookie";

/// Cookies.Keep hook. ponytail: one global, pointed at the live Settings in main, so the GUI and /auto read
/// the same list; pass the list in explicitly if a second Settings instance ever appears.
pub var keep_settings: ?*const Settings = null;

/// Cookies.Keep(): the current keep-list. Outer slice is the caller's; strings are borrowed from Settings.
pub fn keep(gpa: Allocator) ![][]const u8 {
    const s = keep_settings orelse return gpa.alloc([]const u8, 0);
    return s.getList(gpa, keep_prefix);
}

/// " .www.Example.com " -> "www.Example.com" -> stripped of "www." -> "Example.com" (not lowered yet).
fn view(host: []const u8) []const u8 {
    const h = std.mem.trimStart(u8, std.mem.trim(u8, host, &std.ascii.whitespace), ".");
    return if (std.ascii.startsWithIgnoreCase(h, "www.")) h[4..] else h;
}

/// Cookies.Normalize: ".www.Example.com" -> "example.com", the form shown in lists and stored in the keep-list.
/// ponytail: ASCII lowercase (host names are ASCII/punycode); .NET lowered all of Unicode.
pub fn normalize(gpa: Allocator, host: []const u8) ![]u8 {
    return std.ascii.allocLowerString(gpa, view(host));
}

/// Cookies.IsKept: keeping example.com keeps .example.com, www.example.com and every other subdomain,
/// but not badexample.com.
pub fn isKept(host: ?[]const u8, keep_list: []const []const u8) bool {
    const raw = host orelse return false;
    const h = std.mem.trimStart(u8, std.mem.trim(u8, raw, &std.ascii.whitespace), ".");
    for (keep_list) |k| {
        const d = view(k);
        if (d.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(h, d)) return true;
        if (h.len > d.len and h[h.len - d.len - 1] == '.' and std.ascii.endsWithIgnoreCase(h, d)) return true;
    }
    return false;
}

/// Cookies.Parse: import format, one domain per line, `#` comments and blank lines ignored.
/// Result normalized, distinct, sorted ordinally; free with `freeList`.
pub fn parse(gpa: Allocator, text: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    defer out.deinit(gpa);
    errdefer for (out.items) |d| gpa.free(d);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const before_comment = line[0 .. std.mem.findScalar(u8, line, '#') orelse line.len];
        const d = try normalize(gpa, before_comment);
        if (d.len == 0) {
            gpa.free(d);
            continue;
        }
        try out.append(gpa, d);
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var n: usize = 0; // drop duplicates (adjacent after sorting)
    for (out.items) |d| {
        if (n > 0 and std.mem.eql(u8, out.items[n - 1], d)) {
            gpa.free(d);
            continue;
        }
        out.items[n] = d;
        n += 1;
    }
    out.shrinkRetainingCapacity(n);
    return out.toOwnedSlice(gpa);
}

pub fn freeList(gpa: Allocator, list: []const []u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

test "Normalize_strips_dot_www_and_case" {
    const gpa = std.testing.allocator;
    for ([_][2][]const u8{
        .{ ".example.com", "example.com" },
        .{ "www.Example.COM", "example.com" },
        .{ " .www.example.com ", "example.com" },
        .{ "mail.google.com", "mail.google.com" },
    }) |c| {
        const got = try normalize(gpa, c[0]);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

test "Keeping_a_domain_keeps_its_subdomains_only" {
    const keep_list: []const []const u8 = &.{"www.example.com"};
    for ([_]struct { ?[]const u8, bool }{
        .{ ".example.com", true },
        .{ "example.com", true },
        .{ "www.example.com", true },
        .{ "deep.sub.example.com", true },
        .{ "badexample.com", false },
        .{ "example.com.evil.net", false },
        .{ null, false },
    }) |c| try std.testing.expectEqual(c[1], isKept(c[0], keep_list));
}

test "Empty_keep_list_keeps_nothing" {
    try std.testing.expect(!isKept("example.com", &.{}));
}

test "Parse_reads_one_domain_per_line_ignoring_comments_and_duplicates" {
    const gpa = std.testing.allocator;
    const got = try parse(gpa, "# my sites\n\nwww.github.com\r\nexample.com  # bank\n.example.com\n  ");
    defer freeList(gpa, got);
    try std.testing.expectEqual(2, got.len);
    try std.testing.expectEqualStrings("example.com", got[0]);
    try std.testing.expectEqualStrings("github.com", got[1]);
}

test "keep() reads the live keep-list from Settings" {
    const gpa = std.testing.allocator;
    var s: Settings = .{ .gpa = gpa, .path = try gpa.dupe(u8, "unused.ini") };
    defer s.deinit();
    try s.setList(keep_prefix, &.{ "example.com", "github.com" });
    keep_settings = &s;
    defer keep_settings = null;
    const list = try keep(gpa);
    defer gpa.free(list);
    try std.testing.expect(isKept("www.github.com", list) and !isKept("gitlab.com", list));
}
