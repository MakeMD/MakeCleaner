# GUI smoke for Tools > Uninstall / Startup: READ-ONLY. Opens the tabs via UI Automation (no keystrokes),
# waits for each list to fill, prints row counts, saves screenshots. Never clicks an action button. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$Config = 'Debug', [string]$ShotDir = $env:TEMP)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root "src\MakeCleaner\bin\$Config\net10.0-windows"
$exe = Join-Path $bin 'MakeCleaner.exe'
. (Join-Path $PSScriptRoot 'screenpin.ps1')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
$AT = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
Set-Content (Join-Path $bin 'portable.dat') '#PORTABLE#'  # keep settings next to the exe, cleaned up below

function ById($w, $id) { $w.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AT::AutomationIdProperty, $id))) }
function SelectTab($w, $name) {
    $c = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)),
        (New-Object System.Windows.Automation.PropertyCondition($AT::NameProperty, $name)))
    $t = $w.FindFirst($TS::Descendants, $c)
    if (-not $t) { throw "tab '$name' not found" }
    $t.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
}
function Rows($w, $id) {
    for ($i = 0; $i -lt 75; $i++) {
        $l = ById $w $id
        if ($l) {
            $n = $l.FindAll($TS::Children, (New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem))).Count
            if ($n -gt 0) { return $n }
        }
        Start-Sleep -Milliseconds 200
    }
    return 0
}
function Shot($w, $name) {
    $r = $w.Current.BoundingRectangle
    $bmp = New-Object System.Drawing.Bitmap ([int]$r.Width), ([int]$r.Height)
    [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bmp.Size)
    $p = Join-Path $ShotDir "makecleaner-$name.png"; $bmp.Save($p); Write-Host "screenshot: $p"
}

Start-ScreenPin -Screen $Screen -Exe $exe
$p = Start-Process $exe -PassThru
try {
    $w = $null
    for ($i = 0; $i -lt 50 -and -not $w; $i++) {
        Start-Sleep -Milliseconds 200
        $w = $AT::RootElement.FindFirst($TS::Children, (New-Object System.Windows.Automation.PropertyCondition($AT::ProcessIdProperty, $p.Id)))
    }
    if (-not $w) { throw 'window did not open' }
    SelectTab $w 'Tools'
    SelectTab $w 'Uninstall'
    $res = [ordered]@{ Uninstall = (Rows $w 'uninstallList') }
    Shot $w 'uninstall'
    SelectTab $w 'Startup'
    foreach ($t in @(@('Windows', 'startupWindows'), @('Scheduled Tasks', 'startupTasks'), @('Context Menu', 'startupContext'), @('Windows Services', 'startupServices'))) {
        SelectTab $w $t[0]
        $res[$t[0]] = Rows $w $t[1]
        Shot $w ('startup-' + ($t[0] -replace ' ', ''))
    }
    $res.GetEnumerator() | ForEach-Object { Write-Host ("{0}: {1} rows" -f $_.Key, $_.Value) }
    $w.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    if ($res.Uninstall -eq 0 -or $res['Windows Services'] -eq 0) { throw 'SMOKE FAILED' }
    Write-Host 'SMOKE OK'
} finally {
    Stop-ScreenPin
    if (-not $p.HasExited) { $p.Kill() }
    Remove-Item (Join-Path $bin 'portable.dat'), (Join-Path $bin 'MakeCleaner.ini') -ErrorAction SilentlyContinue
}
