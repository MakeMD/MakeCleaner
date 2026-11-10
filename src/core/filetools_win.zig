//! Win32 path + handle helpers shared by the MC-E tools (duplicates/diskanalyzer walker, securedelete).
//! Win32 calls get a full `\\?\` path so folders deeper than MAX_PATH work like they do in .NET.
const std = @import("std");
const w = @import("kit").w;

pub const PathW = std.Io.Threaded.WindowsPathSpace;

/// Full, `\\?\`-prefixed UTF-16 path of `path` (WTF-8; relative = against the CWD, "." / ".." / "/" normalized
/// like Path.GetFullPath).
pub fn winPath(path: []const u8) !PathW {
    var p = try std.Io.Threaded.sliceToPrefixedFileW(null, path, .{ .allow_relative = false });
    if (std.mem.startsWith(u16, p.span(), &.{ '\\', '?', '?', '\\' })) p.data[1] = '\\'; // NT \??\ -> Win32 \\?\
    return p;
}

/// Path.GetFullPath: `winPath` back in WTF-8 without the `\\?\` prefix (`\\?\UNC\s\x` -> `\\s\x`).
pub fn fullPath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const p = try winPath(path);
    var s: []const u16 = p.span();
    const unc = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\UNC\\");
    if (std.mem.startsWith(u16, s, unc)) {
        const out = try std.unicode.wtf16LeToWtf8Alloc(gpa, s[unc.len - 2 ..]);
        out[0] = '\\';
        return out;
    }
    if (std.mem.startsWith(u16, s, &.{ '\\', '\\', '?', '\\' })) s = s[4..];
    return std.unicode.wtf16LeToWtf8Alloc(gpa, s);
}

/// A raw, unbuffered Win32 file handle: `open` = write, no sharing (FileShare.None); `openRead` = read.
pub const Handle = struct {
    h: w.HANDLE,

    /// `disposition` = w.OPEN_EXISTING / CREATE_NEW / TRUNCATE_EXISTING; `flags` e.g. FILE_FLAG_DELETE_ON_CLOSE.
    pub fn open(path: []const u8, disposition: c_int, flags: c_int) !Handle {
        return create(path, w.GENERIC_WRITE, 0, disposition, flags);
    }

    /// FileInfo.OpenRead: read access sharing read only (FileShare.Read), so a file another process holds open
    /// for writing fails with error.FileBusy instead of being read half-written.
    pub fn openRead(path: []const u8) !Handle {
        return create(path, w.GENERIC_READ, w.FILE_SHARE_READ, w.OPEN_EXISTING, 0);
    }

    fn create(path: []const u8, access: w.DWORD, share: w.DWORD, disposition: c_int, flags: c_int) !Handle {
        const p = try winPath(path);
        const h = w.CreateFileW(p.span().ptr, access, share, null, @intCast(disposition), @bitCast(w.FILE_ATTRIBUTE_NORMAL | flags), null);
        if (h == w.INVALID_HANDLE_VALUE) return switch (w.GetLastError()) {
            w.ERROR_FILE_NOT_FOUND, w.ERROR_PATH_NOT_FOUND => error.FileNotFound,
            w.ERROR_ACCESS_DENIED => error.AccessDenied,
            w.ERROR_SHARING_VIOLATION, w.ERROR_LOCK_VIOLATION => error.FileBusy,
            w.ERROR_FILE_EXISTS, w.ERROR_ALREADY_EXISTS => error.PathAlreadyExists,
            else => error.Unexpected,
        };
        return .{ .h = h };
    }

    pub fn close(f: Handle) void {
        _ = w.CloseHandle(f.h);
    }

    pub fn len(f: Handle) !u64 {
        var size: w.LARGE_INTEGER = undefined;
        if (w.GetFileSizeEx(f.h, &size) == 0) return error.Unexpected;
        return @intCast(size.QuadPart);
    }

    pub fn rewind(f: Handle) !void {
        if (w.SetFilePointerEx(f.h, .{ .QuadPart = 0 }, null, w.FILE_BEGIN) == 0) return error.Unexpected;
    }

    /// Bytes read into `buf`, 0 = end of file.
    pub fn read(f: Handle, buf: []u8) !usize {
        var n: w.DWORD = 0;
        if (w.ReadFile(f.h, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(w.DWORD))), &n, null) == 0) return error.InputOutput;
        return n;
    }

    /// error.DiskFull = ERROR_DISK_FULL / ERROR_HANDLE_DISK_FULL.
    pub fn write(f: Handle, data: []const u8) !void {
        var done: usize = 0;
        while (done < data.len) {
            var n: w.DWORD = 0;
            if (w.WriteFile(f.h, data[done..].ptr, @intCast(data.len - done), &n, null) == 0) return switch (w.GetLastError()) {
                w.ERROR_DISK_FULL, w.ERROR_HANDLE_DISK_FULL => error.DiskFull,
                else => error.InputOutput,
            };
            done += n;
        }
    }

    /// Flush(true): FlushFileBuffers.
    pub fn flush(f: Handle) !void {
        if (w.FlushFileBuffers(f.h) == 0) return error.InputOutput;
    }
};

/// Test helper: directory junction `link` -> `target` (mklink /J needs no privilege, unlike symlinks).
pub fn testJunction(gpa: std.mem.Allocator, io: std.Io, link: []const u8, target: []const u8) !void {
    const r = try std.process.run(gpa, io, .{ .argv = &.{ "cmd.exe", "/c", "mklink", "/J", link, target } });
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    if (!r.term.success()) return error.JunctionFailed;
}
