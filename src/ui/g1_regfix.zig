//! "Fix registry issues" (legacy RegFixDialog.cs): the n/N stepper shown after the backup is written. Look at one
//! issue at a time, fix it, fix all, or close. Fixed issues stay in the walk (marked) so the counter never jumps.
//! Every batch is one regcleaner.apply on a job (one UAC prompt at most), then the registry itself says which
//! issues are gone; the rest stay unfixed and can be retried.
const std = @import("std");
const kit = @import("kit");
const g = @import("g1_common.zig");
const regcleaner = @import("../core/regcleaner.zig");

const im = kit.im;
const pal = kit.app.palettes.cleaner;
const Allocator = std.mem.Allocator;
const Job = kit.jobs.Job;
const RegIssue = regcleaner.RegIssue;

const title = "Fix registry issues###regfixdlg";

pub const Fix = struct {
    gpa: Allocator,
    io: std.Io,
    issues: []const RegIssue = &.{}, // borrowed from the Registry page until the dialog closes
    fixed: []bool = &.{},
    failed: []bool = &.{},
    at: usize = 0,
    open: bool = false,
    want_open: bool = false,
    job: Job = .{},
    batch: std.ArrayList(usize) = .empty,
    all: bool = false, // the running batch is "Fix All Selected"
    close_pending: bool = false,
    confirm: g.Dialog = .{},

    pub fn init(gpa: Allocator, io: std.Io) Fix {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(f: *Fix) void {
        f.job.cancel();
        f.job.join();
        f.gpa.free(f.fixed);
        f.gpa.free(f.failed);
        f.batch.deinit(f.gpa);
    }

    pub fn start(f: *Fix, issues: []const RegIssue) !void {
        f.gpa.free(f.fixed);
        f.gpa.free(f.failed);
        f.fixed = &.{};
        f.failed = &.{};
        f.fixed = try f.gpa.alloc(bool, issues.len);
        f.failed = try f.gpa.alloc(bool, issues.len);
        @memset(f.fixed, false);
        @memset(f.failed, false);
        f.issues = issues;
        f.at = 0;
        f.close_pending = false;
        f.open = true;
        f.want_open = true;
    }

    pub fn failedCount(f: *const Fix) usize {
        var n: usize = 0;
        for (f.failed) |x| n += @intFromBool(x);
        return n;
    }

    fn anyLeft(f: *const Fix) bool {
        for (f.fixed) |x| if (!x) return true;
        return false;
    }

    /// Draws the modal; true once when it closed.
    pub fn draw(f: *Fix) bool {
        if (!f.open) return false;
        const s = g.scale();
        if (f.want_open) {
            _ = im.ImGui_OpenPopup(title, 0);
            f.want_open = false;
        }
        if (g.ended(&f.job)) f.finishApply();
        const busy = f.job.isRunning();

        const vp = im.ImGui_GetMainViewport();
        im.ImGui_SetNextWindowPosEx(im.ImGuiViewport_GetCenter(vp), im.ImGuiCond_Appearing, .{ .x = 0.5, .y = 0.5 });
        im.ImGui_SetNextWindowSizeConstraints(.{ .x = 560 * s, .y = 0 }, .{ .x = 560 * s, .y = 10000 }, null, null);
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_PopupBg, g.col(pal.bg));
        im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_WindowPadding, .{ .x = 18 * s, .y = 18 * s });
        var keep = true;
        const visible = im.ImGui_BeginPopupModal(title, if (busy) null else &keep, im.ImGuiWindowFlags_AlwaysAutoResize | im.ImGuiWindowFlags_NoSavedSettings);
        im.ImGui_PopStyleVar();
        im.ImGui_PopStyleColor();
        if (!visible) {
            if (!keep and !busy) return f.close(false);
            return false;
        }
        defer im.ImGui_EndPopup();
        if ((!keep and !busy) or f.close_pending) return f.close(true);

        const n = f.issues.len;
        const x = &f.issues[f.at];
        // << Issue n of N >>
        const nav = n > 1 and !busy;
        if (g.buttonMin("<<##regprev", nav, false, 50)) f.show(f.at + n - 1);
        im.ImGui_SameLineEx(0, 12 * s);
        var cbuf: [160]u8 = undefined;
        const mark: []const u8 = if (busy) "  -  fixing..." else if (f.fixed[f.at]) "  -  fixed" else if (f.failed[f.at]) "  -  not fixed (administrator rights declined?)" else "";
        const counter: []const u8 = std.mem.print(&cbuf, "Issue {d} of {d}{s}", .{ f.at + 1, n, mark }) catch "";
        const cy = im.ImGui_GetCursorPosY();
        im.ImGui_SetCursorPosY(cy + (32 * s - im.ImGui_GetFontSize()) / 2);
        im.ImGui_PushFontFloat(g.boldFont(), 0);
        g.label(counter, "regcounter", 0, pal.text);
        im.ImGui_PopFont();
        im.ImGui_SameLine();
        im.ImGui_SetCursorPosY(cy);
        g.alignRight(@max(50 * s, im.ImGui_CalcTextSize(">>").x + 32 * s));
        if (g.buttonMin(">>##regnext", nav, false, 50)) f.show(f.at + 1);

        // details
        im.ImGui_Dummy(.{ .x = 0, .y = 6 * s });
        var dbuf: [3000]u8 = undefined;
        const target = x.target(f.gpa) catch null;
        defer if (target) |t| f.gpa.free(t);
        const details: []const u8 = std.mem.print(&dbuf, "Problem: {s}\nData: {s}\nRegistry key: {s}\n\nSolution: delete the registry {s}.", .{
            x.problem, x.data, target orelse x.key_path, if (x.value_name == null) "key" else "value",
        }) catch "";
        g.label(details, "regdetails", im.ImGui_GetContentRegionAvail().x, pal.text);
        im.ImGui_Dummy(.{ .x = 0, .y = 6 * s });

        // Fix Issue / Fix All Selected / Close
        const w = g.buttonWidth("Fix Issue##regfixone") + g.buttonWidth("Fix All Selected##regfixall") + g.buttonWidth("Close##regclose") + 16 * s;
        g.alignRight(w);
        if (g.button("Fix Issue##regfixone", !busy and !f.fixed[f.at], false)) f.startApply(false);
        im.ImGui_SameLineEx(0, 8 * s);
        if (g.button("Fix All Selected##regfixall", !busy and f.anyLeft(), true)) {
            var left: usize = 0;
            for (f.fixed) |d| left += @intFromBool(!d);
            var mbuf: [160]u8 = undefined;
            const msg: []const u8 = std.mem.print(&mbuf, "Fix all {d} remaining issues? The backup you just saved can undo this.", .{left}) catch "Fix all remaining issues?";
            f.confirm.show(0, .warning, "Fix All Selected", msg, &.{ "Fix all", "Cancel" });
        }
        im.ImGui_SameLineEx(0, 8 * s);
        if (g.button("Close##regclose", !busy, false)) return f.close(true);

        if (f.confirm.draw()) |a| if (a.index == 0) f.startApply(true);
        return false;
    }

    fn show(f: *Fix, i: usize) void {
        f.at = i % f.issues.len;
    }

    fn close(f: *Fix, in_popup: bool) bool {
        if (in_popup) im.ImGui_CloseCurrentPopup();
        f.open = false;
        return true;
    }

    fn startApply(f: *Fix, all: bool) void {
        f.batch.clearRetainingCapacity();
        if (all) {
            for (f.fixed, 0..) |d, i| if (!d) f.batch.append(f.gpa, i) catch return;
        } else f.batch.append(f.gpa, f.at) catch return;
        f.all = all;
        f.job.start(f, applyWorker) catch {};
    }

    fn applyWorker(job: *Job) anyerror!void {
        const f = job.ctx(Fix);
        kit.win.comInitSta() catch {}; // ShellExecuteEx (elevated reg.exe import) wants COM on this thread
        defer kit.win.comUninit();
        const batch = try f.gpa.alloc(RegIssue, f.batch.items.len);
        defer f.gpa.free(batch);
        for (f.batch.items, batch) |i, *b| b.* = f.issues[i];
        _ = try regcleaner.apply(f.gpa, f.io, batch, null);
        for (f.batch.items) |i| {
            const gone = !regcleaner.exists(&f.issues[i]);
            f.fixed[i] = gone;
            f.failed[i] = !gone;
        }
    }

    fn finishApply(f: *Fix) void {
        f.job.join();
        var ebuf: [128]u8 = undefined;
        if (f.job.errorText(&ebuf) != null) for (f.batch.items) |i| {
            if (!f.fixed[i]) f.failed[i] = true;
        };
        const n = f.issues.len;
        if (!f.all) {
            // next unfixed after this one (wrapping, this one last); none left -> close
            for (1..n + 1) |d| {
                const i = (f.at + d) % n;
                if (!f.fixed[i]) return f.show(i);
            }
            f.close_pending = true;
            return;
        }
        // stay when something is still broken: show the first one
        for (f.failed, 0..) |x, i| if (x) return f.show(i);
        f.close_pending = true;
    }
};
