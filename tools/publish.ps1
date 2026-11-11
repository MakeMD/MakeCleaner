# Release assets for GitHub: tools\release.ps1 (ReleaseSafe build, portable zip, setup), then dist\SHA256SUMS.txt
# (sha256sum format: "<hex>  <file>") for the setup + portable zip. MakeUpdate.exe verifies the setup against it.
# Default = dry run: prints the exact `gh release create` command. -Publish runs it. -SkipBuild reuses dist\.
# Pure ASCII (PS 5.1).
param([switch]$Publish, [switch]$SkipBuild, [string]$NotesFile = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root 'dist'
$version = [regex]::Match((Get-Content -Raw (Join-Path $root 'build.zig.zon')), '\.version\s*=\s*"([^"]+)"').Groups[1].Value
if (-not $version) { throw 'could not read .version from build.zig.zon' }
$tag = "v$version"

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'release.ps1')
    if (-not $?) { throw 'release.ps1 failed' }
}
$assets = "MakeCleaner-Setup-$version.exe", "MakeCleaner-$version-portable.zip"
foreach ($a in $assets) { if (-not (Test-Path (Join-Path $dist $a))) { throw "dist\$a not found - run tools\release.ps1" } }

$sums = Join-Path $dist 'SHA256SUMS.txt'
$lines = foreach ($a in $assets) { (Get-FileHash -Algorithm SHA256 (Join-Path $dist $a)).Hash.ToLowerInvariant() + '  ' + $a }
[IO.File]::WriteAllText($sums, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "SHA256SUMS.txt:" -ForegroundColor Cyan
$lines | ForEach-Object { Write-Host "  $_" }

$files = @($assets | ForEach-Object { Join-Path $dist $_ }) + $sums
$notes = if ($NotesFile) { @('--notes-file', $NotesFile) } else { @('--notes', "MakeCleaner $version") }
$ghArgs = @('release', 'create', $tag) + $files + @('--repo', 'MakeMD/MakeCleaner', '--title', "MakeCleaner $version", '--latest') + $notes
$shown = 'gh ' + (($ghArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
if (-not $Publish) {
    Write-Host 'Dry run. Publish with:' -ForegroundColor Yellow
    Write-Host $shown
    return
}
Write-Host $shown
& gh @ghArgs
if ($LASTEXITCODE) { throw "gh release create failed (exit $LASTEXITCODE)" }
Write-Host "PUBLISHED $tag" -ForegroundColor Green
