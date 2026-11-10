//! Special.cs: built-in procedures behind SpecialKey= in rules (things a FileKey/RegKey cannot express).
const std = @import("std");
const kit = @import("kit");
const common = @import("common.zig");
const rules = @import("rules.zig");
const elevated = @import("elevated.zig");
const fs = @import("rules_fs.zig");

const w = kit.w;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const FileInfo = common.FileInfo;

/// record Pending(Label, Bytes, Run): something Clean will do that is not a file or registry entry
/// (clipboard, DNS cache, event logs). `run` returns success.
pub const Pending = struct {
    label: []const u8,
    bytes: u64,
    run: *const fn () bool,
};

/// Special.WipeFreeSpace: run by CleanPass after Clean (needs passes + progress); never by /auto.
pub const wipe_free_space = "WIPEFREESPACE";

/// Keys of Special.Files and Special.Actions (the dictionaries' key sets).
pub const file_keys = [_][]const u8{ "RECYCLEBIN", "BROKENSTARTMENU", "BROKENDESKTOP" };
pub const action_keys = [_][]const u8{ "CLIPBOARD", "DNSCACHE", "EVENTLOGS" };

/// Special.Files[key](rule): RECYCLEBIN, BROKENSTARTMENU, BROKENDESKTOP (key case-insensitive). null = not a
/// file procedure. The files go through the normal Clean path (secure delete, locked files skipped).
pub fn files(arena: Allocator, io: Io, key: []const u8, rule: *const rules.Rule) !?[]FileInfo {
    const eq = common.eqlIgnoreCase;
    if (eq(key, "RECYCLEBIN")) return try recycleBin(arena, io, try recycleBinDirs(arena), rule.older_than_hours, Io.Timestamp.now(io, .real));
    if (eq(key, "BROKENSTARTMENU")) return try brokenShortcuts(arena, io, &.{ try folder(arena, &w.FOLDERID_StartMenu), try folder(arena, &w.FOLDERID_CommonStartMenu) });
    if (eq(key, "BROKENDESKTOP")) return try brokenShortcuts(arena, io, &.{ try folder(arena, &w.FOLDERID_Desktop), try folder(arena, &w.FOLDERID_PublicDesktop) });
    return null;
}

/// Special.Actions[key](): CLIPBOARD, DNSCACHE, EVENTLOGS (key case-insensitive). null = unknown key or
/// nothing to do (e.g. empty clipboard). Analyze only describes them, Clean runs them.
/// EVENTLOGS runs through elevated.run (UAC only when Clean runs; tests must inject elevated.runner).
pub fn action(arena: Allocator, io: Io, key: []const u8) !?Pending {
    _ = io;
    const eq = common.eqlIgnoreCase;
    if (eq(key, "CLIPBOARD")) return if (w.CountClipboardFormats() > 0) .{ .label = "Clipboard contents", .bytes = 0, .run = emptyClipboardNow } else null;
    if (eq(key, "DNSCACHE")) return .{ .label = "DNS resolver cache", .bytes = 0, .run = flushDns };
    if (eq(key, "EVENTLOGS")) return try eventLogs(arena);
    return null;
}

/// Environment.GetFolderPath: "" when the folder is unknown on this PC.
fn folder(arena: Allocator, id: *const w.KNOWNFOLDERID) ![]const u8 {
    return kit.win.knownFolder(arena, id) catch |e| switch (e) {
        error.OutOfMemory => e,
        else => "",
    };
}

// ---- Recycle Bin: X:\$Recycle.Bin\<user SID>\$Ixxxx (metadata) + $Rxxxx (file or folder) ----

extern "advapi32" fn ConvertSidToStringSidW(sid: w.PSID, out: *w.LPWSTR) callconv(.winapi) w.WINBOOL;
extern "shell32" fn SHUpdateRecycleBinIcon() callconv(.winapi) void;

/// Every fixed drive's bin folder of the current user (existing or not).
fn recycleBinDirs(arena: Allocator) ![]const []const u8 {
    const sid = try userSid(arena) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    const drives = w.GetLogicalDrives();
    for (0..26) |i| {
        if ((drives >> @intCast(i)) & 1 == 0) continue;
        const letter: u8 = 'A' + @as(u8, @intCast(i));
        const root = [_:0]u16{ letter, ':', '\\' };
        if (w.GetDriveTypeW(&root) != w.DRIVE_FIXED) continue;
        try out.append(arena, try arena.print("{c}:\\$Recycle.Bin\\{s}", .{ letter, sid }));
    }
    return out.toOwnedSlice(arena);
}

/// WindowsIdentity.GetCurrent().User.Value ("S-1-5-21-...").
fn userSid(arena: Allocator) !?[]u8 {
    var tok: w.HANDLE = null;
    if (w.OpenProcessToken(w.GetCurrentProcess(), w.TOKEN_QUERY, &tok) == 0) return null;
    defer _ = w.CloseHandle(tok);
    var buf: [512]u8 align(8) = undefined;
    var len: w.DWORD = 0;
    if (w.GetTokenInformation(tok, w.TokenUser, &buf, buf.len, &len) == 0) return null;
    const tu: *const w.TOKEN_USER = @ptrCast(&buf);
    var s: w.LPWSTR = null;
    if (ConvertSidToStringSidW(tu.User.Sid, &s) == 0) return null;
    defer _ = w.LocalFree(s);
    return try kit.win.fromWZ(arena, @ptrCast(s));
}

/// Special.RecycleBin: X:\$Recycle.Bin\<SID>\$Ixxxx (metadata) + $Rxxxx (file or folder contents).
/// older_than_hours: only items deleted at least that long ago (FILETIME at offset 16 of $I).
pub fn recycleBin(arena: Allocator, io: Io, bin_dirs: []const []const u8, older_than_hours: ?i32, now_utc: Io.Timestamp) ![]FileInfo {
    var out: std.ArrayList(FileInfo) = .empty;
    for (bin_dirs) |dir| {
        if (!fs.isDir(dir)) continue;
        for (try fs.list(arena, dir, "$I*", .{ .skip = 0 })) |i| {
            if (older_than_hours) |h| if (deletedUtc(io, i.path)) |deleted| {
                if (now_utc.nanoseconds - deleted.nanoseconds < @as(i96, h) * std.time.ns_per_hour) continue;
            };
            try out.append(arena, i.info());
            const r = try std.mem.concat(arena, u8, &.{ Io.Dir.path.dirname(i.path).?, "\\$R", Io.Dir.path.basename(i.path)[2..] });
            const st = fs.stat(r) orelse continue;
            if (!st.isDir()) {
                try out.append(arena, st.info());
            } else if (st.attrs & fs.attr_reparse == 0) { // a recycled junction/dir symlink: never list its target (C# did)
                for (try fs.list(arena, r, "*", .{ .recurse = true })) |f| try out.append(arena, f.info());
            }
        }
    }
    return out.toOwnedSlice(arena);
}

/// Deletion time of a $I file, null when unreadable, short or out of DateTime range.
fn deletedUtc(io: Io, meta: []const u8) ?Io.Timestamp {
    var b: [24]u8 = undefined;
    const got = Io.Dir.cwd().readFile(io, meta, &b) catch return null;
    if (got.len < 24) return null;
    const ft = std.mem.readInt(i64, b[16..24], .little);
    if (ft < 0 or ft > 2650467743999999999) return null; // DateTime.FromFileTimeUtc range
    return .fromNanoseconds((@as(i96, ft) - 116444736000000000) * 100);
}

/// Special.AfterClean: for a RECYCLEBIN rule, drops the emptied $R folders and refreshes the bin icon.
pub fn afterClean(gpa: Allocator, io: Io, rule: *const rules.Rule) void {
    _ = io;
    if (!rule.hasSpecial("RECYCLEBIN")) return;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    removeEmptyItems(arena, recycleBinDirs(arena) catch return);
    SHUpdateRecycleBinIcon();
}

/// The AfterClean body for given bin folders: every $R folder holding no file goes (junction-safe:
/// removeEmptyTree drops a link as a link; a link whose target holds files stays).
pub fn removeEmptyItems(arena: Allocator, bin_dirs: []const []const u8) void {
    for (bin_dirs) |dir| {
        if (!fs.isDir(dir)) continue;
        for (fs.list(arena, dir, "$R*", .{ .files = false, .dirs = true, .skip = 0 }) catch continue) |r| {
            const left = fs.list(arena, r.path, "*", .{ .recurse = true, .skip = 0 }) catch continue;
            if (left.len == 0) _ = fs.removeEmptyTree(arena, r.path);
        }
    }
}

// ---- Broken shortcuts: .lnk whose target is a missing path on a ready local fixed drive ----

/// Special.BrokenShortcuts: .lnk files whose target is a missing path on a ready local fixed drive.
/// Network, removable and shell-item targets (no file path) are never treated as broken.
/// Reads links through IShellLinkW/IPersistFile (C# used WScript.Shell); initializes COM if the thread has not.
pub fn brokenShortcuts(arena: Allocator, io: Io, folders: []const []const u8) ![]FileInfo {
    _ = io;
    const hr = w.CoInitializeEx(null, @intCast(w.COINIT_APARTMENTTHREADED));
    defer if (hr >= 0) w.CoUninitialize(); // RPC_E_CHANGED_MODE: the thread already has COM (MTA) - use it
    var out: std.ArrayList(FileInfo) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    next: for (folders) |f| {
        if (f.len == 0 or !fs.isDir(f)) continue;
        for (seen.items) |s| if (common.eqlIgnoreCase(s, f)) continue :next;
        try seen.append(arena, f);
        for (try fs.list(arena, f, "*.lnk", .{ .recurse = true })) |lnk| {
            const target = try linkTarget(arena, lnk.path) orelse continue;
            if (isBrokenTarget(target)) try out.append(arena, lnk.info());
        }
    }
    return out.toOwnedSlice(arena);
}

/// IShellLink::GetPath of a .lnk ("" for shell-item targets); null when it cannot be read.
fn linkTarget(arena: Allocator, path: []const u8) !?[]u8 {
    var link: [*c]w.IShellLinkW = null;
    if (w.CoCreateInstance(&w.CLSID_ShellLink, null, w.CLSCTX_INPROC_SERVER, &w.IID_IShellLinkW, @ptrCast(&link)) < 0) return null;
    defer kit.win.release(link);
    var pf: [*c]w.IPersistFile = null;
    if (link.*.lpVtbl.*.QueryInterface.?(link, &w.IID_IPersistFile, @ptrCast(&pf)) < 0) return null;
    defer kit.win.release(pf);
    const pw = try kit.win.toW(arena, path);
    if (pf.*.lpVtbl.*.Load.?(pf, pw.ptr, w.STGM_READ) < 0) return null;
    var buf: [32768]u16 = undefined;
    buf[0] = 0;
    if (link.*.lpVtbl.*.GetPath.?(link, &buf, buf.len, null, 0) < 0) return null;
    return try kit.win.fromWZ(arena, @ptrCast(&buf));
}

fn isBrokenTarget(target: []const u8) bool {
    // Path.IsPathFullyQualified minus UNC/device paths: "X:\..."
    if (target.len < 3 or !std.ascii.isAlphabetic(target[0]) or target[1] != ':' or (target[2] != '\\' and target[2] != '/')) return false;
    const root = [_:0]u16{ target[0], ':', '\\' };
    if (w.GetDriveTypeW(&root) != w.DRIVE_FIXED) return false;
    if (w.GetVolumeInformationW(&root, null, 0, null, null, null, null, 0) == 0) return false; // DriveInfo.IsReady
    return !fs.exists(target);
}

// ---- Event logs: one elevated wevtutil loop, UAC only when Clean runs ----

fn eventLogs(arena: Allocator) !Pending {
    var bytes: u64 = 0;
    const sys = try folder(arena, &w.FOLDERID_System);
    if (sys.len > 0) {
        const dir = try Io.Dir.path.join(arena, &.{ sys, "winevt", "Logs" });
        // size unknown without admin: enumeration failures just leave 0
        for (fs.list(arena, dir, "*.evtx", .{ .skip = fs.attr_hidden | fs.attr_system }) catch &[_]fs.Entry{}) |f| bytes += f.size;
    }
    return .{ .label = "Windows event logs (all)", .bytes = bytes, .run = clearEventLogs };
}

fn clearEventLogs() bool {
    return elevated.run("cmd.exe", "/c for /f \"delims=\" %l in ('wevtutil el') do @wevtutil cl \"%l\"");
}

// ---- Win32 ----

fn emptyClipboardNow() bool {
    if (w.OpenClipboard(null) == 0) return false;
    defer _ = w.CloseClipboard();
    return w.EmptyClipboard() != 0;
}

/// Clears the local resolver cache only (same as ipconfig /flushdns); sends nothing over the network.
/// dnsapi is loaded on demand, so the exe imports no DNS/network library.
fn flushDns() bool {
    const lib = w.LoadLibraryW(kit.win.L("dnsapi.dll"));
    if (lib == null) return false;
    defer _ = w.FreeLibrary(lib);
    const f = w.GetProcAddress(lib, "DnsFlushResolverCache") orelse return false;
    const flush: *const fn () callconv(.winapi) w.WINBOOL = @ptrCast(f);
    return flush() != 0;
}
