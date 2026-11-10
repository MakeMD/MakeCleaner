# GUI smoke for the Applications tab: sandbox copy (portable), TEMP/AppData pointed at fixtures, waits for app
# detection, opens the Applications tab, ticks the first detected entry and runs Analyze ONLY (read-only).
# Never clicks Run Cleaner. MakeKit automation pipe. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$BinDir = '', [string]$Shot = "$env:TEMP\makecleaner-apps-smoke.png")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $BinDir) { $BinDir = Join-Path $root 'zig-out\bin' } # -BinDir: a published copy (tools\releasecheck.ps1)
. (Join-Path $PSScriptRoot 'mc-auto.ps1')

$sb = New-McSandbox $BinDir 'apps'
$app = $null
try {
    [IO.File]::WriteAllBytes((Join-Path $sb.Temp 'a.tmp'), (New-Object byte[] 1024))
    Set-McIni $sb
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $app = Start-McApp $sb -Screen $Screen
    $d = (Wait-AutoLabel $app '*applications detected##status').label
    Write-Host ("detect: $d in {0:N1}s" -f $sw.Elapsed.TotalSeconds)
    Invoke-AutoClick $app 'Applications##tabApps'
    $null = Invoke-AutoFrames $app 3
    $groups = @(Get-McItems $app '*##ag:*')
    Write-Host "groups: $($groups.Count)"
    $ticked = '(none)'
    if ($groups.Count -gt 0) {
        $leaves = @(Get-McItems $app '*##ai:*')
        if ($leaves.Count -eq 0) { # first group collapsed: expand it
            Invoke-AutoClick $app ('##at:' + ($groups[0].label -replace '^.*##ag:', ''))
            $null = Invoke-AutoFrames $app 3
            $leaves = @(Get-McItems $app '*##ai:*')
        }
        if ($leaves.Count -gt 0) {
            Invoke-AutoClick $app $leaves[0].label; $null = Invoke-AutoFrames $app 2
            if ((Wait-AutoItem $app $leaves[0].label).checked) { $ticked = $leaves[0].label }
        }
    }
    Write-Host "ticked: $ticked"
    Invoke-AutoClick $app 'Analyze##analyze'
    $a = (Wait-AutoLabel $app 'Analysis complete*##status' 120000).label
    Write-Host "analyze: $a"
    Save-McShot $app $Shot
    $left = @(Get-ChildItem $sb.Temp -File).Count
    $code = Close-McApp $app
    if ($groups.Count -eq 0 -or $ticked -eq '(none)' -or $a -notlike '*registry entries*' -or $left -ne 1 -or $code -ne 0) { throw 'SMOKE FAILED' }
    Write-Host 'SMOKE OK (analyze only, nothing deleted)'
} finally {
    Remove-McSandbox $sb $app
}
