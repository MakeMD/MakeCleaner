# MakeCleaner release: zig build ReleaseSafe -> dist\publish -> portable zip -> Inno Setup installer, all into dist\.
# Version comes from build.zig.zon (.version) - the only place it lives (the exe gets it through build.zig options). Pure ASCII (PS 5.1). Run from PowerShell (ISCC).
# ponytail: no icon, no signing, no CI - one script, native calls.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root 'dist'
$build = Join-Path $dist 'build'
$publish = Join-Path $dist 'publish'

$m = [regex]::Match((Get-Content -Raw (Join-Path $root 'build.zig.zon')), '\.version\s*=\s*"([^"]+)"')
if (-not $m.Success) { throw 'could not read .version from build.zig.zon' }
$version = $m.Groups[1].Value

$zig = Join-Path $env:LOCALAPPDATA 'Programs\zig\0.17.1\zig.exe'
if (-not (Test-Path $zig)) { throw "zig 0.17.1 not found at $zig" }

# 1. ReleaseSafe build into dist\build (zig-out stays the dev build), then only the shipped files into dist\publish.
Write-Host "[1/3] zig build -Doptimize=ReleaseSafe $version" -ForegroundColor Cyan
# older versions' zip/setup in dist\ are left alone; this version's outputs are rebuilt from scratch
$zip = Join-Path $dist "MakeCleaner-$version-portable.zip"
$setup = Join-Path $dist "MakeCleaner-Setup-$version.exe"
foreach ($p in $build, $publish, (Join-Path $dist 'portable'), $zip, $setup) { if (Test-Path $p) { Remove-Item $p -Recurse -Force } }
Push-Location $root
try { & $zig build -Doptimize=ReleaseSafe -p $build } finally { Pop-Location }
if ($LASTEXITCODE) { throw "zig build failed (exit $LASTEXITCODE)" }
New-Item -ItemType Directory -Force (Join-Path $publish 'rules') | Out-Null
Copy-Item (Join-Path $build 'bin\MakeCleaner.exe') $publish
Copy-Item (Join-Path $build 'bin\MakeUpdate.exe') $publish
Copy-Item (Join-Path $build 'bin\rules\*') (Join-Path $publish 'rules')
Copy-Item (Join-Path $root 'THIRD-PARTY-NOTICES.txt') $publish
$shipped = 'MakeCleaner.exe', 'MakeUpdate.exe','rules\Winapp2.ini', 'rules\Windows.ini', 'rules\README.md', 'THIRD-PARTY-NOTICES.txt'
foreach ($f in $shipped) {
    if (-not (Test-Path (Join-Path $publish $f))) { throw "publish output is missing $f" }
}
$extra = @(Get-ChildItem $publish -Recurse -File | ForEach-Object { $_.FullName.Substring($publish.Length + 1) } | Where-Object { $shipped -notcontains $_ })
if ($extra.Count) { throw "publish output has unexpected files: $($extra -join ', ')" }

# 2. Portable zip = the publish folder + portable.dat (settings then live next to the exe).
Write-Host "[2/3] portable zip" -ForegroundColor Cyan
$stage = Join-Path $dist 'portable\MakeCleaner'
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item (Join-Path $publish '*') $stage -Recurse
Set-Content (Join-Path $stage 'portable.dat') '#PORTABLE#' -Encoding ASCII
Compress-Archive -Path $stage -DestinationPath $zip
Remove-Item (Join-Path $dist 'portable') -Recurse -Force

# 3. Installer.
Write-Host "[3/3] ISCC" -ForegroundColor Cyan
$iscc = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
    throw "ISCC.exe not found. Install Inno Setup 6 (https://jrsoftware.org/isdl.php) into %LOCALAPPDATA%\Programs\Inno Setup 6 or Program Files (x86)\Inno Setup 6."
}
& $iscc /Q "/DMyAppVersion=$version" (Join-Path $root 'installer\MakeCleaner.iss')
if ($LASTEXITCODE) { throw "ISCC failed (exit $LASTEXITCODE)" }
Remove-Item $build -Recurse -Force

foreach ($f in (Join-Path $publish 'MakeCleaner.exe'), $zip, $setup) {
    if (-not (Test-Path $f)) { throw "expected $f, not found" }
    Write-Host ("OK  {0}  ({1} MB)" -f $f, [math]::Round((Get-Item $f).Length / 1MB, 2)) -ForegroundColor Green
}
