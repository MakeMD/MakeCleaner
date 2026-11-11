# Theme screenshots of every page into zig-out\shots\<Prefix>-*.png: Cleaner after an Analyze of a fixture TEMP, the
# Cleaner warning dialog (cancelled), Registry (no scan), every Tools and Options sub-page. mc-auto sandbox (portable
# copy, fixture TEMP/APPDATA/LOCALAPPDATA, only "Temporary Files" on). Never clicks an action button besides Analyze.
# Pure ASCII (PS 5.1).
#   powershell -ExecutionPolicy Bypass -File tools\shots.ps1 [-BinDir zig-out\bin] [-ShotDir zig-out\shots] [-Prefix carbon]
param([int]$Screen = 1, [string]$BinDir = '', [string]$ShotDir = '', [string]$Prefix = 'carbon')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $BinDir) { $BinDir = Join-Path $root 'zig-out\bin' }
if (-not $ShotDir) { $ShotDir = Join-Path $root 'zig-out\shots' }
. (Join-Path $PSScriptRoot 'mc-auto.ps1')

$sb = New-McSandbox $BinDir 'shots'
$app = $null
function Shot($name) { Save-McShot $app (Join-Path $ShotDir "$Prefix-$name.png") }
try {
    for ($i = 0; $i -lt 60; $i++) { [IO.File]::WriteAllBytes((Join-Path $sb.Temp "f$i.tmp"), (New-Object byte[] (1000 * ($i + 1)))) }
    Set-McIni $sb -On 'Temporary Files'
    $app = Start-McApp $sb -Screen $Screen
    $null = Wait-AutoLabel $app '*applications detected##status'

    Invoke-AutoClick $app 'Analyze##analyze'
    $null = Wait-AutoLabel $app 'Analysis complete*##status' 60000
    Shot 'cleaner'
    Shot 'overview' # the main screen, for the user
    Invoke-AutoClick $app 'Files##viewFiles'
    Invoke-AutoClick $app '##l2' # a selected row (select only, no action)
    Invoke-AutoClick $app 'Files##viewFiles' # mouse off the rows
    Shot 'cleaner-files'
    Invoke-AutoClick $app 'Summary##viewSummary'

    # warning dialog: collapse the groups above Advanced so Wipe Free Space is on screen, then Cancel
    foreach ($g in @('Windows Explorer', 'System')) { Invoke-AutoClick $app "##wt:$g" }
    $null = Invoke-AutoFrames $app 3
    Invoke-AutoClick $app 'Wipe Free Space##wi:Wipe Free Space'
    $null = Wait-AutoItem $app 'Turn on##msgButton0' 5000
    Shot 'warning'
    Invoke-AutoClick $app 'Cancel##msgButton1'

    Invoke-AutoClick $app 'Registry'
    Shot 'registry'

    Invoke-AutoClick $app 'Tools'
    $tools = 'uninstall', 'startup', 'duplicates', 'disk', 'wiper', 'restore'
    for ($i = 0; $i -lt $tools.Count; $i++) {
        Invoke-AutoClick $app "##toolsNav$i"
        Start-Sleep -Milliseconds 1500 # lists load in the background
        Shot ("tools-" + $tools[$i])
    }

    Invoke-AutoClick $app 'Options'
    $opts = 'settings', 'include', 'exclude', 'cookies', 'schedule', 'about'
    for ($i = 0; $i -lt $opts.Count; $i++) {
        Invoke-AutoClick $app "##optionsNav$i"
        Start-Sleep -Milliseconds 800
        Shot ("options-" + $opts[$i])
    }
    $null = Close-McApp $app
    Write-Host 'SHOTS OK'
} finally {
    Remove-McSandbox $sb $app
}
