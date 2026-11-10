# Runs the `test` blocks of src/ui/*.zig (pure ASCII). build.zig has no test root for the GUI files, so this
# copies src to zig-out\uitest\src, adds a root that references them and builds it with a throw-away build.zig
# that takes kit / sqlite / rules from this repo (dependency "../..").
#   powershell -ExecutionPolicy Bypass -File tools\ui-selftest.ps1   -> 'N/N tests passed'
# ponytail: delete once build.zig grows a test step for src/ui.
param([string]$Zig = "$env:LOCALAPPDATA\Programs\zig\0.17.1\zig.exe")
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dir = Join-Path $repo 'zig-out\uitest'
if (Test-Path "$dir\src") { Remove-Item -Recurse -Force "$dir\src" }
New-Item -ItemType Directory -Force $dir | Out-Null
Copy-Item -Recurse (Join-Path $repo 'src') "$dir\src"
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText("$dir\src\ui_selftest.zig", @'
const std = @import("std");
test {
    _ = @import("ui/tools_ui.zig");
    std.testing.refAllDecls(@import("ui/tools_wiper.zig").View);
    std.testing.refAllDecls(@import("ui/options_cookies.zig").View);
}
'@, $utf8)
[IO.File]::WriteAllText("$dir\build.zig.zon", @'
.{
    .name = .mcuitest,
    .version = "0.0.1",
    .fingerprint = 0xa2641425611dd7f5,
    .minimum_zig_version = "0.17.1",
    .dependencies = .{
        .translate_c = .{
            .url = "git+https://codeberg.org/ziglang/translate-c?ref=2.0.2#c11030012dc325d446474d17b78c242fd1d622ec",
            .hash = "translate_c-2.0.2-Q_BUWvBNBwBgPKQJPblip6M7AHNK_IPNPmyv4rSIQMQc",
        },
        .mc = .{ .path = "../.." },
    },
    .paths = .{""},
}
'@, $utf8)
[IO.File]::WriteAllText("$dir\build.zig", @'
const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{});
    const mc = b.dependency("mc", .{ .target = target, .optimize = optimize });
    const kit_dep = mc.builder.dependency("makekit", .{ .target = target, .optimize = optimize });
    const sqlite_c = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    sqlite_c.addCSourceFile(.{ .file = mc.path("third_party/sqlite/sqlite3.c"), .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-fno-sanitize=undefined" } });
    const sqlite_lib = b.addLibrary(.{ .name = "sqlite3", .root_module = sqlite_c });
    const sqlite_t: Translator = .init(b.dependency("translate_c", .{}), .{ .name = "sqlite", .c_source_file = mc.path("third_party/sqlite/sqlite3.h"), .target = target, .optimize = optimize });
    sqlite_t.mod.linkLibrary(sqlite_lib);
    const m = b.createModule(.{ .root_source_file = b.path("src/ui_selftest.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "kit", .module = kit_dep.module("kit") },
        .{ .name = "sqlite", .module = sqlite_t.mod },
    } });
    m.addAnonymousImport("windows_ini", .{ .root_source_file = mc.path("rules/Windows.ini") });
    b.step("test", "src/ui tests").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
}
'@, $utf8)
Push-Location $dir
try {
    $ErrorActionPreference = 'Continue'
    $out = & $Zig build test --summary all 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
} finally { Pop-Location }
$out | Where-Object { $_ -match 'error|passed|failed|Summary' } | ForEach-Object { Write-Host $_ }
exit $code
