# GUI smoke for Tools (Drive Wiper, System Restore) and Options > Settings: sandbox copy (portable), TEMP/AppData
# pointed at fixtures. Opens each page over the MakeKit automation pipe, ticks the first drive to show warnings (then
# unticks it), takes screenshots. Clicks Wipe only while no drive is ticked (the 'Select at least one drive.' check);
# NEVER Remove / Erase / Restart as admin. Options > Settings: secure delete 3 passes + TempOlderThan24h are saved. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$BinDir = '', [string]$ShotDir = $env:TEMP)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $BinDir) { $BinDir = Join-Path $root 'zig-out\bin' } # -BinDir: a published copy (tools\releasecheck.ps1)
. (Join-Path $PSScriptRoot 'mc-auto.ps1')

$sb = New-McSandbox $BinDir 'wiper'
$app = $null
try {
    Set-McIni $sb
    $app = Start-McApp $sb -Screen $Screen
    $fail = @()

    $wipeItem = @(Get-McItems $app 'Wipe Free Space##wi:Wipe Free Space')
    Write-Host ("cleaner has Wipe Free Space item: " + ($wipeItem.Count -eq 1))
    if ($wipeItem.Count -ne 1) { $fail += 'no wipe item' }

    Invoke-AutoClick $app 'Tools'; Invoke-AutoClick $app 'Drive Wiper##toolsNav4'
    $drives = @()  # the page probes drives and SSDs on first open
    for ($i = 0; $i -lt 50 -and $drives.Count -eq 0; $i++) {
        $null = Invoke-AutoFrames $app 2; Start-Sleep -Milliseconds 200
        $drives = @(Get-AutoItems $app | Where-Object { $_.label -match '##drive\d+$' })
    }
    Write-Host ("drives listed: " + $drives.Count + " -> " + (($drives | ForEach-Object { $_.label -replace '##drive\d+$', '' }) -join ' | '))
    if ($drives.Count -eq 0) { $fail += 'no drives' }
    elseif (@($drives | Where-Object { $_.checked }).Count -eq 0) {
        Invoke-AutoClick $app 'Wipe##wipe'; $null = Invoke-AutoFrames $app 2
        $none = Get-McText $app 'wipeProgress'
        Write-Host "wipe with no drive: $none"
        if ($none -ne 'Select at least one drive.') { $fail += "no-drive message ($none)" }
    }
    if ($drives.Count -gt 0) {
        Invoke-AutoClick $app $drives[0].label; $null = Invoke-AutoFrames $app 3
        if (-not (Wait-AutoItem $app $drives[0].label).checked) { $fail += 'drive tick did not stick' }
    }
    Write-Host ("warning: " + (Get-McText $app 'wipeWarning'))
    Write-Host ("wipe button enabled (not clicked): " + (-not (Wait-AutoItem $app 'Wipe##wipe').disabled))
    Save-McShot $app (Join-Path $ShotDir 'makecleaner-drivewiper.png')
    if ($drives.Count -gt 0) { Invoke-AutoClick $app $drives[0].label; $null = Invoke-AutoFrames $app 2 }

    Invoke-AutoClick $app 'System Restore##toolsNav5'
    $rp = ''
    for ($i = 0; $i -lt 50 -and (-not $rp -or $rp -eq 'Loading...'); $i++) { $null = Invoke-AutoFrames $app 2; Start-Sleep -Milliseconds 200; $rp = Get-McText $app 'rpStatus' }
    Write-Host ("restore status: " + $rp)
    if (-not $rp) { $fail += 'restore status empty' }
    Save-McShot $app (Join-Path $ShotDir 'makecleaner-restore.png')

    Invoke-AutoClick $app 'Options'; Invoke-AutoClick $app 'Settings##optionsNav0'
    $sd = Get-McText $app 'secureDelete' # combo button 'chosen method##secureDelete'
    Write-Host ("secure delete combo: " + $sd)
    if ($null -eq $sd) { $fail += 'secure delete combo missing' } elseif (-not $sd) { $fail += 'secure delete combo has no selection' }
    Invoke-AutoClick $app '##secureDelete'; Invoke-AutoClick $app '##secureDelete2'; Invoke-AutoClick $app '##TempOlderThan24h'
    $null = Invoke-AutoFrames $app 2
    $ini = [IO.File]::ReadAllText($sb.Ini)
    if ($ini -notmatch 'SecureDeletePasses=3' -or $ini -notmatch 'TempOlderThan24h=True') { $fail += 'settings not saved' }
    Save-McShot $app (Join-Path $ShotDir 'makecleaner-options.png')

    $code = Close-McApp $app
    if ($code -ne 0) { $fail += "exit code $code" }
    if ($fail) { throw ('SMOKE FAILED: ' + ($fail -join ', ')) }
    Write-Host 'SMOKE OK'
} finally {
    Remove-McSandbox $sb $app
}
