# GUI smoke for Options > Include / Exclude and saved checkbox states (ticket 04). Portable mode, fixture folder in TEMP.
# Adds an Include via the UI -> Analyze sees the fixture files; adds an Exclude -> Analyze hides them; restarts the exe
# and checks the lists and checkbox states came back. Analyze ONLY, never clicks Run Cleaner. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$Config = 'Debug', [string]$ShotDir = $env:TEMP)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root "src\MakeCleaner\bin\$Config\net10.0-windows"
$exe = Join-Path $bin 'MakeCleaner.exe'
$ini = Join-Path $bin 'MakeCleaner.ini'
. (Join-Path $PSScriptRoot 'screenpin.ps1')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
$AT = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

$fx = Join-Path ([IO.Path]::GetTempPath()) ('mc-incexc-' + [guid]::NewGuid().ToString('N'))
foreach ($rel in 'a.log', 'b.log', 'private\c.log') {
    $p = Join-Path $fx $rel
    New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
    [IO.File]::WriteAllBytes($p, (New-Object byte[] 1024))
}
Set-Content (Join-Path $bin 'portable.dat') '#PORTABLE#'
# Temp off so the real %TEMP% is never even scanned; Custom on so the Include is analyzed.
Set-Content $ini "[Options]`r`nTemporary Files=False`r`nCustom Files and Folders=True"

function ById($w, $id) { $w.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AT::AutomationIdProperty, $id))) }
function Click($w, $id) { (ById $w $id).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
function SetText($w, $id, $v) { (ById $w $id).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($v) }
function Tab($w, $name) {
    $c = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AT::NameProperty, $name)),
        (New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)))
    $w.FindFirst($TS::Descendants, $c).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
}
function Status($w) { (ById $w 'status').Current.Name }
function WaitStatus($w, $like) { for ($i = 0; $i -lt 150; $i++) { $s = Status $w; if ($s -like $like) { return $s }; Start-Sleep -Milliseconds 200 }; throw "timeout waiting for '$like', last: $s" }
function ListItems($w, $id) {
    @((ById $w $id).FindAll($TS::Children, (New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem))) | ForEach-Object { $_.Current.Name })
}
function Shot($w, $name) {
    $r = $w.Current.BoundingRectangle
    $bmp = New-Object System.Drawing.Bitmap ([int]$r.Width), ([int]$r.Height)
    [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bmp.Size)
    $path = Join-Path $ShotDir "makecleaner-$name.png"; $bmp.Save($path); Write-Host "screenshot: $path"
}
function Open() {
    $p = Start-Process $exe -PassThru
    $w = $null
    for ($i = 0; $i -lt 50 -and -not $w; $i++) {
        Start-Sleep -Milliseconds 200
        $w = $AT::RootElement.FindFirst($TS::Children, (New-Object System.Windows.Automation.PropertyCondition($AT::ProcessIdProperty, $p.Id)))
    }
    if (-not $w) { throw 'window did not open' }
    WaitStatus $w '*applications detected' | Out-Null # app detection must not overwrite the analyze status later
    return $p, $w
}
function Analyze($w) { Tab $w 'Cleaner'; Click $w 'analyze'; WaitStatus $w 'Analysis complete*' }

Start-ScreenPin -Screen $Screen -Exe $exe
$p = $null
try {
    $p, $w = Open
    Tab $w 'Options'
    SetText $w 'incPath' 'C:\'
    Click $w 'incAdd'
    $rej = (ById $w 'incStatus').Current.Name
    Write-Host "reject C:\ : $rej"
    SetText $w 'incPath' $fx
    Click $w 'incAdd'
    $inc = ListItems $w 'incList'
    Write-Host "include list: $inc"
    Shot $w 'options-incexc'
    $a1 = Analyze $w
    Write-Host "with include: $a1"

    Tab $w 'Options'
    SetText $w 'excPath' (Join-Path $fx 'private')
    Click $w 'excAdd'
    $a2 = Analyze $w
    Write-Host "with exclude: $a2"
    Shot $w 'cleaner-incexc'
    $w.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $p.WaitForExit(5000) | Out-Null

    $p, $w = Open
    Tab $w 'Options'
    $inc2 = ListItems $w 'incList'; $exc2 = ListItems $w 'excList'
    $a3 = Analyze $w
    Write-Host "after restart: include=$inc2 exclude=$exc2 analyze=$a3"
    $w.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $p.WaitForExit(5000) | Out-Null
    $saved = Get-Content $ini
    $left = @(Get-ChildItem $fx -Recurse -File).Count

    if ($rej -notlike '*drive*' -or $a1 -notlike '*: 3 files*' -or $a2 -notlike '*: 2 files*' -or $a3 -notlike '*: 2 files*' `
        -or $inc2.Count -ne 1 -or $exc2.Count -ne 1 -or -not ($saved -contains 'Temporary Files=False') `
        -or -not ($saved -contains 'Custom Files and Folders=True') -or $left -ne 3) { throw 'SMOKE FAILED' }
    Write-Host 'SMOKE OK (analyze only, nothing deleted)'
} finally {
    Stop-ScreenPin
    if ($p -and -not $p.HasExited) { $p.Kill() }
    Remove-Item -Recurse -Force $fx -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $bin 'portable.dat'), $ini -ErrorAction SilentlyContinue
}
