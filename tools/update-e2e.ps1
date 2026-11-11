# Update end-to-end on the REAL MakeCleaner.exe + MakeUpdate.exe (pure ASCII, PS 5.1). Never contacts GitHub and
# never runs a real installer: a fake GitHub (python http.server on 127.0.0.1, free port) serves a newer release
# v2.1.1 of MakeMD/MakeCleaner whose "setup" is MakeKit's tools\update-e2e-fake.zig (writes a marker file, installs
# nothing). The app runs in an mc-auto sandbox (%TEMP%\makecleaner-test-upd-*) WITHOUT portable.dat (installed mode,
# settings in the sandbox's fixture %AppData%), with fixture TEMP/LOCALAPPDATA and MAKEKIT_UPDATE_API = the fake.
#   1. banner appears; Update now -> app exits, MakeUpdate verifies SHA-256, runs the fake setup with the silent
#      switches after the app exited, relaunches the app, cleans its temp folder, logs to LOCALAPPDATA\MakeUpdate
#   2. Later hides the banner and skips 2.1.1 (UpdateSkip); the next daily check stays quiet; Options > About
#      "Check for updates" shows it again
#   3. MAKEKIT_NO_UPDATE=1: no banner, MakeUpdate never starts, no UpdateLastCheck
#   4. offline (server down): the check runs (UpdateLastCheck saved) and shows nothing
#   powershell -ExecutionPolicy Bypass -File tools\update-e2e.ps1 [-BinDir zig-out\bin] [-Screen 1]
param([int]$Screen = 1, [string]$BinDir = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
if (-not $BinDir) { $BinDir = Join-Path $root 'zig-out\bin' }
. (Join-Path $PSScriptRoot 'mc-auto.ps1')
$zig = Join-Path $env:LOCALAPPDATA 'Programs\zig\0.17.1\zig.exe'
$python = (& py -3.12 -c 'import sys; print(sys.executable)').Trim()
foreach ($f in 'MakeCleaner.exe', 'MakeUpdate.exe') { if (-not (Test-Path (Join-Path $BinDir $f))) { throw "$BinDir\$f not found - zig build first" } }

$latest = '2.1.1'
$setupName = "MakeCleaner-Setup-$latest.exe"
$work = Join-Path ([IO.Path]::GetTempPath()) ('makecleaner-test-upd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$srv = Join-Path $work 'srv'
$marks = Join-Path $work 'marks'
foreach ($d in $work, $srv, $marks, "$srv\dl", "$srv\repos\MakeMD\MakeCleaner\releases\tags") { $null = New-Item -ItemType Directory -Force $d }

$fail = @()
function Check($cond, [string]$what) { if ($cond) { Write-Host "  ok  $what" } else { Write-Host "  FAIL $what" -ForegroundColor Red; $script:fail += $what } }
function Write-Utf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false))) }
function Wait-Until([scriptblock]$Cond, [int]$Ms) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    while (-not (& $Cond)) { if ((Get-Date) -gt $deadline) { return $false }; Start-Sleep -Milliseconds 200 }
    $true
}

$sb = $null; $app = $null; $server = $null
# the user's real settings must come out untouched
$realIni = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'MakeCleaner\MakeCleaner.ini'
function RealIniHash { if (Test-Path $realIni) { (Get-FileHash $realIni).Hash } else { 'absent' } }
$realBefore = RealIniHash
$own = New-Object System.Collections.ArrayList   # extra processes of this run (relaunched app)
try {
    # ---- fake setup + fake GitHub
    Push-Location (Join-Path $root '..\MakeKit')
    try { & $zig build-exe tools\update-e2e-fake.zig -O ReleaseSmall "-femit-bin=$work\fake.exe" } finally { Pop-Location }
    if ($LASTEXITCODE) { throw "building the fake setup failed ($LASTEXITCODE)" }
    Remove-Item "$work\fake.pdb" -ErrorAction SilentlyContinue
    Copy-Item "$work\fake.exe" "$srv\dl\$setupName"
    $hash = (Get-FileHash "$srv\dl\$setupName" -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8 "$srv\dl\SHA256SUMS.txt" ("{0}  {1}`n{2}  MakeCleaner-$latest-portable.zip`n" -f $hash, $setupName, ('0' * 64))
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
    $base = "http://127.0.0.1:$port"
    $rel = ('{"tag_name":"vVER","html_url":"BASE/MakeMD/MakeCleaner/releases/tag/vVER","draft":false,"prerelease":false,"body":"Fake release for update-e2e","assets":[' +
        '{"name":"SETUP","browser_download_url":"BASE/dl/SETUP","size":SIZE},' +
        '{"name":"SHA256SUMS.txt","browser_download_url":"BASE/dl/SHA256SUMS.txt","size":200}]}').Replace('BASE', $base).Replace('VER', $latest).Replace('SETUP', $setupName).Replace('SIZE', "$((Get-Item "$srv\dl\$setupName").Length)")
    Write-Utf8 "$srv\repos\MakeMD\MakeCleaner\releases\latest" $rel
    Write-Utf8 "$srv\repos\MakeMD\MakeCleaner\releases\tags\v$latest" $rel
    $server = Start-Process -FilePath $python -ArgumentList @('-I', '-m', 'http.server', "$port", '--bind', '127.0.0.1', '--directory', $srv) `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput "$work\srv.out" -RedirectStandardError "$work\srv.err"
    $up = Wait-Until { $c = New-Object Net.Sockets.TcpClient; try { $c.Connect('127.0.0.1', $port); $true } catch { $false } finally { $c.Close() } } 15000
    if (-not $up) { throw "fake server did not start: $(Get-Content "$work\srv.err" -Raw)" }

    # ---- sandbox in installed mode (no portable.dat): settings in fixture %AppData%\MakeCleaner
    $sb = New-McSandbox -BinDir $BinDir -Tag 'upd'
    Remove-Item (Join-Path $sb.App 'portable.dat')
    # FOLDERID_RoamingAppData ignores %APPDATA%: MAKECLEANER_SETTINGS_DIR keeps the ini in the sandbox
    $ini = Join-Path $sb.Roaming 'MakeCleaner\MakeCleaner.ini'
    $log = Join-Path $sb.Local 'MakeUpdate\update.log'
    $updEnv = @{ MAKEKIT_NO_UPDATE = '0'; MAKEKIT_UPDATE_API = $base; MAKEUPDATE_E2E_DIR = $marks; MAKECLEANER_SETTINGS_DIR = (Split-Path $ini) }
    function IniValue([string]$Key) {
        if (-not (Test-Path $ini)) { return $null }
        foreach ($line in [IO.File]::ReadAllLines($ini)) { if ($line -like "$Key=*") { return $line.Substring($Key.Length + 1) } }
        $null
    }
    function Reset-Ini([string[]]$Keys) {
        if (-not (Test-Path $ini)) { return }
        $keep = @([IO.File]::ReadAllLines($ini) | Where-Object { $l = $_; -not ($Keys | Where-Object { $l -like "$_=*" }) })
        [IO.File]::WriteAllLines($ini, [string[]]$keep, (New-Object Text.UTF8Encoding($false)))
    }
    function Updaters { @(Get-Process MakeUpdate -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$($sb.Root)\*" }) }
    $bannerLike = "Version $latest is available##updText"

    Write-Host '3. MAKEKIT_NO_UPDATE=1: nothing (first: its close also proves the ini lands in the sandbox)'
    $env3 = $updEnv.Clone(); $env3['MAKEKIT_NO_UPDATE'] = '1'
    $app = Start-McApp $sb -Screen $Screen -Env $env3
    $seen = 0
    for ($i = 0; $i -lt 30; $i++) { $seen += @(Updaters).Count; $null = Invoke-AutoFrames $app 2; Start-Sleep -Milliseconds 200 }
    Check ($seen -eq 0) 'MakeUpdate never started'
    Check (@(Get-McItems $app '*##updText').Count -eq 0) 'no banner'
    $null = Close-McApp $app; $app = $null
    Check ($null -eq (IniValue 'UpdateLastCheck')) 'no check attempted'
    if (-not (Test-Path $ini) -or (RealIniHash) -ne $realBefore) { throw 'settings did not land in the sandbox ini - stopping before any update check' }

    Write-Host '1. banner -> Update now -> verified silent setup -> relaunch'
    $app = Start-McApp $sb -Screen $Screen -Env $updEnv
    $null = Wait-AutoLabel $app $bannerLike 60000
    Check $true 'banner shows the newer version'
    Check ([long](IniValue 'UpdateLastCheck') -gt 1700000000) 'UpdateLastCheck saved after the check'
    Save-McShot $app (Join-Path $work 'banner.png')
    Copy-Item (Join-Path $work 'banner.png') (Join-Path $root 'zig-out\update-banner.png') -ErrorAction SilentlyContinue
    $pid1 = $app.Process.Id
    Invoke-AutoClick $app 'Update now##updNow'
    Check ($app.Process.WaitForExit(15000)) 'app exited after Update now'
    try { $app.Pipe.Dispose() } catch { }
    $app = $null
    $setupMark = Join-Path $marks "$setupName.txt"
    Check (Wait-Until { Test-Path $setupMark } 90000) 'fake setup ran'
    if (Test-Path $setupMark) {
        $args0 = @((Get-Content $setupMark -Raw) -split "`n")
        Check (($args0[0..3] -join ' ') -eq '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS') "setup switches ($($args0 -join ' '))"
    }
    $relaunched = $null
    $null = Wait-Until { $script:relaunched = @(Get-Process MakeCleaner -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $sb.Exe -and $_.Id -ne $pid1 }) | Select-Object -First 1; $null -ne $script:relaunched } 30000
    Check ($null -ne $relaunched) 'app relaunched by MakeUpdate'
    if ($relaunched) { $null = $own.Add($relaunched) }
    Check (Wait-Until { (Test-Path $log) -and (Get-Content $log -Raw) -like '*relaunched*' } 15000) 'update.log in LOCALAPPDATA\MakeUpdate'
    if (Test-Path $log) {
        $text = Get-Content $log -Raw
        Write-Host $text
        Check ($text -like '*SHA-256 ok*' -and $text -like '*setup done*') 'log: SHA-256 verified, setup done'
    }
    Check ((Wait-Until { @(Updaters).Count -eq 0 } 15000)) 'MakeUpdate finished'
    Check (@(Get-ChildItem $sb.Temp -Filter 'MakeUpdate-*' -Force).Count -eq 0) 'temp download folder removed'
    Check ((Test-Path (Join-Path $sb.App 'MakeUpdate.exe')) -and -not (Test-Path (Join-Path $sb.App 'MakeUpdate.exe.old'))) 'MakeUpdate.exe back in place, no .old'
    if ($relaunched) {
        $null = $relaunched.CloseMainWindow()
        if (-not $relaunched.WaitForExit(10000)) { Stop-Process -Id $relaunched.Id -Force }
    }

    Write-Host '2. Later skips this version; About > Check for updates shows it again'
    Reset-Ini @('UpdateLastCheck', 'UpdateSkip')
    $app = Start-McApp $sb -Screen $Screen -Env $updEnv
    $null = Wait-AutoLabel $app $bannerLike 60000
    Invoke-AutoClick $app 'Later##updLater'
    $null = Invoke-AutoFrames $app 3
    Check (@(Get-McItems $app '*##updText').Count -eq 0) 'Later hides the banner'
    Check ((IniValue 'UpdateSkip') -eq $latest) "UpdateSkip=$latest saved"
    $null = Close-McApp $app; $app = $null
    Reset-Ini @('UpdateLastCheck')
    $app = Start-McApp $sb -Screen $Screen -Env $updEnv
    Check (Wait-Until { $null -ne (IniValue 'UpdateLastCheck') } 60000) 'next daily check ran'
    $null = Invoke-AutoFrames $app 5
    Check (@(Get-McItems $app '*##updText').Count -eq 0) 'skipped version: no banner'
    Invoke-AutoClick $app 'Options'; $null = Invoke-AutoFrames $app 2
    Invoke-AutoClick $app '##optionsNav5'; $null = Invoke-AutoFrames $app 2
    Invoke-AutoClick $app '##updCheck'
    $null = Wait-AutoLabel $app $bannerLike 60000
    Check $true 'Check for updates by hand shows the skipped version'
    Check ((Get-AutoText $app '##updStatus') -like "*$latest*") 'About status line names the version'
    Invoke-AutoClick $app 'Settings##optionsNav0'; $null = Invoke-AutoFrames $app 2
    Check ((Get-McItems $app '*##UpdateCheck')[0].checked) 'Settings: automatic check on by default'
    $null = Close-McApp $app; $app = $null

    Write-Host '4. offline: the check fails quietly'
    Stop-Process -Id $server.Id -Force; $null = $server.WaitForExit(5000); $server = $null
    $app = Start-McApp $sb -Screen $Screen -Env $updEnv
    Check (Wait-Until { $null -ne (IniValue 'UpdateLastCheck') } 60000) 'check attempted (UpdateLastCheck saved)'
    $null = Invoke-AutoFrames $app 5
    Check (@(Get-McItems $app '*##updText').Count -eq 0) 'no banner, no message'
    $null = Close-McApp $app; $app = $null
} catch {
    $fail += "error: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
    Write-Host $_ -ForegroundColor Red
} finally {
    if ($app -and -not $app.Process.HasExited) { $null = Stop-AutoApp $app }
    foreach ($p in $own) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    if ($sb) {
        # anything still running from this run's sandbox (relaunched app, updater) is ours
        Get-Process MakeCleaner, MakeUpdate -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$($sb.Root)\*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
    if ($sb) { Remove-Item -Recurse -Force $sb.Root -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Check ((RealIniHash) -eq $realBefore) 'real %AppData%\MakeCleaner\MakeCleaner.ini untouched'
if ($fail.Count) { Write-Host ("UPDATE-E2E FAILED: " + ($fail -join '; ')) -ForegroundColor Red; exit 1 }
Write-Host 'UPDATE-E2E OK'
