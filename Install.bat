@echo off
REM Double-click to install/update the TapTapLoot Watchdog (no admin needed).
title TapTapLoot Watchdog Installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-TapTapLootWatchdog.ps1" %*
echo.
pause
