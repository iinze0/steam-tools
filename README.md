# steam-tools (Windows 10/11)

Steam leftovers, save backups, and a single game list — no Python, no Linux paths.

Works with extra Steam libraries (`D:\Games`, etc). Reads the Steam install path from the registry.

| Command | What it does |
|:--------|:-------------|
| `steam-reclaim` | leftover `common` folders and shader caches after uninstall |
| `steam-saves` | backup local Steam Cloud folders |
| `shelf` | list / size / launch installed Steam (and Epic) games |

## Install

PowerShell:

```powershell
irm https://raw.githubusercontent.com/iinze0/steam-tools/main/install.ps1 | iex
```

Close and reopen the terminal. Then:

```powershell
steam-reclaim
steam-saves list
shelf
```

Scripts land in `%LOCALAPPDATA%\iinze0\bin` and that folder is added to your user PATH.

## Use

### steam-reclaim

```powershell
steam-reclaim
steam-reclaim -Apply
```

Lists orphan game folders and shader caches. `-Apply` deletes after a yes prompt. Close Steam first.

### steam-saves

```powershell
steam-saves list
steam-saves backup
steam-saves backup elden
steam-saves restore -From "$env:USERPROFILE\SteamSaves\2026-09-25"
```

Default backup folder: `%USERPROFILE%\SteamSaves\YYYY-MM-DD`.

### shelf

```powershell
shelf
shelf -Size
shelf hades
shelf elden -Path
shelf -Store steam
```

If several names match, it lists them instead of launching the wrong one.

## Notes

- Windows PowerShell 5.1 is enough (built into Windows 10/11).
- Set `STEAM_PATH` if Steam is in a weird place.
- `shelf` also reads Epic manifests under `C:\ProgramData\Epic\...` when they exist.
- These do not touch VAC, achievements, or other accounts.
