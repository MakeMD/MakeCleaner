# GUI smoke: sandbox copy (portable) with TEMP pointed at a fixture folder, only Temporary Files ticked;
# clicks Analyze then Run Cleaner over the MakeKit automation pipe, checks the status line, saves a screenshot.
# Never touches the real %TEMP%. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$BinDir = '', [string]$Shot = "$env:TEMP\makecleaner-smoke.png")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $BinDir) { $BinDir = Join-Path $root 'zig-out\bin' } # -BinDir: a published copy (tools\releasecheck.ps1)
. (Join-Path $PSScriptRoot 'mc-auto.ps1')

$sb = New-McSandbox $BinDir 'smoke'
$app = $null
try {
    New-Item -ItemType Directory -Force (Join-Path $sb.Temp 'sub') | Out-Null
    'a', 'b', 'sub\c' | ForEach-Object { [IO.File]::WriteAllBytes((Join-Path $sb.Temp "$_.tmp"), (New-Object byte[] 1024)) }
    # Only Temporary Files on (= the fixture TEMP); browsers: AppData points at empty fixture folders.
    Set-McIni $sb -On 'Temporary Files'

    $app = Start-McApp $sb -Screen $Screen
    Invoke-AutoClick $app 'Analyze##analyze'
    $a = (Wait-AutoLabel $app 'Analysis complete*##status').label
    Write-Host "analyze: $a"
    Save-McShot $app $Shot
    Invoke-AutoClick $app 'Run Cleaner##clean'
    $c = (Wait-AutoLabel $app 'Cleaning complete*##status').label
    Write-Host "clean: $c"
    $left = @(Get-ChildItem $sb.Temp -Recurse -File).Count
    Write-Host "fixture files left: $left"
    $code = Close-McApp $app
    Write-Host ("exit code: $code, portable ini next to exe: " + (Test-Path $sb.Ini))
    if ($a -notlike '*: 3 files*' -or $left -ne 0 -or $code -ne 0 -or -not (Test-Path $sb.Ini)) { throw 'SMOKE FAILED' }
    Write-Host 'SMOKE OK'
} finally {
    Remove-McSandbox $sb $app
}
