@echo off
REM ===================================================================
REM  TapTapLoot Watchdog - single-file installer
REM  Double-click to install/update (no admin). From a terminal you can
REM  also pass options, e.g.:
REM     Install-TapTapLootWatchdog.bat -IntervalMinutes 20
REM     Install-TapTapLootWatchdog.bat -ForceResident
REM     Install-TapTapLootWatchdog.bat -Uninstall
REM  How it works: this .bat embeds a PowerShell script after the marker
REM  below; it extracts that to a temp file, runs it, then deletes it.
REM ===================================================================
title TapTapLoot Watchdog Installer
setlocal
set "_TTLPS=%TEMP%\TapTapLootWatchdog_%RANDOM%%RANDOM%.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f=[IO.File]::ReadAllText('%~f0');$m='#:::PSCODE'+':::';$i=$f.LastIndexOf($m)+$m.Length;[IO.File]::WriteAllText($env:_TTLPS,$f.Substring($i),[Text.UTF8Encoding]::new($false))"
powershell -NoProfile -ExecutionPolicy Bypass -File "%_TTLPS%" %*
del "%_TTLPS%" >nul 2>&1
endlocal
echo.
pause
exit /b
#:::PSCODE:::
<#
    TapTapLoot Watchdog - self-contained installer
    --------------------------------------------------
    Installs a tiny background helper that, every N minutes, restarts Tap Tap Loot
    and/or Bongo Cat *only if they are currently running* - working around the
    BongoCatBuffSystem memory leak by giving the process a fresh start.

    Key properties:
      - NO admin rights required.
      - Auto-starts at Windows logon.
      - Restarts THROUGH Steam (steam://rungameid/...) so Steam Cloud saves sync.
      - Closes the game gracefully first (lets it save); force-kills only if it hangs.
      - Re-running this installer just updates the existing install.

    Install mechanism (chosen automatically):
      1. Preferred: a per-user Scheduled Task (logon + every N min). No resident process.
      2. Fallback (if Task Scheduler is locked down): a Startup-folder shortcut that
         launches a lightweight resident loop. Still no admin needed.

    Usage:
        Double-click Install.bat  (or right-click this file > Run with PowerShell)
        Change interval:   -IntervalMinutes 20
        Force resident mode (skip Task Scheduler):   -ForceResident
        Remove everything: -Uninstall   (or Uninstall.bat)
#>
[CmdletBinding()]
param(
    [int]    $IntervalMinutes = 30,
    [switch] $ForceResident,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

$AppName       = 'TapTapLootWatchdog'
$TaskName      = 'TapTapLoot Watchdog'
$InstallDir    = Join-Path $env:LOCALAPPDATA $AppName
$WorkerPath    = Join-Path $InstallDir 'watchdog.ps1'
$StartupDir    = [Environment]::GetFolderPath('Startup')
$ShortcutPath  = Join-Path $StartupDir 'TapTapLoot Watchdog.lnk'
$PsExe         = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Write-Step($m){ Write-Host "  $m" -ForegroundColor Cyan }
function Write-Ok($m)  { Write-Host "  $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "  $m" -ForegroundColor Yellow }

function Stop-Residents {
    # Stop any already-running resident worker (so updates take effect).
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'watchdog\.ps1' -and $_.CommandLine -match '-Resident' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
}

Write-Host ""
Write-Host "=== TapTapLoot Watchdog ===" -ForegroundColor White

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if ($Uninstall) {
    Write-Step "Stopping resident helper (if running)..."; Stop-Residents
    Write-Step "Removing scheduled task..."
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; Write-Ok "Task removed." }
    catch { Write-Warn2 "No scheduled task present." }
    if (Test-Path $ShortcutPath) { Remove-Item $ShortcutPath -Force -ErrorAction SilentlyContinue; Write-Ok "Startup shortcut removed." }
    if (Test-Path $InstallDir)   {
        try { Remove-Item $InstallDir -Recurse -Force -ErrorAction Stop; Write-Ok "Files removed." }
        catch { Write-Warn2 "Could not remove $InstallDir : $($_.Exception.Message)" }
    }
    Write-Host ""; Write-Ok "Uninstall complete."
    return
}

# ---------------------------------------------------------------------------
# 1) Write the worker script
# ---------------------------------------------------------------------------
Write-Step "Installing to $InstallDir ..."
Stop-Residents
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# Worker stored literally (single-quoted here-string) so its own $vars are not
# expanded at install time.
$worker = @'
<#  TapTapLoot Watchdog worker.
    Modes:
      (default)           one check, restart any listed game that is running.
      -DryRun             one check, log only (no restart).
      -Resident           loop forever: every IntervalMinutes, do a check.
#>
param(
    [switch]$DryRun,
    [switch]$Resident,
    [int]$IntervalMinutes = 30
)
$ErrorActionPreference = 'SilentlyContinue'

$log = Join-Path $PSScriptRoot 'watchdog.log'
function Log($m) {
    "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m | Out-File -FilePath $log -Append -Encoding utf8
}
if ((Test-Path $log) -and ((Get-Item $log).Length -gt 512KB)) { Clear-Content $log }

# Games to watch.  Process = name WITHOUT .exe.  AppId = Steam app id.
$targets = @(
    @{ Name = 'Tap Tap Loot'; Process = 'TapTapLoot'; AppId = 3959890 },
    @{ Name = 'Bongo Cat';    Process = 'BongoCat';   AppId = 3419430 }
)

# Win32 helpers so we can put YOUR previous window back in front after a restart
# (the game grabs focus when it launches).  Best-effort; failures are ignored.
$script:HasFocusApi = $false
try {
    Add-Type -ErrorAction Stop -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace TtlWd {
  public static class Win {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    public static uint PidOf(IntPtr h){ uint p; GetWindowThreadProcessId(h, out p); return p; }
    public static void Restore(IntPtr h){
      if (h == IntPtr.Zero || !IsWindow(h)) return;
      IntPtr fg = GetForegroundWindow();
      uint dummy;
      uint t1 = GetWindowThreadProcessId(fg, out dummy);
      uint t2 = GetWindowThreadProcessId(h, out dummy);
      uint me = GetCurrentThreadId();
      AttachThreadInput(t1, me, true); AttachThreadInput(t2, me, true);
      BringWindowToTop(h); SetForegroundWindow(h);
      AttachThreadInput(t1, me, false); AttachThreadInput(t2, me, false);
    }
  }
}
"@
    $script:HasFocusApi = $true
} catch { $script:HasFocusApi = $false }

function Restart-One {
    param($t, [bool]$Dry)
    $procs = @(Get-Process -Name $t.Process -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { Log "$($t.Name): not running - skip."; return $false }

    Log "$($t.Name): running (PID $($procs.Id -join ',')) - restarting."
    if ($Dry) { Log "$($t.Name): [DryRun] would restart."; return $true }

    # Remember the exe path BEFORE closing, so we can relaunch it directly.
    $exe = $null
    try { $exe = $procs[0].Path } catch { }

    # Graceful close so the game runs its normal save-on-quit.
    foreach ($p in $procs) { $null = $p.CloseMainWindow() }

    # Wait up to 25s for a clean exit (lets the game save + Steam Cloud sync).
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Process -Name $t.Process -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $deadline)) {
        Start-Sleep -Milliseconds 500
    }

    # Force-kill only if it refused to close.
    $still = @(Get-Process -Name $t.Process -ErrorAction SilentlyContinue)
    if ($still.Count -gt 0) {
        Log "$($t.Name): did not close in time - force killing."
        $still | Stop-Process -Force
        Start-Sleep -Seconds 2
    }

    if ($exe -and (Test-Path $exe)) {
        # Launch the exe directly with SteamAppId/SteamGameId set.  This makes the
        # game's SteamAPI.RestartAppIfNecessary() return false, so it runs straight
        # away WITHOUT Steam's focus-stealing "preparing to launch" popup.  Steam is
        # already running, so Steam Cloud / overlay still work.
        $env:SteamAppId  = "$($t.AppId)"
        $env:SteamGameId = "$($t.AppId)"
        try { Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) } catch { }
        Remove-Item Env:\SteamAppId  -ErrorAction SilentlyContinue
        Remove-Item Env:\SteamGameId -ErrorAction SilentlyContinue
        Log "$($t.Name): relaunched directly (no Steam popup): $exe"
    }
    else {
        # Fallback if we couldn't read the exe path (shows the Steam popup).
        Start-Process "steam://rungameid/$($t.AppId)"
        Log "$($t.Name): exe path unknown - relaunched via steam://rungameid/$($t.AppId)."
    }
    Start-Sleep -Seconds 3
    return $true
}

function Invoke-Check {
    param([bool]$Dry)
    Log "--- tick (DryRun=$Dry) ---"

    # Capture the window you're currently using, so we can hand focus back after.
    $prevWin = [IntPtr]::Zero; $prevPid = 0
    if (-not $Dry -and $script:HasFocusApi) {
        try { $prevWin = [TtlWd.Win]::GetForegroundWindow(); $prevPid = [TtlWd.Win]::PidOf($prevWin) } catch { }
    }

    $restarted = $false
    $gamePids  = @()
    foreach ($t in $targets) {
        $gamePids += @(Get-Process -Name $t.Process -ErrorAction SilentlyContinue).Id
        if (Restart-One $t $Dry) { $restarted = $true }
    }

    # If you were working in some OTHER window, put it back in front (the game's
    # window will have stolen focus while launching).  Skip if you were in the game.
    if ($restarted -and -not $Dry -and $script:HasFocusApi -and $prevWin -ne [IntPtr]::Zero) {
        Start-Sleep -Seconds 4   # let the game window appear & grab focus first
        try {
            if (([TtlWd.Win]::IsWindow($prevWin)) -and ($gamePids -notcontains $prevPid)) {
                [TtlWd.Win]::Restore($prevWin)
                Log "focus: restored your previous window."
            } else {
                Log "focus: previous window was a restarted game (or gone) - left as-is."
            }
        } catch { Log "focus: restore attempt failed (ignored)." }
    }
    Log "--- tick done ---"
}

if ($Resident) {
    # Single-instance guard so we never run two loops.
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\TapTapLootWatchdog', [ref]$created)
    if (-not $created) { Log "resident: another instance already running - exiting."; return }
    $sleepSec = [Math]::Max(60, $IntervalMinutes * 60)
    Log "resident: started (every $IntervalMinutes min)."
    try {
        while ($true) {
            Start-Sleep -Seconds $sleepSec   # wait first so we don't restart a game right at logon
            Invoke-Check -Dry:$false
        }
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
else {
    Invoke-Check -Dry:$DryRun
}
'@

Set-Content -Path $WorkerPath -Value $worker -Encoding UTF8 -Force
Write-Ok "Worker written: $WorkerPath"

# Clean any previous mechanism so we start from a known state.
try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
if (Test-Path $ShortcutPath) { Remove-Item $ShortcutPath -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# 2) Preferred: per-user Scheduled Task (unless -ForceResident)
# ---------------------------------------------------------------------------
$installedVia = $null

if (-not $ForceResident) {
    Write-Step "Trying Scheduled Task (every $IntervalMinutes min, at logon)..."
    try {
        $action = New-ScheduledTaskAction -Execute $PsExe `
                    -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $WorkerPath)

        $repInterval  = New-TimeSpan -Minutes $IntervalMinutes
        $rep = (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($IntervalMinutes) -RepetitionInterval $repInterval).Repetition

        $logonTrigger = New-ScheduledTaskTrigger -AtLogOn
        $logonTrigger.Repetition = $rep
        $nowTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($IntervalMinutes)
        $nowTrigger.Repetition = $rep

        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
                        -LogonType Interactive -RunLevel Limited

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($logonTrigger, $nowTrigger) `
            -Settings $settings -Principal $principal `
            -Description "Restarts Tap Tap Loot / Bongo Cat every $IntervalMinutes min if running (memory-leak workaround)." -ErrorAction Stop | Out-Null

        $installedVia = 'task'
        Write-Ok "Scheduled task registered."
    }
    catch {
        Write-Warn2 "Task Scheduler unavailable without admin on this PC - using the no-admin fallback."
    }
}

# ---------------------------------------------------------------------------
# 3) Fallback: Startup-folder shortcut + resident loop (no admin)
# ---------------------------------------------------------------------------
if ($installedVia -ne 'task') {
    Write-Step "Setting up Startup helper (resident, no admin needed)..."
    $args = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Resident -IntervalMinutes {1}' -f $WorkerPath, $IntervalMinutes

    $wsh = New-Object -ComObject WScript.Shell
    $sc  = $wsh.CreateShortcut($ShortcutPath)
    $sc.TargetPath       = $PsExe
    $sc.Arguments        = $args
    $sc.WorkingDirectory = $InstallDir
    $sc.WindowStyle      = 7   # minimized
    $sc.Description      = 'TapTapLoot Watchdog (memory-leak workaround)'
    $sc.Save()
    Write-Ok "Startup shortcut created: $ShortcutPath"

    # Start it now so it's active without needing to log off/on.
    Start-Process -FilePath $PsExe -ArgumentList $args -WindowStyle Hidden | Out-Null
    $installedVia = 'resident'
    Write-Ok "Resident helper started."
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Ok "Done! The watchdog is active."
if ($installedVia -eq 'task') {
    Write-Host "  - Mechanism : Scheduled Task '$TaskName' (no resident process)." -ForegroundColor Gray
} else {
    Write-Host "  - Mechanism : Startup shortcut + lightweight resident loop." -ForegroundColor Gray
}
Write-Host "  - Interval  : every $IntervalMinutes minutes; only restarts games that are open." -ForegroundColor Gray
Write-Host "  - Autostart : runs at Windows logon." -ForegroundColor Gray
Write-Host "  - Log file  : $InstallDir\watchdog.log" -ForegroundColor Gray
Write-Host "  - Test now  : powershell -ExecutionPolicy Bypass -File `"$WorkerPath`" -DryRun" -ForegroundColor Gray
Write-Host "  - Uninstall : Uninstall.bat  (or this script with -Uninstall)" -ForegroundColor Gray
Write-Host ""
