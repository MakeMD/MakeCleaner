# Release check on the PUBLISHED build (run tools\release.ps1 first). Pure ASCII (PS 5.1).
# 1. Unzips dist\MakeCleaner-<ver>-portable.zip into a temp folder and runs every tools\*smoke*.ps1 against that copy
#    (-BinDir). The smokes only ever clean their own fixtures.
# 2. Meanwhile a background job polls Get-NetTCPConnection / Get-NetUDPEndpoint for every MakeCleaner process started
#    from that folder: any connection or endpoint = FAIL.
#    ponytail: polling (~every 100-300 ms) can miss a sub-100 ms connection; the unit test that no shipped assembly
#    references System.Net.* is the static half. ETW/WFP capture if this ever needs to be airtight.
# 3. Portable must not write outside its folder: snapshots %AppData%, %LocalAppData% (top level), %TEMP%\.net and
#    HKCU\Software before and after. A new entry named *MakeCleaner* = FAIL; other new entries are listed (other apps
#    keep writing there too).
param([int]$Screen = 1)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$zip = Get-ChildItem (Join-Path $root 'dist') -Filter 'MakeCleaner-*-portable.zip' | Select-Object -First 1
if (-not $zip) { throw 'dist\MakeCleaner-*-portable.zip not found - run tools\release.ps1 first' }

$work = Join-Path ([IO.Path]::GetTempPath()) ('mc-release-' + [guid]::NewGuid().ToString('N'))
Expand-Archive $zip.FullName $work
$bin = Join-Path $work 'MakeCleaner'
Write-Host "portable copy: $bin"

function Snap {
    $s = @{}
    foreach ($d in $env:APPDATA, $env:LOCALAPPDATA, (Join-Path $env:TEMP '.net')) {
        if (Test-Path $d) { Get-ChildItem $d -Force -ErrorAction SilentlyContinue | ForEach-Object { $s[$_.FullName] = 1 } }
    }
    Get-ChildItem 'HKCU:\Software' -ErrorAction SilentlyContinue | ForEach-Object { $s[$_.Name] = 1 }
    return $s
}
$before = Snap

$stop = Join-Path $work 'stop.flag'
$job = Start-Job -ArgumentList $bin, $stop -ScriptBlock {
    param($bin, $stop)
    $samples = 0; $hits = @()
    while (-not (Test-Path $stop)) {
        $ids = @(Get-Process MakeCleaner -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$bin\*" } | ForEach-Object Id)
        if ($ids.Count) {
            $samples++
            $hits += @(Get-NetTCPConnection -OwningProcess $ids -ErrorAction SilentlyContinue | ForEach-Object { "TCP pid=$($_.OwningProcess) $($_.LocalAddress):$($_.LocalPort) -> $($_.RemoteAddress):$($_.RemotePort) $($_.State)" })
            $hits += @(Get-NetUDPEndpoint -OwningProcess $ids -ErrorAction SilentlyContinue | ForEach-Object { "UDP pid=$($_.OwningProcess) $($_.LocalAddress):$($_.LocalPort)" })
        }
        Start-Sleep -Milliseconds 100
    }
    [pscustomobject]@{ Samples = $samples; Hits = @($hits | Select-Object -Unique) }
}

$failed = @()
try {
    # ponytail: the zip ships the WinForms exe until ticket 19, so the WPF-only smoke has nothing to run against yet
    foreach ($s in Get-ChildItem $PSScriptRoot -Filter '*smoke*.ps1' | Where-Object Name -ne 'guismoke-wpf.ps1' | Sort-Object Name) {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $s.FullName -Screen $Screen -BinDir $bin *>&1 | Out-String
        $ok = $LASTEXITCODE -eq 0 -and $out -match 'SMOKE OK'
        Write-Host ("{0,-24} {1}" -f $s.Name, $(if ($ok) { 'OK' } else { 'FAIL' }))
        if (-not $ok) { $failed += $s.Name; Write-Host $out }
    }
} finally {
    New-Item -ItemType File $stop | Out-Null
    $net = Receive-Job $job -Wait -AutoRemoveJob
}

$after = Snap
$new = @($after.Keys | Where-Object { -not $before.ContainsKey($_) } | Sort-Object)
$ours = @($new | Where-Object { $_ -match 'MakeCleaner' })
Write-Host ("network: {0} samples of running MakeCleaner processes, {1} connections/endpoints" -f $net.Samples, $net.Hits.Count)
$net.Hits | ForEach-Object { Write-Host "  $_" }
Write-Host ("outside the portable folder: {0} new entries, {1} named MakeCleaner" -f $new.Count, $ours.Count)
$new | ForEach-Object { Write-Host "  new: $_" }
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

if ($failed.Count -or $net.Samples -eq 0 -or $net.Hits.Count -or $ours.Count) {
    throw ("RELEASE CHECK FAILED (smokes: {0}; samples: {1}; network: {2}; MakeCleaner entries: {3})" -f ($failed -join ','), $net.Samples, $net.Hits.Count, $ours.Count)
}
Write-Host 'RELEASE CHECK OK'
