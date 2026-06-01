@echo off
REM Double-click to remove the TapTapLoot Watchdog (task + files).
title TapTapLoot Watchdog Uninstaller
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-TapTapLootWatchdog.ps1" -Uninstall
echo.
pause
