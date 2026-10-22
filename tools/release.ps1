# MakeCleaner release: dotnet publish -> portable zip -> Inno Setup installer, all into dist\.
# Version comes from Directory.Build.props (<Version>) - the only place it lives. Pure ASCII (PS 5.1).
# ponytail: no icon, no signing, no CI - one script, native calls (same shape as Projects\MakePack\tools\build.ps1).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$proj = Join-Path $root 'src\MakeCleaner'
$dist = Join-Path $root 'dist'
$publish = Join-Path $dist 'publish'

$version = (dotnet msbuild $proj -getProperty:Version).Trim()
if ($LASTEXITCODE -or -not $version) { throw "could not read <Version> from the csproj" }

# 1. Self-contained single-file exe. The bundle is compressed and unpacked in memory; the native dlls (e_sqlite3 and
#    WPF's *_cor3.dll) stay next to the exe instead of self-extracting, so a portable copy never writes to %TEMP%
#    (no IncludeNativeLibrariesForSelfExtract).
Write-Host "[1/3] dotnet publish $version" -ForegroundColor Cyan
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
dotnet publish $proj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true `
    -p:EnableCompressionInSingleFile=true -p:DebugType=None -o $publish
if ($LASTEXITCODE) { throw "dotnet publish failed (exit $LASTEXITCODE)" }
foreach ($f in 'MakeCleaner.exe', 'e_sqlite3.dll', 'wpfgfx_cor3.dll', 'PresentationNative_cor3.dll',
               'rules\Winapp2.ini', 'rules\README.md', 'THIRD-PARTY-NOTICES.txt') {
    if (-not (Test-Path (Join-Path $publish $f))) { throw "publish output is missing $f" }
}

# 2. Portable zip = the publish folder + portable.dat (settings then live next to the exe).
Write-Host "[2/3] portable zip" -ForegroundColor Cyan
$stage = Join-Path $dist 'portable\MakeCleaner'
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item (Join-Path $publish '*') $stage -Recurse
Set-Content (Join-Path $stage 'portable.dat') '#PORTABLE#' -Encoding ASCII
$zip = Join-Path $dist "MakeCleaner-$version-portable.zip"
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

$setup = Join-Path $dist "MakeCleaner-Setup-$version.exe"
foreach ($f in (Join-Path $publish 'MakeCleaner.exe'), $zip, $setup) {
    if (-not (Test-Path $f)) { throw "expected $f, not found" }
    Write-Host ("OK  {0}  ({1} MB)" -f $f, [math]::Round((Get-Item $f).Length / 1MB, 2)) -ForegroundColor Green
}
