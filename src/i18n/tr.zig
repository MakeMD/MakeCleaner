//! The UI strings of the current language: `tr().cleaner.analyze`. One table per language (src/i18n/<code>.zig,
//! all of type en.Strings), picked by kit.i18n.current() (main.zig calls kit.i18n.apply at startup and the
//! Options > Settings language combo changes it live). /auto never calls apply, so everything stays English there.
//! Helpers: `fmt` / `n` (templates and plurals into a buffer) and `lookup` (display name of a core name, by its
//! English text; unknown names, e.g. Winapp2 rules, come back unchanged).
const std = @import("std");
const kit = @import("kit");
const i18n = kit.i18n;
pub const en = @import("en.zig");
const uk = @import("uk.zig");
const pl = @import("pl.zig");
const de = @import("de.zig");
const es = @import("es.zig");
const fr = @import("fr.zig");

pub const Strings = en.Strings;

const tables = std.enums.EnumArray(i18n.Lang, *const Strings).init(.{ .en = &en.t, .uk = &uk.t, .pl = &pl.t, .de = &de.t, .es = &es.t, .fr = &fr.t });

/// The current language's table (one atomic load: fine every frame and on worker threads).
pub fn tr() *const Strings {
    return tables.get(i18n.current());
}

/// kit.i18n.fmt: "{0}".."{9}" of `template` replaced by `args` (strings as-is, numbers {d}, format() types {f}).
pub const fmt = i18n.fmt;

/// The plural form of `forms` for `count`, with {0} = `shown` (the number as displayed, e.g. "1,234").
pub fn n(buf: []u8, forms: i18n.Forms, count: u64, shown: anytype) [:0]const u8 {
    return i18n.fmt(buf, i18n.pick(forms, count), .{shown});
}

/// Display text of `name` in the map `field` of Strings (rule, group, warn, browser_item, browser_warn, reg_cat,
/// reg_problem, disk_cat, svc, method, action): the current language's entry whose English text is `name`.
pub fn lookup(comptime field: []const u8, name: []const u8) ?[:0]const u8 {
    const M = @FieldType(Strings, field);
    const cur = &@field(tr().*, field);
    inline for (@typeInfo(M).@"struct".field_names) |f| {
        if (std.mem.eql(u8, name, @field(@field(en.t, field), f))) return @field(cur, f);
    }
    return null;
}

/// `lookup`, else `name` itself.
pub fn show(comptime field: []const u8, name: []const u8) []const u8 {
    return lookup(field, name) orelse name;
}

/// Warning of an own Windows.ini rule (by its English name), translated; null for other rules.
pub fn ruleWarning(name: []const u8) ?[:0]const u8 {
    const W = @FieldType(Strings, "warn");
    inline for (@typeInfo(W).@"struct".field_names) |f| {
        if (std.mem.eql(u8, name, @field(en.t.rule, f))) return @field(tr().warn, f);
    }
    return null;
}

/// Browser item warning by item id ("passwords", "forms", "session").
pub fn browserWarning(id: []const u8) ?[:0]const u8 {
    const W = @FieldType(Strings, "browser_warn");
    inline for (@typeInfo(W).@"struct".field_names) |f| {
        if (std.mem.eql(u8, id, f)) return @field(tr().browser_warn, f);
    }
    return null;
}

/// Browser item name by item id.
pub fn browserItem(id: []const u8) ?[:0]const u8 {
    const W = @FieldType(Strings, "browser_item");
    inline for (@typeInfo(W).@"struct".field_names) |f| {
        if (std.mem.eql(u8, id, f)) return @field(tr().browser_item, f);
    }
    return null;
}

/// A Settings key "<browser>: <item>" (BrowserItem.key, also the summary name of a browser row) for display:
/// the item part translated. Anything else: `lookup("rule")` or unchanged. Result in `buf` or a static string.
pub fn ruleOrBrowserKey(buf: []u8, name: []const u8) []const u8 {
    if (lookup("rule", name)) |s| return s;
    const sep = std.mem.find(u8, name, ": ") orelse return name;
    const item = lookup("browser_item", name[sep + 2 ..]) orelse return name;
    return std.mem.print(buf, "{s}: {s}", .{ name[0..sep], item }) catch name;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "every language table: same placeholders as English, the plural forms its language needs, no empty text" {
    for (i18n.all) |l| {
        if (i18n.check(Strings, &en.t, tables.get(l), l)) |bad| {
            std.debug.print("{s}: bad field {s}\n", .{ l.code(), bad });
            return error.TestUnexpectedResult;
        }
    }
}

test "lookup maps core names by their English text, in the current language" {
    defer i18n.set(.en);
    i18n.set(.en);
    try testing.expectEqualStrings("Temporary Files", show("rule", "Temporary Files"));
    try testing.expectEqualStrings("Firefox junk *", show("rule", "Firefox junk *")); // Winapp2: unchanged
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Google Chrome: Cookies", ruleOrBrowserKey(&buf, "Google Chrome: Cookies"));
    i18n.set(.uk);
    try testing.expectEqualStrings(uk.t.rule.temp_files, show("rule", "Temporary Files"));
    try testing.expectEqualStrings(uk.t.group.advanced, show("group", "Advanced"));
    try testing.expectEqualStrings(uk.t.warn.wipe_free_space, ruleWarning("Wipe Free Space").?);
    try testing.expectEqual(null, ruleWarning("Clipboard"));
    try testing.expectEqualStrings(uk.t.browser_warn.passwords, browserWarning("passwords").?);
    const key = ruleOrBrowserKey(&buf, "Google Chrome: Saved Passwords");
    try testing.expect(std.mem.startsWith(u8, key, "Google Chrome: ") and std.mem.endsWith(u8, key, uk.t.browser_item.passwords));
    var nb: [64]u8 = undefined;
    try testing.expectEqualStrings("22 файли", n(&nb, tr().common.files, 22, 22));
}

test "the English maps match the core data they translate" {
    const rules = @import("../core/rules.zig");
    const custom = @import("../core/custom.zig");
    const regcleaner = @import("../core/regcleaner.zig");
    const disk = @import("../core/diskanalyzer.zig");
    const securedelete = @import("../core/securedelete.zig");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // every Windows.ini section, its group and its warning
    const list = try rules.parseIni(arena.allocator(), @import("../core/engine.zig").built_in_rules);
    var warned: usize = 0;
    for (list) |r| {
        testing.expect(lookup("rule", r.name) != null and lookup("group", r.group()) != null) catch |e| {
            std.debug.print("Windows.ini [{s}] / group {s} has no entry in en.zig\n", .{ r.name, r.group() });
            return e;
        };
        if (r.warning) |w| {
            try testing.expectEqualStrings(w, ruleWarning(r.name).?);
            warned += 1;
        }
    }
    try testing.expectEqual(@typeInfo(@FieldType(Strings, "warn")).@"struct".field_names.len, warned);
    try testing.expectEqual(list.len + 1, @typeInfo(@FieldType(Strings, "rule")).@"struct".field_names.len);
    try testing.expect(lookup("rule", custom.rule_name) != null);
    for ([_]i32{ 3021, 3022, 3023, 3024, 3025, 0 }) |ref| {
        const r: rules.Rule = .{ .lang_sec_ref = ref };
        try testing.expect(lookup("group", r.group()) != null);
    }
    // registry categories in order
    const cats = @typeInfo(@FieldType(Strings, "reg_cat")).@"struct".field_names;
    try testing.expectEqual(regcleaner.categories.len, cats.len);
    inline for (cats, 0..) |f, i| try testing.expectEqualStrings(regcleaner.categories[i].name, @field(en.t.reg_cat, f));
    for (disk.categories) |c| try testing.expect(lookup("disk_cat", c) != null);
    for (securedelete.methods) |m| try testing.expect(lookup("method", m.label) != null);
}
