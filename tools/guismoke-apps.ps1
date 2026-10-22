# GUI smoke for the Applications tab: portable mode, TEMP pointed at a fixture, waits for app detection,
# opens the Applications tab, ticks the first detected entry (if UIA allows) and runs Analyze ONLY.
# Never clicks Run Cleaner. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$Config = 'Debug', [string]$Shot = "$env:TEMP\makecleaner-apps-smoke.png")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root "src\MakeCleaner\bin\$Config\net10.0-windows"
$exe = Join-Path $bin 'MakeCleaner.exe'
. (Join-Path $PSScriptRoot 'screenpin.ps1')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
$AT = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

$fx = Join-Path ([IO.Path]::GetTempPath()) ('mc-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $fx | Out-Null
[IO.File]::WriteAllBytes((Join-Path $fx 'a.tmp'), (New-Object byte[] 1024))
Set-Content (Join-Path $bin 'portable.dat') '#PORTABLE#'

function ById($w, $id) { $w.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AT::AutomationIdProperty, $id))) }
function ByName($w, $name) { $w.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AT::NameProperty, $name))) }
function Status($w) { (ById $w 'status').Current.Name }
function WaitStatus($w, $like) { for ($i = 0; $i -lt 150; $i++) { $s = Status $w; if ($s -like $like) { return $s }; Start-Sleep -Milliseconds 200 }; throw "timeout waiting for '$like', last: $s" }

Start-ScreenPin -Screen $Screen -Exe $exe
$oldTemp = $env:TEMP; $env:TEMP = $fx
$sw = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Process $exe -PassThru
$env:TEMP = $oldTemp
try {
    $w = $null
    for ($i = 0; $i -lt 50 -and -not $w; $i++) {
        Start-Sleep -Milliseconds 200
        $w = $AT::RootElement.FindFirst($TS::Children, (New-Object System.Windows.Automation.PropertyCondition($AT::ProcessIdProperty, $p.Id)))
    }
    if (-not $w) { throw 'window did not open' }
    $d = WaitStatus $w '*applications detected'
    Write-Host ("detect: $d in {0:N1}s" -f $sw.Elapsed.TotalSeconds)
    (ByName $w 'Applications').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 300
    $tree = ById $w 'apps'
    $groups = $tree.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)
    Write-Host "groups: $($groups.Count)"
    $ticked = '(none)'
    if ($groups.Count -gt 0) {
        $g = $groups[0]
        $g.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
        $leaf = $g.FindFirst($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)
        $tp = $null
        if ($leaf -and $leaf.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$tp)) { $tp.Toggle(); $ticked = $leaf.Current.Name }
    }
    Write-Host "ticked: $ticked"
    (ById $w 'analyze').GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $a = WaitStatus $w 'Analysis complete*'
    Write-Host "analyze: $a"
    $r = $w.Current.BoundingRectangle
    $bmp = New-Object System.Drawing.Bitmap ([int]$r.Width), ([int]$r.Height)
    [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bmp.Size)
    $bmp.Save($Shot); Write-Host "screenshot: $Shot"
    $left = @(Get-ChildItem $fx -File).Count
    $w.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $p.WaitForExit(5000) | Out-Null
    if ($groups.Count -eq 0 -or $a -notlike '*registry entries*' -or $left -ne 1) { throw 'SMOKE FAILED' }
    Write-Host 'SMOKE OK (analyze only, nothing deleted)'
} finally {
    Stop-ScreenPin
    if (-not $p.HasExited) { $p.Kill() }
    Remove-Item -Recurse -Force $fx -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $bin 'portable.dat'), (Join-Path $bin 'MakeCleaner.ini') -ErrorAction SilentlyContinue
}
