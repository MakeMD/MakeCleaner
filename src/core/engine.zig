//! Engine.cs: Analyze -> list of targets (files / registry entries / actions) -> Clean. ExcludeKey and the
//! user's global Exclude list filter on one path. Results are allocated in the `arena` passed in.
const std = @import("std");
const kit = @import("kit");
const common = @import("common.zig");
const rules = @import("rules.zig");
const reg = @import("reg.zig");
const special = @import("special.zig");
const securedelete = @import("securedelete.zig");
const fs = @import("rules_fs.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const FileInfo = common.FileInfo;
const Rule = rules.Rule;

/// record CleanResult(Deleted, BytesFreed, Skipped).
pub const CleanResult = struct {
    deleted: usize = 0,
    bytes_freed: u64 = 0,
    skipped: usize = 0,
};

/// Engine.BuiltInRules: rules\Windows.ini compiled in (build.zig anonymous import), so the Windows tab can
/// never go missing.
pub const built_in_rules: []const u8 = @embedFile("windows_ini");

/// Engine.Analyze(rule, extra, ct): files the rule would delete. `extra` = the user's global Exclude list
/// (Options), applied on top of the rule's own ExcludeKeys. Cancel is checked per file -> error.Canceled.
/// Never sweeps a whole drive with RECURSE, never lets a wildcard right under a drive root reach system folders
/// (targetDirs, stricter than C#); never follows junctions/symlinks out of the target.
pub fn analyze(arena: Allocator, io: Io, rule: *const Rule, extra: []const rules.ExcludeKey, cancel: ?*const common.Cancel) ![]FileInfo {
    var found: rules.IgnoreCaseMap(FileInfo) = .empty;
    const excludes = try fileExcludes(arena, io, rule.excludes.items, extra);
    const now = Io.Timestamp.now(io, .real).nanoseconds;
    const cutoff: ?i96 = if (rule.older_than_hours) |h| now - @as(i96, h) * std.time.ns_per_hour else null;
    for (rule.file_keys.items) |key| {
        for (try targetDirs(arena, io, key.path)) |dir| { // unknown env var or missing folder -> nothing
            for (key.patterns) |pattern| {
                // .NET splits a directory part off the pattern ("sub\*.log" = *.log in dir\sub); ".." / rooted: refused
                const p = std.mem.trim(u8, pattern, &std.ascii.whitespace);
                const cut = std.mem.findLastAny(u8, p, "\\/");
                const sub = if (cut) |c| p[0..c] else "";
                if (std.mem.find(u8, sub, "..") != null or std.mem.findScalar(u8, sub, ':') != null or (sub.len > 0 and (sub[0] == '\\' or sub[0] == '/'))) continue;
                const in = if (sub.len == 0) dir else try std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, dir, "\\"), "\\", sub });
                if (key.recurse and try fs.isRoot(arena, in)) continue; // never sweep a whole drive
                for (try fs.list(arena, in, if (cut) |c| p[c + 1 ..] else p, .{ .recurse = key.recurse, .cancel = cancel })) |e| {
                    const t = e.mtime.nanoseconds;
                    if (cutoff) |c| if (t > c) continue;
                    if (key.older_than_hours != 0 and t >= now - @as(i96, key.older_than_hours) * std.time.ns_per_hour) continue;
                    if (excluded(excludes, e.path)) continue;
                    const gop = try found.getOrPut(arena, e.path);
                    if (!gop.found_existing) gop.value_ptr.* = e.info();
                }
            }
        }
    }
    for (rule.special_keys.items) |k| {
        for (try special.files(arena, io, k, rule) orelse continue) |f| {
            if (excluded(excludes, f.path)) continue;
            const gop = try found.getOrPut(arena, f.path);
            if (!gop.found_existing) gop.value_ptr.* = f;
        }
    }
    return found.values();
}

pub const RootWildcard = enum { none, partial, generic };

/// The folder right under a drive root in (some expansion of) `path` is a wildcard segment: `generic` when it
/// matches anything ("C:\*", "C:\*.*", "C:\Windows\..\?*"), `partial` otherwise ("%SystemDrive%\*.tmp" and
/// "%SystemDrive%\Python*" are real Winapp2 keys). Unresolvable expansions count as generic.
pub fn rootWildcard(arena: Allocator, path: []const u8) !RootWildcard {
    var worst: RootWildcard = .none;
    for (try rules.paths.expandVars(arena, path)) |e| {
        const full = (try fs.fullPath(arena, std.mem.trim(u8, e, &std.ascii.whitespace))) orelse return .generic;
        var segs = std.mem.tokenizeAny(u8, full, "\\/");
        _ = segs.next() orelse continue;
        const seg = segs.next() orelse continue;
        if (std.mem.findAny(u8, seg, "*?") == null) continue;
        if (std.mem.trim(u8, seg, "*?.").len == 0) return .generic;
        worst = .partial;
    }
    return worst;
}

/// Paths.ExpandDirs plus a data-loss guard C# lacked: a generic wildcard right under a drive root yields nothing
/// (it would reach Windows, Program Files, Users); a partial one never yields a folder below Windows, Program
/// Files (x86), Users or a hidden/system top folder (ProgramData, $Recycle.Bin, System Volume Information).
fn targetDirs(arena: Allocator, io: Io, path: []const u8) ![]const []const u8 {
    const rw = try rootWildcard(arena, path);
    if (rw == .generic) return &.{};
    const dirs = try rules.paths.expandDirs(arena, io, path);
    if (rw == .none) return dirs;
    var out: std.ArrayList([]const u8) = .empty;
    next: for (dirs) |d| {
        const full = (try fs.fullPath(arena, d)) orelse continue;
        const cut = std.mem.findScalarPos(u8, full, 3, '\\') orelse full.len;
        const top = full[0..cut]; // "C:\Program Files"
        const st = fs.stat(top) orelse continue;
        if (st.attrs & (fs.attr_hidden | fs.attr_system) != 0) continue;
        for ([_]*const kit.w.KNOWNFOLDERID{ &kit.w.FOLDERID_Windows, &kit.w.FOLDERID_ProgramFiles, &kit.w.FOLDERID_ProgramFilesX86, &kit.w.FOLDERID_Profile }) |id| {
            const k = kit.win.knownFolder(arena, id) catch continue;
            const sys = if (id == &kit.w.FOLDERID_Profile) Io.Dir.path.dirname(k) orelse k else k; // the Users folder
            if (common.eqlIgnoreCase(top, sys)) continue :next;
        }
        try out.append(arena, d);
    }
    return out.toOwnedSlice(arena);
}

/// Engine.AnalyzeActions: the rule's SpecialKey actions that have something to do.
pub fn analyzeActions(arena: Allocator, io: Io, rule: *const Rule) ![]special.Pending {
    var out: std.ArrayList(special.Pending) = .empty;
    for (rule.special_keys.items) |k| if (try special.action(arena, io, k)) |a| try out.append(arena, a);
    return out.toOwnedSlice(arena);
}

/// Engine.RunActions: Deleted = actions that succeeded, Skipped = failed.
pub fn runActions(actions: []const special.Pending) CleanResult {
    var r: CleanResult = .{};
    for (actions) |a| {
        if (a.run()) r.deleted += 1 else r.skipped += 1;
    }
    return r;
}

/// One FILE / PATH exclude, resolved to a folder prefix ("dir\").
const FileExclude = struct { file: bool, prefix: []const u8, patterns: []const []const u8 };

/// FILE: name match directly in dir; PATH: anywhere under dir (no patterns = everything).
fn fileExcludes(arena: Allocator, io: Io, own: []const rules.ExcludeKey, extra: []const rules.ExcludeKey) ![]FileExclude {
    var list: std.ArrayList(FileExclude) = .empty;
    for ([_][]const rules.ExcludeKey{ own, extra }) |set| for (set) |x| {
        if (x.kind != .file and x.kind != .path) continue;
        for (try rules.paths.expandDirs(arena, io, x.path)) |dir| try list.append(arena, .{
            .file = x.kind == .file,
            .prefix = try std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, dir, "\\"), "\\" }),
            .patterns = if (x.patterns.len > 0) x.patterns else &.{"*"},
        });
    };
    return list.toOwnedSlice(arena);
}

fn excluded(excludes: []const FileExclude, path: []const u8) bool {
    const cut = (std.mem.findScalarLast(u8, path, '\\') orelse return false) + 1;
    const name = path[cut..];
    for (excludes) |x| {
        const in_dir = if (x.file) common.eqlIgnoreCase(path[0..cut], x.prefix) else common.startsWithIgnoreCase(path, x.prefix);
        if (!in_dir) continue;
        for (x.patterns) |p| if (rules.paths.matches(p, name)) return true;
    }
    return false;
}

/// Engine.AnalyzeRegistry(rule, extra): RegKeys that exist and are not excluded (REG excludes, key prefix +
/// optional value match).
pub fn analyzeRegistry(arena: Allocator, rule: *const Rule, extra: []const rules.ExcludeKey) ![]rules.RegKey {
    var reg_ex: std.ArrayList(rules.RegKey) = .empty;
    for ([_][]const rules.ExcludeKey{ rule.excludes.items, extra }) |set| for (set) |x| {
        // = RegKey.Parse(x.Path + "|" + x.Patterns[0]); x.Path is already trimmed and holds no '|'
        if (x.kind == .reg) try reg_ex.append(arena, .{ .key = x.path, .value = if (x.patterns.len > 0) x.patterns[0] else null });
    };
    var out: std.ArrayList(rules.RegKey) = .empty;
    next: for (rule.reg_keys.items) |t| {
        for (reg_ex.items) |x| {
            const under = try std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, x.key, "\\"), "\\" });
            const key_hit = common.eqlIgnoreCase(t.key, x.key) or common.startsWithIgnoreCase(t.key, under);
            const value_hit = if (x.value) |xv| (if (t.value) |tv| common.eqlIgnoreCase(xv, tv) else false) else true;
            if (key_hit and value_hit) continue :next;
        }
        if (reg.exists(t)) try out.append(arena, t);
    }
    return out.toOwnedSlice(arena);
}

/// Engine.CleanRegistry: reg.delete per target.
pub fn cleanRegistry(targets: []const rules.RegKey) CleanResult {
    var r: CleanResult = .{};
    for (targets) |t| {
        if (reg.delete(t)) r.deleted += 1 else r.skipped += 1;
    }
    return r;
}

/// Engine.RemoveEmptyDirs: after Clean, REMOVESELF folders go only if nothing is left inside (deepest first;
/// locked/excluded files keep them); also runs special.afterClean. Returns the number of folders removed.
pub fn removeEmptyDirs(gpa: Allocator, io: Io, rule: *const Rule) usize {
    special.afterClean(gpa, io, rule);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var removed: usize = 0;
    for (rule.file_keys.items) |key| {
        if (!key.remove_self) continue;
        for (targetDirs(arena, io, key.path) catch continue) |dir| { // the empty folders of system folders stay too
            if (fs.isRoot(arena, dir) catch true) continue;
            const subs = fs.list(arena, dir, "*", .{ .files = false, .dirs = true, .recurse = true }) catch continue;
            // deepest first, so emptied children make their parents empty
            std.mem.sort(fs.Entry, subs, {}, struct {
                fn longer(_: void, a: fs.Entry, b: fs.Entry) bool {
                    return a.path.len > b.path.len;
                }
            }.longer);
            for (subs) |d| {
                if (fs.isEmpty(d.path) and fs.removeDir(d.path)) removed += 1;
            }
            if (fs.isEmpty(dir) and fs.removeDir(dir)) removed += 1;
        }
    }
    return removed;
}

/// Engine.Clean(files, passes): deletes exactly the files Analyze returned; locked/denied ones are skipped and
/// counted; read-only is cleared first; passes > 0 = securedelete.delete (0 = plain File.Delete, as
/// SecureDelete.Delete does). Files already gone are not counted.
pub fn clean(gpa: Allocator, io: Io, files: []const FileInfo, passes: u8) CleanResult {
    _ = gpa;
    var r: CleanResult = .{};
    for (files) |f| {
        const st = fs.stat(f.path) orelse continue; // f.Refresh(); !f.Exists
        if (st.isDir()) continue;
        if (st.attrs & fs.attr_readonly != 0) fs.setAttrs(f.path, st.attrs & ~fs.attr_readonly) catch {
            r.skipped += 1;
            continue;
        };
        const del = if (passes == 0) fs.deleteFile(f.path) else securedelete.delete(io, f.path, passes);
        del catch {
            r.skipped += 1;
            continue;
        };
        r.deleted += 1;
        r.bytes_freed += st.size;
    }
    return r;
}
