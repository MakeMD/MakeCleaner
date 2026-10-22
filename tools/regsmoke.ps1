# Registry GUI smoke: opens the Registry window from the main form, runs Scan (read-only),
# checks the status line and saves a screenshot. Never clicks Fix. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$Config = 'Debug', [string]$Shot = "$env:TEMP\makecleaner-regsmoke.png")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root "src\MakeCleaner\bin\$Config\net10.0-windows"
$exe = Join-Path $bin 'MakeCleaner.exe'
. (Join-Path $PSScriptRoot 'screenpin.ps1')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type -Namespace W -Name U -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);'
$AT = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

function ById($w, $id) { $w.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AT::AutomationIdProperty, $id))) }
function Wait($what, $fn) { for ($i = 0; $i -lt 100; $i++) { $r = & $fn; if ($r) { return $r }; Start-Sleep -Milliseconds 200 }; throw "timeout: $what" }

Set-Content (Join-Path $bin 'portable.dat') '#PORTABLE#'
Start-ScreenPin -Screen $Screen -Exe $exe
$p = Start-Process $exe -PassThru
try {
    $byPid = New-Object System.Windows.Automation.PropertyCondition($AT::ProcessIdProperty, $p.Id)
    $main = Wait 'main window' { $AT::RootElement.FindFirst($TS::Children, $byPid) }
    # BM_CLICK via PostMessage: Invoke would block on the modal dialog
    [W.U]::PostMessage([IntPtr](ById $main 'registry').Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    # owned modal dialogs show up under their owner in the UIA tree
    $byName = New-Object System.Windows.Automation.PropertyCondition($AT::NameProperty, 'MakeCleaner - Registry')
    $reg = Wait 'registry window' { $main.FindFirst($TS::Descendants, $byName) }
    (ById $reg 'regscan').GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $s = Wait 'scan' { $t = (ById $reg 'regstatus').Current.Name; if ($t -like 'Scan complete*') { $t } }
    Write-Host "scan: $s"
    $r = $reg.Current.BoundingRectangle
    $bmp = New-Object System.Drawing.Bitmap ([int]$r.Width), ([int]$r.Height)
    [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bmp.Size)
    $bmp.Save($Shot); Write-Host "screenshot: $Shot"
    $reg.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    Start-Sleep -Milliseconds 500
    $main.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $p.WaitForExit(5000) | Out-Null
    Write-Host 'SMOKE OK'
} finally {
    Stop-ScreenPin
    if (-not $p.HasExited) { $p.Kill() }
    Remove-Item (Join-Path $bin 'portable.dat'), (Join-Path $bin 'MakeCleaner.ini') -ErrorAction SilentlyContinue
}
