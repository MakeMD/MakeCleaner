# GUI smoke for Options > Include / Exclude and saved checkbox states. Sandbox copy (portable), fixture folder,
# TEMP/AppData pointed at fixtures. Adds an Include via the UI -> Analyze sees the fixture files; adds an Exclude ->
# Analyze hides them; restarts the exe and checks the lists and checkbox states came back. Also: C:\ and C:\Windows
# are refused, the OLDER=48 entry format, a REG| exclude. Analyze ONLY, never clicks Run Cleaner. MakeKit automation pipe. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$BinDir = '', [string]$ShotDir = $env:TEMP)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $BinDir) { $BinDir = Join-Path $root 'zig-out\bin' } # -BinDir: a published copy (tools\releasecheck.ps1)
. (Join-Path $PSScriptRoot 'mc-auto.ps1')

$sb = New-McSandbox $BinDir 'incexc'
$app = $null
try {
    $fx = Join-Path $sb.Fx 'incexc'
    foreach ($rel in 'a.log', 'b.log', 'private\c.log') {
        $p = Join-Path $fx $rel
        New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
        [IO.File]::WriteAllBytes($p, (New-Object byte[] 1024))
        (Get-Item $p).LastWriteTime = [datetime]'2026-01-02 03:04:05' # old enough for OLDER=48
    }
    Set-McIni $sb -On 'Custom Files and Folders'

    function Rows($kind) { @(Get-AutoItems $app | Where-Object { $_.label -match "##$kind\d+$" } | ForEach-Object { $_.label -replace '##[a-z]+\d+$', '' }) }
    function Analyze() {
        Invoke-AutoClick $app 'Cleaner'
        Invoke-AutoClick $app 'Analyze##analyze'
        (Wait-McLabel $app 'Analysis complete*##status').label
    }
    function Open() {
        $a = Start-McApp $sb -Screen $Screen
        $null = Wait-McLabel $a '*applications detected##status' # app detection must not overwrite the analyze status later
        $a
    }

    $app = Open
    Invoke-AutoClick $app 'Options'; Invoke-AutoClick $app 'Include##optionsNav1'
    Set-McText $app '##incPath' 'C:\'
    Invoke-AutoClick $app 'Add##incAdd'; $null = Invoke-AutoFrames $app 2
    $rej = Get-McText $app 'incStatus'
    Write-Host "reject C:\ : $rej"
    Set-McText $app '##incPath' 'C:\Windows'
    Invoke-AutoClick $app 'Add##incAdd'; $null = Invoke-AutoFrames $app 2
    $rejWin = Get-McText $app 'incStatus'
    Write-Host "reject C:\Windows : $rejWin"
    Set-McText $app '##incAge' '48'
    Set-McText $app '##incPath' $fx
    Invoke-AutoClick $app 'Add##incAdd'; $null = Invoke-AutoFrames $app 2
    $inc = Rows 'inc'
    Write-Host "include list: $inc"
    Save-McShot $app (Join-Path $ShotDir 'makecleaner-options-incexc.png')
    $a1 = Analyze
    Write-Host "with include: $a1"

    Invoke-AutoClick $app 'Options'; Invoke-AutoClick $app 'Exclude##optionsNav2'
    Set-McText $app '##excPath' (Join-Path $fx 'private')
    Invoke-AutoClick $app 'Add##excAdd'; $null = Invoke-AutoFrames $app 2
    Invoke-AutoClick $app '##excKind'; Invoke-AutoClick $app '##excKind2'
    Set-McText $app '##excPath' 'HKCU\Software\MakeCleanerTestKey'
    Invoke-AutoClick $app 'Add##excAdd'; $null = Invoke-AutoFrames $app 2
    $exc = Rows 'exc'
    Write-Host "exclude list: $exc"
    $a2 = Analyze
    Write-Host "with exclude: $a2"
    Save-McShot $app (Join-Path $ShotDir 'makecleaner-cleaner-incexc.png')
    $code1 = Close-McApp $app

    $app = Open
    Invoke-AutoClick $app 'Options'; Invoke-AutoClick $app 'Include##optionsNav1'; $null = Invoke-AutoFrames $app 2
    $inc2 = @(Rows 'inc')
    Invoke-AutoClick $app 'Exclude##optionsNav2'; $null = Invoke-AutoFrames $app 2
    $exc2 = @(Rows 'exc')
    $a3 = Analyze
    Write-Host "after restart: include=$inc2 exclude=$exc2 analyze=$a3"
    $code2 = Close-McApp $app
    $saved = Get-Content $sb.Ini
    $left = @(Get-ChildItem $fx -Recurse -File).Count

    if ($rej -notlike '*drive*' -or $rejWin -ne 'The Windows folder is protected.' -or @($inc)[0] -notlike '*\incexc|`*.`*|RECURSE|OLDER=48' `
        -or $exc -notcontains 'REG|HKCU\Software\MakeCleanerTestKey' -or $a1 -notlike '*: 3 files*' -or $a2 -notlike '*: 2 files*' -or $a3 -notlike '*: 2 files*' `
        -or $inc2.Count -ne 1 -or $exc2.Count -ne 2 -or -not ($saved -contains 'Temporary Files=False') `
        -or -not ($saved -contains 'Custom Files and Folders=True') -or $left -ne 3 -or $code1 -ne 0 -or $code2 -ne 0) { throw 'SMOKE FAILED' }
    Write-Host 'SMOKE OK (analyze only, nothing deleted)'
} finally {
    Remove-McSandbox $sb $app
}
