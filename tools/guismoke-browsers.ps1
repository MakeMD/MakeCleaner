# GUI smoke for the Browsers tab: TEMP/LOCALAPPDATA/APPDATA point at a fixture with a fake Chrome and Firefox,
# so the real browsers are never seen. Opens Cleaner > Browsers, clicks Analyze ONLY (never Run Cleaner),
# checks the fixture is untouched and Winapp2 Chrome sections are hidden. UI Automation, no keystrokes. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$Config = 'Debug', [string]$Shot = "$env:TEMP\makecleaner-browsers-smoke.png")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root "src\MakeCleaner\bin\$Config\net10.0-windows"
$exe = Join-Path $bin 'MakeCleaner.exe'
. (Join-Path $PSScriptRoot 'screenpin.ps1')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
$AT = [System.Windows.Automation.AutomationElement]
$Desc = [System.Windows.Automation.TreeScope]::Descendants

$fx = Join-Path ([IO.Path]::GetTempPath()) ('mc-browsers-smoke-' + [guid]::NewGuid().ToString('N'))
$files = @(
    'Local\Google\Chrome\User Data\Default\Preferences',
    'Local\Google\Chrome\User Data\Default\Cache\Cache_Data\data_0',
    'Local\Google\Chrome\User Data\Default\Cache\Cache_Data\data_1',
    'Local\Google\Chrome\User Data\Default\Network\Cookies',
    'Roaming\Mozilla\Firefox\Profiles\abc.default\cookies.sqlite',
    'Local\Mozilla\Firefox\Profiles\abc.default\cache2\entries\E1',
    'Temp\keep.txt'
)
foreach ($rel in $files) {
    $p = Join-Path $fx $rel
    New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
    [IO.File]::WriteAllText($p, '{}')
}
[IO.File]::WriteAllText((Join-Path $fx 'Roaming\Mozilla\Firefox\profiles.ini'), "[Profile0]`r`nName=default`r`nIsRelative=1`r`nPath=Profiles/abc.default`r`n")
$before = @(Get-ChildItem $fx -Recurse -File).Count
Set-Content (Join-Path $bin 'portable.dat') '#PORTABLE#'
# Windows-tab rules default on would scan real user data: turn all off except Temporary Files.
$names = Select-String -Path (Join-Path $root 'src\MakeCleaner\rules\Windows.ini') -Pattern '^\[(.+)\]$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
Set-Content (Join-Path $bin 'MakeCleaner.ini') (@('[Options]', 'Custom Files and Folders=False') + ($names | ForEach-Object { "$_=" + ($_ -eq 'Temporary Files') }))

function Find($w, $prop, $val) { $w.FindFirst($Desc, (New-Object System.Windows.Automation.PropertyCondition($prop, $val))) }
function Tab($w, $name) {
    $c = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AT::NameProperty, $name)),
        (New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)))
    $w.FindFirst($Desc, $c).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
}
function Status($w) { (Find $w $AT::AutomationIdProperty 'status').Current.Name }
function WaitStatus($w, $prefix) { for ($i = 0; $i -lt 100; $i++) { $s = Status $w; if ($s -like "$prefix*") { return $s }; Start-Sleep -Milliseconds 200 }; throw "timeout waiting for '$prefix', last: $s" }
function Nodes($w, $id) {
    $t = Find $w $AT::AutomationIdProperty $id
    $t.FindAll([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, [System.Windows.Automation.ControlType]::TreeItem))) | ForEach-Object { $_.Current.Name }
}

Start-ScreenPin -Screen $Screen -Exe $exe
$old = $env:TEMP, $env:LOCALAPPDATA, $env:APPDATA
$env:TEMP = Join-Path $fx 'Temp'; $env:LOCALAPPDATA = Join-Path $fx 'Local'; $env:APPDATA = Join-Path $fx 'Roaming'
$p = Start-Process $exe -PassThru
$env:TEMP, $env:LOCALAPPDATA, $env:APPDATA = $old
try {
    $w = $null
    for ($i = 0; $i -lt 50 -and -not $w; $i++) {
        Start-Sleep -Milliseconds 200
        $w = $AT::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition($AT::ProcessIdProperty, $p.Id)))
    }
    if (-not $w) { throw 'window did not open' }
    WaitStatus $w '*applications detected' | Out-Null
    Tab $w 'Applications'
    $appGroups = @(Nodes $w 'apps')
    Tab $w 'Browsers'
    $browserGroups = @(Nodes $w 'browsers')
    Write-Host ("browsers tab: " + ($browserGroups -join ', '))
    Write-Host ("applications groups: " + ($appGroups -join ', '))
    (Find $w $AT::AutomationIdProperty 'analyze').GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $a = WaitStatus $w 'Analysis complete'
    Write-Host "analyze: $a"
    $r = $w.Current.BoundingRectangle
    $bmp = New-Object System.Drawing.Bitmap ([int]$r.Width), ([int]$r.Height)
    [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bmp.Size)
    $bmp.Save($Shot); Write-Host "screenshot: $Shot"
    $w.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $p.WaitForExit(5000) | Out-Null
    $after = @(Get-ChildItem $fx -Recurse -File).Count
    # Temp keep.txt + 2 Chrome cache + Firefox cache = 4 files (cookies are rows now; see guismoke-cookies.ps1)
    $ok = ($browserGroups -contains 'Google Chrome') -and ($browserGroups -contains 'Mozilla Firefox') -and
          -not ($appGroups -contains 'Google Chrome Web Browser') -and ($a -like '*: 4 files*') -and ($after -eq $before)
    if (-not $ok) { throw "SMOKE FAILED (fixture files $before -> $after)" }
    Write-Host 'SMOKE OK (analyze only, nothing deleted)'
} finally {
    Stop-ScreenPin
    if (-not $p.HasExited) { $p.Kill() }
    Remove-Item -Recurse -Force $fx -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $bin 'portable.dat'), (Join-Path $bin 'MakeCleaner.ini') -ErrorAction SilentlyContinue
}
