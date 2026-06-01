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

function Invoke-Check {
    param([bool]$Dry)
    Log "--- tick (DryRun=$Dry) ---"
    foreach ($t in $targets) {
        $procs = @(Get-Process -Name $t.Process -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) { Log "$($t.Name): not running - skip."; continue }

        Log "$($t.Name): running (PID $($procs.Id -join ',')) - restarting."
        if ($Dry) { Log "$($t.Name): [DryRun] would close + relaunch via steam://rungameid/$($t.AppId)."; continue }

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

        # Relaunch through Steam (preserves cloud saves + overlay; starts Steam if needed).
        Start-Process "steam://rungameid/$($t.AppId)"
        Log "$($t.Name): relaunched via steam://rungameid/$($t.AppId)."
        Start-Sleep -Seconds 3
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
