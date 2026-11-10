# Registry GUI smoke: sandbox copy (portable), switches to Registry (rail tile), runs Scan for Issues (read-only),
# checks the status line and saves a screenshot. Never clicks Fix. MakeKit automation pipe. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$BinDir = '', [string]$Shot = "$env:TEMP\makecleaner-regsmoke.png")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $BinDir) { $BinDir = Join-Path $root 'zig-out\bin' } # -BinDir: a published copy (tools\releasecheck.ps1)
. (Join-Path $PSScriptRoot 'mc-auto.ps1')

$sb = New-McSandbox $BinDir 'regsmoke'
$app = $null
try {
    Set-McIni $sb  # registry categories keep their defaults; no cleaner rule is ticked
    $app = Start-McApp $sb -Screen $Screen
    Invoke-AutoClick $app 'Registry'
    $null = Wait-AutoItem $app 'Scan for Issues##regscan' 5000
    Invoke-AutoClick $app 'Scan for Issues##regscan'
    $s = (Wait-McLabel $app 'Scan complete*##regstatus' 120000).label
    Write-Host "scan: $s"
    Save-McShot $app $Shot
    $code = Close-McApp $app
    if ($code -ne 0) { throw "SMOKE FAILED (exit code $code)" }
    Write-Host 'SMOKE OK'
} finally {
    Remove-McSandbox $sb $app
}
