# GUI smoke for the Cleaner screen: tri-state group checkbox, Cancel during Analyze, Summary / Files views, and /auto
# from MakeCleaner.exe. Sandbox copy (portable); TEMP/LOCALAPPDATA/APPDATA point at a fixture; every rule is off except
# Temporary Files, so nothing real is ever scanned. The window never clicks Run Cleaner; only the final /auto cleans,
# and it cleans the fixture TEMP. MakeKit automation pipe. Pure ASCII (PS 5.1).
param([int]$Screen = 1, [string]$BinDir = '', [string]$ShotDir = $env:TEMP, [int]$Files = 40000)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $BinDir) { $BinDir = Join-Path $root 'zig-out\bin' } # -BinDir: a published copy (tools\releasecheck.ps1)
. (Join-Path $PSScriptRoot 'mc-auto.ps1')

$sb = New-McSandbox $BinDir 'cleaner'
$app = $null
try {
    # A TEMP big enough that Analyze is still running when Cancel is pressed: many folders, few files each
    # (walking folders is what makes Analyze slow enough to be cancelled).
    $temp = $sb.Temp
    $dirs = [int]($Files / 10)
    for ($d = 0; $d -lt $dirs; $d++) { [void][IO.Directory]::CreateDirectory((Join-Path $temp ("a{0}\d{1}" -f ($d % 50), $d))) }
    $empty = New-Object byte[] 0
    for ($i = 0; $i -lt $Files; $i++) { $d = $i % $dirs; [IO.File]::WriteAllBytes((Join-Path $temp ("a{0}\d{1}\f{2}.tmp" -f ($d % 50), $d, $i)), $empty) }
    Set-McIni $sb -On 'Temporary Files'

    # group -> rule names (Section= in Windows.ini) for the tri-state check
    $section = @{}; $cur = $null
    foreach ($l in [IO.File]::ReadAllLines((Join-Path $sb.App 'rules\Windows.ini'))) {
        if ($l -match '^\[(.+)\]\s*$') { $cur = $Matches[1] } elseif ($cur -and $l -match '^Section=(.+)$') { $section[$cur] = $Matches[1].Trim() }
    }
    # The automation item has no "mixed" flag (kit.ui.triCheckbox reports mixed as unchecked): a group reads
    # Indeterminate when its box is unchecked while some of its items are ticked, Off when none are.
    function GroupState($group) {
        $items = @(Get-AutoItems $app)
        $box = @($items | Where-Object { $_.label -eq "$group##wg:$group" })
        if ($box.Count -ne 1) { return 'missing' }
        $kids = @($section.Keys | Where-Object { $section[$_] -eq $group } | ForEach-Object { $n = $_; $items | Where-Object { $_.label -eq "$n##wi:$n" } })
        $on = @($kids | Where-Object { $_.checked }).Count
        if ($box[0].checked) { 'On' } elseif ($on -gt 0 -and $on -lt $kids.Count) { 'Indeterminate' } elseif ($on -eq 0 -and $kids.Count -gt 0) { 'Off' } else { "?($on/$($kids.Count))" }
    }

    $app = Start-McApp $sb -Screen $Screen
    $null = Wait-McLabel $app '*applications detected##status'
    Save-McShot $app (Join-Path $ShotDir 'makecleaner-cleaner-main.png')

    # only Temporary Files is on: System shows the third state, Windows Explorer is off
    $sys = GroupState 'System'; $exp = GroupState 'Windows Explorer'
    Write-Host "groups: System=$sys, Windows Explorer=$exp"

    # Cancel while analyzing: nothing may stay armed for Run Cleaner (a warm disk cache can still win the race: a few tries)
    $c = ''
    for ($try = 1; $try -le 5 -and $c -notlike 'Analysis cancelled*'; $try++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Invoke-AutoClick $app 'Analyze##analyze'
        $err = 'ok'
        try { Invoke-AutoClick $app 'Cancel##cancel' } catch { $err = $_.Exception.Message } # too late: this Analyze already finished
        $c = (Wait-McLabel $app 'Analysis*##status' 60000).label
        Write-Host ("try {0}: cancel click {1}, status after {2} ms: {3}" -f $try, $err, $sw.ElapsedMilliseconds, $c)
    }
    $cleanAfterCancel = -not (Wait-AutoItem $app 'Run Cleaner##clean').disabled
    Write-Host "cancel: $c (Run Cleaner enabled: $cleanAfterCancel)"

    # full Analyze, then Summary and Files views
    Invoke-AutoClick $app 'Analyze##analyze'
    $a = (Wait-McLabel $app 'Analysis complete*##status' 120000).label
    Write-Host "analyze: $a"
    Invoke-AutoClick $app 'Summary##viewSummary'; $null = Invoke-AutoFrames $app 3
    $summaryRows = @(Get-AutoItems $app | Where-Object { $_.label -match '##l\d+$' }).Count
    Save-McShot $app (Join-Path $ShotDir 'makecleaner-cleaner-summary.png')
    Invoke-AutoClick $app 'Files##viewFiles'; $null = Invoke-AutoFrames $app 3
    $fileRows = @(Get-AutoItems $app | Where-Object { $_.label -match '##l\d+$' }).Count
    Write-Host "rows: summary=$summaryRows files(visible)=$fileRows"
    Save-McShot $app (Join-Path $ShotDir 'makecleaner-cleaner-files.png')
    $code = Close-McApp $app
    $left = @(Get-ChildItem $temp -Recurse -File).Count

    # /auto: no window, exit code 0, the fixture TEMP emptied
    $auto = Invoke-McHeadless $sb -Arguments '/auto' -Screen $Screen -TimeoutMs 300000
    $afterAuto = @(Get-ChildItem $temp -Recurse -File).Count
    Write-Host "window run left the fixture: $left of $Files; /auto exit $($auto.ExitCode), window $($auto.SawWindow), files left $afterAuto"

    if ($sys -ne 'Indeterminate' -or $exp -ne 'Off' -or $c -notlike 'Analysis cancelled*' -or $cleanAfterCancel `
        -or $a -notlike "Analysis complete: $Files files*" -or $summaryRows -ne 1 -or $fileRows -lt 2 -or $left -ne $Files -or $code -ne 0 `
        -or $auto.ExitCode -ne 0 -or $auto.SawWindow -or $afterAuto -ne 0) { throw 'SMOKE FAILED' }
    Write-Host 'SMOKE OK'
} finally {
    Remove-McSandbox $sb $app
}
