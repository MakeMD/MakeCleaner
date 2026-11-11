# Shared helpers for the MakeCleaner GUI smokes (tools\guismoke*.ps1, autosmoke.ps1, regsmoke.ps1). Dot-source it.
# Drives the Zig/ImGui exe through the MakeKit automation pipe (..\..\MakeKit\tools\imgui-auto.ps1), never UIA,
# never real input. Every run works on a sandbox copy: %TEMP%\makecleaner-test-<tag>-<rand>\app (+ portable.dat)
# with TEMP/TMP/APPDATA/LOCALAPPDATA pointed at sandbox fixture folders. Pure ASCII (PS 5.1).
. (Join-Path $PSScriptRoot '..\..\MakeKit\tools\imgui-auto.ps1')
# scans and analyses take longer than the kit's 5 s default
$PSDefaultParameterValues['Wait-AutoLabel:TimeoutMs'] = 30000
# the app version (build.zig.zon .version is the only place it is written)
$McVersion = [regex]::Match((Get-Content -Raw (Join-Path $PSScriptRoot '..\build.zig.zon')), '\.version\s*=\s*"([^"]+)"').Groups[1].Value

# Copies BinDir (exe + rules + notices, no pdb/ini/log/portable.dat) into a fresh sandbox; returns its paths.
function New-McSandbox {
    param([Parameter(Mandatory = $true)][string]$BinDir, [Parameter(Mandatory = $true)][string]$Tag)
    $root = Join-Path ([IO.Path]::GetTempPath()) ("makecleaner-test-$Tag-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $app = Join-Path $root 'app'
    $fx = Join-Path $root 'fx'
    New-Item -ItemType Directory -Force $app, (Join-Path $fx 'Temp'), (Join-Path $fx 'Local'), (Join-Path $fx 'Roaming') | Out-Null
    Get-ChildItem -LiteralPath $BinDir -Force | Where-Object { $_.Name -notmatch '\.(pdb|log)$|^portable\.dat$|^MakeCleaner\.ini$' } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $app -Recurse -Force }
    [IO.File]::WriteAllText((Join-Path $app 'portable.dat'), '#PORTABLE#')
    [pscustomobject]@{
        Root = $root; App = $app; Exe = (Join-Path $app 'MakeCleaner.exe'); Ini = (Join-Path $app 'MakeCleaner.ini'); Fx = $fx
        Temp = (Join-Path $fx 'Temp'); Local = (Join-Path $fx 'Local'); Roaming = (Join-Path $fx 'Roaming')
    }
}

function Get-McSections($file) {
    foreach ($l in [IO.File]::ReadAllLines($file)) { if ($l -match '^\[(.+)\]\s*$') { $Matches[1] } }
}

# Writes the sandbox ini: every Windows.ini rule and every Winapp2 rule off except -On, Custom Files and Folders
# per -On, then -Extra lines. Nothing outside the fixtures can be ticked unless a test ticks it itself.
function Set-McIni {
    param([Parameter(Mandatory = $true)]$Sb, [string[]]$On = @(), [string[]]$Extra = @())
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[Options]')
    foreach ($n in (Get-McSections (Join-Path $Sb.App 'rules\Windows.ini'))) { $lines.Add("$n=" + ($On -contains $n)) }
    $lines.Add('Custom Files and Folders=' + ($On -contains 'Custom Files and Folders'))
    foreach ($n in (Get-McSections (Join-Path $Sb.App 'rules\Winapp2.ini'))) { $lines.Add("$n=False") }
    foreach ($e in $Extra) { $lines.Add($e) }
    [IO.File]::WriteAllLines($Sb.Ini, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

# Environment of every sandbox run: fixture TEMP/AppData, window on \\.\DISPLAY<Screen>, English UI
# (MAKEKIT_LANG beats the Windows UI language and the saved Language= choice; the smokes compare English
# labels and status texts). Pass -Env @{ MAKEKIT_LANG = 'uk' } to run a smoke in another language.
# MAKEKIT_NO_UPDATE=1: no test run ever spawns MakeUpdate.exe (only tools\update-e2e.ps1 lifts it, against a local fake).
function Get-McEnv {
    param([Parameter(Mandatory = $true)]$Sb, [int]$Screen = 1, [hashtable]$Env = @{})
    $e = @{ TEMP = $Sb.Temp; TMP = $Sb.Temp; APPDATA = $Sb.Roaming; LOCALAPPDATA = $Sb.Local; MAKEKIT_DISPLAY = "\\.\DISPLAY$Screen"; MAKEKIT_LANG = 'en'; MAKEKIT_NO_UPDATE = '1' }
    foreach ($k in $Env.Keys) { $e[$k] = $Env[$k] }
    $e
}

function Start-McApp {
    param([Parameter(Mandatory = $true)]$Sb, [int]$Screen = 1, [hashtable]$Env = @{})
    Start-AutoApp -Exe $Sb.Exe -Env (Get-McEnv $Sb $Screen $Env) -TimeoutMs 30000
}

# Headless run (/auto): returns the exited process and whether it ever had a window.
function Invoke-McHeadless {
    param([Parameter(Mandatory = $true)]$Sb, [string[]]$Arguments = @(), [int]$Screen = 1, [hashtable]$Env = @{}, [int]$TimeoutMs = 120000)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Sb.Exe
    $psi.Arguments = $Arguments -join ' '
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $Sb.App
    $e = Get-McEnv $Sb $Screen $Env
    foreach ($k in $e.Keys) { $psi.EnvironmentVariables[$k] = [string]$e[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $sawWindow = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited) {
        $p.Refresh(); if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $sawWindow = $true }
        if ($sw.ElapsedMilliseconds -gt $TimeoutMs) { Stop-Process -Id $p.Id -Force; throw "headless run did not exit within $TimeoutMs ms" }
        Start-Sleep -Milliseconds 100
    }
    $p.WaitForExit()
    [pscustomobject]@{ ExitCode = $p.ExitCode; SawWindow = $sawWindow }
}

function Get-McItems($app, [string]$like = '*') { @(Get-AutoItems $app | Where-Object { $_.label -like $like }) }

# Replaces the text of an input: click it, select all, delete, type, Tab out.
function Set-McText($app, [string]$label, [string]$text) {
    Invoke-AutoClick $app $label; Invoke-AutoKey $app 'ctrl+A'; Invoke-AutoKey $app 'Delete'
    if ($text.Length -gt 0) { Invoke-AutoType $app $text }
    Invoke-AutoKey $app 'Tab'
    $null = Invoke-AutoFrames $app 2
}

function Save-McShot($app, [string]$png) {
    $null = Invoke-AutoFrames $app 3
    New-Item -ItemType Directory -Force (Split-Path ([IO.Path]::GetFullPath($png))) | Out-Null
    Write-Host ("screenshot: " + (Save-AutoScreenshot $app $png -Png))
}

# WM_CLOSE (the real close path: saves the Cleaner ticks); kills by PID if it hangs. Returns the exit code.
function Close-McApp($app) {
    $null = $app.Process.CloseMainWindow()
    if (-not $app.Process.WaitForExit(10000)) { $null = Stop-AutoApp $app; throw 'app did not exit on WM_CLOSE' }
    try { $app.Pipe.Dispose() } catch { }
    $app.Process.ExitCode
}

function Remove-McSandbox($sb, $app) {
    if ($app -and -not $app.Process.HasExited) { $null = Stop-AutoApp $app }
    # retried: an AV scanner briefly holds the fresh exe (and so app\) open after a failed or finished run
    if ($sb) { for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath $sb.Root); $i++) { Start-Sleep -Milliseconds 250; Remove-Item -LiteralPath $sb.Root -Recurse -Force -ErrorAction SilentlyContinue } }
}
