# GUI smoke: runs the built exe in portable mode with TEMP pointed at a fixture folder,
# clicks Analyze then Run Cleaner via UI Automation (no keystrokes), checks the status line,
# saves a screenshot. Never touches the real %TEMP%. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$Config = 'Debug', [string]$Shot = "$env:TEMP\makecleaner-smoke.png")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root "src\MakeCleaner\bin\$Config\net10.0-windows"
$exe = Join-Path $bin 'MakeCleaner.exe'
. (Join-Path $PSScriptRoot 'screenpin.ps1')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
$AT = [System.Windows.Automation.AutomationElement]

$fx = Join-Path ([IO.Path]::GetTempPath()) ('mc-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force (Join-Path $fx 'sub') | Out-Null
'a', 'b', 'sub\c' | ForEach-Object { [IO.File]::WriteAllBytes((Join-Path $fx "$_.tmp"), (New-Object byte[] 1024)) }
Set-Content (Join-Path $bin 'portable.dat') '#PORTABLE#'
# Only Temporary Files on: every other Windows-tab rule would touch real user data on Run Cleaner.
$names = Select-String -Path (Join-Path $root 'src\MakeCleaner\rules\Windows.ini') -Pattern '^\[(.+)\]$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
Set-Content (Join-Path $bin 'MakeCleaner.ini') (@('[Options]') + ($names | ForEach-Object { "$_=" + ($_ -eq 'Temporary Files') }))

function Status($w) { $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AT::AutomationIdProperty, 'status'))).Current.Name }
function Click($w, $id) { $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AT::AutomationIdProperty, $id))).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
function WaitStatus($w, $prefix) { for ($i = 0; $i -lt 50; $i++) { $s = Status $w; if ($s -like "$prefix*") { return $s }; Start-Sleep -Milliseconds 200 }; throw "timeout waiting for '$prefix', last: $s" }

# Browser items default to on and this smoke clicks Run Cleaner: point AppData at an empty folder so no real browser is found.
$noApps = Join-Path ([IO.Path]::GetTempPath()) ('mc-smoke-noapps-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $noApps | Out-Null
Start-ScreenPin -Screen $Screen -Exe $exe
$old = $env:TEMP, $env:LOCALAPPDATA, $env:APPDATA
$env:TEMP = $fx; $env:LOCALAPPDATA = $noApps; $env:APPDATA = $noApps
$p = Start-Process $exe -PassThru
$env:TEMP, $env:LOCALAPPDATA, $env:APPDATA = $old
try {
    $w = $null
    for ($i = 0; $i -lt 50 -and -not $w; $i++) {
        Start-Sleep -Milliseconds 200
        $w = $AT::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition($AT::ProcessIdProperty, $p.Id)))
    }
    if (-not $w) { throw 'window did not open' }
    Click $w 'analyze'
    $a = WaitStatus $w 'Analysis complete'
    Write-Host "analyze: $a"
    $r = $w.Current.BoundingRectangle
    $bmp = New-Object System.Drawing.Bitmap ([int]$r.Width), ([int]$r.Height)
    [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bmp.Size)
    $bmp.Save($Shot); Write-Host "screenshot: $Shot"
    Click $w 'clean'
    $c = WaitStatus $w 'Cleaning complete'
    Write-Host "clean: $c"
    $left = @(Get-ChildItem $fx -Recurse -File).Count
    Write-Host "fixture files left: $left"
    $w.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $p.WaitForExit(5000) | Out-Null
    $ini = Join-Path $bin 'MakeCleaner.ini'
    Write-Host ("portable ini next to exe: " + (Test-Path $ini))
    if ($a -notlike '*3 files*' -or $left -ne 0 -or -not (Test-Path $ini)) { throw 'SMOKE FAILED' }
    Write-Host 'SMOKE OK'
} finally {
    Stop-ScreenPin
    if (-not $p.HasExited) { $p.Kill() }
    Remove-Item -Recurse -Force $fx, $noApps -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $bin 'portable.dat'), (Join-Path $bin 'MakeCleaner.ini') -ErrorAction SilentlyContinue
}
