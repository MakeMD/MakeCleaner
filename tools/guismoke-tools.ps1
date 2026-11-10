# GUI smoke for Tools > Uninstall / Startup: READ-ONLY. Sandbox copy (portable), TEMP/AppData pointed at fixtures.
# Opens the pages over the MakeKit automation pipe, waits for each list to fill, prints row counts, saves
# screenshots. Never clicks an action button. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$BinDir = '', [string]$ShotDir = $env:TEMP)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $BinDir) { $BinDir = Join-Path $root 'zig-out\bin' } # -BinDir: a published copy (tools\releasecheck.ps1)
. (Join-Path $PSScriptRoot 'mc-auto.ps1')

$sb = New-McSandbox $BinDir 'tools'
$app = $null
# Rows submitted this frame (clipped lists: the visible ones), polled until the list has filled.
function Rows($regex) {
    for ($i = 0; $i -lt 75; $i++) {
        $n = @(Get-AutoItems $app | Where-Object { $_.label -match $regex }).Count
        if ($n -gt 0) { return $n }
        $null = Invoke-AutoFrames $app 2; Start-Sleep -Milliseconds 200
    }
    return 0
}
try {
    Set-McIni $sb
    $app = Start-McApp $sb -Screen $Screen
    Invoke-AutoClick $app 'Tools'
    Invoke-AutoClick $app 'Uninstall##toolsNav0'
    $res = [ordered]@{ Uninstall = (Rows '##u\d+p$') }
    Write-Host ("uninstall count line: " + (Get-McText $app 'uninstallCount'))
    Save-McShot $app (Join-Path $ShotDir 'makecleaner-uninstall.png')
    Invoke-AutoClick $app 'Startup##toolsNav1'
    $k = 0
    foreach ($t in @(@('Windows', 'startupWindows'), @('Scheduled Tasks', 'startupTasks'), @('Context Menu', 'startupContext'), @('Windows Services', 'startupServices'))) {
        Invoke-AutoClick $app ('##' + $t[1])
        $res[$t[0]] = Rows "##st${k}_\d+$"
        Save-McShot $app (Join-Path $ShotDir ('makecleaner-startup-' + ($t[0] -replace ' ', '') + '.png'))
        $k++
    }
    $res.GetEnumerator() | ForEach-Object { Write-Host ("{0}: {1} rows" -f $_.Key, $_.Value) }
    $code = Close-McApp $app
    if ($res.Uninstall -eq 0 -or $res['Windows Services'] -eq 0 -or $code -ne 0) { throw 'SMOKE FAILED' }
    Write-Host 'SMOKE OK'
} finally {
    Remove-McSandbox $sb $app
}
