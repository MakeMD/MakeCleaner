# Smoke for MakeCleaner /auto: sandbox copy (portable) with only Temporary Files ticked (+ Wipe Free Space, which
# /auto must ignore), TEMP/AppData pointed at fixtures. Runs the exe headless, checks exit code, fixture emptied, no
# window, log line. Then opens the GUI on Options > Schedule, reads the scheduled-cleaning status and clicks Create
# only with an invalid start time (refused before any task call; a valid one would register a real task). MakeKit automation pipe. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$BinDir = '', [string]$Shot = "$env:TEMP\makecleaner-schedule.png")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $BinDir) { $BinDir = Join-Path $root 'zig-out\bin' } # -BinDir: a published copy (tools\releasecheck.ps1)
. (Join-Path $PSScriptRoot 'mc-auto.ps1')

$sb = New-McSandbox $BinDir 'auto'
$app = $null
try {
    New-Item -ItemType Directory -Force (Join-Path $sb.Temp 'sub') | Out-Null
    'a', 'sub\b' | ForEach-Object { [IO.File]::WriteAllBytes((Join-Path $sb.Temp "$_.tmp"), (New-Object byte[] 1024)) }
    Set-McIni $sb -On 'Temporary Files', 'Wipe Free Space'
    $log = Join-Path $sb.App 'MakeCleaner-auto.log'

    $a = Invoke-McHeadless $sb -Arguments '/auto' -Screen $Screen
    $left = @(Get-ChildItem $sb.Temp -Recurse -File).Count
    $line = if (Test-Path $log) { Get-Content $log -Tail 1 } else { '(no log)' }
    Write-Host "auto exit: $($a.ExitCode), window: $($a.SawWindow), fixture files left: $left"
    Write-Host "log: $line"
    if ($a.ExitCode -ne 0 -or $a.SawWindow -or $left -ne 0 -or $line -notlike '*Cleaning complete: 2 files removed*' -or $line -like '*free space*') { throw 'AUTO SMOKE FAILED' }

    $app = Start-McApp $sb -Screen $Screen
    Invoke-AutoClick $app 'Options'
    Invoke-AutoClick $app 'Schedule##optionsNav4'
    $st = Get-AutoText $app '##schedStatus'
    for ($i = 0; $i -lt 50 -and -not $st; $i++) { $null = Invoke-AutoFrames $app 2; Start-Sleep -Milliseconds 100; $st = Get-AutoText $app '##schedStatus' }
    Write-Host "schedule status: $st"
    Set-McText $app '##schedAt' 'bad'
    Invoke-AutoClick $app 'Create task##schedCreate'; $null = Invoke-AutoFrames $app 2
    $bad = Get-AutoText $app '##schedStatus'
    Write-Host "bad time: $bad"
    Save-McShot $app $Shot
    $code = Close-McApp $app
    if ($st -notlike '*scheduled cleaning*' -or $bad -ne 'Enter the start time like 2026-01-31 18:00.' -or $code -ne 0) { throw 'SMOKE FAILED' }
    Write-Host 'SMOKE OK'
} finally {
    Remove-McSandbox $sb $app
}
