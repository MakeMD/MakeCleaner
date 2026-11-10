# GUI smoke for the cookie keep-list: sandbox copy (portable), TEMP/LOCALAPPDATA/APPDATA point at a fixture with real
# cookie databases of a fake Chrome and Firefox (built with py -3.12 sqlite3), so the real browsers are never seen.
# Checks Options > Cookies lists and Keep >, then Analyze and Run Cleaner ON THE FIXTURE: kept domains must survive,
# the rest must go. If a real Chrome/Firefox is running, Run Cleaner would ask to close it, so the smoke stops after
# Analyze (never answers). Every cleaner rule is off via the ini. MakeKit automation pipe. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$BinDir = '', [string]$ShotDir = $env:TEMP)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $BinDir) { $BinDir = Join-Path $root 'zig-out\bin' } # -BinDir: a published copy (tools\releasecheck.ps1)
. (Join-Path $PSScriptRoot 'mc-auto.ps1')

$sb = New-McSandbox $BinDir 'cookies'
$app = $null
try {
    $chrome = Join-Path $sb.Local 'Google\Chrome\User Data\Default'
    $firefox = Join-Path $sb.Roaming 'Mozilla\Firefox\Profiles\abc.default'
    New-Item -ItemType Directory -Force (Join-Path $chrome 'Network'), $firefox | Out-Null
    [IO.File]::WriteAllText((Join-Path $chrome 'Preferences'), '{}')
    [IO.File]::WriteAllText((Join-Path $sb.Roaming 'Mozilla\Firefox\profiles.ini'), "[Profile0]`r`nName=default`r`nIsRelative=1`r`nPath=Profiles/abc.default`r`n")
    # PS 5.1 mangles quotes in native arguments, so the Python goes through files (outside the fixture tree)
    $pyDir = Join-Path $sb.Root 'py'
    New-Item -ItemType Directory -Force $pyDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $pyDir 'make.py'), @'
import sqlite3, sys
def make(path, table, col, hosts):
    c = sqlite3.connect(path); c.execute(f"CREATE TABLE {table}({col} TEXT)")
    c.executemany(f"INSERT INTO {table} VALUES(?)", [(h,) for h in hosts]); c.commit(); c.close()
make(sys.argv[1], "cookies", "host_key", [".example.com", "www.example.com", ".tracker.net", "ads.tracker.net"])
make(sys.argv[2], "moz_cookies", "host", [".example.com", ".spam.org"])
'@)
    [IO.File]::WriteAllText((Join-Path $pyDir 'hosts.py'), 'import sqlite3, sys; print(";".join(sorted(r[0] for r in sqlite3.connect(sys.argv[1]).execute("SELECT " + sys.argv[3] + " FROM " + sys.argv[2]))))')
    & py -3.12 -I (Join-Path $pyDir 'make.py') (Join-Path $chrome 'Network\Cookies') (Join-Path $firefox 'cookies.sqlite')
    if ($LASTEXITCODE -ne 0) { throw 'could not build fixture databases (py -3.12 sqlite3)' }
    function Hosts($db, $table, $col) { (& py -3.12 -I (Join-Path $pyDir 'hosts.py') $db $table $col).Trim() }
    function Rows($kind) { @(Get-AutoItems $app | Where-Object { $_.label -match "##$kind\d+$" } | ForEach-Object { $_.label -replace '##[a-z]+\d+$', '' }) }

    Set-McIni $sb -Extra 'KeepCookie1=example.com' # browser items keep their defaults (fixture browsers only)
    $realBrowser = @(Get-Process chrome, firefox -ErrorAction SilentlyContinue).Count -gt 0

    $app = Start-McApp $sb -Screen $Screen
    $null = Wait-AutoLabel $app '*applications detected##status'
    Invoke-AutoClick $app 'Options'
    Invoke-AutoClick $app 'Cookies##optionsNav3'
    $scan = (Wait-AutoLabel $app '*domains with cookies*##cookieStatus').label
    $all = (Rows 'ca') -join ';'
    $keep = (Rows 'ck') -join ';'
    Write-Host "options: $scan | on computer: $all | keep: $keep"
    Save-McShot $app (Join-Path $ShotDir 'makecleaner-options-cookies.png')
    # move spam.org to the keep-list with the Keep > button
    $spam = @(Get-AutoItems $app | Where-Object { $_.label -match '^spam\.org##ca\d+$' })
    if ($spam.Count -eq 1) { Invoke-AutoClick $app $spam[0].label }
    Invoke-AutoClick $app 'Keep >##cookieToKeep'
    $null = Invoke-AutoFrames $app 3
    $keep2 = (Rows 'ck') -join ';'
    $all2 = (Rows 'ca') -join ';'
    Write-Host "after Keep >: on computer: $all2 | keep: $keep2"

    Invoke-AutoClick $app 'Cleaner'
    Invoke-AutoClick $app 'Analyze##analyze'
    $a = (Wait-AutoLabel $app 'Analysis complete*##status').label
    Write-Host "analyze: $a"
    $okLists = ($all -eq 'ads.tracker.net;spam.org;tracker.net') -and ($keep -eq 'example.com') -and
               ($keep2 -eq 'example.com;spam.org') -and ($all2 -eq 'ads.tracker.net;tracker.net') -and ($a -like '*, 2 browser entries*')

    if ($realBrowser) {
        Write-Host 'real Chrome/Firefox is running: skipping Run Cleaner (it would ask to close them)'
        $okClean = $true
    } else {
        Invoke-AutoClick $app 'Run Cleaner##clean'
        $c = (Wait-AutoLabel $app 'Cleaning complete*##status').label
        Write-Host "clean: $c"
        $chromeLeft = Hosts (Join-Path $chrome 'Network\Cookies') 'cookies' 'host_key'
        $firefoxLeft = Hosts (Join-Path $firefox 'cookies.sqlite') 'moz_cookies' 'host'
        Write-Host "left: chrome=$chromeLeft firefox=$firefoxLeft"
        $okClean = ($c -like '*2 browser entries removed*') -and ($chromeLeft -eq '.example.com;www.example.com') -and ($firefoxLeft -eq '.example.com;.spam.org')
    }
    $code = Close-McApp $app
    if (-not ($okLists -and $okClean) -or $code -ne 0) { throw 'SMOKE FAILED' }
    Write-Host 'SMOKE OK'
} finally {
    Remove-McSandbox $sb $app
}
