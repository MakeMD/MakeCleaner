# Smoke for MakeCleaner /auto: portable ini with only Temporary Files ticked, TEMP/AppData pointed at a fixture.
# Runs the built exe headless, checks exit code, fixture emptied, no window, log line. Then opens the GUI on the
# Options tab and reads the scheduled-cleaning status (never clicks Create: that would register a real task).
# Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$Config = 'Debug', [string]$BinDir = '', [switch]$Wpf, [string]$Shot = "$env:TEMP\makecleaner-schedule.png")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$app = if ($Wpf) { 'MakeCleaner.Wpf' } else { 'MakeCleaner' } # -Wpf: the WPF window; WinForms stays the default until ticket 19
$bin = if ($BinDir) { $BinDir } else { Join-Path $root "src\$app\bin\$Config\net10.0-windows" } # -BinDir: a published copy (tools\releasecheck.ps1)
$exe = Join-Path $bin "$app.exe"
. (Join-Path $PSScriptRoot 'screenpin.ps1')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
$AT = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

$fx = Join-Path ([IO.Path]::GetTempPath()) ('mc-auto-' + [guid]::NewGuid().ToString('N'))
$tmp = Join-Path $fx 'temp'; $noApps = Join-Path $fx 'noapps'
New-Item -ItemType Directory -Force (Join-Path $tmp 'sub'), $noApps | Out-Null
'a', 'sub\b' | ForEach-Object { [IO.File]::WriteAllBytes((Join-Path $tmp "$_.tmp"), (New-Object byte[] 1024)) }
Set-Content (Join-Path $bin 'portable.dat') '#PORTABLE#'
# Only Temporary Files on (Wipe Free Space on too: /auto must ignore it).
$names = Select-String -Path (Join-Path $root 'src\MakeCleaner.Core\rules\Windows.ini') -Pattern '^\[(.+)\]$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
Set-Content (Join-Path $bin 'MakeCleaner.ini') (@('[Options]', 'Custom Files and Folders=False') + ($names | ForEach-Object { "$_=" + ($_ -in 'Temporary Files', 'Wipe Free Space') }))
$log = Join-Path $bin 'MakeCleaner-auto.log'
Remove-Item $log -ErrorAction SilentlyContinue

function Window($p) { $AT::RootElement.FindFirst($TS::Children, (New-Object System.Windows.Automation.PropertyCondition($AT::ProcessIdProperty, $p.Id))) }

$old = $env:TEMP, $env:TMP, $env:LOCALAPPDATA, $env:APPDATA
try {
    $env:TEMP = $tmp; $env:TMP = $tmp; $env:LOCALAPPDATA = $noApps; $env:APPDATA = $noApps
    $a = Start-Process $exe -ArgumentList '/auto' -PassThru
    $env:TEMP, $env:TMP, $env:LOCALAPPDATA, $env:APPDATA = $old
    $sawWindow = $false
    while (-not $a.HasExited) { if (Window $a) { $sawWindow = $true }; Start-Sleep -Milliseconds 100 }
    $a.WaitForExit()
    $left = @(Get-ChildItem $tmp -Recurse -File).Count
    $line = Get-Content $log -Tail 1
    Write-Host "auto exit: $($a.ExitCode), window: $sawWindow, fixture files left: $left"
    Write-Host "log: $line"
    if ($a.ExitCode -ne 0 -or $sawWindow -or $left -ne 0 -or $line -notlike '*Cleaning complete: 2 files removed*' -or $line -like '*free space*') { throw 'AUTO SMOKE FAILED' }

    Start-ScreenPin -Screen $Screen -Exe $exe
    $env:LOCALAPPDATA = $noApps; $env:APPDATA = $noApps
    $p = Start-Process $exe -PassThru
    $env:TEMP, $env:TMP, $env:LOCALAPPDATA, $env:APPDATA = $old
    $w = $null
    for ($i = 0; $i -lt 100 -and -not $w; $i++) { Start-Sleep -Milliseconds 200; $w = Window $p }
    if (-not $w) { throw 'window did not open' }
    # Options: a WinForms tab, or a WPF rail tile followed by its Schedule sub-page
    $kinds = New-Object System.Windows.Automation.OrCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)),
        (New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)))
    foreach ($name in @('Options') + @(if ($Wpf) { 'Schedule' })) {
        $c = New-Object System.Windows.Automation.AndCondition($kinds, (New-Object System.Windows.Automation.PropertyCondition($AT::NameProperty, $name)))
        $w.FindFirst($TS::Descendants, $c).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Start-Sleep -Milliseconds 300
    }
    Start-Sleep -Milliseconds 500
    # focus scrolls the Options panel down to the schedule group for the screenshot
    $w.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AT::AutomationIdProperty, 'schedRemove'))).SetFocus()
    Start-Sleep -Milliseconds 300
    $st =$w.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AT::AutomationIdProperty, 'schedStatus'))).Current.Name
    Write-Host "schedule status: $st"
    $r = $w.Current.BoundingRectangle
    $bmp = New-Object System.Drawing.Bitmap ([int]$r.Width), ([int]$r.Height)
    [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bmp.Size)
    $bmp.Save($Shot); Write-Host "screenshot: $Shot"
    $w.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $p.WaitForExit(5000) | Out-Null
    if ($st -notlike '*scheduled cleaning*') { throw 'SMOKE FAILED' }
    Write-Host 'SMOKE OK'
} finally {
    $env:TEMP, $env:TMP, $env:LOCALAPPDATA, $env:APPDATA = $old
    Stop-ScreenPin
    if ($p -and -not $p.HasExited) { $p.Kill() }
    Remove-Item -Recurse -Force $fx -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $bin 'portable.dat'), (Join-Path $bin 'MakeCleaner.ini'), $log -ErrorAction SilentlyContinue
}
