# MC-G1 GUI test (Zig/ImGui build): shell (rail, About), Cleaner and Registry pages, driven through the MakeKit
# automation pipe on \\.\DISPLAY<Screen>. Two runs, each on its own mc-auto sandbox (portable copy, fixture
# TEMP/APPDATA/LOCALAPPDATA, every Windows rule off except "Custom Files and Folders" -> fixture Junk folder):
#   1. a fake Edge profile, a fake "msedge.exe" (renamed ping.exe, killed by PID) and MuiCache fixture values in HKCU
#      that only this test creates and fixes. Real stale MuiCache entries are never selected ("Select none" first,
#      counter checked). Wipe warning, group tick, Files right-click exclude, running-browser dialog, Registry
#      review/fix, About, ticks persisted on WM_CLOSE.
#   2. modal dim, Registry cell tooltip, and closing the window during Run Cleaner (must exit at once, not wait for
#      the clean): secure delete 7 passes on 100 x 4 MB fixture files keeps the clean busy long enough.
# Never clicks Open containing folder / Open in RegEdit (they open windows / may elevate). Pure ASCII (PS 5.1).
#   powershell -ExecutionPolicy Bypass -File tools\g1-gui-test.ps1 [-BinDir zig-out\bin] [-ShotDir zig-out\shots]
param([int]$Screen = 1, [string]$BinDir = '', [string]$ShotDir = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
if (-not $BinDir) { $BinDir = Join-Path $root 'zig-out\bin' }
if (-not $ShotDir) { $ShotDir = Join-Path $root 'zig-out\shots' }
. (Join-Path $PSScriptRoot 'mc-auto.ps1')

$rnd = [guid]::NewGuid().ToString('N').Substring(0, 8)
$cats = @('Missing Shared DLLs', 'Unused File Extensions', 'ActiveX and Class Issues', 'Type Libraries', 'Applications', 'Fonts',
    'Application Paths', 'Help Files', 'Installer', 'Obsolete Software', 'Run At Startup', 'Start Menu Ordering', 'MUI Cache',
    'Sound Events', 'Windows Services')
$regIni = @($cats | ForEach-Object { "Reg:$_=" + ($_ -eq 'MUI Cache') })

# MuiCache fixtures: values naming exes that do not exist (= "Missing MUI reference")
$muiPath = 'Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache'
$mui = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($muiPath)
$fixDir = "C:\mc-g1-fixture-$rnd"
$fixNames = @('one', 'two', 'three') | ForEach-Object { "$fixDir\$_.exe.FriendlyAppName" }
$fixDir2 = "C:\mc-g1-fix-$rnd\a-rather-long-folder-name-that-overflows-the-data-column"
$fixNames2 = @('one', 'two') | ForEach-Object { "$fixDir2\$_.exe.FriendlyAppName" }
foreach ($n in $fixNames + $fixNames2) { $mui.SetValue($n, 'MakeCleaner G1 fixture') }

$sb = $null
$app = $null
$fakeEdge = $null
$shot = 'MC-G1'
function Shot($name) { Save-McShot $app (Join-Path $ShotDir "$shot-$name.png") }
function Item($label) { Wait-AutoItem $app $label 5000 }
function Items() { @(Get-AutoItems $app) }
function Gone($like) { if (@(Items | Where-Object { $_.label -like $like }).Count -gt 0) { throw "'$like' should be gone" } }
function Check($cond, $msg) { if (-not $cond) { throw "FAILED: $msg" }; Write-Host "ok: $msg" }
function Settle($ms) { $end = (Get-Date).AddMilliseconds($ms); while ((Get-Date) -lt $end) { $null = Invoke-AutoFrames $app 1; Start-Sleep -Milliseconds 50 } }
function Junk($rel) { $d = Join-Path $sb.Fx $rel; New-Item -ItemType Directory -Force $d | Out-Null; $d }

try {
    # ================ run 1
    $sb = New-McSandbox $BinDir 'g1'
    $junk = Junk 'Junk'
    $null = Junk 'Junk\sub'
    foreach ($f in @('a.tmp', 'b.tmp', 'keep.txt', 'sub\c.tmp')) { [IO.File]::WriteAllBytes((Join-Path $junk $f), (New-Object byte[] 1500)) }
    $edge = Join-Path $sb.Local 'Microsoft\Edge\User Data\Default'
    New-Item -ItemType Directory -Force (Join-Path $edge 'Cache\Cache_Data') | Out-Null
    Set-Content (Join-Path $edge 'Preferences') '{}' -Encoding Ascii
    [IO.File]::WriteAllBytes((Join-Path $edge 'Cache\Cache_Data\data_0'), (New-Object byte[] 4096))
    Set-McIni $sb -On 'Custom Files and Folders' -Extra (@("Include1=$junk|*.*|RECURSE") + $regIni)
    $app = Start-McApp $sb -Screen $Screen

    # ---------------- Cleaner
    $null = Wait-AutoLabel $app '*detected##status'
    Shot 'cleaner-start'
    # collapse the groups above Advanced so its items are on screen (automation clicks visible items only)
    foreach ($gname in @('Windows Explorer', 'System')) { Invoke-AutoClick $app "##wt:$gname" }
    $null = Invoke-AutoFrames $app 3
    $wipe = Item 'Wipe Free Space##wi:Wipe Free Space'
    Check (-not $wipe.checked) 'Wipe Free Space starts off'
    Invoke-AutoClick $app 'Wipe Free Space##wi:Wipe Free Space'
    $null = Item 'Turn on##msgButton0'
    Shot 'cleaner-warning'
    Invoke-AutoClick $app 'Cancel##msgButton1'
    $null = Invoke-AutoFrames $app 3
    Check (-not (Item 'Wipe Free Space##wi:Wipe Free Space').checked) 'warning Cancel leaves the box off'
    # group tick: Advanced has risky items -> ticks only safe ones; next click (all safe on) unticks all
    $custom = 'Custom Files and Folders##wi:Custom Files and Folders'
    Invoke-AutoClick $app $custom; $null = Invoke-AutoFrames $app 2
    Check (-not (Item $custom).checked) 'item click unticks'
    Invoke-AutoClick $app 'Advanced##wg:Advanced'; $null = Invoke-AutoFrames $app 2
    Check ((Item $custom).checked -and -not (Item 'Wipe Free Space##wi:Wipe Free Space').checked) 'group tick = safe items only'
    Invoke-AutoClick $app 'Advanced##wg:Advanced'; $null = Invoke-AutoFrames $app 2
    Check (-not (Item $custom).checked) 'second group click unticks all'
    Invoke-AutoClick $app $custom; $null = Invoke-AutoFrames $app 2
    Check ((Item $custom).checked) 'Custom Files and Folders ticked again'
    Shot 'cleaner-windows-ticks'
    Invoke-AutoClick $app 'Browsers##tabBrowsers'; $null = Invoke-AutoFrames $app 3
    $null = Item 'Microsoft Edge##bg:Microsoft Edge'
    Shot 'cleaner-browsers'
    Invoke-AutoClick $app 'Applications##tabApps'; $null = Invoke-AutoFrames $app 3
    Shot 'cleaner-apps'
    Invoke-AutoClick $app 'Windows##tabWindows'

    Invoke-AutoClick $app 'Analyze##analyze'
    $st = Wait-AutoLabel $app 'Analysis complete*##status' 60000
    Write-Host "status: $($st.label)"
    Check ((Item 'Run Cleaner##clean').disabled -eq $false) 'Run Cleaner enabled after a non-empty analysis'
    Shot 'cleaner-summary'
    Invoke-AutoClick $app 'Files##viewFiles'; $null = Invoke-AutoFrames $app 3
    $keep = Wait-AutoLabel $app '*keep.txt##l*'
    Invoke-AutoClick $app $keep.label -Kind rclick
    $null = Item 'Add file to Exclude'
    Shot 'cleaner-files-menu'
    Invoke-AutoClick $app 'Add file to Exclude'
    $null = Wait-AutoLabel $app 'Added to Exclude:*keep.txt*##status'
    Gone '*keep.txt##l*'

    # fake running Edge: a renamed ping.exe of our own (killed by PID below)
    $fakeExe = Join-Path $sb.Root 'msedge.exe'
    Copy-Item (Join-Path $env:WINDIR 'System32\PING.EXE') $fakeExe
    $fakeEdge = Start-Process -FilePath $fakeExe -ArgumentList '-n', '300', '127.0.0.1' -WindowStyle Hidden -PassThru
    Invoke-AutoClick $app 'Run Cleaner##clean'
    $null = Item 'Skip##msgButton1'
    Shot 'cleaner-browser-running'
    Invoke-AutoClick $app 'Cancel##msgButton2'; $null = Invoke-AutoFrames $app 3
    Check (Test-Path (Join-Path $junk 'a.tmp')) 'Cancel on the browser dialog cleans nothing'
    Invoke-AutoClick $app 'Run Cleaner##clean'
    $null = Item 'Skip##msgButton1'
    $real = @(Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $fakeEdge.Id })
    if ($real.Count -eq 0) {
        Invoke-AutoClick $app 'Close Microsoft Edge##msgButton0' # only our fake runs: it has no window, so it never closes
        $null = Wait-AutoLabel $app 'Closing Microsoft Edge*##status' 5000
        $null = Wait-AutoLabel $app '*did not close*##msgText' 20000
        Shot 'cleaner-not-closed'
        Invoke-AutoClick $app 'OK##msgButton0'
    } else {
        Write-Host 'real Edge is running: Skip instead of Close'
        Invoke-AutoClick $app 'Skip##msgButton1'
    }
    $st = Wait-AutoLabel $app 'Cleaning complete*##status' 60000
    Write-Host "status: $($st.label)"
    Shot 'cleaner-cleaned'
    Check ($st.label -like '*skipped because open: Microsoft Edge*') 'running Edge left out'
    Check (-not (Test-Path (Join-Path $junk 'a.tmp')) -and -not (Test-Path (Join-Path $junk 'sub\c.tmp'))) 'fixture junk removed'
    Check (Test-Path (Join-Path $junk 'keep.txt')) 'excluded file kept'
    Check (Test-Path (Join-Path $edge 'Cache\Cache_Data\data_0')) 'skipped browser kept its cache'
    Check ((Item 'Run Cleaner##clean').disabled) 'Run Cleaner disabled after cleaning'
    Stop-Process -Id $fakeEdge.Id -Force -ErrorAction SilentlyContinue; $fakeEdge = $null
    # untick the Edge group: must be persisted on close
    Invoke-AutoClick $app 'Browsers##tabBrowsers'; $null = Invoke-AutoFrames $app 3
    for ($k = 0; $k -lt 3 -and @(Items | Where-Object { $_.label -like '*##bi:Microsoft Edge: *' -and $_.checked }).Count -gt 0; $k++) {
        Invoke-AutoClick $app 'Microsoft Edge##bg:Microsoft Edge'; $null = Invoke-AutoFrames $app 2
    }
    Check (@(Items | Where-Object { $_.label -like '*##bi:Microsoft Edge: *' -and $_.checked }).Count -eq 0) 'Edge group unticked'

    # ---------------- About
    Invoke-AutoClick $app 'About##about'
    $null = Wait-AutoLabel $app "MakeCleaner $McVersion*##msgText" 5000
    Shot 'about'
    Invoke-AutoKey $app 'Enter'; $null = Invoke-AutoFrames $app 3
    Gone '*##msgText'

    # ---------------- Registry
    Invoke-AutoClick $app 'Registry'
    $null = Wait-AutoLabel $app 'Pick the categories*##regstatus' 5000
    Invoke-AutoClick $app 'All categories##regall'; $null = Invoke-AutoFrames $app 2
    Check ((Item 'All categories##regall').checked -and (Item 'Fonts##regcat:Fonts').checked) 'All categories from mixed -> all on'
    Invoke-AutoClick $app 'Scan for Issues##regscan'
    Invoke-AutoClick $app 'Cancel##regcancel'
    $st = Wait-AutoLabel $app 'Scan c*##regstatus' 120000
    Write-Host "scan + cancel: $($st.label)"
    Invoke-AutoClick $app 'All categories##regall'; $null = Invoke-AutoFrames $app 2
    Check (-not (Item 'MUI Cache##regcat:MUI Cache').checked) 'All categories from on -> all off'
    Invoke-AutoClick $app 'Scan for Issues##regscan'
    $null = Wait-AutoLabel $app 'Tick at least one category*##regstatus' 5000
    Invoke-AutoClick $app 'MUI Cache##regcat:MUI Cache'
    Shot 'registry-start'
    Invoke-AutoClick $app 'Scan for Issues##regscan'
    $st = Wait-AutoLabel $app 'Scan complete*##regstatus' 60000
    Write-Host "scan: $($st.label)"
    Shot 'registry-scanned'
    $fx3 = Wait-AutoLabel $app "##rc*:*mc-g1-fixture-$rnd\three.exe*"
    $row3 = '##row' + ($fx3.label -replace '^##rc(\d+):.*$', '$1')
    Invoke-AutoClick $app $row3 -Kind rclick
    $null = Item 'Add to Exclude list'
    Shot 'registry-menu'
    Invoke-AutoClick $app 'Add to Exclude list'
    $null = Wait-AutoLabel $app 'Excluded:*three.exe*##regstatus'
    Gone "##rc*:*three.exe*"
    $fx1 = Wait-AutoLabel $app "##rc*:*mc-g1-fixture-$rnd\one.exe*"
    Invoke-AutoClick $app ('##row' + ($fx1.label -replace '^##rc(\d+):.*$', '$1')) -Kind rclick
    Invoke-AutoClick $app 'Select none'; $null = Invoke-AutoFrames $app 2
    Check (@(Items | Where-Object { $_.label -like '##rc*' -and $_.checked }).Count -eq 0) 'Select none'
    foreach ($n in @('one', 'two')) { Invoke-AutoClick $app (Wait-AutoLabel $app "##rc*:*mc-g1-fixture-$rnd\$n.exe*").label }
    $null = Invoke-AutoFrames $app 2
    $ticked = @(Items | Where-Object { $_.label -like '##rc*' -and $_.checked })
    Check ($ticked.Count -eq 2 -and @($ticked | Where-Object { $_.label -notlike "*mc-g1-fixture-$rnd*" }).Count -eq 0) 'only the two fixtures ticked'
    Invoke-AutoClick $app 'Review selected Issues...##regfix'
    $null = Wait-AutoLabel $app 'Issue 1 of 2*##regcounter' 15000
    Check (@(Get-ChildItem (Join-Path $sb.App 'RegistryBackups') -Filter 'MakeCleaner_registry_*.reg').Count -eq 1) 'silent backup written'
    $null = Wait-AutoLabel $app "*mc-g1-fixture-$rnd*##regdetails"
    Shot 'registry-fix-dialog'
    Invoke-AutoClick $app '>>##regnext'
    $null = Wait-AutoLabel $app 'Issue 2 of 2*##regcounter' 3000
    Invoke-AutoClick $app 'Fix All Selected##regfixall'
    $null = Item 'Fix all##msgButton0'
    Shot 'registry-fix-confirm'
    Invoke-AutoKey $app 'Escape'; $null = Invoke-AutoFrames $app 3
    Gone 'Fix all##msgButton0'
    $det = Wait-AutoLabel $app "*mc-g1-fixture-$rnd*##regdetails"
    Check ($det.label -like '*Solution: delete the registry value.*') 'details show the solution'
    Invoke-AutoClick $app 'Fix Issue##regfixone'
    $null = Wait-AutoLabel $app 'Issue 1 of 2*##regcounter' 15000
    Check (@($mui.GetValueNames() | Where-Object { $_ -eq $fixNames[0] -or $_ -eq $fixNames[1] }).Count -eq 1) 'Fix Issue removed one fixture'
    Invoke-AutoClick $app 'Fix All Selected##regfixall'
    Invoke-AutoClick $app 'Fix all##msgButton0'
    $st = Wait-AutoLabel $app 'Fixed 2 issues*##regstatus' 15000
    Write-Host "fix: $($st.label)"
    Shot 'registry-fixed'
    Check (@($mui.GetValueNames() | Where-Object { $_ -eq $fixNames[0] -or $_ -eq $fixNames[1] }).Count -eq 0) 'Fix All removed the other fixture'
    Check (@($mui.GetValueNames() | Where-Object { $_ -eq $fixNames[2] }).Count -eq 1) 'excluded fixture untouched'
    Invoke-AutoClick $app 'Cleaner'; $null = Invoke-AutoFrames $app 3

    # ---------------- close = WM_CLOSE (saves the ticks); automation 'quit' would skip that
    Check ((Close-McApp $app) -eq 0) 'exit code 0'
    $saved = Get-Content $sb.Ini
    $saved | Where-Object { $_ -match '^(Microsoft Edge|Custom|Wipe|Reg:MUI|Exclude)' } | ForEach-Object { Write-Host "ini: $_" }
    Check ($saved -contains 'Microsoft Edge: Internet Cache=False') 'browser ticks persisted on close'
    Check ($saved -contains 'Custom Files and Folders=True') 'rule ticks persisted on close'
    Check (-not ($saved -contains 'Wipe Free Space=True')) 'wipe never saved as on'
    Check ($saved -contains 'Reg:MUI Cache=True' -and $saved -contains 'Reg:Fonts=False') 'registry categories persisted'
    Check (@($saved | Where-Object { $_ -like 'Exclude*=FILE|*keep.txt' }).Count -eq 1 -and @($saved | Where-Object { $_ -like "Exclude*=REG|*three.exe.FriendlyAppName" }).Count -eq 1) 'excludes saved'
    Remove-McSandbox $sb $app
    $sb = $null; $app = $null

    # ================ run 2: modal dim, Registry cell tooltip, close during Run Cleaner
    $shot = 'fix-MC-G1'
    $sb = New-McSandbox $BinDir 'g1fix'
    $junk = Junk 'Junk\a-long-folder-name-so-the-item-column-has-to-cut-it\and-one-more-level'
    $blob = New-Object byte[] (4MB)
    for ($i = 0; $i -lt 100; $i++) { [IO.File]::WriteAllBytes((Join-Path $junk ("junk{0:D3}.tmp" -f $i)), $blob) }
    Set-McIni $sb -On 'Custom Files and Folders' -Extra (@("Include1=$junk|*.*|RECURSE", 'SecureDeletePasses=7') + $regIni)
    $app = Start-McApp $sb -Screen $Screen
    $null = Wait-AutoLabel $app '*detected##status'
    Shot 'cleaner-empty'
    $r = @(Items | Where-Object { $_.label -eq 'Summary##viewSummary' })[0]
    Write-Host ("radio item: " + ($r | ConvertTo-Json -Compress))

    Invoke-AutoClick $app 'About##about'
    $null = Wait-AutoLabel $app "MakeCleaner $McVersion*##msgText" 5000
    Shot 'about-3frames'
    Settle 600
    Shot 'about-settled'
    Invoke-AutoKey $app 'Enter'; $null = Invoke-AutoFrames $app 3

    Invoke-AutoClick $app 'Registry'
    $null = Wait-AutoLabel $app 'Pick the categories*##regstatus' 5000
    Shot 'registry-empty'
    Invoke-AutoClick $app 'Scan for Issues##regscan'
    $null = Wait-AutoLabel $app 'Scan complete*##regstatus' 60000
    $fx1 = Wait-AutoLabel $app "##rc*:*mc-g1-fix-$rnd*one.exe*"
    Invoke-AutoClick $app ('##row' + ($fx1.label -replace '^##rc(\d+):.*$', '$1')) -Kind hover
    Settle 1200
    Check (@(Get-AutoItems $app -Windows | Where-Object { $_.name -like '*Tooltip*' }).Count -gt 0) 'cut-off Registry cell shows a tooltip'
    Shot 'registry-tooltip'

    Invoke-AutoClick $app 'Cleaner'; $null = Invoke-AutoFrames $app 3
    Invoke-AutoClick $app 'Analyze##analyze'
    $st = Wait-AutoLabel $app 'Analysis complete*##status' 60000
    Write-Host "status: $($st.label)"
    Invoke-AutoClick $app 'Files##viewFiles'; $null = Invoke-AutoFrames $app 3
    Shot 'cleaner-files'
    Invoke-AutoClick $app 'Run Cleaner##clean'
    $null = Wait-AutoLabel $app 'Cleaning...##status' 5000
    Start-Sleep -Milliseconds 800
    $left = @(Get-ChildItem $junk -File).Count
    Write-Host "files left when closing: $left of 100"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = $app.Process.CloseMainWindow()
    $exited = $app.Process.WaitForExit(5000)
    $sw.Stop()
    $after = @(Get-ChildItem $junk -File).Count
    Write-Host ("exit after {0} ms, exit code {1}, files left after exit: {2}" -f $sw.ElapsedMilliseconds, $(if ($exited) { $app.Process.ExitCode } else { '-' }), $after)
    Check $exited 'closing during Run Cleaner exits within 5 s'
    Check ($app.Process.ExitCode -eq 0) 'exit code 0'
    Check ($after -gt 0) 'the clean was still running when the process ended (files left)'
    Check ((Get-Content $sb.Ini) -contains 'Custom Files and Folders=True') 'ticks saved before the early exit'
    Write-Host 'G1 GUI TEST OK'
} catch {
    Write-Host "ERROR: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
    if ($app -and -not $app.Process.HasExited) { try { Shot 'error' } catch { } }
    throw
} finally {
    $ErrorActionPreference = 'Continue'
    if ($fakeEdge) { Stop-Process -Id $fakeEdge.Id -Force -ErrorAction SilentlyContinue }
    foreach ($n in $fixNames + $fixNames2) { try { $mui.DeleteValue($n, $false) } catch { } }
    $mui.Close()
    Remove-McSandbox $sb $app
}
