# Release check on the PUBLISHED build (run tools\release.ps1 first). Pure ASCII (PS 5.1).
# 1. Unzips the newest dist\MakeCleaner-<ver>-portable.zip into a temp folder.
# 2. Import table of that MakeCleaner.exe (PE import directory parsed here, no tools): FAIL on ws2_32, wsock32,
#    wininet, winhttp, urlmon, iphlpapi, any DLL with "net" in its name, dnsapi beyond DnsFlushResolverCache (the
#    DNS Cache rule), or any delay-load import (not inspected). Prints the imported DLLs. MakeUpdate.exe (the
#    updater, shipped next to it) may import only winhttp, kernel32, ntdll (+ api-ms-win-*).
# 3. Runs every tools\*smoke*.ps1 with -BinDir = that copy (each smoke copies it into its own
#    %TEMP%\makecleaner-test-<tag>-<rand> sandbox and only ever cleans its own fixtures).
# 4. Meanwhile a background job polls Get-NetTCPConnection / Get-NetUDPEndpoint for every MakeCleaner process running
#    from a %TEMP%\makecleaner-test-* sandbox: any connection or endpoint = FAIL.
#    ponytail: polling (~every 100-300 ms) can miss a sub-100 ms connection; the import check is the static half.
#    ETW/WFP capture if this ever needs to be airtight.
# 5. Portable must not write outside its folder: snapshots %AppData%, %LocalAppData% (top level) and HKCU\Software
#    before and after. A new entry named *MakeCleaner* = FAIL; other new entries are listed (other apps keep writing
#    there too).
param([int]$Screen = 1)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$zip = Get-ChildItem (Join-Path $root 'dist') -Filter 'MakeCleaner-*-portable.zip' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $zip) { throw 'dist\MakeCleaner-*-portable.zip not found - run tools\release.ps1 first' }

$work = Join-Path ([IO.Path]::GetTempPath()) ('mc-release-' + [guid]::NewGuid().ToString('N'))
Expand-Archive $zip.FullName $work
$bin = Join-Path $work 'MakeCleaner'
Write-Host "portable copy: $bin ($($zip.Name))"

# ---- import table
# Returns one object per imported DLL: Dll, Functions (names, or #ordinal). Delay-load DLLs come back with Delay=$true.
function Get-PeImports([string]$path) {
    $b = [IO.File]::ReadAllBytes($path)
    $u16 = { param($o) [BitConverter]::ToUInt16($b, $o) }
    $u32 = { param($o) [BitConverter]::ToUInt32($b, $o) }
    $pe = & $u32 0x3C
    if ((& $u32 $pe) -ne 0x4550) { throw "$path is not a PE file" }
    $nsec = & $u16 ($pe + 6)
    $opt = $pe + 24
    $is64 = (& $u16 $opt) -eq 0x20B
    $dirs = $opt + $(if ($is64) { 112 } else { 96 })
    $secs = $opt + (& $u16 ($pe + 20))
    $off = { param($rva)
        for ($i = 0; $i -lt $nsec; $i++) {
            $s = $secs + 40 * $i; $va = & $u32 ($s + 12); $size = [Math]::Max((& $u32 ($s + 8)), (& $u32 ($s + 16)))
            if ($rva -ge $va -and $rva -lt $va + $size) { return [int]($rva - $va + (& $u32 ($s + 20))) }
        }
        throw ("RVA 0x{0:X} is outside every section" -f $rva)
    }
    $str = { param($o) $e = $o; while ($b[$e] -ne 0) { $e++ }; [Text.Encoding]::ASCII.GetString($b, $o, $e - $o) }
    $width = if ($is64) { 8 } else { 4 }
    $out = @()
    if ((& $u32 ($dirs + 8)) -ne 0) {
        $d = & $off (& $u32 ($dirs + 8))
        while (($nameRva = & $u32 ($d + 12)) -ne 0) {
            $names = (& $u32 $d); if ($names -eq 0) { $names = & $u32 ($d + 16) }
            $t = & $off $names; $fn = @()
            while ((& $u32 $t) -ne 0 -or ($is64 -and (& $u32 ($t + 4)) -ne 0)) {
                if ($b[$t + $width - 1] -band 0x80) { $fn += '#' + (& $u16 $t) } else { $fn += & $str ((& $off ((& $u32 $t) -band 0x7FFFFFFF)) + 2) }
                $t += $width
            }
            $out += [pscustomobject]@{ Dll = (& $str (& $off $nameRva)); Functions = $fn; Delay = $false }
            $d += 20
        }
    }
    if ((& $u32 ($dirs + 13 * 8)) -ne 0) {
        $d = & $off (& $u32 ($dirs + 13 * 8))
        while (($nameRva = & $u32 ($d + 4)) -ne 0) { $out += [pscustomobject]@{ Dll = (& $str (& $off $nameRva)); Functions = @(); Delay = $true }; $d += 32 }
    }
    $out
}
$imports = @(Get-PeImports (Join-Path $bin 'MakeCleaner.exe'))
$banned = 'ws2_32.dll', 'wsock32.dll', 'wininet.dll', 'winhttp.dll', 'urlmon.dll', 'iphlpapi.dll'
$importFail = @()
foreach ($i in $imports) {
    $n = $i.Dll.ToLowerInvariant()
    $note = ''
    if ($i.Delay) { $importFail += "$n (delay-load)"; $note = '  <- delay-load: not inspected' }
    elseif ($banned -contains $n -or $n -like '*net*') { $importFail += $n; $note = '  <- network DLL' }
    elseif ($n -eq 'dnsapi.dll') {
        $other = @($i.Functions | Where-Object { $_ -ne 'DnsFlushResolverCache' })
        if ($other.Count) { $importFail += "dnsapi.dll ($($other -join ', '))"; $note = '  <- only DnsFlushResolverCache is allowed' }
        else { $note = '  (DnsFlushResolverCache only)' }
    }
    Write-Host ("  import: {0,-28} {1,4} functions{2}" -f $i.Dll, @($i.Functions).Count, $note)
}
Write-Host ("imports: {0} DLLs, {1} not allowed" -f $imports.Count, $importFail.Count)

# MakeUpdate.exe (MakeKit updater, the only binary allowed online): WinHTTP and plain system DLLs only.
$updAllowed = 'winhttp.dll', 'kernel32.dll', 'ntdll.dll'
$updImports = @(Get-PeImports (Join-Path $bin 'MakeUpdate.exe'))
foreach ($i in $updImports) {
    $n = $i.Dll.ToLowerInvariant()
    $ok = -not $i.Delay -and ($updAllowed -contains $n -or $n -like 'api-ms-win-*')
    if (-not $ok) { $importFail += "MakeUpdate.exe: $n" }
    Write-Host ("  MakeUpdate import: {0,-28} {1,4} functions{2}" -f $i.Dll, @($i.Functions).Count, $(if ($ok) { '' } else { '  <- not allowed' }))
}

# ---- smokes + network poll + traces
function Snap {
    $s = @{}
    foreach ($d in $env:APPDATA, $env:LOCALAPPDATA) {
        if (Test-Path $d) { Get-ChildItem $d -Force -ErrorAction SilentlyContinue | ForEach-Object { $s[$_.FullName] = 1 } }
    }
    # HKCU\Software\MakeCleanerTest-* keys belong to `zig build test` runs (src/core common.TestKey), not to the app
    Get-ChildItem 'HKCU:\Software' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -notlike 'MakeCleanerTest-*' } | ForEach-Object { $s[$_.Name] = 1 }
    return $s
}
$before = Snap

$stop = Join-Path $work 'stop.flag'
$sandboxes = Join-Path ([IO.Path]::GetTempPath()) 'makecleaner-test-*'
$job = Start-Job -ArgumentList $sandboxes, $stop -ScriptBlock {
    param($sandboxes, $stop)
    $samples = 0; $hits = @()
    while (-not (Test-Path $stop)) {
        $ids = @(Get-Process MakeCleaner -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$sandboxes\*" } | ForEach-Object Id)
        if ($ids.Count) {
            $samples++
            $hits += @(Get-NetTCPConnection -OwningProcess $ids -ErrorAction SilentlyContinue | ForEach-Object { "TCP pid=$($_.OwningProcess) $($_.LocalAddress):$($_.LocalPort) -> $($_.RemoteAddress):$($_.RemotePort) $($_.State)" })
            $hits += @(Get-NetUDPEndpoint -OwningProcess $ids -ErrorAction SilentlyContinue | ForEach-Object { "UDP pid=$($_.OwningProcess) $($_.LocalAddress):$($_.LocalPort)" })
        }
        # the smokes run with MAKEKIT_NO_UPDATE=1: the updater must never start from a sandbox
        $hits += @(Get-Process MakeUpdate -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$sandboxes\*" } | ForEach-Object { "MakeUpdate.exe started: pid=$($_.Id) $($_.Path)" })
        Start-Sleep -Milliseconds 100
    }
    [pscustomobject]@{ Samples = $samples; Hits = @($hits | Select-Object -Unique) }
}

$failed = @()
try {
    foreach ($s in Get-ChildItem $PSScriptRoot -Filter '*smoke*.ps1' | Sort-Object Name) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        # Continue: under Stop, PS 5.1 turns the smoke's stderr into a terminating error (no FAIL line, no cleanup)
        $out = & { $ErrorActionPreference = 'Continue'; & powershell -NoProfile -ExecutionPolicy Bypass -File $s.FullName -Screen $Screen -BinDir $bin *>&1 } | Out-String
        $ok = $LASTEXITCODE -eq 0 -and $out -match 'SMOKE OK'
        Write-Host ("{0,-24} {1}  ({2:N0} s)" -f $s.Name, $(if ($ok) { 'SMOKE OK' } else { 'FAIL' }), $sw.Elapsed.TotalSeconds)
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
# retried: an AV scanner may still hold the unzipped exe
for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath $work); $i++) { Start-Sleep -Milliseconds 250; Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

if ($importFail.Count -or $failed.Count -or $net.Samples -eq 0 -or $net.Hits.Count -or $ours.Count) {
    throw ("RELEASE CHECK FAILED (imports: {0}; smokes: {1}; samples: {2}; network: {3}; MakeCleaner entries: {4})" -f ($importFail -join ','), ($failed -join ','), $net.Samples, $net.Hits.Count, $ours.Count)
}
Write-Host 'RELEASE CHECK OK'
