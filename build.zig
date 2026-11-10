const std = @import("std");
const Translator = @import("translate_c").Translator;

// zig build              exe (zig-out/bin/MakeCleaner.exe + rules/)
// zig build test         every test (src/test_all.zig)
// zig build test-<pkg>   one package: base | rules | browsers | registry | systools | filetools | ui
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{});
    const kit_dep = b.dependency("makekit", .{ .target = target, .optimize = optimize });

    // ---- SQLite amalgamation (third_party/sqlite, see VERSION) as a static C lib, exposed as module "sqlite"
    const sqlite_c = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sqlite_c.addCSourceFile(.{
        .file = b.path("third_party/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_SHARED_CACHE",
            "-fno-sanitize=undefined", // UBSan traps in Debug on sqlite's deliberate overflow/shift idioms
        },
    });
    const sqlite_lib = b.addLibrary(.{ .name = "sqlite3", .root_module = sqlite_c });
    const tc = b.dependency("translate_c", .{});
    const sqlite_t: Translator = .init(tc, .{ .name = "sqlite", .c_source_file = b.path("third_party/sqlite/sqlite3.h"), .target = target, .optimize = optimize });
    sqlite_t.mod.linkLibrary(sqlite_lib);

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "kit", .module = kit_dep.module("kit") },
        .{ .name = "sqlite", .module = sqlite_t.mod },
    };

    // ---- exe
    const exe = b.addExecutable(.{
        .name = "MakeCleaner",
        .root_module = module(b, "src/main.zig", imports, target, optimize),
        .win32_manifest = kit_dep.namedLazyPath("manifest"), // ponytail: no icon yet; switch to app.rc (`1 ICON` + `1 24 "app.manifest"`) when one exists
    });
    exe.subsystem = .windows;
    b.installArtifact(exe);
    // rules next to the exe (Winapp2.ini must ship with its CC BY-SA attribution in README.md)
    b.installDirectory(.{ .source_dir = b.path("rules"), .install_dir = .bin, .install_subdir = "rules" });

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run MakeCleaner").dependOn(&run.step);

    // ---- tests: one root per package (owned by that package), test_all = everything
    for ([_][]const u8{ "all", "base", "rules", "browsers", "registry", "systools", "filetools", "ui" }) |name| {
        const root = b.fmt("src/test_{s}.zig", .{name});
        const t = b.addTest(.{ .name = b.fmt("test-{s}", .{name}), .root_module = module(b, root, imports, target, optimize) });
        const step_name = if (std.mem.eql(u8, name, "all")) "test" else b.fmt("test-{s}", .{name});
        const run_t = b.addRunArtifact(t);
        // ScheduleTests runs the installed exe with /auto: never let it run a stale one.
        if (std.mem.eql(u8, name, "systools") or std.mem.eql(u8, name, "all")) run_t.step.dependOn(b.getInstallStep());
        b.step(step_name, b.fmt("Run {s} tests", .{name})).dependOn(&run_t.step);
    }
}

fn module(b: *std.Build, root: []const u8, imports: []const std.Build.Module.Import, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const m = b.createModule(.{ .root_source_file = b.path(root), .target = target, .optimize = optimize, .imports = imports });
    // Engine.BuiltInRules: Windows.ini is compiled in so the Windows tab can never go missing (`@embedFile("windows_ini")`).
    m.addAnonymousImport("windows_ini", .{ .root_source_file = b.path("rules/Windows.ini") });
    return m;
}
