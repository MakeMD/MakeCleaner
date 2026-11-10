# MC-G1 GUI test (Zig/ImGui build): shell (rail, About), Cleaner and Registry pages, driven through the MakeKit
# automation pipe on \\.\DISPLAY1. Sandbox: a copy of zig-out\bin with portable.dat, fixture TEMP/APPDATA/LOCALAPPDATA,
# an ini where every Windows rule is off except "Custom Files and Folders" (-> fixture Junk folder), a fake Edge
# profile, a fake "msedge.exe" (renamed ping.exe, killed by PID) and MuiCache fixture values in HKCU that only this
# test creates and fixes. Real stale MuiCache entries are never selected ("Select none" first, counter checked).
# Never clicks Open containing folder / Open in RegEdit (they open windows / may elevate). Pure ASCII (PS 5.1).
#   powershell -ExecutionPolicy Bypass -File tools\g1-gui-test.ps1 [-Bin zig-out\bin] [-Shots zig-out\shots]
param([string]$Bin = '', [string]$Shots = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
if (-not $Bin) { $Bin = Join-Path $root 'zig-out\bin' }
if (-not $Shots) { $Shots = Join-Path $root 'zig-out\shots' }
. (Join-Path $root '..\MakeKit\tools\imgui-auto.ps1')
New-Item -ItemType Directory -Force $Shots | Out-Null

$rnd = [guid]::NewGuid().ToString('N').Substring(0, 8)
$T = Join-Path ([IO.Path]::GetTempPath()) "makecleaner-test-g1-$rnd"
$appDir = Join-Path $T 'app'
$fx = Join-Path $T 'fx'
$junk = Join-Path $fx 'Junk'
$local = Join-Path $fx 'Local'
$roaming = Join-Path $fx 'Roaming'
$temp = Join-Path $fx 'Temp'
foreach ($d in @($appDir, $junk, (Join-Path $junk 'sub'), $local, $roaming, $temp)) { New-Item -ItemType Directory -Force $d | Out-Null }
Copy-Item -Recurse -Force (Join-Path $Bin '*') $appDir
Set-Content (Join-Path $appDir 'portable.dat') '#PORTABLE#' -Encoding Ascii
foreach ($f in @('a.tmp', 'b.tmp', 'keep.txt', 'sub\c.tmp')) { [IO.File]::WriteAllBytes((Join-Path $junk $f), (New-Object byte[] 1500)) }
$edge = Join-Path $local 'Microsoft\Edge\User Data\Default'
New-Item -ItemType Directory -Force (Join-Path $edge 'Cache\Cache_Data') | Out-Null
Set-Content (Join-Path $edge 'Preferences') '{}' -Encoding Ascii
[IO.File]::WriteAllBytes((Join-Path $edge 'Cache\Cache_Data\data_0'), (New-Object byte[] 4096))

$cats = @('Missing Shared DLLs', 'Unused File Extensions', 'ActiveX and Class Issues', 'Type Libraries', 'Applications', 'Fonts',
    'Application Paths', 'Help Files', 'Installer', 'Obsolete Software', 'Run At Startup', 'Start Menu Ordering', 'MUI Cache',
    'Sound Events', 'Windows Services')
$names = Select-String -Path (Join-Path $root 'rules\Windows.ini') -Pattern '^\[(.+)\]$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
$ini = @('[Options]') + ($names | ForEach-Object { "$_=False" }) + @('Custom Files and Folders=True', "Include1=$junk|*.*|RECURSE") +
    ($cats | ForEach-Object { "Reg:$_=" + ($_ -eq 'MUI Cache') })
Set-Content (Join-Path $appDir 'MakeCleaner.ini') $ini -Encoding UTF8

# MuiCache fixtures: values naming exes that do not exist (= "Missing MUI reference")
$muiPath = 'Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache'
$mui = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($muiPath)
$fixDir = "C:\mc-g1-fixture-$rnd"
$fixNames = @('one', 'two', 'three') | ForEach-Object { "$fixDir\$_.exe.FriendlyAppName" }
foreach ($n in $fixNames) { $mui.SetValue($n, 'MakeCleaner G1 fixture') }

$fakeEdge = $null
$app = $null
function Shot($name) { $null = Save-AutoScreenshot $app (Join-Path $Shots "MC-G1-$name.bmp"); Write-Host "shot: MC-G1-$name" }
function Item($label) { Wait-AutoItem $app $label 5000 }
function Items() { @(Get-AutoItems $app) }
function WaitLabel($like, $ms = 30000) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) {
        $hit = @(Items | Where-Object { $_.label -like $like })
        if ($hit.Count -gt 0) { return $hit[0] }
        $null = Invoke-AutoFrames $app 2
        Start-Sleep -Milliseconds 100
    }
    throw "timeout waiting for '$like'"
}
function Gone($like) { if (@(Items | Where-Object { $_.label -like $like }).Count -gt 0) { throw "'$like' should be gone" } }
function Check($cond, $msg) { if (-not $cond) { throw "FAILED: $msg" }; Write-Host "ok: $msg" }

$envs = @{ TEMP = $temp; TMP = $temp; APPDATA = $roaming; LOCALAPPDATA = $local }
try {
    $app = Start-AutoApp -Exe (Join-Path $appDir 'MakeCleaner.exe') -Env $envs
    # ---------------- Cleaner
    $null = WaitLabel '*applications detected##status'
    Shot 'cleaner-start'
    # collapse the groups above Advanced so its items are on screen (automation clicks visible items only)
    foreach ($gname in @('Windows Explorer', 'System')) { Invoke-AutoClick $app "##wt:$gname" }
    $null = Invoke-AutoFrames $app 3
    $wipe = Item 'Wipe Free Space##wi:Wipe Free Space'
    Check (-not $wipe.checked) 'Wipe Free Space starts off'
    Invoke-AutoClick $app 'Wipe Free Space##wi:Wipe Free Space'
    $null = Item 'Turn on##dialogButton0'
    Shot 'cleaner-warning'
    Invoke-AutoClick $app 'Cancel##dialogButton1'
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
    $st = WaitLabel 'Analysis complete*##status' 60000
    Write-Host "status: $($st.label)"
    Check ((Item 'Run Cleaner##clean').disabled -eq $false) 'Run Cleaner enabled after a non-empty analysis'
    Shot 'cleaner-summary'
    Invoke-AutoClick $app 'Files##viewFiles'; $null = Invoke-AutoFrames $app 3
    $keep = WaitLabel '*keep.txt##l*'
    Invoke-AutoClick $app $keep.label -Kind rclick
    $null = Item 'Add file to Exclude'
    Shot 'cleaner-files-menu'
    Invoke-AutoClick $app 'Add file to Exclude'
    $null = WaitLabel 'Added to Exclude:*keep.txt*##status'
    Gone '*keep.txt##l*'

    # fake running Edge: a renamed ping.exe of our own (killed by PID below)
    $fakeExe = Join-Path $T 'msedge.exe'
    Copy-Item (Join-Path $env:WINDIR 'System32\PING.EXE') $fakeExe
    $fakeEdge = Start-Process -FilePath $fakeExe -ArgumentList '-n', '300', '127.0.0.1' -WindowStyle Hidden -PassThru
    Invoke-AutoClick $app 'Run Cleaner##clean'
    $null = Item 'Skip##dialogButton1'
    Shot 'cleaner-browser-running'
    Invoke-AutoClick $app 'Cancel##dialogButton2'; $null = Invoke-AutoFrames $app 3
    Check (Test-Path (Join-Path $junk 'a.tmp')) 'Cancel on the browser dialog cleans nothing'
    Invoke-AutoClick $app 'Run Cleaner##clean'
    $null = Item 'Skip##dialogButton1'
    $real = @(Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $fakeEdge.Id })
    if ($real.Count -eq 0) {
        Invoke-AutoClick $app 'Close Microsoft Edge##dialogButton0' # only our fake runs: it has no window, so it never closes
        $null = WaitLabel 'Closing Microsoft Edge*##status' 5000
        $null = WaitLabel '*did not close*##dialogText' 20000
        Shot 'cleaner-not-closed'
        Invoke-AutoClick $app 'OK##dialogButton0'
    } else {
        Write-Host 'real Edge is running: Skip instead of Close'
        Invoke-AutoClick $app 'Skip##dialogButton1'
    }
    $st = WaitLabel 'Cleaning complete*##status' 60000
    Write-Host "status: $($st.label)"
    Shot 'cleaner-cleaned'
    Check ($st.label -like '*skipped running: Microsoft Edge*') 'running Edge left out'
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
    $null = WaitLabel 'MakeCleaner 2.0.0*##dialogText' 5000
    Shot 'about'
    Invoke-AutoKey $app 'Enter'; $null = Invoke-AutoFrames $app 3
    Gone '*##dialogText'

    # ---------------- Registry
    Invoke-AutoClick $app 'Registry'
    $null = WaitLabel 'Pick the categories*##regstatus' 5000
    Invoke-AutoClick $app 'All categories##regall'; $null = Invoke-AutoFrames $app 2
    Check ((Item 'All categories##regall').checked -and (Item 'Fonts##regcat:Fonts').checked) 'All categories from mixed -> all on'
    Invoke-AutoClick $app 'Scan for Issues##regscan'
    Invoke-AutoClick $app 'Cancel##regcancel'
    $st = WaitLabel 'Scan c*##regstatus' 120000
    Write-Host "scan + cancel: $($st.label)"
    Invoke-AutoClick $app 'All categories##regall'; $null = Invoke-AutoFrames $app 2
    Check (-not (Item 'MUI Cache##regcat:MUI Cache').checked) 'All categories from on -> all off'
    Invoke-AutoClick $app 'Scan for Issues##regscan'
    $null = WaitLabel 'Tick at least one category*##regstatus' 5000
    Invoke-AutoClick $app 'MUI Cache##regcat:MUI Cache'
    Shot 'registry-start'
    Invoke-AutoClick $app 'Scan for Issues##regscan'
    $st = WaitLabel 'Scan complete*##regstatus' 60000
    Write-Host "scan: $($st.label)"
    Shot 'registry-scanned'
    $fx3 = WaitLabel "##rc*:*mc-g1-fixture-$rnd\three.exe*"
    $row3 = '##row' + ($fx3.label -replace '^##rc(\d+):.*$', '$1')
    Invoke-AutoClick $app $row3 -Kind rclick
    $null = Item 'Add to Exclude list'
    Shot 'registry-menu'
    Invoke-AutoClick $app 'Add to Exclude list'
    $null = WaitLabel 'Excluded:*three.exe*##regstatus'
    Gone "##rc*:*three.exe*"
    $fx1 = WaitLabel "##rc*:*mc-g1-fixture-$rnd\one.exe*"
    Invoke-AutoClick $app ('##row' + ($fx1.label -replace '^##rc(\d+):.*$', '$1')) -Kind rclick
    Invoke-AutoClick $app 'Select none'; $null = Invoke-AutoFrames $app 2
    Check (@(Items | Where-Object { $_.label -like '##rc*' -and $_.checked }).Count -eq 0) 'Select none'
    foreach ($n in @('one', 'two')) { Invoke-AutoClick $app (WaitLabel "##rc*:*mc-g1-fixture-$rnd\$n.exe*").label }
    $null = Invoke-AutoFrames $app 2
    $ticked = @(Items | Where-Object { $_.label -like '##rc*' -and $_.checked })
    Check ($ticked.Count -eq 2 -and @($ticked | Where-Object { $_.label -notlike "*mc-g1-fixture-$rnd*" }).Count -eq 0) 'only the two fixtures ticked'
    Invoke-AutoClick $app 'Review selected Issues...##regfix'
    $c = WaitLabel 'Issue 1 of 2*##regcounter' 15000
    Check (@(Get-ChildItem (Join-Path $appDir 'RegistryBackups') -Filter 'MakeCleaner_registry_*.reg').Count -eq 1) 'silent backup written'
    $null = WaitLabel "*mc-g1-fixture-$rnd*##regdetails"
    Shot 'registry-fix-dialog'
    Invoke-AutoClick $app '>>##regnext'
    $null = WaitLabel 'Issue 2 of 2*##regcounter' 3000
    Invoke-AutoClick $app 'Fix All Selected##regfixall'
    $null = Item 'Fix all##dialogButton0'
    Shot 'registry-fix-confirm'
    Invoke-AutoKey $app 'Escape'; $null = Invoke-AutoFrames $app 3
    Gone 'Fix all##dialogButton0'
    $det = WaitLabel "*mc-g1-fixture-$rnd*##regdetails"
    Check ($det.label -like '*Solution: delete the registry value.*') 'details show the solution'
    Invoke-AutoClick $app 'Fix Issue##regfixone'
    $null = WaitLabel 'Issue 1 of 2*##regcounter' 15000
    Check (@($mui.GetValueNames() | Where-Object { $_ -eq $fixNames[0] -or $_ -eq $fixNames[1] }).Count -eq 1) 'Fix Issue removed one fixture'
    Invoke-AutoClick $app 'Fix All Selected##regfixall'
    Invoke-AutoClick $app 'Fix all##dialogButton0'
    $st = WaitLabel 'Fixed 2 issues*##regstatus' 15000
    Write-Host "fix: $($st.label)"
    Shot 'registry-fixed'
    Check (@($mui.GetValueNames() | Where-Object { $_ -eq $fixNames[0] -or $_ -eq $fixNames[1] }).Count -eq 0) 'Fix All removed the other fixture'
    Check (@($mui.GetValueNames() | Where-Object { $_ -eq $fixNames[2] }).Count -eq 1) 'excluded fixture untouched'
    Invoke-AutoClick $app 'Cleaner'; $null = Invoke-AutoFrames $app 3

    # ---------------- close = WM_CLOSE (saves the ticks); automation 'quit' would skip that
    $null = $app.Process.CloseMainWindow()
    if (-not $app.Process.WaitForExit(10000)) { throw 'app did not exit on WM_CLOSE' }
    Check ($app.Process.ExitCode -eq 0) 'exit code 0'
    $saved = Get-Content (Join-Path $appDir 'MakeCleaner.ini')
    $saved | Where-Object { $_ -match '^(Microsoft Edge|Custom|Wipe|Reg:MUI|Exclude)' } | ForEach-Object { Write-Host "ini: $_" }
    Check ($saved -contains 'Microsoft Edge: Internet Cache=False') 'browser ticks persisted on close'
    Check ($saved -contains 'Custom Files and Folders=True') 'rule ticks persisted on close'
    Check (-not ($saved -contains 'Wipe Free Space=True')) 'wipe never saved as on'
    Check ($saved -contains 'Reg:MUI Cache=True' -and $saved -contains 'Reg:Fonts=False') 'registry categories persisted'
    Check (@($saved | Where-Object { $_ -like 'Exclude*=FILE|*keep.txt' }).Count -eq 1 -and @($saved | Where-Object { $_ -like "Exclude*=REG|*three.exe.FriendlyAppName" }).Count -eq 1) 'excludes saved'
    Write-Host 'G1 GUI TEST OK'
} catch {
    Write-Host "ERROR: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
    if ($app -and -not $app.Process.HasExited) { try { Shot 'error' } catch { } }
    throw
} finally {
    $ErrorActionPreference = 'Continue'
    if ($app -and -not $app.Process.HasExited) { $null = Stop-AutoApp $app }
    if ($fakeEdge) { Stop-Process -Id $fakeEdge.Id -Force -ErrorAction SilentlyContinue }
    foreach ($n in $fixNames) { try { $mui.DeleteValue($n, $false) } catch { } }
    $mui.Close()
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $T -ErrorAction SilentlyContinue
    # BMP -> PNG
    $py = "import sys,glob,os`nfrom PIL import Image`nfor b in glob.glob(os.path.join(sys.argv[1],'MC-G1-*.bmp')):`n    Image.open(b).save(b[:-4]+'.png'); os.remove(b)"
    $pyFile = Join-Path ([IO.Path]::GetTempPath()) "g1-bmp2png-$rnd.py"
    Set-Content $pyFile $py -Encoding Ascii
    foreach ($v in @('-3.12', '-3.10')) { & py $v -c 'import PIL' 2>$null; if ($LASTEXITCODE -eq 0) { & py $v $pyFile $Shots; break } }
    Remove-Item $pyFile -ErrorAction SilentlyContinue
}
