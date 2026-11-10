# MC-G2 GUI exercise (pure ASCII): Tools + Options pages of MakeCleaner in a sandbox.
#   zig build; powershell -ExecutionPolicy Bypass -File tools\mc-g2-gui-test.ps1  -> 'MC-G2 GUI OK' + zig-out\shots\MC-G2-*.png
# Sandbox: copy of the exe in %TEMP%\makecleaner-test-<rand>, portable.dat, every rule unticked,
# TEMP/TMP/APPDATA/LOCALAPPDATA = fixture dirs. Only fixture files are deleted.
param([string]$Bin = (Join-Path $PSScriptRoot '..\zig-out\bin'), [string]$Shots = (Join-Path $PSScriptRoot '..\zig-out\shots'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot '..\..\MakeKit\tools\imgui-auto.ps1')

$root = Join-Path $env:TEMP ('makecleaner-test-mcg2-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$appDir = Join-Path $root 'app'
New-Item -ItemType Directory -Force $appDir | Out-Null
Copy-Item (Join-Path $Bin 'MakeCleaner.exe') $appDir
Copy-Item (Join-Path $Bin 'rules') $appDir -Recurse
[IO.File]::WriteAllText((Join-Path $appDir 'portable.dat'), '#PORTABLE#')
$ini = New-Object System.Text.StringBuilder
[void]$ini.Append("[Options]`r`n")
foreach ($l in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot '..\rules\Windows.ini'))) {
    $t = $l.Trim(); if ($t -match '^\[(.+)\]$') { [void]$ini.Append("$($Matches[1])=False`r`n") }
}
foreach ($b in 'Google Chrome', 'Microsoft Edge', 'Brave', 'Vivaldi', 'Opera', 'Opera GX', 'Arc', 'Mozilla Firefox') {
    foreach ($i in 'Internet Cache', 'Internet History', 'Download History', 'Last Download Location', 'Session', 'Saved Form Information', 'Saved Passwords', 'Compact Databases', 'Cookies') {
        [void]$ini.Append("${b}: $i=False`r`n")
    }
}
[void]$ini.Append("Custom Files and Folders=False`r`n")
[IO.File]::WriteAllText((Join-Path $appDir 'MakeCleaner.ini'), $ini.ToString())

$fx = @{}
foreach ($d in 'temp', 'appdata', 'localappdata', 'dups', 'dups\sub', 'inc', 'disk') { $p = Join-Path $root $d; New-Item -ItemType Directory -Force $p | Out-Null; $fx[$d] = $p }
$big = 'x' * 50000
foreach ($f in 'dups\a.txt', 'dups\sub\a.txt', 'dups\b.log', 'dups\sub\b.log', 'disk\one.txt', 'disk\two.jpg', 'disk\three.zip') {
    [IO.File]::WriteAllText((Join-Path $root $f), $big)
    (Get-Item (Join-Path $root $f)).LastWriteTime = [datetime]'2026-01-02 03:04:05'
}
New-Item -ItemType Directory -Force $Shots | Out-Null

$app = Start-AutoApp -Exe (Join-Path $appDir 'MakeCleaner.exe') -Env @{ TEMP = $fx['temp']; TMP = $fx['temp']; APPDATA = $fx['appdata']; LOCALAPPDATA = $fx['localappdata'] }
Write-Host "pid $($app.Process.Id) sandbox $root"
$shotList = @()
function Shot([string]$name) {
    $null = Invoke-AutoFrames $app 3
    $bmp = Join-Path $root "$name.bmp"
    $null = Save-AutoScreenshot $app $bmp
    $script:shotList += $bmp
}
function Click([string]$l) { Invoke-AutoClick $app $l }
function Items { @(Get-AutoItems $app) }
# Polls until an item whose label ends with $suffix has a label matching $pattern.
function WaitText([string]$suffix, [string]$pattern, [int]$ms = 10000) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ($true) {
        $it = @(Items | Where-Object { $_.label.EndsWith($suffix) })
        if ($it.Count -gt 0 -and $it[0].label -match $pattern) { return $it[0].label }
        if ((Get-Date) -gt $deadline) { throw "timeout: $suffix !~ $pattern (got: $(if ($it.Count) { $it[0].label } else { 'none' }))" }
        $null = Invoke-AutoFrames $app 2
        Start-Sleep -Milliseconds 100
    }
}
function SetText([string]$l, [string]$text) {
    Click $l; Invoke-AutoKey $app 'ctrl+A'; Invoke-AutoKey $app 'Delete'
    if ($text.Length -gt 0) { Invoke-AutoType $app $text }
    Invoke-AutoKey $app 'Tab'
}
function Check([bool]$cond, [string]$what) { if (-not $cond) { throw "CHECK FAILED: $what" }; Write-Host "ok  $what" }

$ok = $false
try {
    Click 'Tools'
    # ---- Uninstall
    $c = WaitText '##uninstallCount' '^\d+ programs##' 15000
    Write-Host "uninstall: $c"
    Shot 'MC-G2-uninstall'
    $before = [int]($c -replace ' programs.*', '')
    SetText '##uninstallSearch' 'Microsoft'
    $c2 = WaitText '##uninstallCount' '^\d+ programs##'
    Check ([int]($c2 -replace ' programs.*', '') -le $before) "search filters ($c2)"
    $row = @(Items | Where-Object { $_.label -match '##u\d+$' -and $_.visible })[0]
    Click $row.label
    Check (-not (@(Items | Where-Object { $_.label -eq 'Delete entry##uninstallDelete' })[0].disabled)) 'Delete entry enabled after select'
    Click 'Delete entry##uninstallDelete'
    $null = Wait-AutoItem $app 'Cancel' 3000
    Shot 'MC-G2-uninstall-confirm'
    Click 'Cancel'
    SetText '##uninstallSearch' ''

    # ---- Startup
    Click 'Startup##toolsNav1'
    $null = Wait-AutoItem $app '##st0_0' 20000
    Shot 'MC-G2-startup'
    Click 'Windows Services##startupServices'
    $null = Invoke-AutoFrames $app 3
    $svc = @(Items | Where-Object { $_.label -match '##st3_\d+$' -and $_.visible })
    Write-Host "services rows visible: $($svc.Count)"
    if ($svc.Count) { Click $svc[0].label }
    Shot 'MC-G2-startup-services'
    Click 'Windows##startupWindows'
    Click '##st0_0'
    Click 'Delete##startupDelete'
    $null = Wait-AutoItem $app 'Cancel' 3000
    Shot 'MC-G2-startup-confirm'
    Click 'Cancel'

    # ---- Duplicate Finder
    Click 'Duplicate Finder##toolsNav2'
    $null = Wait-AutoItem $app '##dupInclude' 3000
    Shot 'MC-G2-dup-setup'
    # cancel path on a big read-only tree
    SetText '##dupInclude' 'C:\Windows'
    SetText '##dupExclude' ''
    Click 'Search##dupSearch'
    $null = Wait-AutoItem $app 'Cancel##dupSearch' 3000
    $null = WaitText '##dupStatus' '^Scanning\.\.\. [\d,]+ files' 10000
    Shot 'MC-G2-dup-scanning'
    Click 'Cancel##dupSearch'
    $null = WaitText '##dupStatus' '^Cancelled##' 15000
    SetText '##dupInclude' $fx['dups']
    Click 'Search##dupSearch'
    $st = WaitText '##dupStatus' '^Found ' 15000
    Write-Host "dup: $st"
    Check ($st -like 'Found 2 duplicate groups, 4 files*') 'two duplicate groups'
    Click 'Select all but first##dupSelect'
    Shot 'MC-G2-dup-results'
    Click 'Delete Selected##dupDelete'
    $null = Wait-AutoItem $app 'Cancel' 3000
    Shot 'MC-G2-dup-confirm'
    Click 'Delete'
    $st = WaitText '##dupStatus' '^Deleted '
    Write-Host "dup delete: $st"
    Check ($st -like 'Deleted 2 files*') 'deleted 2 fixture files'
    Check (@(Get-ChildItem $fx['dups'] -Recurse -File).Count -eq 2) 'two fixture files remain on disk'
    Click 'Back##dupBack'

    # ---- Disk Analyzer
    Click 'Disk Analyzer##toolsNav3'
    $null = Wait-AutoItem $app '##daRoots' 3000
    Shot 'MC-G2-disk-default'
    Click 'Analyze##daScan'
    $null = Wait-AutoItem $app 'Cancel##daScan' 3000
    Start-Sleep -Milliseconds 700
    Click 'Cancel##daScan'
    $null = WaitText '##daStatus' '^Cancelled##' 20000
    SetText '##daRoots' $fx['disk']
    Click 'Analyze##daScan'
    $st = WaitText '##daStatus' '^Analysis complete' 15000
    Write-Host "disk: $st"
    Check ($st -like 'Analysis complete: 3 files*') 'three fixture files analyzed'
    Click 'Pictures##daCat0'
    $null = Wait-AutoItem $app 'two.jpg##daFile0' 3000
    Click 'two.jpg##daFile0'
    Shot 'MC-G2-disk'
    Click 'Delete Selected##daDelete'
    $null = Wait-AutoItem $app 'Cancel' 3000
    Click 'Delete'
    $st = WaitText '##daStatus' '^Deleted '
    Check ($st -like 'Deleted 1 files*') "disk delete ($st)"
    Check (-not (Test-Path (Join-Path $fx['disk'] 'two.jpg'))) 'two.jpg gone'

    # ---- Drive Wiper (no wipe is started)
    Click 'Drive Wiper##toolsNav4'
    $null = Wait-AutoItem $app '##wipeMode' 3000
    Click 'Wipe##wipe'
    $null = WaitText '##wipeProgress' '^Select at least one drive\.##'
    Click '##wipeMode'
    Click '##wipeMode1'
    Click '##drive0'
    $w = WaitText '##wipeWarning' '^WARNING: Entire Drive'
    Shot 'MC-G2-wiper'
    Click '##drive0'
    Click '##wipeMode'
    Click '##wipeMode0'
    $null = WaitText '##wipeWarning' '^##wipeWarning$'

    # ---- System Restore
    Click 'System Restore##toolsNav5'
    $st = WaitText '##rpStatus' '(restore point|Administrator|unavailable|No restore)' 20000
    Write-Host "restore: $st"
    Shot 'MC-G2-restore'

    # ---- Options
    Click 'Options'
    $null = Wait-AutoItem $app '##secureDelete' 3000
    Click '##secureDelete'
    Click '##secureDelete2'
    Click '##TempOlderThan24h'
    Shot 'MC-G2-options-settings'
    $iniText = [IO.File]::ReadAllText((Join-Path $appDir 'MakeCleaner.ini'))
    Check ($iniText -match 'SecureDeletePasses=3') 'secure delete saved'
    Check ($iniText -match 'TempOlderThan24h=True') 'TempOlderThan24h saved'

    Click 'Include##optionsNav1'
    SetText '##incPath' 'C:\Windows'
    Click 'Add##incAdd'
    $null = WaitText '##incStatus' '^The Windows folder is protected\.##'
    SetText '##incAge' '48'
    SetText '##incPath' $fx['inc']
    Click 'Add##incAdd'
    $null = WaitText '##incStatus' '^Added\. Tick'
    $e = (Wait-AutoItem $app '##inc0' 3000).label
    Write-Host "include entry: $e"
    Check ($e -like '*\inc|`*.`*|RECURSE|OLDER=48##inc0') 'include entry format'
    Shot 'MC-G2-options-include'
    Click '##inc0'; Click 'Remove##incRemove'
    $null = Invoke-AutoFrames $app 3
    Check (@(Items | Where-Object { $_.label -like '*##inc0' }).Count -eq 0) 'include removed'

    Click 'Exclude##optionsNav2'
    SetText '##excPath' $fx['inc']
    Click 'Add##excAdd'
    $null = WaitText '##excStatus' '^Added\.'
    Click '##excKind'; Click '##excKind2'
    SetText '##excPath' 'HKCU\Software\MakeCleanerTestKey'
    Click 'Add##excAdd'
    $e1 = (Wait-AutoItem $app '##exc1' 3000).label
    Check ($e1 -like 'REG|HKCU\Software\MakeCleanerTestKey##exc1') "registry exclude ($e1)"
    Shot 'MC-G2-options-exclude'
    Click '##exc0'; Click 'Remove##excRemove'

    Click 'Cookies##optionsNav3'
    $null = WaitText '##cookieStatus' 'domains with cookies' 20000
    SetText '##cookieDomain' 'www.Example.com'
    Click 'Add##cookieAdd'
    $null = WaitText '##cookieStatus' '^Keeping cookies of example\.com'
    $null = Wait-AutoItem $app 'example.com##ck0' 3000
    SetText '##cookieDomain' 'nodot'
    Click 'Add##cookieAdd'
    $null = WaitText '##cookieStatus' '^Enter a domain like'
    Shot 'MC-G2-options-cookies'
    Check ([IO.File]::ReadAllText((Join-Path $appDir 'MakeCleaner.ini')) -match 'KeepCookie1=example.com') 'keep-list saved'

    Click 'Schedule##optionsNav4'
    $st = WaitText '##schedStatus' '(Scheduled cleaning|No scheduled)' 10000
    Write-Host "schedule: $st"
    SetText '##schedAt' 'bad'
    Click 'Create task##schedCreate'
    $null = WaitText '##schedStatus' '^Start time format: yyyy-MM-dd HH:mm##'
    Shot 'MC-G2-options-schedule'

    Click 'About##optionsNav5'
    Shot 'MC-G2-options-about'
    $ok = $true
} finally {
    $code = Stop-AutoApp $app
    Write-Host "exit code $code"
    foreach ($b in $shotList) {
        $png = Join-Path $Shots ([IO.Path]::GetFileNameWithoutExtension($b) + '.png')
        & py -3.10 -c "import sys; from PIL import Image; Image.open(sys.argv[1]).save(sys.argv[2])" $b $png
    }
    Remove-Item -Recurse -Force $root
    Write-Host "sandbox removed"
}
if ($ok) { Write-Host 'MC-G2 GUI OK' } else { Write-Host 'MC-G2 GUI FAILED'; exit 1 }
