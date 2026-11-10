//! Tools > Drive Wiper (legacy DriveWiperView): wipe free space, or format + wipe a whole non-system drive
//! (admin relaunch + typed "ERASE" confirmation). The wipe runs on a job with progress text and Cancel.
const std = @import("std");
const kit = @import("kit");
const Ctx = @import("ctx.zig").Ctx;
const ui = @import("tools_ui.zig");
const securedelete = @import("../core/securedelete.zig");
const drivewiper = @import("../core/drivewiper.zig");
const common = @import("../core/common.zig");

const im = kit.im;
const w = kit.w;

pub const confirm_word = "ERASE";
const tag_free = 1;
const tag_refused = 2;
const tag_admin = 3;

const Drive = struct {
    root: [4]u8, // "X:\"
    text: [200]u8,
    text_len: usize,
    ssd: ?bool,
    on: bool = false,
};

/// Wipe methods with passes > 0 (combo order).
const methods = blk: {
    var out: [securedelete.methods.len - 1]securedelete.Method = undefined;
    var n = 0;
    for (securedelete.methods) |m| if (m.passes > 0) {
        out[n] = m;
        n += 1;
    };
    break :blk out;
};

pub const View = struct {
    io: std.Io,
    job: kit.jobs.Job = .{},
    drives: std.ArrayList(Drive) = .empty,
    mode: c_int = 0,
    passes: c_int = 0,
    // job input
    targets: [26][4]u8 = undefined,
    n_targets: usize = 0,
    entire: bool = false,
    n_passes: u8 = 1,
    progress: ui.Text(300) = .{},
    prompt_open: bool = false,
    prompt: ui.Buf(32) = .{},
    dlg: ui.Dialog = .{},
    cur_root: []const u8 = "", // worker only

    pub fn create(ctx: *Ctx) !*View {
        const v = try ctx.gpa.create(View);
        v.* = .{ .io = ctx.io };
        v.listDrives(ctx.gpa);
        return v;
    }

    pub fn destroy(v: *View, ctx: *Ctx) void {
        v.job.cancel();
        v.job.join();
        v.drives.deinit(ctx.gpa);
        ctx.gpa.destroy(v);
    }

    /// Ready Fixed/Removable drives: "X:\ (System) [SSD]   label   FS   N GB free of M GB".
    fn listDrives(v: *View, gpa: std.mem.Allocator) void {
        const sys = drivewiper.systemRoot(gpa) catch null;
        defer if (sys) |p| gpa.free(p);
        const mask = w.GetLogicalDrives();
        for (0..26) |i| {
            if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
            const letter: u8 = 'A' + @as(u8, @intCast(i));
            const root_w = [_:0]u16{ letter, ':', '\\' };
            const t = w.GetDriveTypeW(&root_w);
            if (t != w.DRIVE_FIXED and t != w.DRIVE_REMOVABLE) continue;
            var label: [w.MAX_PATH + 1]u16 = undefined;
            var fs: [w.MAX_PATH + 1]u16 = undefined;
            if (w.GetVolumeInformationW(&root_w, &label, label.len, null, null, null, &fs, fs.len) == 0) continue; // IsReady
            var free: w.ULARGE_INTEGER = undefined;
            var total: w.ULARGE_INTEGER = undefined;
            if (w.GetDiskFreeSpaceExW(&root_w, &free, &total, null) == 0) continue;
            var d: Drive = .{ .root = .{ letter, ':', '\\', 0 }, .text = undefined, .text_len = 0, .ssd = drivewiper.isSsd(&.{ letter, ':', '\\' }) };
            const root = d.root[0..3];
            var lb: [300]u8 = undefined;
            var fb: [32]u8 = undefined;
            const l8 = lb[0..std.unicode.wtf16LeToWtf8(&lb, std.mem.sliceTo(&label, 0))];
            const f8 = fb[0..std.unicode.wtf16LeToWtf8(&fb, std.mem.sliceTo(&fs, 0))];
            var g1: [32]u8 = undefined;
            var g2: [32]u8 = undefined;
            const free_gb = ui.fmt01(&g1, @as(f64, @floatFromInt(free.QuadPart)) / (1 << 30));
            const total_gb = ui.fmt01(&g2, @as(f64, @floatFromInt(total.QuadPart)) / (1 << 30));
            const is_sys = if (sys) |p| common.eqlIgnoreCase(p, root) else false;
            const txt = std.mem.print(&d.text, "{s}{s}{s}   {s}   {s}   {s} GB free of {s} GB", .{
                root, if (is_sys) " (System)" else "", if (d.ssd == true) " [SSD]" else "", l8, f8, free_gb, total_gb,
            }) catch d.text[0..0];
            d.text_len = txt.len;
            v.drives.append(gpa, d) catch return;
        }
    }

    fn entireMode(v: *const View) bool {
        return v.mode == 1;
    }

    fn targetNames(v: *View, buf: []u8) []const u8 {
        var n: usize = 0;
        for (v.targets[0..v.n_targets], 0..) |t, i| {
            const part = std.mem.print(buf[n..], "{s}{s}", .{ if (i > 0) ", " else "", t[0..3] }) catch break;
            n += part.len;
        }
        return buf[0..n];
    }

    /// Wipe button: collect targets, then the confirmations (each answer continues in `draw`).
    fn run(v: *View) void {
        v.n_targets = 0;
        for (v.drives.items) |d| if (d.on) {
            v.targets[v.n_targets] = d.root;
            v.n_targets += 1;
        };
        if (v.n_targets == 0) return v.progress.set("Select at least one drive.", .{});
        v.n_passes = methods[@intCast(v.passes)].passes;
        v.entire = v.entireMode();
        var nb: [128]u8 = undefined;
        if (v.entire) {
            const gpa = std.heap.smp_allocator;
            const sys = drivewiper.systemRoot(gpa) catch return;
            defer gpa.free(sys);
            var eb: [w.MAX_PATH + 1]u16 = undefined;
            const n = w.GetModuleFileNameW(null, &eb, eb.len);
            var exe_root: [3]u8 = .{ 0, ':', '\\' };
            if (n >= 3) exe_root[0] = @intCast(eb[0] & 0x7F);
            for (v.targets[0..v.n_targets]) |*t| {
                if (drivewiper.checkErasable(gpa, t[0..3], sys, &exe_root) catch null) |why| {
                    defer gpa.free(why);
                    v.dlg.show(tag_refused, "Drive Wiper", .err, &.{"OK"}, "{s}", .{why});
                    return;
                }
            }
            if (!ui.requireAdmin(&v.dlg, tag_admin, "Erasing an entire drive")) return;
            v.prompt.set("");
            v.prompt_open = true;
        } else {
            v.dlg.show(tag_free, "Drive Wiper", .warning, &.{ "Wipe free space", "Cancel" }, "Wipe free space on {s} with {d} pass(es)? This can take a long time; the drive is temporarily filled.", .{ v.targetNames(&nb), v.n_passes });
        }
    }

    fn startJob(v: *View) void {
        if (v.job.thread != null) return;
        v.progress.set("", .{});
        v.job.start(v, worker) catch {};
    }

    fn worker(job: *kit.jobs.Job) anyerror!void {
        const v = job.ctx(View);
        const gpa = std.heap.smp_allocator;
        for (v.targets[0..v.n_targets]) |*t| {
            const root = t[0..3];
            if (v.entire) {
                job.setStatus("Formatting {s}", .{root});
                try drivewiper.format(gpa, v.io, root);
            }
            const dir = try drivewiper.wipeDir(gpa, root);
            defer gpa.free(dir);
            const Rep = struct {
                fn f(c: ?*anyopaque, s: []const u8) void {
                    const j: *kit.jobs.Job = @ptrCast(@alignCast(c.?));
                    j.setStatus("Erasing {s}: {s}", .{ j.ctx(View).cur_root, s });
                }
            };
            v.cur_root = root;
            _ = try securedelete.wipeFreeSpace(v.io, dir, v.n_passes, .{ .ctx = job, .func = Rep.f }, &job.cancel_flag, std.math.maxInt(u64));
        }
    }

    pub fn draw(v: *View, ctx: *Ctx) void {
        const s = ui.scale();
        if (ui.jobDone(&v.job)) {
            var eb: [256]u8 = undefined;
            if (v.job.cancelled()) {
                v.progress.set("Cancelled. Temporary wipe files removed.", .{});
            } else if (v.job.errorText(&eb)) |e| {
                v.progress.set("Failed: {s}", .{e});
            } else v.progress.set("Drive Wiper complete.", .{});
            v.refreshDrives(ctx.gpa); // a format changes label / file system / free space
        }
        if (v.job.isRunning()) {
            var sb: [256]u8 = undefined;
            const st = v.job.status(&sb);
            v.progress.set("{s}", .{st});
        }
        if (v.dlg.draw()) |ans| switch (ans.tag) {
            tag_free => if (ans.button == 0) v.startJob(),
            tag_admin => if (ans.button == 0) ui.restartAsAdmin(ctx),
            else => {},
        };
        if (v.drawPrompt()) |erase| if (erase) v.startJob();

        im.ImGui_TextUnformatted("Securely erase the free space or the whole contents of a drive.");
        im.ImGui_Dummy(.{ .x = 0, .y = 8 * s });
        const busy = v.job.isRunning();
        im.ImGui_BeginDisabled(busy);
        const x = im.ImGui_GetCursorPosX();
        im.ImGui_PushFontFloat(ctx.app.fonts.bold, 0);
        ui.label("Wipe");
        im.ImGui_PopFont();
        im.ImGui_SameLineEx(x + 90 * s, 0);
        _ = ui.combo("wipeMode", &.{ "Free Space Only", "Entire Drive (all data will be erased)" }, &v.mode, 320 * s);
        im.ImGui_PushFontFloat(ctx.app.fonts.bold, 0);
        ui.label("Security");
        im.ImGui_PopFont();
        im.ImGui_SameLineEx(x + 90 * s, 0);
        var items: [methods.len][*:0]const u8 = undefined;
        inline for (methods, 0..) |m, i| items[i] = std.fmt.comptimePrint("{s}", .{m.label});
        _ = ui.combo("wipePasses", &items, &v.passes, 320 * s);
        im.ImGui_Dummy(.{ .x = 0, .y = 8 * s });

        const avail = im.ImGui_GetContentRegionAvail();
        // warning (2 lines) + progress row (2 lines), each preceded by an item gap
        const bottom_h = im.ImGui_GetFontSize() * 4 + ui.sp() * 3 + 4 * s;
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ChildBg, ui.col(ui.pal.surface));
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Border, ui.col(ui.pal.line));
        if (im.ImGui_BeginChild("##drives", .{ .x = 0, .y = @max(60 * s, avail.y - bottom_h) }, im.ImGuiChildFlags_Borders, 0)) {
            for (v.drives.items, 0..) |*d, i| {
                var lb: [256]u8 = undefined;
                _ = ui.check(ui.idLabel(&lb, d.text[0..d.text_len], "drive{d}", .{i}).ptr, &d.on);
            }
        }
        im.ImGui_EndChild();
        im.ImGui_PopStyleColorEx(2);
        im.ImGui_EndDisabled();

        // warning (Danger), then [progress text] [Wipe] [Cancel]
        var wb: [400]u8 = undefined;
        var ww: std.Io.Writer = .fixed(&wb);
        if (v.entireMode()) ww.writeAll("WARNING: Entire Drive erases ALL data on the selected drives. The system drive cannot be erased.") catch {};
        for (v.drives.items) |d| if (d.on and d.ssd != false) {
            if (ww.end > 0) ww.writeAll("\n") catch {};
            ww.writeAll("Solid-state drives can wear out prematurely when securely wiped, and wiping does not reliably reach all of their cells.") catch {};
            break;
        };
        im.ImGui_SetCursorPosY(im.ImGui_GetCursorPosY() + 4 * s);
        ui.statusIn("wipeWarning", wb[0..ww.end], ui.pal.danger, im.ImGui_GetContentRegionAvail().x);
        const btns = 90 * s + 8 * s + 90 * s;
        ui.statusIn("wipeProgress", v.progress.slice(), ui.pal.text, im.ImGui_GetContentRegionAvail().x - btns - 8 * s);
        im.ImGui_SameLineEx(0, 8 * s);
        if (ui.primary("Wipe##wipe", !busy)) v.run();
        im.ImGui_SameLineEx(0, 8 * s);
        if (ui.button("Cancel##wipeCancel", busy)) v.job.cancel();
        if (busy) ctx.app.requestFrames(2);
    }

    /// listDrives again, keeping the ticks by drive letter.
    fn refreshDrives(v: *View, gpa: std.mem.Allocator) void {
        var on: u32 = 0;
        for (v.drives.items) |d| if (d.on) {
            on |= @as(u32, 1) << @intCast(d.root[0] - 'A');
        };
        v.drives.clearRetainingCapacity();
        v.listDrives(gpa);
        for (v.drives.items) |*d| d.on = on & (@as(u32, 1) << @intCast(d.root[0] - 'A')) != 0;
    }

    /// DriveWiperView.Prompt answer: OK (button or Enter) erases only when the box says exactly ERASE (blanks around
    /// it ignored, case-sensitive, like `box.Text.Trim() == ConfirmWord`); OK with anything else, Cancel and Esc
    /// close without erasing. null = still open.
    pub fn promptAnswer(typed: []const u8, ok: bool, cancel: bool) ?bool {
        if (ok) return std.mem.eql(u8, std.mem.trim(u8, typed, &std.ascii.whitespace), confirm_word);
        return if (cancel) false else null;
    }

    test promptAnswer {
        try std.testing.expectEqual(@as(?bool, true), promptAnswer("ERASE", true, false));
        try std.testing.expectEqual(@as(?bool, true), promptAnswer("  ERASE\t", true, false));
        try std.testing.expectEqual(@as(?bool, false), promptAnswer("erase", true, false));
        try std.testing.expectEqual(@as(?bool, false), promptAnswer("ERASED", true, false));
        try std.testing.expectEqual(@as(?bool, false), promptAnswer("", true, false));
        try std.testing.expectEqual(@as(?bool, false), promptAnswer("ERASE", false, true));
        try std.testing.expectEqual(@as(?bool, null), promptAnswer("ERASE", false, false));
    }

    /// Typed-word confirmation (DriveWiperView.Prompt); see `promptAnswer`.
    fn drawPrompt(v: *View) ?bool {
        const id = "Drive Wiper##erasePrompt";
        if (v.prompt_open) {
            _ = im.ImGui_OpenPopup(id, 0);
            v.prompt_open = false;
        }
        const s = ui.scale();
        im.ImGui_SetNextWindowPosEx(im.ImGuiViewport_GetCenter(im.ImGui_GetMainViewport()), im.ImGuiCond_Appearing, .{ .x = 0.5, .y = 0.5 });
        im.ImGui_SetNextWindowSize(.{ .x = 440 * s, .y = 0 }, 0);
        if (!im.ImGui_BeginPopupModal(id, null, im.ImGuiWindowFlags_NoResize | im.ImGuiWindowFlags_NoSavedSettings)) return null;
        defer im.ImGui_EndPopup();
        var nb: [128]u8 = undefined;
        var tb: [300]u8 = undefined;
        const text = ui.z(&tb, "All data on {s} will be permanently erased.\nType {s} to continue:", .{ v.targetNames(&nb), confirm_word });
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Text, ui.col(ui.pal.danger));
        im.ImGui_TextWrappedUnformatted(text.ptr);
        im.ImGui_PopStyleColor();
        im.ImGui_Dummy(.{ .x = 0, .y = 4 * s });
        if (im.ImGui_IsWindowAppearing()) im.ImGui_SetKeyboardFocusHere();
        const entered = im.ImGui_InputText("##confirmWord", &v.prompt.b, v.prompt.b.len + 1, im.ImGuiInputTextFlags_EnterReturnsTrue);
        im.ImGui_Dummy(.{ .x = 0, .y = 6 * s });
        im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + im.ImGui_GetContentRegionAvail().x - 96 * s * 2 - 8 * s);
        const ok = ui.primary("Erase##erasePromptOk", true) or entered;
        im.ImGui_SameLineEx(0, 8 * s);
        const no = ui.button("Cancel##erasePromptCancel", true) or im.ImGui_IsKeyPressed(im.ImGuiKey_Escape);
        const answer = promptAnswer(v.prompt.slice(), ok, no);
        if (answer != null) im.ImGui_CloseCurrentPopup();
        return answer;
    }
};
