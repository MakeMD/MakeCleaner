# GUI smoke for Tools (Drive Wiper, System Restore) and Options: opens each page via UI Automation,
# ticks the first drive to show warnings, takes screenshots. NEVER clicks Wipe / Remove / Erase.
# Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$Config = 'Debug', [string]$ShotDir = $env:TEMP)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root "src\MakeCleaner\bin\$Config\net10.0-windows"
$exe = Join-Path $bin 'MakeCleaner.exe'
. (Join-Path $PSScriptRoot 'screenpin.ps1')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
$AT = [System.Windows.Automation.AutomationElement]
$Desc = [System.Windows.Automation.TreeScope]::Descendants
Set-Content (Join-Path $bin 'portable.dat') '#PORTABLE#'

function ById($w, $id) { $w.FindFirst($Desc, (New-Object System.Windows.Automation.PropertyCondition($AT::AutomationIdProperty, $id))) }
function Tab($w, $name) {
    $c = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)),
        (New-Object System.Windows.Automation.PropertyCondition($AT::NameProperty, $name)))
    $w.FindFirst($Desc, $c).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 700
}
function Shot($w, $name) {
    $r = $w.Current.BoundingRectangle
    $bmp = New-Object System.Drawing.Bitmap ([int]$r.Width), ([int]$r.Height)
    [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bmp.Size)
    $f = Join-Path $ShotDir "makecleaner-$name.png"; $bmp.Save($f); Write-Host "screenshot: $f"
}
function Items($el) { @($el.FindAll($Desc, (New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, [System.Windows.Automation.ControlType]::CheckBox)))) }

Start-ScreenPin -Screen $Screen -Exe $exe
$p = Start-Process $exe -PassThru
try {
    $w = $null
    for ($i = 0; $i -lt 50 -and -not $w; $i++) {
        Start-Sleep -Milliseconds 200
        $w = $AT::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition($AT::ProcessIdProperty, $p.Id)))
    }
    if (-not $w) { throw 'window did not open' }
    $fail = @()

    $wipeItem = $w.FindFirst($Desc, (New-Object System.Windows.Automation.PropertyCondition($AT::NameProperty, 'Wipe Free Space')))
    Write-Host ("cleaner has Wipe Free Space item: " + [bool]$wipeItem)
    if (-not $wipeItem) { $fail += 'no wipe item' }

    Tab $w 'Tools'; Tab $w 'Drive Wiper'
    $drives = Items (ById $w 'drives')
    Write-Host ("drives listed: " + $drives.Count + " -> " + (($drives | ForEach-Object { $_.Current.Name }) -join ' | '))
    if ($drives.Count -eq 0) { $fail += 'no drives' }
    else { $drives[0].GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle(); Start-Sleep -Milliseconds 500 }
    Write-Host ("warning: " + (ById $w 'wipeWarning').Current.Name)
    Write-Host ("wipe button enabled (not clicked): " + (ById $w 'wipe').Current.IsEnabled)
    Shot $w 'drivewiper'

    Tab $w 'System Restore'
    $rp = ById $w 'rpStatus'
    for ($i = 0; $i -lt 25 -and -not $rp.Current.Name; $i++) { Start-Sleep -Milliseconds 200 }
    Write-Host ("restore status: " + $rp.Current.Name)
    if (-not $rp.Current.Name) { $fail += 'restore status empty' }
    Shot $w 'restore'

    Tab $w 'Options'
    $sd = ById $w 'secureDelete'
    Write-Host ("secure delete combo: " + $sd.Current.Name + " / value: " + $sd.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value)
    Shot $w 'options'

    $w.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $p.WaitForExit(5000) | Out-Null
    if ($fail) { throw ('SMOKE FAILED: ' + ($fail -join ', ')) }
    Write-Host 'SMOKE OK'
} finally {
    Stop-ScreenPin
    if (-not $p.HasExited) { $p.Kill() }
    Remove-Item (Join-Path $bin 'portable.dat'), (Join-Path $bin 'MakeCleaner.ini') -ErrorAction SilentlyContinue
}
