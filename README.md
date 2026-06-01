# TapTapLoot Watchdog

A tiny, no-admin helper that works around the memory leak in Tap Tap Loot
(`BongoCatBuffSystem`) by **restarting the game(s) every 30 minutes — but only if
they're currently open.** Restarts go *through Steam* and close the game
gracefully first, so saves and Steam Cloud sync normally.

Watches both **Tap Tap Loot** (`appid 3959890`) and **Bongo Cat** (`appid 3419430`).

## Why this exists

Tap Tap Loot leaks memory the longer it runs. The cause is in its buff system
(`BongoCatBuffSystem`): buffs are applied as runtime `ScriptableObject` effects,
but the "remove buff" path builds a *brand-new* object to look up what to remove.
Because those objects compare by reference, the lookup never matches — so:

- buffs are **never actually removed** (they pile up on the player),
- the internal effect list/dictionary **grows without bound**, and
- each update **orphans more `ScriptableObject`s**, which Unity does not
  garbage-collect on their own.

This is driven on a loop by the Bongo Cat buff feed, so memory climbs steadily
during a long session and the game gets slower over time. It's a bug in the game
that only the developers can fix in source.

This helper can't patch the game, so it does the next best thing: it gives the
process a **clean slate on a schedule**. Periodically restarting the game frees
the accumulated objects and resets memory back to baseline — keeping it playable
during long idle sessions. It restarts *through Steam* and closes the game
gracefully first specifically so your progress and Steam Cloud saves are
preserved. (Full technical write-up: [`MEMORY_LEAK_REPORT.md`](MEMORY_LEAK_REPORT.md).)

## Install

**Easiest (single file):** download **`Install-TapTapLootWatchdog.bat`** from the
[latest release](../../releases/latest) and double-click it. That one file contains
everything — no other downloads needed.

**Or from a clone of this repo:** double-click **`Install.bat`**.

That's it. No admin needed.

- It first tries to register a per-user **Scheduled Task**. If the PC locks that
  down (some do), it automatically falls back to a **Startup-folder shortcut +
  a lightweight resident loop** — still no admin.
- Auto-starts at every Windows logon.
- Re-running `Install.bat` just **updates** the existing install (no duplicates).

## Options

Run from a terminal in this folder if you want to tweak things:

```powershell
# Change the interval (e.g. 20 minutes):
powershell -ExecutionPolicy Bypass -File .\Install-TapTapLootWatchdog.ps1 -IntervalMinutes 20

# Skip Task Scheduler and always use the resident loop:
powershell -ExecutionPolicy Bypass -File .\Install-TapTapLootWatchdog.ps1 -ForceResident

# Dry run — log what it WOULD restart, without touching anything:
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\TapTapLootWatchdog\watchdog.ps1" -DryRun
```

## Uninstall

Double-click **`Uninstall.bat`** (removes the task/shortcut and all files).

## Where things go

- Worker script + log: `%LOCALAPPDATA%\TapTapLootWatchdog\`
  (`watchdog.log` shows each check and restart — handy to confirm it's working.)
- Startup shortcut (fallback mode only):
  `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\TapTapLoot Watchdog.lnk`

## Notes

- It only ever **restarts games that are already running** — if neither is open,
  it does nothing.
- It does **not** touch your save files or game install; it just closes and
  relaunches the game.
- **No Steam launch popup:** it relaunches the game's `.exe` directly with the
  `SteamAppId` environment variable set, so the game doesn't bounce itself back
  through Steam (which would show the focus-stealing "preparing to launch"
  dialog). Steam stays running, so Steam Cloud and the overlay still work. If the
  exe path can't be read for some reason, it falls back to `steam://` (which does
  show the popup).
- **Focus is handed back:** the game window grabs focus when it relaunches, so the
  watchdog remembers whatever window you were using and restores it a few seconds
  later — unless you were actually in the game at the time.
- Editing which games are watched: change the `$targets` list near the top of
  `watchdog.ps1` (in the install folder), or edit the installer and re-run it.
