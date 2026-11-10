//! Bytes.cs: human-readable sizes. `w.print("{f}", .{bytes.fmt(n)})` -> "1.5 KB".
const std = @import("std");

pub fn fmt(b: u64) Fmt {
    return .{ .b = b };
}

pub const Fmt = struct {
    b: u64,

    /// Bytes.Fmt: up to two decimals, trailing zeros dropped ("0.##").
    /// ponytail: always "." as the decimal separator; .NET used the current culture.
    pub fn format(f: Fmt, wr: *std.Io.Writer) std.Io.Writer.Error!void {
        const units = [_]struct { u6, []const u8 }{ .{ 30, "GB" }, .{ 20, "MB" }, .{ 10, "KB" } };
        for (units) |u| {
            const unit = @as(u64, 1) << u[0];
            if (f.b < unit) continue;
            const x = @as(f64, @floatFromInt(f.b)) / @as(f64, @floatFromInt(unit));
            const c: u64 = @round(x * 100); // half away from zero, like .NET
            try wr.print("{d}", .{c / 100});
            const frac = c % 100;
            if (frac % 10 != 0) {
                try wr.print(".{d:0>2}", .{frac});
            } else if (frac != 0) {
                try wr.print(".{d}", .{frac / 10});
            }
            return wr.print(" {s}", .{u[1]});
        }
        return wr.print("{d} B", .{f.b});
    }
};

test "Bytes.Fmt" {
    try std.testing.expectFmt("0 B|1023 B|1 KB|1.5 KB|1.33 KB|1 MB|2.25 GB|1024 GB", "{f}|{f}|{f}|{f}|{f}|{f}|{f}|{f}", .{
        fmt(0),       fmt(1023),          fmt(1024),    fmt(1536), fmt(1362),
        fmt(1 << 20), fmt((9 << 30) / 4), fmt(1 << 40),
    });
}
