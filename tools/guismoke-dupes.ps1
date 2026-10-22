# GUI smoke for Tools: Duplicate Finder + Disk Analyzer on a small fixture folder, plus cancel of a
# full-drive Disk Analyzer scan (read-only). Never deletes anything. UI Automation only, no keystrokes.
# Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$Config = 'Debug', [string]$BinDir = '', [string]$ShotDir = $env:TEMP)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = if ($BinDir) { $BinDir } else { Join-Path $root "src\MakeCleaner\bin\$Config\net10.0-windows" } # -BinDir: a published copy (tools\releasecheck.ps1)
$exe = Join-Path $bin 'MakeCleaner.exe'
. (Join-Path $PSScriptRoot 'screenpin.ps1')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
$AT = [System.Windows.Automation.AutomationElement]
$Desc = [System.Windows.Automation.TreeScope]::Descendants

$fx = Join-Path ([IO.Path]::GetTempPath()) ('mc-tools-smoke-' + [guid]::NewGuid().ToString('N'))
$t = [datetime]'2024-01-02 03:04:05'
foreach ($rel in 'a\photo.jpg', 'b\photo.jpg', 'a\song.mp3', 'b\song.mp3', 'a\notes.txt', 'a\other.xyz') {
    $p = Join-Path $fx $rel
    New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
    [IO.File]::WriteAllBytes($p, (New-Object byte[] 2048))
    (Get-Item $p).LastWriteTime = $t
}
$before = @(Get-ChildItem $fx -Recurse -File).Count
Set-Content (Join-Path $bin 'portable.dat') '#PORTABLE#'

function Find($w, $prop, $val) { $w.FindFirst($Desc, (New-Object System.Windows.Automation.PropertyCondition($prop, $val))) }
function Id($w, $id) { Find $w $AT::AutomationIdProperty $id }
function Tab($w, $name) {
    $c = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AT::NameProperty, $name)),
        (New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)))
    $w.FindFirst($Desc, $c).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
}
function Click($w, $id) { (Id $w $id).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
function SetText($w, $id, $v) { (Id $w $id).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($v) }
function WaitText($w, $id, $prefix, $tries = 100) { for ($i = 0; $i -lt $tries; $i++) { $s = (Id $w $id).Current.Name; if ($s -like "$prefix*") { return $s }; Start-Sleep -Milliseconds 200 }; throw "timeout waiting for '$prefix' in $id, last: $s" }
function Shot($w, $name) {
    $r = $w.Current.BoundingRectangle
    $bmp = New-Object System.Drawing.Bitmap ([int]$r.Width), ([int]$r.Height)
    [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bmp.Size)
    $path = Join-Path $ShotDir $name; $bmp.Save($path); Write-Host "screenshot: $path"
}

Start-ScreenPin -Screen $Screen -Exe $exe
$p = Start-Process $exe -PassThru
try {
    $w = $null
    for ($i = 0; $i -lt 50 -and -not $w; $i++) {
        Start-Sleep -Milliseconds 200
        $w = $AT::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition($AT::ProcessIdProperty, $p.Id)))
    }
    if (-not $w) { throw 'window did not open' }

    Tab $w 'Tools'
    Tab $w 'Duplicate Finder'
    SetText $w 'dupInclude' $fx
    Click $w 'dupSearch'
    $d = WaitText $w 'dupStatus' 'Found'
    Write-Host "duplicates: $d"
    Shot $w 'makecleaner-smoke-dupes.png'

    Tab $w 'Disk Analyzer'
    SetText $w 'daRoots' $fx
    Click $w 'daScan'
    $a = WaitText $w 'daStatus' 'Analysis complete'
    Write-Host "disk analyzer: $a"
    Shot $w 'makecleaner-smoke-disk.png'

    # cancel: start a full scan of the system drive, cancel it, UI must answer right away
    SetText $w 'daRoots' $env:SystemDrive\
    Click $w 'daScan'
    Start-Sleep -Milliseconds 700
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Click $w 'daScan'
    $c = WaitText $w 'daStatus' 'Cancelled' 50
    Write-Host ("cancel: $c in {0} ms" -f $sw.ElapsedMilliseconds)

    $w.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $p.WaitForExit(5000) | Out-Null
    $after = @(Get-ChildItem $fx -Recurse -File).Count
    if ($d -notlike 'Found 2 duplicate groups, 4 files*' -or $a -notlike '*6 files*' -or $after -ne $before) { throw 'SMOKE FAILED' }
    Write-Host 'SMOKE OK'
} finally {
    Stop-ScreenPin
    if (-not $p.HasExited) { $p.Kill() }
    Remove-Item -Recurse -Force $fx -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $bin 'portable.dat'), (Join-Path $bin 'MakeCleaner.ini') -ErrorAction SilentlyContinue
}
