# GUI smoke for Tools: Duplicate Finder + Disk Analyzer on a small fixture folder, plus cancel of a full-drive
# Disk Analyzer scan (read-only). Sandbox copy (portable), TEMP/AppData pointed at fixtures. Never deletes anything.
# MakeKit automation pipe. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$BinDir = '', [string]$ShotDir = $env:TEMP)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $BinDir) { $BinDir = Join-Path $root 'zig-out\bin' } # -BinDir: a published copy (tools\releasecheck.ps1)
. (Join-Path $PSScriptRoot 'mc-auto.ps1')

$sb = New-McSandbox $BinDir 'dupes'
$app = $null
try {
    $fx = Join-Path $sb.Fx 'tools'
    $t = [datetime]'2024-01-02 03:04:05'
    foreach ($rel in 'a\photo.jpg', 'b\photo.jpg', 'a\song.mp3', 'b\song.mp3', 'a\notes.txt', 'a\other.xyz') {
        $p = Join-Path $fx $rel
        New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
        [IO.File]::WriteAllBytes($p, (New-Object byte[] 2048))
        (Get-Item $p).LastWriteTime = $t
    }
    $before = @(Get-ChildItem $fx -Recurse -File).Count
    Set-McIni $sb

    $app = Start-McApp $sb -Screen $Screen
    Invoke-AutoClick $app 'Tools'
    Invoke-AutoClick $app 'Duplicate Finder##toolsNav2'
    $null = Wait-AutoItem $app '##dupInclude' 3000
    Set-McText $app '##dupInclude' $fx
    Save-McShot $app (Join-Path $ShotDir 'makecleaner-smoke-dupes-setup.png')
    Invoke-AutoClick $app 'Search##dupSearch'
    $d = (Wait-AutoLabel $app 'Found*##dupStatus' 20000).label
    Write-Host "duplicates: $d"
    Save-McShot $app (Join-Path $ShotDir 'makecleaner-smoke-dupes.png')

    Invoke-AutoClick $app 'Disk Analyzer##toolsNav3'
    $null = Wait-AutoItem $app '##daRoots' 3000
    Set-McText $app '##daRoots' $fx
    Invoke-AutoClick $app 'Analyze##daScan'
    $a = (Wait-AutoLabel $app 'Analysis complete*##daStatus' 20000).label
    Write-Host "disk analyzer: $a"
    Save-McShot $app (Join-Path $ShotDir 'makecleaner-smoke-disk.png')

    # cancel: start a full scan of the system drive, cancel it, UI must answer right away
    Set-McText $app '##daRoots' "$env:SystemDrive\"
    Invoke-AutoClick $app 'Analyze##daScan'
    $null = Wait-AutoItem $app 'Cancel##daScan' 3000
    Start-Sleep -Milliseconds 700
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-AutoClick $app 'Cancel##daScan'
    $c = (Wait-AutoLabel $app 'Cancelled*##daStatus' 10000).label
    Write-Host ("cancel: $c in {0} ms" -f $sw.ElapsedMilliseconds)

    $code = Close-McApp $app
    $after = @(Get-ChildItem $fx -Recurse -File).Count
    if ($d -notlike 'Found 2 duplicate groups, 4 files*' -or $a -notlike '*: 6 files*' -or $after -ne $before -or $code -ne 0) { throw 'SMOKE FAILED' }
    Write-Host 'SMOKE OK'
} finally {
    Remove-McSandbox $sb $app
}
