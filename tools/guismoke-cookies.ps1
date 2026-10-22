# GUI smoke for the cookie keep-list: TEMP/LOCALAPPDATA/APPDATA point at a fixture with real cookie databases of a
# fake Chrome and Firefox (built with Python's sqlite3), so the real browsers are never seen. Checks Options > Cookies
# lists, then Analyze and Run Cleaner ON THE FIXTURE: kept domains must survive, the rest must go.
# If a real Chrome/Firefox is running, Clean would ask to close it, so the smoke stops after Analyze (never answers).
# Windows-tab rules are all off via the ini. UI Automation, no keystrokes. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$Config = 'Debug', [string]$BinDir = '', [string]$ShotDir = $env:TEMP)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = if ($BinDir) { $BinDir } else { Join-Path $root "src\MakeCleaner\bin\$Config\net10.0-windows" } # -BinDir: a published copy (tools\releasecheck.ps1)
$exe = Join-Path $bin 'MakeCleaner.exe'
. (Join-Path $PSScriptRoot 'screenpin.ps1')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
$AT = [System.Windows.Automation.AutomationElement]
$Desc = [System.Windows.Automation.TreeScope]::Descendants

$fx = Join-Path ([IO.Path]::GetTempPath()) ('mc-cookies-smoke-' + [guid]::NewGuid().ToString('N'))
$chrome = Join-Path $fx 'Local\Google\Chrome\User Data\Default'
$firefox = Join-Path $fx 'Roaming\Mozilla\Firefox\Profiles\abc.default'
New-Item -ItemType Directory -Force (Join-Path $chrome 'Network'), $firefox, (Join-Path $fx 'Temp') | Out-Null
[IO.File]::WriteAllText((Join-Path $chrome 'Preferences'), '{}')
[IO.File]::WriteAllText((Join-Path $fx 'Roaming\Mozilla\Firefox\profiles.ini'), "[Profile0]`r`nName=default`r`nIsRelative=1`r`nPath=Profiles/abc.default`r`n")
$py = @'
import sqlite3, sys
def make(path, table, col, hosts):
    c = sqlite3.connect(path); c.execute(f"CREATE TABLE {table}({col} TEXT)")
    c.executemany(f"INSERT INTO {table} VALUES(?)", [(h,) for h in hosts]); c.commit(); c.close()
make(sys.argv[1], "cookies", "host_key", [".example.com", "www.example.com", ".tracker.net", "ads.tracker.net"])
make(sys.argv[2], "moz_cookies", "host", [".example.com", ".spam.org"])
'@
# PS 5.1 mangles quotes in native arguments, so the Python goes through a file (outside the fixture tree)
$pyDir = Join-Path ([IO.Path]::GetTempPath()) ('mc-cookies-py-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $pyDir | Out-Null
[IO.File]::WriteAllText((Join-Path $pyDir 'make.py'), $py)
& python -I (Join-Path $pyDir 'make.py') (Join-Path $chrome 'Network\Cookies') (Join-Path $firefox 'cookies.sqlite')
if ($LASTEXITCODE -ne 0) { throw 'could not build fixture databases (python sqlite3)' }
[IO.File]::WriteAllText((Join-Path $pyDir 'hosts.py'), 'import sqlite3, sys; print(";".join(sorted(r[0] for r in sqlite3.connect(sys.argv[1]).execute("SELECT " + sys.argv[3] + " FROM " + sys.argv[2]))))')
function Hosts($db, $table, $col) { (& python -I (Join-Path $pyDir 'hosts.py') $db $table $col).Trim() }

Set-Content (Join-Path $bin 'portable.dat') '#PORTABLE#'
$names = Select-String -Path (Join-Path $root 'src\MakeCleaner.Core\rules\Windows.ini') -Pattern '^\[(.+)\]$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
Set-Content (Join-Path $bin 'MakeCleaner.ini') (@('[Options]', 'Custom Files and Folders=False', 'KeepCookie1=example.com') + ($names | ForEach-Object { "$_=False" }))

function Find($w, $prop, $val) { $w.FindFirst($Desc, (New-Object System.Windows.Automation.PropertyCondition($prop, $val))) }
function Id($w, $id) { Find $w $AT::AutomationIdProperty $id }
function Tab($w, $name) {
    $c = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AT::NameProperty, $name)),
        (New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)))
    $w.FindFirst($Desc, $c).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
}
function Click($w, $id) { (Id $w $id).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
function WaitText($w, $id, $pattern) { for ($i = 0; $i -lt 100; $i++) { $s = (Id $w $id).Current.Name; if ($s -like $pattern) { return $s }; Start-Sleep -Milliseconds 200 }; throw "timeout waiting for '$pattern' in $id, last: $s" }
function Items($w, $id) { @((Id $w $id).FindAll([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem))) | ForEach-Object { $_.Current.Name }) }
function Shot($w, $name) {
    $r = $w.Current.BoundingRectangle
    $bmp = New-Object System.Drawing.Bitmap ([int]$r.Width), ([int]$r.Height)
    [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bmp.Size)
    $path = Join-Path $ShotDir "makecleaner-$name.png"; $bmp.Save($path); Write-Host "screenshot: $path"
}

$realBrowser = @(Get-Process chrome, firefox -ErrorAction SilentlyContinue).Count -gt 0
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
    WaitText $w 'status' '*applications detected' | Out-Null

    Tab $w 'Options'
    $scan = WaitText $w 'cookieStatus' '*domains with cookies*'
    $all = (Items $w 'cookieAll') -join ';'
    $keep = (Items $w 'cookieKeep') -join ';'
    Write-Host "options: $scan | on computer: $all | keep: $keep"
    (Id $w 'cookieKeep').SetFocus() # WinForms scrolls the focused control into view (focus only, no keystrokes)
    Start-Sleep -Milliseconds 300
    Shot $w 'options-cookies'
    # move spam.org to the keep-list with the Keep > button (selection via UIA, no keystrokes)
    $spam = (Id $w 'cookieAll').FindFirst([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition($AT::NameProperty, 'spam.org')))
    $spam.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Click $w 'cookieToKeep'
    $keep2 = (Items $w 'cookieKeep') -join ';'
    $all2 = (Items $w 'cookieAll') -join ';'
    Write-Host "after Keep >: on computer: $all2 | keep: $keep2"

    Tab $w 'Cleaner'
    Click $w 'analyze'
    $a = WaitText $w 'status' 'Analysis complete*'
    Write-Host "analyze: $a"
    $okLists = ($all -eq 'ads.tracker.net;spam.org;tracker.net') -and ($keep -eq 'example.com') -and
               ($keep2 -eq 'example.com;spam.org') -and ($all2 -eq 'ads.tracker.net;tracker.net') -and ($a -like '*, 2 browser entries*')

    if ($realBrowser) {
        Write-Host 'real Chrome/Firefox is running: skipping Run Cleaner (it would ask to close them)'
        $okClean = $true
    } else {
        Click $w 'clean'
        $c = WaitText $w 'status' 'Cleaning complete*'
        Write-Host "clean: $c"
        $chromeLeft = Hosts (Join-Path $chrome 'Network\Cookies') 'cookies' 'host_key'
        $firefoxLeft = Hosts (Join-Path $firefox 'cookies.sqlite') 'moz_cookies' 'host'
        Write-Host "left: chrome=$chromeLeft firefox=$firefoxLeft"
        $okClean = ($c -like '*2 browser entries removed*') -and ($chromeLeft -eq '.example.com;www.example.com') -and ($firefoxLeft -eq '.example.com;.spam.org')
    }
    $w.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $p.WaitForExit(5000) | Out-Null
    if (-not ($okLists -and $okClean)) { throw 'SMOKE FAILED' }
    Write-Host 'SMOKE OK'
} finally {
    Stop-ScreenPin
    if (-not $p.HasExited) { $p.Kill() }
    Remove-Item -Recurse -Force $fx, $pyDir -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $bin 'portable.dat'), (Join-Path $bin 'MakeCleaner.ini') -ErrorAction SilentlyContinue
}
