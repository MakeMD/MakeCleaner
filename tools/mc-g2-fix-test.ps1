# MC-G2 fix verification (pure ASCII): Tools + Options gaps of the MC-G2 review, in a sandbox.
#   zig build; powershell -ExecutionPolicy Bypass -File tools\mc-g2-fix-test.ps1  -> 'MC-G2 FIX OK' + zig-out\shots\fix-MC-G2-*.png
# Sandbox: mc-auto.ps1 (portable copy, every rule unticked, TEMP/APPDATA = fixture dirs, window on DISPLAY<Screen>).
# Destructive actions only touch fixtures created here:
#   - HKCU ...\Uninstall\MakeCleanerFixture-<rand> (its commands run marker.exe, a windowless exe built here)
#   - HKCU ...\Run value MakeCleanerFixture-<rand> (+ its StartupApproved value), pointing at a missing exe
#   - scheduled task "MakeCleaner Auto Clean" (Once, 2099) - skipped when the user already has one
#   - files under the sandbox
# Native file dialogs are answered with WM_SETTEXT + IDOK (no SendInput); they open on DISPLAY1 next to the app.
param([int]$Screen = 1, [string]$BinDir = (Join-Path $PSScriptRoot '..\zig-out\bin'), [string]$ShotDir = (Join-Path $PSScriptRoot '..\zig-out\shots'),
    [string]$Zig = "$env:LOCALAPPDATA\Programs\zig\0.17.1\zig.exe")
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot 'mc-auto.ps1')

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class McDlg {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, string l);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    static string Cls(IntPtr h) { var sb = new StringBuilder(64); GetClassName(h, sb, 64); return sb.ToString(); }
    // First visible top-level window of `pid` with class `cls`.
    public static IntPtr Top(uint pid, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h) && Cls(h) == cls) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    // "class:id" of every visible descendant (diagnostics).
    public static string Dump(IntPtr dlg) {
        var sb = new StringBuilder();
        EnumChildWindows(dlg, (h, l) => { if (IsWindowVisible(h)) sb.Append(Cls(h)).Append(':').Append(GetDlgCtrlID(h)).Append(' '); return true; }, IntPtr.Zero);
        return sb.ToString();
    }
    static IntPtr FirstEdit(IntPtr parent) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, (h, l) => { if (Cls(h) == "Edit") { found = h; return false; } return true; }, IntPtr.Zero);
        return found;
    }
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
    // Common Item Dialog: the file name box is control 1148 (open) / 1001 (save), the folder box 1152; a ComboBox(Ex32) or Edit
    // nested somewhere below the dialog (EnumChildWindows walks all descendants).
    public static bool Accept(IntPtr dlg, string text) {
        IntPtr box = IntPtr.Zero;
        foreach (int id in new[] { 1148, 1152, 1001 }) {
            EnumChildWindows(dlg, (h, l) => {
                string c = Cls(h);
                if (GetDlgCtrlID(h) == id && IsWindowVisible(h) && (c == "Edit" || c == "ComboBox" || c == "ComboBoxEx32")) { box = h; return false; }
                return true;
            }, IntPtr.Zero);
            if (box != IntPtr.Zero) break;
        }
        if (box == IntPtr.Zero) return false;
        IntPtr edit = Cls(box) == "Edit" ? box : FirstEdit(box);
        if (edit == IntPtr.Zero) return false;
        SendMessage(edit, 0x000C, IntPtr.Zero, text);           // WM_SETTEXT
        return PostMessage(dlg, 0x0111, (IntPtr)1, IntPtr.Zero); // WM_COMMAND IDOK
    }
}
'@

# schtasks exit code without tripping $ErrorActionPreference = Stop on its stderr
function TaskExists([string]$name) {
    $ErrorActionPreference = 'Continue'
    schtasks /query /tn $name 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
}

$tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
$sb = New-McSandbox $BinDir 'mcg2fix'
Set-McIni $sb
$root = $sb.Root

$fx = @{}
foreach ($d in 'dups', 'dups\sub', 'dups2', 'inc', 'disk', 'disk2', 'out') { $p = Join-Path $root $d; New-Item -ItemType Directory -Force $p | Out-Null; $fx[$d] = $p }
$big = 'x' * 50000
foreach ($f in 'dups\a.txt', 'dups\sub\a.txt', 'dups\b.log', 'dups\sub\b.log', 'dups2\a.txt', 'disk\one.txt', 'disk\two.jpg', 'disk\three.zip', 'disk2\four.txt', 'disk2\five.mp3') {
    [IO.File]::WriteAllText((Join-Path $root $f), $big)
    (Get-Item (Join-Path $root $f)).LastWriteTime = [datetime]'2026-01-02 03:04:05'
}
[IO.File]::WriteAllText((Join-Path $root 'cookies-in.txt'), "# fixture`r`nkeep.example.org`r`nHTTP://WWW.Foo.COM/path`r`nwww.Second.net`r`n")
# windowless marker.exe <file>: creates <file> (the fixture uninstaller / modify command)
$markerC = Join-Path $root 'marker.c'
$marker = Join-Path $root 'marker.exe'
[IO.File]::WriteAllText($markerC, @'
#include <windows.h>
#include <stdlib.h>
int WINAPI WinMain(HINSTANCE a, HINSTANCE b, LPSTR c, int d) {
    if (__argc < 2) return 1;
    HANDLE h = CreateFileA(__argv[1], GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) return 2;
    CloseHandle(h);
    return 0;
}
'@)
$ErrorActionPreference = 'Continue'
& $Zig cc -O2 '-Wl,--subsystem,windows' -o $marker $markerC 2>&1 | Out-Null
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $marker)) { throw 'marker.exe was not built' }

# registry fixtures (HKCU only)
$fxName = "MakeCleanerFixture-$tag"
$uninstKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$fxName"
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$approvedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$runMarker = Join-Path $root 'out\run.marker'
$modMarker = Join-Path $root 'out\modify.marker'
$schedName = 'MakeCleaner Auto Clean'
$schedPreexisting = TaskExists $schedName
$app = $null
$appPid = [uint32]0
function Shot([string]$name) { Save-McShot $app (Join-Path $ShotDir "$name.png") }
function Click([string]$l) { Invoke-AutoClick $app $l }
function Items { @(Get-AutoItems $app) }
function Item([string]$suffix) { $i = @(Items | Where-Object { $_.label.EndsWith($suffix) }); if ($i.Count -ne 1) { throw "expected one item ending '$suffix', got $($i.Count)" }; $i[0] }
function WaitText([string]$suffix, [string]$pattern, [int]$ms = 10000) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ($true) {
        $it = @(Items | Where-Object { $_.label.EndsWith($suffix) })
        if ($it.Count -gt 0 -and $it[0].label -match $pattern) { return $it[0].label }
        if ((Get-Date) -gt $deadline) { throw "timeout: $suffix !~ $pattern (got: $(if ($it.Count) { $it[0].label } else { 'none' }))" }
        $null = Invoke-AutoFrames $app 2
        Start-Sleep -Milliseconds 100
    }
}
function WaitFile([string]$path, [int]$ms = 10000) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while (-not (Test-Path $path)) { if ((Get-Date) -gt $deadline) { throw "timeout waiting for $path" }; Start-Sleep -Milliseconds 100 }
}
function Check([bool]$cond, [string]$what) { if (-not $cond) { throw "CHECK FAILED: $what" }; Write-Host "ok  $what" }
# Clicks a button that opens a native file dialog, then answers it with `text` + OK.
# The click reply comes only after the dialog closed (IFileDialog::Show blocks the UI thread), so it is read last.
function DialogOk([string]$button, [string]$text) {
    $app.Writer.WriteLine("click $button")
    $reply = $app.Reader.ReadLineAsync()
    $deadline = (Get-Date).AddSeconds(10)
    while (($h = [McDlg]::Top($appPid, '#32770')) -eq [IntPtr]::Zero) {
        if ((Get-Date) -gt $deadline) { throw "no file dialog after $button" }
        Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Milliseconds 400
    $accepted = [McDlg]::Accept($h, $text)
    if (-not $accepted) { Write-Host "dialog controls: $([McDlg]::Dump($h))"; $null = [McDlg]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) } # WM_CLOSE
    Check $accepted "file dialog of $button answered with $text"
    # a folder picker first navigates into a typed folder; the next OK selects it
    $deadline = (Get-Date).AddSeconds(10)
    $nextOk = (Get-Date).AddMilliseconds(1500)
    while (($h2 = [McDlg]::Top($appPid, '#32770')) -ne [IntPtr]::Zero) {
        if ((Get-Date) -gt $deadline) { throw "file dialog of $button did not close" }
        if ((Get-Date) -gt $nextOk) { $null = [McDlg]::PostMessage($h2, 0x0111, [IntPtr]1, [IntPtr]::Zero); $nextOk = (Get-Date).AddMilliseconds(1500) }
        Start-Sleep -Milliseconds 100
    }
    if (-not $reply.Wait(10000)) { throw "no automation reply after the dialog of $button" }
    if (-not ($reply.Result | ConvertFrom-Json).ok) { throw "click $button failed: $($reply.Result)" }
    $null = Invoke-AutoFrames $app 3
}
# Moves/resizes the app window without activating it (stays on DISPLAY1: x < 0).
function Place([int]$x, [int]$y, [int]$w, [int]$h) {
    $null = [McDlg]::SetWindowPos($app.Process.MainWindowHandle, [IntPtr]::Zero, $x, $y, $w, $h, 0x0014) # NOZORDER|NOACTIVATE
    $null = Invoke-AutoFrames $app 4
}
function CrlfLines([string]$path) {
    $raw = [IO.File]::ReadAllText($path)
    Check ($raw.EndsWith("`r`n") -and -not ($raw -replace "`r`n", '').Contains("`n")) "$([IO.Path]::GetFileName($path)) is CRLF-terminated"
    $raw -split "`r`n"
}

$ok = $false
try {
    New-Item -Force $uninstKey | Out-Null
    Set-ItemProperty $uninstKey DisplayName "$fxName test program"
    Set-ItemProperty $uninstKey Publisher 'Fixture Publisher With A Name Too Long For The Publisher Column'
    Set-ItemProperty $uninstKey DisplayVersion '1.2.3'
    Set-ItemProperty $uninstKey InstallDate '20260102'
    New-ItemProperty $uninstKey EstimatedSize -Value 2048 -PropertyType DWord -Force | Out-Null
    Set-ItemProperty $uninstKey UninstallString "`"$marker`" `"$runMarker`""
    Set-ItemProperty $uninstKey ModifyPath "`"$marker`" `"$modMarker`""
    New-ItemProperty $runKey $fxName -Value "`"$root\missing-fixture.exe`" --fixture" -PropertyType String -Force | Out-Null
    $app = Start-McApp $sb -Screen $Screen
    $appPid = [uint32]$app.Process.Id
    Write-Host "pid $appPid sandbox $root"

    Click 'Tools'
    # ---- Uninstall: GridView table (scroll, resize, tooltip, cells as items) + fixture Run/Repair/Change/Delete entry
    $null = WaitText '##uninstallCount' '^\d+ programs##' 15000
    Shot 'fix-MC-G2-uninstall-table'
    Set-McText $app '##uninstallSearch' $fxName
    $null = WaitText '##uninstallCount' '^1 programs##'
    $row = @(Items | Where-Object { $_.label -like "$fxName test program##u*" -and $_.label -match '##u\d+$' })
    Check ($row.Count -eq 1) 'fixture program row'
    $u = ($row[0].label -replace '^.*##u', '')
    Check ((Item "##u${u}p").label -like 'Fixture Publisher With A Name*') 'Publisher cell is an item'
    Check ((Item "##u${u}v").label -eq "1.2.3##u${u}v") 'Version cell is an item'
    Check ((Item "##u${u}s").label -eq "2 MB##u${u}s") 'Size cell is an item'
    Click $row[0].label
    Invoke-AutoClick $app "##u${u}p" -Kind hover
    Start-Sleep -Milliseconds 600
    $null = Invoke-AutoFrames $app 4
    Shot 'fix-MC-G2-uninstall-tooltip'
    $out1 = Join-Path $fx['out'] 'programs.txt'
    DialogOk 'Save to text file##uninstallSave' $out1
    WaitFile $out1
    $lines = CrlfLines $out1
    Check ($lines[0] -eq "Program`tPublisher`tInstalled On`tSize`tVersion" -and $lines[1] -like "$fxName test program`tFixture Publisher*`t2 MB`t1.2.3") 'programs.txt content'
    Click 'Run Uninstaller##uninstallRun'
    WaitFile $runMarker
    Check $true 'Run Uninstaller launched the fixture command'
    Click 'Repair##uninstallRepair'
    WaitFile $modMarker
    Remove-Item $modMarker
    Click 'Change##uninstallChange'
    WaitFile $modMarker
    Check $true 'Repair and Change launched ModifyPath'
    Click 'Delete entry##uninstallDelete'
    $null = Wait-AutoItem $app 'Cancel' 3000
    Shot 'fix-MC-G2-uninstall-delete-confirm'
    Click 'Delete entry'
    $null = WaitText '##uninstallCount' '^0 programs##'
    Check (-not (Test-Path $uninstKey)) 'Delete entry removed the fixture key'
    Set-McText $app '##uninstallSearch' ''

    # ---- Startup: tabs fill as they are read; fixture Run value Disable / Enable / Delete
    Click 'Startup##toolsNav1'
    $early = $false
    for ($i = 0; $i -lt 40; $i++) {
        $it = Items
        $hasRows = @($it | Where-Object { $_.label -match '##st0_\d+$' }).Count -gt 0
        $tasksLoading = @($it | Where-Object { $_.label -eq 'Loading...##startupTasksLoading' }).Count -gt 0
        if ($hasRows -and $tasksLoading) { $early = $true }
        if ($hasRows) { break }
        Start-Sleep -Milliseconds 30
    }
    Write-Host "Windows rows shown while later tabs were still loading: $early"
    $null = Wait-AutoItem $app '##st0_0' 20000
    $deadline = (Get-Date).AddSeconds(30)
    while ((Item 'Refresh##startupRefresh').disabled) { if ((Get-Date) -gt $deadline) { throw 'startup load did not finish' }; $null = Invoke-AutoFrames $app 2; Start-Sleep -Milliseconds 100 }
    $fr = @(Items | Where-Object { $_.label -like "$fxName##st0_*" -and $_.label -match '##st0_\d+$' })
    Check ($fr.Count -eq 1) 'fixture Run row'
    $r = ($fr[0].label -replace '^.*##st0_', '')
    Check ((Item "##st0_${r}en").label -eq "Yes##st0_${r}en") 'Enabled cell = Yes'
    Check ((Item "##st0_${r}loc").label -like 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run##*') 'Location cell is an item'
    Invoke-AutoClick $app "##st0_${r}loc" -Kind hover
    Start-Sleep -Milliseconds 600
    $null = Invoke-AutoFrames $app 4
    Shot 'fix-MC-G2-startup-tooltip'
    Check ((Item "##st0_${r}cmd").label -like "*missing-fixture.exe*") 'Command cell is an item'
    Click $fr[0].label
    Click 'Disable##startupDisable'
    $deadline = (Get-Date).AddSeconds(20)
    while ($true) {
        $fr = @(Items | Where-Object { $_.label -like "$fxName##st0_*" -and $_.label -match '##st0_\d+$' })
        if ($fr.Count -eq 1) { $r = ($fr[0].label -replace '^.*##st0_', ''); $en = @(Items | Where-Object { $_.label -eq "No##st0_${r}en" }); if ($en.Count) { break } }
        if ((Get-Date) -gt $deadline) { throw 'fixture not disabled' }
        $null = Invoke-AutoFrames $app 2; Start-Sleep -Milliseconds 100
    }
    $ap = (Get-ItemProperty $approvedKey -Name $fxName).$fxName
    Check ($ap[0] -eq 3) 'Disable wrote StartupApproved byte 3'
    Shot 'fix-MC-G2-startup-disabled'
    Click $fr[0].label
    Click 'Enable##startupEnable'
    $deadline = (Get-Date).AddSeconds(20)
    while ($true) {
        $fr = @(Items | Where-Object { $_.label -like "$fxName##st0_*" -and $_.label -match '##st0_\d+$' })
        if ($fr.Count -eq 1) { $r = ($fr[0].label -replace '^.*##st0_', ''); $en = @(Items | Where-Object { $_.label -eq "Yes##st0_${r}en" }); if ($en.Count) { break } }
        if ((Get-Date) -gt $deadline) { throw 'fixture not enabled' }
        $null = Invoke-AutoFrames $app 2; Start-Sleep -Milliseconds 100
    }
    $ap = (Get-ItemProperty $approvedKey -Name $fxName).$fxName
    Check ($ap[0] -eq 2) 'Enable wrote StartupApproved byte 2'
    Click $fr[0].label
    Click 'Delete##startupDelete'
    $null = Wait-AutoItem $app 'Cancel' 3000
    Click 'Delete'
    $deadline = (Get-Date).AddSeconds(20)
    while (@(Items | Where-Object { $_.label -like "$fxName##st0_*" }).Count -gt 0) {
        if ((Get-Date) -gt $deadline) { throw 'fixture row not deleted' }
        $null = Invoke-AutoFrames $app 2; Start-Sleep -Milliseconds 100
    }
    Check ($null -eq (Get-ItemProperty $runKey -Name $fxName -ErrorAction SilentlyContinue)) 'Delete removed the Run value'
    Check ($null -eq (Get-ItemProperty $approvedKey -Name $fxName -ErrorAction SilentlyContinue)) 'Delete removed the StartupApproved value'

    # ---- Duplicate Finder: Browse appends "; folder"; group headers + checkboxes readable; delete on the job
    Click 'Duplicate Finder##toolsNav2'
    $null = Wait-AutoItem $app '##dupInclude' 3000
    Set-McText $app '##dupInclude' $fx['dups']
    Set-McText $app '##dupExclude' ''
    DialogOk 'Browse...##dupIncludeBrowse' $fx['dups2']
    Click 'Search##dupSearch'
    $st = WaitText '##dupStatus' '^Found ' 15000
    Write-Host "dup: $st"
    Check ($st -like 'Found 2 duplicate groups, 5 files*') 'Browse appended dups2 (a.txt group has 3 files)'
    $g = @(Items | Where-Object { $_.label -match '##dupGroup\d+$' })
    Check ($g.Count -eq 2 -and $g[0].label -like '#1: 3 x 48.83 KB##dupGroup0') "group headers are items ($($g[0].label))"
    $chk = @(Items | Where-Object { $_.label -match '##dupChk\d+$' })
    Check ($chk.Count -eq 5 -and $chk[0].label.StartsWith('##' + $root)) "checkboxes carry the file path ($($chk[0].label))"
    $cells = @(Items | Where-Object { $_.label -match '##dupRow\d+f$' })
    Check ($cells.Count -eq 5) 'Folder cells are items'
    Click 'Select all but first##dupSelect'
    $null = Invoke-AutoFrames $app 2
    Check (@(Items | Where-Object { $_.label -match '##dupChk\d+$' -and $_.checked }).Count -eq 3) 'three boxes ticked'
    Shot 'fix-MC-G2-dup-results'
    Click 'Delete Selected##dupDelete'
    $null = Wait-AutoItem $app 'Cancel' 3000
    Click 'Delete'
    $st = WaitText '##dupStatus' '^Deleted '
    Check ($st -like 'Deleted 3 files*') "dup delete on the job ($st)"
    Check (@(Get-ChildItem $fx['dups'], $fx['dups2'] -Recurse -File).Count -eq 2) 'two fixture files remain'
    Check (@(Items | Where-Object { $_.label -match '##dupChk\d+$' }).Count -eq 2 -and @(Items | Where-Object { $_.label -match '##dupGroup\d+$' }).Count -eq 2) 'deleted rows left, headers with a file stay'
    Click 'Back##dupBack'

    # ---- Disk Analyzer: Browse appends, categories readable, delete on the job, Save Report OK path
    Click 'Disk Analyzer##toolsNav3'
    $null = Wait-AutoItem $app '##daRoots' 3000
    Set-McText $app '##daRoots' $fx['disk']
    DialogOk 'Browse...##daBrowse' $fx['disk2']
    Click 'Analyze##daScan'
    $st = WaitText '##daStatus' '^Analysis complete' 15000
    Check ($st -like 'Analysis complete: 5 files*') "Browse appended disk2 ($st)"
    $cat = (Item '##daCat0').label
    Write-Host "category 0: $cat"
    Check ($cat -match '^Pictures  48\.83 KB  1 files .+ 20%###daCat0$') 'category size / count / percent readable'
    Click '##daCat0'
    $null = Wait-AutoItem $app 'two.jpg##daFile0' 3000
    Check ((Item '##daFile0f').label -eq "$($fx['disk'])##daFile0f") 'Folder cell is an item'
    Click 'two.jpg##daFile0'
    Shot 'fix-MC-G2-disk'
    Click 'Delete Selected##daDelete'
    $null = Wait-AutoItem $app 'Cancel' 3000
    Click 'Delete'
    $st = WaitText '##daStatus' '^Deleted '
    Check ($st -like 'Deleted 1 files*') "disk delete on the job ($st)"
    Check ((Item '##daCat0').label -match '^Pictures  .+  0 files') "category refreshed ($((Item '##daCat0').label))"
    $rep = Join-Path $fx['out'] 'disk report.txt'
    DialogOk 'Save Report...##daSave' $rep
    WaitFile $rep
    $null = CrlfLines $rep

    # ---- Options > Include / Exclude: Browse OK path fills the box (replace, not append)
    Click 'Options'
    Click 'Include##optionsNav1'
    DialogOk 'Browse...##incPathBrowse' $fx['inc']
    Click 'Add##incAdd'
    $null = WaitText '##incStatus' '^Added\. Tick'
    Check ((Wait-AutoItem $app '##inc0' 3000).label -like "$($fx['inc'])|*##inc0") 'Include Browse -> Add'
    Click '##inc0'; Click 'Remove##incRemove'
    Click 'Exclude##optionsNav2'
    DialogOk 'Browse...##excPathBrowse' $fx['dups2'] # not the folder the picker reopens in (typing that one does not close it)
    Click 'Add##excAdd'
    Check ((Wait-AutoItem $app '##exc0' 3000).label -eq "PATH|$($fx['dups2'])##exc0") 'Exclude Browse -> Add'
    Click '##exc0'; Click 'Remove##excRemove'

    # ---- Cookies: status after Keep / Remove, junk rejected, Import / Export OK path
    Click 'Cookies##optionsNav3'
    $st = WaitText '##cookieStatus' 'domains with cookies' 20000
    $nFound = [int]($st -replace ' domains.*', '')
    Set-McText $app '##cookieDomain' 'HTTP://WWW.Foo.COM/path'
    Click 'Add##cookieAdd'
    $null = WaitText '##cookieStatus' '^Enter a domain like'
    Set-McText $app '##cookieDomain' '*.baz.net'
    Click 'Add##cookieAdd'
    $null = WaitText '##cookieStatus' '^Enter a domain like'
    DialogOk 'Import...##cookieImport' (Join-Path $root 'cookies-in.txt')
    $st = WaitText '##cookieStatus' '^Imported '
    Check ($st -like 'Imported 2 domains, 1 invalid lines skipped.##*') "import skips junk ($st)"
    Check (@(Items | Where-Object { $_.label -match '##ck\d+$' }).Count -eq 2) 'two kept domains'
    Click '##ck0'
    Click '< Remove##cookieRemove'
    $st = WaitText '##cookieStatus' 'domains with cookies'
    Check ($st -like "$nFound domains with cookies, 1 kept##*") "status current after Remove ($st)"
    $exp = Join-Path $fx['out'] 'cookies-out.txt'
    DialogOk 'Export...##cookieExport' $exp
    $null = WaitText '##cookieStatus' '^Exported 1 domains\.'
    $lines = CrlfLines $exp
    Check ($lines[0] -eq 'second.net') "export content ($($lines[0]))"
    Shot 'fix-MC-G2-cookies'

    # ---- Schedule: create / remove on the job
    Click 'Schedule##optionsNav4'
    $null = WaitText '##schedStatus' '(Scheduled cleaning|No scheduled)' 10000
    if ($schedPreexisting) {
        Write-Host 'skip: the user has a scheduled task of the same name'
    } else {
        Click '##schedKind'; Click '##schedKind0'
        Set-McText $app '##schedAt' '2099-01-01 12:00'
        Click 'Create task##schedCreate'
        $st = WaitText '##schedStatus' '^Scheduled cleaning is on' 15000
        Check ($st -like 'Scheduled cleaning is on. Next run: 2099-01-01 12:00##*') "task created ($st)"
        Shot 'fix-MC-G2-schedule'
        Click 'Remove task##schedRemove'
        $null = WaitText '##schedStatus' '^No scheduled cleaning\.' 15000
        Check (-not (TaskExists $schedName)) 'task removed'
    }

    # ---- small window: Options pages scroll (host child), list boxes shrink
    $rc = New-Object McDlg+RECT
    $null = [McDlg]::GetWindowRect($app.Process.MainWindowHandle, [ref]$rc)
    Place $rc.Left $rc.Top 760 430
    Click 'Include##optionsNav1'
    $null = Invoke-AutoFrames $app 4
    Shot 'fix-MC-G2-options-small-include'
    Click 'Cookies##optionsNav3'
    $null = Invoke-AutoFrames $app 4
    # clipped items carry no label (ImGui skips ItemInfo when ItemAdd clips): count them instead
    Write-Host "at the minimum window size: cookieStatus shown=$(@(Items | Where-Object { $_.label -like '*##cookieStatus' }).Count), Export shown=$(@(Items | Where-Object { $_.label -eq 'Export...##cookieExport' }).Count)"
    Shot 'fix-MC-G2-options-small-cookies'
    Place $rc.Left $rc.Top ($rc.Right - $rc.Left) ($rc.Bottom - $rc.Top)
    $ok = $true
} finally {
    # fixtures (Remove-McSandbox below also stops the app if it still runs)
    if (Test-Path $uninstKey) { Remove-Item -Recurse -Force $uninstKey }
    Remove-ItemProperty $runKey -Name $fxName -ErrorAction SilentlyContinue
    Remove-ItemProperty $approvedKey -Name $fxName -ErrorAction SilentlyContinue
    if (-not $schedPreexisting -and (TaskExists $schedName)) { $ErrorActionPreference = 'Continue'; schtasks /delete /tn $schedName /f 2>&1 | Out-Null }
    Remove-McSandbox $sb $app
    Write-Host "sandbox and fixtures removed"
}
if ($ok) { Write-Host 'MC-G2 FIX OK' } else { Write-Host 'MC-G2 FIX FAILED'; exit 1 }
