# MC-G1 gap fixes check: empty-list hint without body column lines, WPF-sized radios, modal dim, Registry cell
# tooltips, and closing the window during Run Cleaner (must exit at once, not wait for the clean).
# Sandbox like g1-gui-test.ps1: portable copy, fixture TEMP/APPDATA/LOCALAPPDATA, every rule off except
# "Custom Files and Folders" (-> fixture Junk), MuiCache fixture values only this test creates (never fixed, deleted
# in finally). Secure delete 7 passes on 100 x 4 MB fixture files keeps the clean busy long enough to close mid-run.
#   powershell -ExecutionPolicy Bypass -File tools\g1-fix-test.ps1 [-Bin zig-out\bin] [-Shots zig-out\shots]
param([string]$Bin = '', [string]$Shots = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
if (-not $Bin) { $Bin = Join-Path $root 'zig-out\bin' }
if (-not $Shots) { $Shots = Join-Path $root 'zig-out\shots' }
. (Join-Path $root '..\MakeKit\tools\imgui-auto.ps1')
New-Item -ItemType Directory -Force $Shots | Out-Null

$rnd = [guid]::NewGuid().ToString('N').Substring(0, 8)
$T = Join-Path ([IO.Path]::GetTempPath()) "makecleaner-test-g1fix-$rnd"
$appDir = Join-Path $T 'app'
$fx = Join-Path $T 'fx'
$junk = Join-Path $fx 'Junk\a-long-folder-name-so-the-item-column-has-to-cut-it\and-one-more-level'
$local = Join-Path $fx 'Local'
$roaming = Join-Path $fx 'Roaming'
$temp = Join-Path $fx 'Temp'
foreach ($d in @($appDir, $junk, $local, $roaming, $temp)) { New-Item -ItemType Directory -Force $d | Out-Null }
Copy-Item -Recurse -Force (Join-Path $Bin '*') $appDir
Set-Content (Join-Path $appDir 'portable.dat') '#PORTABLE#' -Encoding Ascii
$blob = New-Object byte[] (4MB)
for ($i = 0; $i -lt 100; $i++) { [IO.File]::WriteAllBytes((Join-Path $junk ("junk{0:D3}.tmp" -f $i)), $blob) }

$cats = @('Missing Shared DLLs', 'Unused File Extensions', 'ActiveX and Class Issues', 'Type Libraries', 'Applications', 'Fonts',
    'Application Paths', 'Help Files', 'Installer', 'Obsolete Software', 'Run At Startup', 'Start Menu Ordering', 'MUI Cache',
    'Sound Events', 'Windows Services')
$names = Select-String -Path (Join-Path $root 'rules\Windows.ini') -Pattern '^\[(.+)\]$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
$ini = @('[Options]') + ($names | ForEach-Object { "$_=False" }) + @('Custom Files and Folders=True', "Include1=$junk|*.*|RECURSE", 'SecureDeletePasses=7') +
    ($cats | ForEach-Object { "Reg:$_=" + ($_ -eq 'MUI Cache') })
Set-Content (Join-Path $appDir 'MakeCleaner.ini') $ini -Encoding UTF8

$muiPath = 'Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache'
$mui = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($muiPath)
$fixDir = "C:\mc-g1-fix-$rnd\a-rather-long-folder-name-that-overflows-the-data-column"
$fixNames = @('one', 'two') | ForEach-Object { "$fixDir\$_.exe.FriendlyAppName" }
foreach ($n in $fixNames) { $mui.SetValue($n, 'MakeCleaner G1 fix fixture') }

$app = $null
function Shot($name) { $null = Save-AutoScreenshot $app (Join-Path $Shots "fix-MC-G1-$name.bmp"); Write-Host "shot: fix-MC-G1-$name" }
function Items() { @(Get-AutoItems $app) }
function WaitLabel($like, $ms = 30000) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) {
        $hit = @(Items | Where-Object { $_.label -like $like })
        if ($hit.Count -gt 0) { return $hit[0] }
        $null = Invoke-AutoFrames $app 2
        Start-Sleep -Milliseconds 100
    }
    throw "timeout waiting for '$like'"
}
function Check($cond, $msg) { if (-not $cond) { throw "FAILED: $msg" }; Write-Host "ok: $msg" }
function Settle($ms) { $end = (Get-Date).AddMilliseconds($ms); while ((Get-Date) -lt $end) { $null = Invoke-AutoFrames $app 1; Start-Sleep -Milliseconds 50 } }

$envs = @{ TEMP = $temp; TMP = $temp; APPDATA = $roaming; LOCALAPPDATA = $local }
try {
    $app = Start-AutoApp -Exe (Join-Path $appDir 'MakeCleaner.exe') -Env $envs
    $null = WaitLabel '*applications detected##status'
    Shot 'cleaner-empty'
    $r = @(Items | Where-Object { $_.label -eq 'Summary##viewSummary' })[0]
    Write-Host ("radio item: " + ($r | ConvertTo-Json -Compress))

    # ---------------- modal dim (About), early and settled
    Invoke-AutoClick $app 'About##about'
    $null = WaitLabel 'MakeCleaner 2.0.0*##dialogText' 5000
    Shot 'about-3frames'
    Settle 600
    Shot 'about-settled'
    Invoke-AutoKey $app 'Enter'; $null = Invoke-AutoFrames $app 3

    # ---------------- Registry: empty list, then cell tooltip
    Invoke-AutoClick $app 'Registry'
    $null = WaitLabel 'Pick the categories*##regstatus' 5000
    Shot 'registry-empty'
    Invoke-AutoClick $app 'Scan for Issues##regscan'
    $null = WaitLabel 'Scan complete*##regstatus' 60000
    $fx1 = WaitLabel "##rc*:*mc-g1-fix-$rnd*one.exe*"
    $row = '##row' + ($fx1.label -replace '^##rc(\d+):.*$', '$1')
    Invoke-AutoClick $app $row -Kind hover
    Settle 1200
    Shot 'registry-tooltip'

    # ---------------- Cleaner: analyze, Files view, then close during Run Cleaner
    Invoke-AutoClick $app 'Cleaner'; $null = Invoke-AutoFrames $app 3
    Invoke-AutoClick $app 'Analyze##analyze'
    $st = WaitLabel 'Analysis complete*##status' 60000
    Write-Host "status: $($st.label)"
    Invoke-AutoClick $app 'Files##viewFiles'; $null = Invoke-AutoFrames $app 3
    Shot 'cleaner-files'
    Invoke-AutoClick $app 'Run Cleaner##clean'
    $null = WaitLabel 'Cleaning...##status' 5000
    Start-Sleep -Milliseconds 800
    $left = @(Get-ChildItem $junk -File).Count
    Write-Host "files left when closing: $left of 100"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = $app.Process.CloseMainWindow()
    $exited = $app.Process.WaitForExit(5000)
    $sw.Stop()
    $after = @(Get-ChildItem $junk -File).Count
    Write-Host ("exit after {0} ms, exit code {1}, files left after exit: {2}" -f $sw.ElapsedMilliseconds, $(if ($exited) { $app.Process.ExitCode } else { '-' }), $after)
    Check $exited 'closing during Run Cleaner exits within 5 s'
    Check ($app.Process.ExitCode -eq 0) 'exit code 0'
    Check ($after -gt 0) 'the clean was still running when the process ended (files left)'
    Check ((Get-Content (Join-Path $appDir 'MakeCleaner.ini')) -contains 'Custom Files and Folders=True') 'ticks saved before the early exit'
    Write-Host 'G1 FIX TEST OK'
} catch {
    Write-Host "ERROR: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
    if ($app -and -not $app.Process.HasExited) { try { Shot 'error' } catch { } }
    throw
} finally {
    $ErrorActionPreference = 'Continue'
    if ($app -and -not $app.Process.HasExited) { $null = Stop-AutoApp $app }
    foreach ($n in $fixNames) { try { $mui.DeleteValue($n, $false) } catch { } }
    $mui.Close()
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $T -ErrorAction SilentlyContinue
    $py = "import sys,glob,os`nfrom PIL import Image`nfor b in glob.glob(os.path.join(sys.argv[1],'fix-MC-G1-*.bmp')):`n    Image.open(b).save(b[:-4]+'.png'); os.remove(b)"
    $pyFile = Join-Path ([IO.Path]::GetTempPath()) "g1fix-bmp2png-$rnd.py"
    Set-Content $pyFile $py -Encoding Ascii
    foreach ($v in @('-3.12', '-3.10')) { & py $v -c 'import PIL' 2>$null; if ($LASTEXITCODE -eq 0) { & py $v $pyFile $Shots; break } }
    Remove-Item $pyFile -ErrorAction SilentlyContinue
}
