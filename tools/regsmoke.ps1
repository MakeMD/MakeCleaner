# Registry GUI smoke: switches the main form to the Registry tab, runs Scan (read-only),
# checks the status line and saves a screenshot. Never clicks Fix. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$Config = 'Debug', [string]$BinDir = '', [string]$Shot = "$env:TEMP\makecleaner-regsmoke.png")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = if ($BinDir) { $BinDir } else { Join-Path $root "src\MakeCleaner\bin\$Config\net10.0-windows" } # -BinDir: a published copy (tools\releasecheck.ps1)
$exe = Join-Path $bin 'MakeCleaner.exe'
. (Join-Path $PSScriptRoot 'screenpin.ps1')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
$AT = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

function Find($w, $prop, $val) { $w.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($prop, $val))) }
function Wait($what, $fn) { for ($i = 0; $i -lt 100; $i++) { $r = & $fn; if ($r) { return $r }; Start-Sleep -Milliseconds 200 }; throw "timeout: $what" }

Set-Content (Join-Path $bin 'portable.dat') '#PORTABLE#'
Start-ScreenPin -Screen $Screen -Exe $exe
$p = Start-Process $exe -PassThru
try {
    $byPid = New-Object System.Windows.Automation.PropertyCondition($AT::ProcessIdProperty, $p.Id)
    $main = Wait 'main window' { $AT::RootElement.FindFirst($TS::Children, $byPid) }
    $tab = Wait 'Registry tab' { $main.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AT::NameProperty, 'Registry'))) |
        Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::TabItem } | Select-Object -First 1 }
    $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    (Wait 'scan button' { Find $main $AT::AutomationIdProperty 'regscan' }).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $s = Wait 'scan' { $t = (Find $main $AT::AutomationIdProperty 'regstatus').Current.Name; if ($t -like 'Scan complete*') { $t } }
    Write-Host "scan: $s"
    $r = $main.Current.BoundingRectangle
    $bmp = New-Object System.Drawing.Bitmap ([int]$r.Width), ([int]$r.Height)
    [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bmp.Size)
    $bmp.Save($Shot); Write-Host "screenshot: $Shot"
    $main.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $p.WaitForExit(5000) | Out-Null
    Write-Host 'SMOKE OK'
} finally {
    Stop-ScreenPin
    if (-not $p.HasExited) { $p.Kill() }
    Remove-Item (Join-Path $bin 'portable.dat'), (Join-Path $bin 'MakeCleaner.ini') -ErrorAction SilentlyContinue
}
