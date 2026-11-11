# MakeCleaner Zig port - package handoff

`master` (2.0.0). The C# 1.x app is the behaviour spec, in git history only (`git show 6d1238c:legacy/<path>`):
`legacy/src/MakeCleaner.Core/*.cs` = logic, `legacy/src/MakeCleaner/*.xaml(.cs)` = GUI,
`legacy/tests/MakeCleaner.Tests/*.cs` = the ported tests. Zig 0.17.1 (on PATH, `%LOCALAPPDATA%\Programs\zig\0.17.1`);
read `..\MakeKit\docs\ZIG-0.17-NOTES.md` before writing Zig.

## Packages

| id | owned files | spec (legacy/src/MakeCleaner.Core) | tests to port (legacy/tests/MakeCleaner.Tests) | step | status |
|---|---|---|---|---|---|
| skeleton | build.zig, build.zig.zon, src/main.zig, src/test_base.zig, src/test_all.zig, src/core/common.zig, settings.zig, custom.zig, cookies.zig, bytes.zig, reg.zig, elevated.zig, third_party/sqlite, docs/ZIG-PORT.md | Settings.cs, Custom.cs, Cookies.cs, Bytes.cs, Reg.cs, Elevated.cs | CookiesTests; EngineTests.Portable_dat_keeps_settings_next_to_exe; CustomTests.Lists_and_checkbox_states_survive_a_restart and the Reject half of System_paths_are_rejected (rest of CustomTests: MC-A) | test-base | done (22 tests) |
| MC-A | src/core/rules.zig, engine.zig, cleanpass.zig, special.zig, src/test_rules.zig (+ src/core/rules_*.zig) | Rules.cs, Engine.cs, CleanPass.cs, Special.cs | EngineTests, CustomTests, Winapp2Tests, WindowsTabTests | test-rules | done (72 tests) |
| MC-B | src/core/browsers.zig, src/test_browsers.zig (+ browsers_*.zig) | Browsers.cs | BrowsersTests | test-browsers | done (46 tests) |
| MC-C | src/core/regcleaner.zig, src/test_registry.zig (+ regcleaner_*.zig) | RegistryCleaner.cs | RegistryTests | test-registry | done (31 tests) |
| MC-D | src/core/startup.zig, uninstall.zig, schedule.zig, restorepoints.zig, src/test_systools.zig (+ startup_*.zig etc.) | Startup.cs, Uninstall.cs, Schedule.cs, RestorePoints.cs | ToolsTests (Startup, Uninstall, Restore parts), ScheduleTests | test-systools | done (55 tests incl. /auto e2e) |
| MC-E | src/core/duplicates.zig, diskanalyzer.zig, securedelete.zig, drivewiper.zig, src/test_filetools.zig (+ own prefixes) | Duplicates.cs (+ Scan), DiskAnalyzer.cs, SecureDelete.cs, DriveWiper.cs | DuplicatesTests, SecureDeleteTests, ToolsTests (DiskAnalyzer, DriveWiper parts) | test-filetools | done (33 tests) |

GUI: `src/ui/*` (Cleaner, Registry, Tools, Options), driven by the smokes in `tools\` (see MC-T below).

## Build

- `zig build` -> `zig-out/bin/MakeCleaner.exe` (GUI subsystem, kit manifest) + `zig-out/bin/rules/` (Winapp2.ini,
  Windows.ini, README.md with the CC BY-SA attribution).
- `zig build test` = `src/test_all.zig` (every package); `zig build test-<pkg>` = one package. Run only your own step.
- Modules visible to every root: `kit` (MakeKit), `sqlite` (SQLite 3.54.1 C API, translate-c of
  `third_party/sqlite/sqlite3.h`, static lib built with SQLITE_THREADSAFE=1, OMIT_LOAD_EXTENSION, DQS=0,
  DEFAULT_MEMSTATUS=0, OMIT_DEPRECATED, OMIT_SHARED_CACHE, -fno-sanitize=undefined), and `windows_ini`
  (`@embedFile("windows_ini")` = rules/Windows.ini; used by `engine.built_in_rules`).
- Test roots call `common.refAll(file)`, which type-checks every pub decl (and nested struct methods) of the
  package files, so a broken signature fails the step even before tests exist. Keep it when adding tests.

## Contracts (what package agents may rely on)

Conventions: `arena: Allocator` = everything returned lives in it (free the arena, not the items);
`gpa: Allocator` = caller frees what the doc says; file I/O takes `io: std.Io`; C# `CancellationToken` =
`cancel: ?*const common.Cancel` (an `std.atomic.Value(bool)`, the same type as `kit.jobs.Job.cancel_flag`;
`try common.check(cancel)` -> `error.Canceled`); C# `IProgress<T>` = `?common.Progress(T)`
(`if (p) |x| x.report(v)`; `common.Count{ done, total }`); C# `FileInfo` = `common.FileInfo{ path, size, mtime }`;
C# `DateTime` used for dates = `common.DateTime` (civil, `nowLocal/nowUtc/dayOfWeek`).
OrdinalIgnoreCase = `common.eqlIgnoreCase` / `common.startsWithIgnoreCase` (Unicode-correct via
CompareStringOrdinal; use them for every path guard). Stub bodies return `error.NotImplemented` or
`@panic("not ported")`; you may change your own signatures, but then fix every caller in other packages by
asking the orchestrator (cross-package callers today: engine -> reg/special/securedelete, cleanpass ->
engine/browsers/securedelete/special/custom, custom -> rules, regcleaner -> reg/custom/elevated,
schedule -> cleanpass, main -> settings/cookies/schedule).

Done in the skeleton (full ports, tested):
- `settings.zig`: `Settings.load(gpa, io, dir)`, `deinit`, `get/getBool/getInt` (bool/int.TryParse semantics),
  `set(key, anytype)` (bool -> True/False), `getList(gpa, prefix)` (outer slice yours, strings borrowed until
  the next mutation), `setList(prefix, items)` (items may be borrowed from the same Settings), `save(io)`
  (atomic temp + rename, CRLF, UTF-8), `resolveDir(gpa, io, exe_dir)`, `file_name`.
- `custom.zig`: `rule_name`, `include_prefix`, `exclude_prefix`, `includeRule(arena, s)`, `excludes(arena, s)`,
  `registryExcludes(arena, s)`, `addExclude(gpa, io, s, entry)`, `reject(gpa, path) !?[]u8`. includeRule /
  excludes / registryExcludes call `rules.FileKey.parse` / `rules.ExcludeKey.parse` (MC-A): CustomTests are MC-A's.
- `cookies.zig`: `keep_prefix`, `keep_settings` (global hook set in main), `keep(gpa)`, `normalize(gpa, host)`,
  `isKept(host, list)`, `parse(gpa, text)` + `freeList`.
- `bytes.zig`: `fmt(u64)` formatter, `"{f}"` -> "1.5 KB".
- `reg.zig`: `split` (never an empty sub: a bare hive is error.InvalidPath), `open(path, writable) !?kit.win.Key`
  (64-bit view), `subKeys(gpa, path)`, `setBinary/setString/deleteValue/deleteKey(gpa, ...) !bool` (direct
  first, access denied -> elevated reg.exe), `tryOpen(key, writable, view) ?Key`, `keyExists`,
  `exists(RegKey)`, `delete(RegKey)` (a key directly under a hive is never deleted).
- `elevated.zig`: `isAdmin`, `relaunchAsAdmin`, `run(exe, args)` (through the swappable `runner`),
  `tryOr(direct_result, exe, args) !bool` (= Elevated.Try), and `elevated.Fake` (install/uninstall, records
  the last call) - every test that could reach UAC must install it.
- `common.zig`: the types above + test helpers `TempDir.create(gpa, io, tag)` (fresh
  `%TEMP%\makecleaner-test-<tag>-<random>`, `.join`, `.cleanup`) and `TestKey.create(gpa, io, tag)`
  (own top-level `HKCU\Software\MakeCleanerTest-<tag>-<random>`, `.sub`, `.full`, `.cleanup`), `refAll`.

Stub surface per package (see doc comments in each file for the C# member mirrored):
- MC-A `rules.zig`: FileKey/RegKey/ExcludeKey (+ parse), Rule (+ group, isDetected), parseIni, loadApplications,
  `paths.{expandVars, expandDirs, anyExists, matches, osInRange, specialDetect}`. `engine.zig`: CleanResult,
  built_in_rules, analyze, analyzeActions, runActions, analyzeRegistry, cleanRegistry, removeEmptyDirs, clean.
  `special.zig`: Pending, wipe_free_space, files, action, recycleBin, afterClean, brokenShortcuts.
  `cleanpass.zig`: ResultRow, BrowserRow, Saved, isWipe, windowsRules, appRules(exe_dir), saved(exe_dir),
  CleanPass{init, deinit, wipe, any, analyze, analyzeSummary, runningBrowsers, clean}.
- MC-B `browsers.zig`: BrowserKind, Browser{roots, profiles, localOf, running}, Action (Func<bool,int>),
  BrowserItem{key, preview, run}, known, replaced_winapp2_sections, isReplacedSection, closeGracefully, detect,
  chromiumProfiles, firefoxProfiles, items, CookieDb, cookieDbs, cookieDomains; `browsers.c` = sqlite C API.
- MC-C `regcleaner.zig`: RegIssue{target}, Hive{key, name}, RegCategory, RegScanner{forThisPc, scan},
  categories (15, in C# order), missingCommand, extractPath, missing, FixResult, ImportElevated, fix, apply,
  deletionScript, exists, defaultBackupName, writeBackup, openKey.
- MC-D `startup.zig`: StartupKind, StartupItem, blocked_key, services_key, prev_start_value, run_keys, folders(),
  shellex_types, isApproved, approvedBytes, readRun, readFolder, readContextMenu, readServices, readTasks,
  readWindows, setEnabled, serviceToggleArgs, isSystemService, delete. `uninstall.zig`: InstalledApp{code,
  canRepair, canChange, uninstallCommand, repairCommand, changeCommand}, roots, read, Command, splitCommand,
  launch, deleteEntry. `schedule.zig`: ScheduleKind, task_name, log_name, auto(gpa, io, settings, exe_dir,
  shutdown) u8 (main's /auto entry), taskXml, create, delete, describe. `restorepoints.zig`: RestorePoint,
  canRemove, list, parseCim, remove.
- MC-E `duplicates.zig`: DupOptions, DupResult, find, allButFirst, `scan.{files, splitPaths}` (shared with
  diskanalyzer). `diskanalyzer.zig`: other, categories, DiskReport{bytes, total}, categoryOf, analyze, toText.
  `securedelete.zig`: setting_key, wipe_dir_prefix, Method, methods, patterns, delete, overwrite, wipeFreeSpace
  (`limit_bytes` mandatory in tests). `drivewiper.zig`: systemRoot, checkErasable, isSystemDrive, wipeDir,
  format (never from tests), isSsd.

## Known gaps / decisions

- test-systools and test depend on the install step: ScheduleTests.Auto_cleans_saved_items runs the installed
  exe with `/auto` in a sandbox (portable.dat, only Temporary Files ticked, TEMP/TMP/APPDATA/LOCALAPPDATA = fixtures).

## Integration (2026-11-10)

- All steps green in the repo: test 173, base 22, rules 72, browsers 46, registry 31, systools 55, filetools 33.
  ReleaseSafe exe 4,082,176 bytes. GUI boot over the automation pipe (DISPLAY1) lists the rail; quit = exit 0.
  `/auto` sandbox run (ReleaseSafe): exit 0, fixture files removed, one log line appended per run.
- Shared helpers moved to common.zig: `trim` (.NET Trim, ASCII), `tempPath`; custom.reject uses rules_fs.fullPath.
- custom.reject also refuses a wildcard in the first segment under a drive (`C:\*`), beyond C#; engine keeps its
  own guard for the same pattern coming from a user winapp2.ini.

## Test and release tooling (MC-T)

- GUI smokes drive the exe over the MakeKit automation pipe (`..\MakeKit\tools\imgui-auto.ps1`), not UIA:
  `tools\guismoke.ps1`, `guismoke-{apps,browsers,cleaner,cookies,dupes,incexc,tools,wiper}.ps1`, `autosmoke.ps1`,
  `regsmoke.ps1`. Shared helpers in `tools\mc-auto.ps1` (no "smoke" in the name, so releasecheck does not run it).
  Each smoke copies `-BinDir` (default `zig-out\bin`) into `%TEMP%\makecleaner-test-<tag>-<rand>\app` with
  portable.dat, writes an ini with every Windows and Winapp2 rule off except its fixture ones, points
  TEMP/TMP/APPDATA/LOCALAPPDATA at sandbox fixtures, prints `SMOKE OK`. `-Screen N` = `MAKEKIT_DISPLAY=\\.\DISPLAYN`.
  Same scenarios/assertions as the legacy UIA scripts (git `HEAD~3:tools/`). screenpin.ps1 is gone (kit places windows).
- Tri-state groups: the automation item has no "mixed" flag, so guismoke-cleaner reads a group as Indeterminate
  when its box is unchecked while some of its items (Windows.ini `Section=`) are ticked.
- `tools\release.ps1`: version from `src\main.zig` (`pub const version`, aliasing `ui\ctx.zig`; build.zig.zon
  must agree) -> `zig build -Doptimize=ReleaseSafe -p dist\build` -> `dist\publish` (MakeCleaner.exe,
  rules\{Winapp2.ini,Windows.ini,README.md}, THIRD-PARTY-NOTICES.txt; any other file fails) -> portable zip with
  portable.dat -> ISCC -> `dist\MakeCleaner-Setup-<ver>.exe`. Older versions' zip/setup in dist\ are kept.
- `tools\releasecheck.ps1`: newest portable zip -> PE import table check (fails on ws2_32, wsock32, wininet,
  winhttp, urlmon, iphlpapi, *net*, dnsapi beyond DnsFlushResolverCache, any delay-load import), every smoke against
  that copy, TCP/UDP poll of MakeCleaner processes in the sandboxes, new entries in %AppData%/%LocalAppData%/HKCU\Software.
  Runtime LoadLibrary (dnsapi in special.zig, srclient in restorepoints.zig) is invisible to the import check.

## Open items (reviewed 2026-11-11)

Closed 2026-11-11:
- Error words: `/auto`'s `FAILED:` log line, the free-space-wipe note and every GUI status/dialog that showed a Zig
  error name (AccessDenied, FileBusy, ...) now show Windows' localized message (`kit.win.errText`, FormatMessageW);
  so do failed background jobs (`kit.jobs` records it, cut on a UTF-8 boundary; error buffers are 512 bytes).
- MakeCleaner.ini in UTF-16 LE with a BOM (Notepad "Unicode") is decoded like a user winapp2.ini already was
  (`common.readAllText`, shared by settings.zig and rules.loadApplications).
- MakeCleaner.exe has a VERSIONINFO resource (app.rc; numbers from build.zig.zon through build.zig `versionDefines`).
- Stale entries removed: UTF-16 user winapp2.ini (was already decoded), the MakeKit imgui `VERSION` include
  workaround (gone from build.zig), "GUI not ported".

Left deliberately (each needs a real environment, fixtures or a design decision; none is a reported bug):
- MC-A: no `\\?\` for paths > MAX_PATH when LongPathsEnabled = 0 (skipped, safe); FileKey pattern with a
  directory part unsupported; fs.list builds the whole tree before filtering (memory on huge trees); app list order
  is ASCII case-insensitive, not culture (display order only); networking / no-UI checks are source scans next to
  the import-table check; afterClean / real Recycle Bin untested.
- MC-B: closeGracefully positive path (a window closing) untested; jsonRemove/prefsRemove rewrite non-atomically
  (as C#); Firefox history DELETEs not in a transaction (as C#); ASCII-only Trim.
- MC-C: exists() on an unknown hive = true (safe); scan errors skipped instead of thrown; cancel granularity =
  one category; elevated import reads a .reg from %TEMP% (as C#).
- MC-D: Uninstall.launch, RestorePoints.remove, Task/Service setEnabled/delete not run by tests (as C#: they need a
  real install / admin); RestorePoints admin branch untested (non-elevated machine); file symlinks in Startup
  folders skipped.
- MC-E: WipeFreeSpace disk-full path, Format, mid-file hash cancel untested; isSsd only smoke-tested; hashing
  opens with full sharing (C# FileShare.Read would fail on a file open for writing).
- settings.zig: case-insensitive key hash is ASCII-only (correct, slower for Cyrillic keys); Bytes.fmt always prints
  "." (the GUI is English); cookie hosts are lowered ASCII-only (hosts are ASCII/punycode).
- `kit.win` registry helpers convert paths/names through a 512-byte buffer: key paths or value names longer than
  ~255 UTF-16 chars fail with error.OutOfMemory (safe direction: treated as missing / not deleted).

Notes: `/auto` goes to `schedule.auto` (as legacy Program.cs -> Schedule.Auto), which drives `cleanpass`.
