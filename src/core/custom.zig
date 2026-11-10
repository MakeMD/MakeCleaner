//! Custom.cs: Options > Include / Exclude. Stored as numbered ini keys (Include1.., Exclude1..) in winapp2
//! syntax, so they run through the same FileKey / ExcludeKey code as every other rule.
//!   Include: "dir|patterns[|RECURSE|REMOVESELF][|OLDER=hours]"
//!   Exclude: "PATH|dir" (folder), "FILE|dir|name" (file), "REG|key[|value]"
//! The tests that need the engine (CustomTests) live with package MC-A.
const std = @import("std");
const kit = @import("kit");
const common = @import("common.zig");
const rules = @import("rules.zig");
const Settings = @import("settings.zig").Settings;

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const rule_name = "Custom Files and Folders";
pub const include_prefix = "Include";
pub const exclude_prefix = "Exclude";

/// Custom.IncludeRule: the "Custom Files and Folders" rule built from Options > Include. Every entry is
/// re-checked on each load: a hand-edited ini must not sneak in C:\ or %windir%.
pub fn includeRule(arena: Allocator, s: *const Settings) !rules.Rule {
    var rule: rules.Rule = .{ .name = rule_name };
    for (try s.getList(arena, include_prefix)) |e| {
        const k = try rules.FileKey.parse(arena, e);
        if ((try reject(arena, k.path)) == null) try rule.file_keys.append(arena, k);
    }
    return rule;
}

/// Custom.Excludes: the user's global Exclude list.
pub fn excludes(arena: Allocator, s: *const Settings) ![]rules.ExcludeKey {
    const list = try s.getList(arena, exclude_prefix);
    const out = try arena.alloc(rules.ExcludeKey, list.len);
    for (list, out) |e, *x| x.* = try rules.ExcludeKey.parse(arena, e);
    return out;
}

/// Custom.RegistryExcludes: REG excludes as "key" or "key\value" (the registry cleaner matches them as prefixes).
pub fn registryExcludes(arena: Allocator, s: *const Settings) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try excludes(arena, s)) |x| {
        if (x.kind != .reg) continue;
        try out.append(arena, if (x.patterns.len > 0) try arena.print("{s}\\{s}", .{ x.path, x.patterns[0] }) else x.path);
    }
    return out.toOwnedSlice(arena);
}

/// Custom.AddExclude: appends `entry` (case-insensitive duplicates dropped) and saves the ini.
pub fn addExclude(gpa: Allocator, io: Io, s: *Settings, entry: []const u8) !void {
    const old = try s.getList(gpa, exclude_prefix);
    defer gpa.free(old);
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(gpa);
    outer: for (old) |e| {
        for (list.items) |x| if (common.eqlIgnoreCase(x, e)) continue :outer;
        try list.append(gpa, e);
    }
    for (list.items) |x| {
        if (common.eqlIgnoreCase(x, entry)) break;
    } else try list.append(gpa, entry);
    try s.setList(exclude_prefix, list.items);
    try s.save(io);
}

/// Custom.Reject: null = ok to clean; otherwise why not (allocated with `gpa`). Blocks drive roots and network
/// shares, anything under %windir%, and any folder that is (or contains) Program Files, Program Files (x86),
/// ProgramData, the user profile or the folder holding all profiles.
pub fn reject(gpa: Allocator, path: []const u8) !?[]u8 {
    const expanded = try kit.win.expandEnv(gpa, std.mem.trim(u8, path, &std.ascii.whitespace));
    defer gpa.free(expanded);
    if (!fullyQualified(expanded)) return try gpa.dupe(u8, "Use a full path like D:\\Folder.");
    const full_raw = try @import("rules_fs.zig").fullPath(gpa, expanded) orelse return try gpa.dupe(u8, "Not a valid path.");
    defer gpa.free(full_raw);
    const full = std.mem.trimEnd(u8, full_raw, "\\");

    if (full.len <= 2 or std.mem.startsWith(u8, full, "\\\\")) return try gpa.dupe(u8, "A whole drive or network share cannot be cleaned.");
    // Beyond C#: "C:\*" expands to every top-level folder (Windows, Program Files, Users), none of them a root.
    const rest = full[3..];
    if (std.mem.findAny(u8, rest[0 .. std.mem.findScalar(u8, rest, '\\') orelse rest.len], "*?") != null)
        return try gpa.dupe(u8, "A wildcard right under a drive cannot be cleaned.");
    const windir = try folder(gpa, &kit.w.FOLDERID_Windows);
    defer gpa.free(windir);
    if (try under(gpa, full, windir)) return try gpa.dupe(u8, "The Windows folder is protected.");
    const pf = try folder(gpa, &kit.w.FOLDERID_ProgramFiles);
    defer gpa.free(pf);
    const pf86 = try folder(gpa, &kit.w.FOLDERID_ProgramFilesX86);
    defer gpa.free(pf86);
    const data = try folder(gpa, &kit.w.FOLDERID_ProgramData);
    defer gpa.free(data);
    const profile = try folder(gpa, &kit.w.FOLDERID_Profile);
    defer gpa.free(profile);
    for ([_][]const u8{ pf, pf86, data, profile, Io.Dir.path.dirname(profile) orelse "" }) |p| {
        if (p.len > 0 and try under(gpa, p, full)) return try gpa.print("This would clean the system folder {s}.", .{p});
    }
    return null;
}

/// Path.IsPathFullyQualified: "X:\..." or a UNC / device path ("\\server", "\\?\").
fn fullyQualified(p: []const u8) bool {
    if (p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/')) return true;
    return p.len >= 2 and (p[0] == '\\' or p[0] == '/') and (p[1] == '\\' or p[1] == '/');
}

/// Environment.GetFolderPath(...).TrimEnd('\\').
fn folder(gpa: Allocator, id: *const kit.w.KNOWNFOLDERID) ![]u8 {
    const p = try kit.win.knownFolder(gpa, id);
    const t = std.mem.trimEnd(u8, p, "\\");
    if (t.len == p.len) return p;
    defer gpa.free(p);
    return gpa.dupe(u8, t);
}

/// Custom.Under: `path` is `dir` or inside it (OrdinalIgnoreCase).
fn under(gpa: Allocator, path: []const u8, dir: []const u8) !bool {
    if (common.eqlIgnoreCase(path, dir)) return true;
    const prefix = try std.mem.concat(gpa, u8, &.{ dir, "\\" });
    defer gpa.free(prefix);
    return common.startsWithIgnoreCase(path, prefix);
}

test "System_paths_are_rejected (CustomTests, Reject part)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const t = try common.TempDir.create(gpa, io, "custom");
    defer t.cleanup(gpa, io);

    const windir = try folder(gpa, &kit.w.FOLDERID_Windows);
    defer gpa.free(windir);
    const pf = try folder(gpa, &kit.w.FOLDERID_ProgramFiles);
    defer gpa.free(pf);
    const pd = try folder(gpa, &kit.w.FOLDERID_ProgramData);
    defer gpa.free(pd);
    const profile = try folder(gpa, &kit.w.FOLDERID_Profile);
    defer gpa.free(profile);
    const upper = try std.ascii.allocUpperString(gpa, profile);
    defer gpa.free(upper);
    const users = Io.Dir.path.dirname(profile).?;
    const dotdot = try gpa.print("{s}\\Downloads\\..", .{profile});
    defer gpa.free(dotdot);

    for ([_][]const u8{ "C:\\", "C:", "D:\\", windir, "%windir%\\Temp", pf, pd, profile, upper, users, "relative\\dir", "\\\\server\\share", dotdot, "  C:/  ", "C:\\*", "D:\\Pro*\\x", "C:\\?indows" }) |bad| {
        const why = (try reject(gpa, bad)) orelse {
            std.debug.print("not rejected: {s}\n", .{bad});
            return error.TestExpectedRejected;
        };
        gpa.free(why);
    }
    try std.testing.expectEqual(null, try reject(gpa, t.path));
    const downloads = try gpa.print("{s}\\Downloads", .{profile});
    defer gpa.free(downloads);
    try std.testing.expectEqual(null, try reject(gpa, downloads));

    const why = (try reject(gpa, users)).?;
    defer gpa.free(why);
    try std.testing.expect(std.mem.startsWith(u8, why, "This would clean the system folder "));
}

test "AddExclude appends once and saves" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const t = try common.TempDir.create(gpa, io, "custom");
    defer t.cleanup(gpa, io);
    var s = try Settings.load(gpa, io, t.path);
    defer s.deinit();
    try s.setList(exclude_prefix, &.{ "PATH|C:\\a", "path|c:\\A", "REG|HKCU\\x" });
    try addExclude(gpa, io, &s, "REG|hkcu\\X"); // already there (case-insensitive)
    try addExclude(gpa, io, &s, "FILE|C:\\b|k.log");
    var again = try Settings.load(gpa, io, t.path);
    defer again.deinit();
    const list = try again.getList(gpa, exclude_prefix);
    defer gpa.free(list);
    try std.testing.expectEqual(3, list.len);
    try std.testing.expectEqualStrings("PATH|C:\\a", list[0]);
    try std.testing.expectEqualStrings("REG|HKCU\\x", list[1]);
    try std.testing.expectEqualStrings("FILE|C:\\b|k.log", list[2]);
}
