# GUI smoke for what only the WPF window has: tri-state group checkbox, Cancel during Analyze, Summary / Files views,
# and /auto from MakeCleaner.Wpf.exe. TEMP/LOCALAPPDATA/APPDATA point at a fixture; every Windows rule is off except
# Temporary Files, so nothing real is ever scanned. The window never clicks Run Cleaner; only the final /auto cleans,
# and it cleans the fixture TEMP. UI Automation, no keystrokes. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$Config = 'Debug', [string]$BinDir = '', [string]$ShotDir = $env:TEMP, [int]$Files = 40000)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = if ($BinDir) { $BinDir } else { Join-Path $root "src\MakeCleaner.Wpf\bin\$Config\net10.0-windows" }
$exe = Join-Path $bin 'MakeCleaner.Wpf.exe'
. (Join-Path $PSScriptRoot 'screenpin.ps1')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
$AT = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]

# Fixture: a TEMP big enough that Analyze is still running when Cancel is pressed, and empty AppData (no browsers).
$fx = Join-Path ([IO.Path]::GetTempPath()) ('mc-wpf-smoke-' + [guid]::NewGuid().ToString('N'))
$temp = Join-Path $fx 'Temp'; $noApps = Join-Path $fx 'noapps'
New-Item -ItemType Directory -Force $noApps | Out-Null
# many folders, few files each: walking folders is what makes Analyze slow enough to be cancelled
$dirs = [int]($Files / 10)
for ($d = 0; $d -lt $dirs; $d++) { [void][IO.Directory]::CreateDirectory((Join-Path $temp ("a{0}\d{1}" -f ($d % 50), $d))) }
$empty = New-Object byte[] 0
for ($i = 0; $i -lt $Files; $i++) { $d = $i % $dirs; [IO.File]::WriteAllBytes((Join-Path $temp ("a{0}\d{1}\f{2}.tmp" -f ($d % 50), $d, $i)), $empty) }
Set-Content (Join-Path $bin 'portable.dat') '#PORTABLE#'
$names = Select-String -Path (Join-Path $root 'src\MakeCleaner.Core\rules\Windows.ini') -Pattern '^\[(.+)\]$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
Set-Content (Join-Path $bin 'MakeCleaner.ini') (@('[Options]', 'Custom Files and Folders=False') + ($names | ForEach-Object { "$_=" + ($_ -eq 'Temporary Files') }))

function Cond($prop, $val) { New-Object System.Windows.Automation.PropertyCondition($prop, $val) }
function ById($w, $id) { $w.FindFirst($TS::Descendants, (Cond $AT::AutomationIdProperty $id)) }
function Status($w) { (ById $w 'status').Current.Name }
function WaitStatus($w, $like, $tries = 150) { for ($i = 0; $i -lt $tries; $i++) { $s = Status $w; if ($s -like $like) { return $s }; Start-Sleep -Milliseconds 200 }; throw "timeout waiting for '$like', last: $s" }
function Invoke($e) { $e.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
function Shot($w, $name) {
    $r = $w.Current.BoundingRectangle
    $bmp = New-Object System.Drawing.Bitmap ([int]$r.Width), ([int]$r.Height)
    [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bmp.Size)
    $p = Join-Path $ShotDir "makecleaner-wpf-$name.png"; $bmp.Save($p); Write-Host "screenshot: $p"
}
function GroupState($w, $group) {
    $g = (ById $w 'windows').FindFirst($TS::Children, (New-Object System.Windows.Automation.AndCondition((Cond $AT::ControlTypeProperty $CT::TreeItem), (Cond $AT::NameProperty $group))))
    $cb = $g.FindFirst($TS::Children, (Cond $AT::ControlTypeProperty $CT::CheckBox))
    $cb.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState
}

Start-ScreenPin -Screen $Screen -Exe $exe
$old = $env:TEMP, $env:LOCALAPPDATA, $env:APPDATA
$env:TEMP = $temp; $env:LOCALAPPDATA = $noApps; $env:APPDATA = $noApps
$p = Start-Process $exe -PassThru
$env:TEMP, $env:LOCALAPPDATA, $env:APPDATA = $old
try {
    $w = $null
    for ($i = 0; $i -lt 100 -and -not $w; $i++) { # up to 20 s: a cold WPF start can take >10 s
        Start-Sleep -Milliseconds 200
        $w = $AT::RootElement.FindFirst($TS::Children, (Cond $AT::ProcessIdProperty $p.Id))
    }
    if (-not $w) { throw 'window did not open' }
    WaitStatus $w '*applications detected' | Out-Null
    Shot $w 'main'

    # only Temporary Files is on: System shows the third state, Windows Explorer is off
    $sys = GroupState $w 'System'; $exp = GroupState $w 'Windows Explorer'
    Write-Host "groups: System=$sys, Windows Explorer=$exp"

    # Cancel while analyzing: nothing may stay armed for Run Cleaner
    # (buttons looked up first: a UIA search takes longer than analyzing the fixture; with a warm disk cache the
    #  analysis can still win the race, so a few tries)
    $cancel = ById $w 'cancel'; $analyzeBtn = ById $w 'analyze'; $c = ''
    for ($try = 1; $try -le 5 -and $c -notlike 'Analysis cancelled*'; $try++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Invoke $analyzeBtn
        for ($i = 0; $i -lt 2000 -and -not $cancel.Current.IsEnabled; $i++) { }
        $seen = $sw.ElapsedMilliseconds; $err = ''
        try { Invoke $cancel } catch { $err = $_.Exception.InnerException.GetType().Name } # too late: this Analyze already finished
        $c = WaitStatus $w 'Analysis*'
        Write-Host ("try {0}: cancel enabled after {1} ms (polls {2}), invoke {3}, status after {4} ms: {5}" -f $try, $seen, $i, $(if ($err) { $err } else { 'ok' }), $sw.ElapsedMilliseconds, $c)
    }
    $cleanAfterCancel = (ById $w 'clean').Current.IsEnabled
    Write-Host "cancel: $c (Run Cleaner enabled: $cleanAfterCancel)"

    # full Analyze, then Summary and Files views
    Invoke (ById $w 'analyze')
    $a = WaitStatus $w 'Analysis complete*'
    Write-Host "analyze: $a"
    $summaryRows = (ById $w 'results').FindAll($TS::Children, (Cond $AT::ControlTypeProperty $CT::DataItem)).Count
    Shot $w 'summary'
    (ById $w 'viewFiles').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 500
    $fileRows = (ById $w 'results').FindAll($TS::Children, (Cond $AT::ControlTypeProperty $CT::DataItem)).Count
    Write-Host "rows: summary=$summaryRows files(visible)=$fileRows"
    Shot $w 'files'
    $w.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $p.WaitForExit(5000) | Out-Null
    $left = @(Get-ChildItem $temp -Recurse -File).Count

    # /auto from the WPF exe: no window, exit code 0, the fixture TEMP emptied
    $env:TEMP = $temp; $env:LOCALAPPDATA = $noApps; $env:APPDATA = $noApps
    $auto = Start-Process $exe -ArgumentList '/auto' -PassThru -Wait
    $env:TEMP, $env:LOCALAPPDATA, $env:APPDATA = $old
    $afterAuto = @(Get-ChildItem $temp -Recurse -File).Count
    Write-Host "window run left the fixture: $left of $Files; /auto exit $($auto.ExitCode), files left $afterAuto"

    if ($sys -ne 'Indeterminate' -or $exp -ne 'Off' -or -not $cancel -or $c -notlike 'Analysis cancelled*' -or $cleanAfterCancel `
        -or $a -notlike "Analysis complete: $Files files*" -or $summaryRows -ne 1 -or $fileRows -lt 2 -or $left -ne $Files `
        -or $auto.ExitCode -ne 0 -or $afterAuto -ne 0) { throw 'SMOKE FAILED' }
    Write-Host 'SMOKE OK'
} finally {
    Stop-ScreenPin
    if (-not $p.HasExited) { $p.Kill() }
    Remove-Item -Recurse -Force $fx -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $bin 'portable.dat'), (Join-Path $bin 'MakeCleaner.ini'), (Join-Path $bin 'MakeCleaner-auto.log') -ErrorAction SilentlyContinue
}
