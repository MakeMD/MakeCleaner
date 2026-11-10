# GUI smoke for the Browsers tab: sandbox copy (portable), TEMP/LOCALAPPDATA/APPDATA point at a fixture with a fake
# Chrome and Firefox, so the real browsers are never seen. Opens Cleaner > Browsers, clicks Analyze ONLY (never
# Run Cleaner), checks the fixture is untouched and Winapp2 Chrome sections are hidden. MakeKit automation pipe.
# Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$BinDir = '', [string]$Shot = "$env:TEMP\makecleaner-browsers-smoke.png")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $BinDir) { $BinDir = Join-Path $root 'zig-out\bin' } # -BinDir: a published copy (tools\releasecheck.ps1)
. (Join-Path $PSScriptRoot 'mc-auto.ps1')

$sb = New-McSandbox $BinDir 'browsers'
$app = $null
try {
    $files = @(
        'Local\Google\Chrome\User Data\Default\Preferences',
        'Local\Google\Chrome\User Data\Default\Cache\Cache_Data\data_0',
        'Local\Google\Chrome\User Data\Default\Cache\Cache_Data\data_1',
        'Local\Google\Chrome\User Data\Default\Network\Cookies',
        'Roaming\Mozilla\Firefox\Profiles\abc.default\cookies.sqlite',
        'Local\Mozilla\Firefox\Profiles\abc.default\cache2\entries\E1',
        'Temp\keep.txt'
    )
    foreach ($rel in $files) {
        $p = Join-Path $sb.Fx $rel
        New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
        [IO.File]::WriteAllText($p, '{}')
    }
    [IO.File]::WriteAllText((Join-Path $sb.Roaming 'Mozilla\Firefox\profiles.ini'), "[Profile0]`r`nName=default`r`nIsRelative=1`r`nPath=Profiles/abc.default`r`n")
    $before = @(Get-ChildItem $sb.Fx -Recurse -File).Count
    Set-McIni $sb -On 'Temporary Files' # browser items keep their defaults (fixture browsers only)

    $app = Start-McApp $sb -Screen $Screen
    $null = Wait-AutoLabel $app '*applications detected##status'
    Invoke-AutoClick $app 'Applications##tabApps'; $null = Invoke-AutoFrames $app 3
    $appGroups = @(Get-McItems $app '*##ag:*' | ForEach-Object { $_.label -replace '^.*##ag:', '' })
    $appChrome = @(Get-McItems $app '*##ai:Google Chrome*' | ForEach-Object { $_.label -replace '^.*##ai:', '' }) # Winapp2 Chrome entries
    Invoke-AutoClick $app 'Browsers##tabBrowsers'; $null = Invoke-AutoFrames $app 3
    $browserGroups = @(Get-McItems $app '*##bg:*' | ForEach-Object { $_.label -replace '^.*##bg:', '' })
    Write-Host ("browsers tab: " + ($browserGroups -join ', '))
    Write-Host ("applications groups: " + ($appGroups -join ', ') + "; Winapp2 Chrome entries shown: " + $appChrome.Count)
    Invoke-AutoClick $app 'Analyze##analyze'
    $a = (Wait-AutoLabel $app 'Analysis complete*##status').label
    Write-Host "analyze: $a"
    Save-McShot $app $Shot
    $code = Close-McApp $app
    $after = @(Get-ChildItem $sb.Fx -Recurse -File).Count
    # Temp keep.txt + 2 Chrome cache + Firefox cache = 4 files (cookies are rows; see guismoke-cookies.ps1)
    $ok = ($browserGroups -contains 'Google Chrome') -and ($browserGroups -contains 'Mozilla Firefox') -and
          $appGroups.Count -gt 0 -and $appChrome.Count -eq 0 -and ($a -like '*: 4 files*') -and ($after -eq $before) -and $code -eq 0
    if (-not $ok) { throw "SMOKE FAILED (fixture files $before -> $after)" }
    Write-Host 'SMOKE OK (analyze only, nothing deleted)'
} finally {
    Remove-McSandbox $sb $app
}
