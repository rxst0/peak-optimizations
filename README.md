# Peak Optimizations

A lightweight Windows 10/11 optimization utility inspired by Chris Titus Tech's WinUtil.
One PowerShell file (~80 KB), no install, no dependencies — it uses the PowerShell 5.1 + WPF that ship with Windows.

## Run

Double-click **`Launch Peak Optimizations.bat`** and accept the UAC prompt.
(Or: `powershell -ExecutionPolicy Bypass -File .\PeakOptimizations.ps1`)

## Tabs

| Tab | What it does |
|---|---|
| **Home** | System overview (OS, CPU, GPU, RAM, disk, uptime, power plan) and quick actions |
| **Install** | ~70 curated apps via `winget`: install/upgrade, uninstall, upgrade all, detect installed, search |
| **Tweaks** | 13 essential + 16 advanced tweaks, Standard / Minimal / Gaming presets, **Undo Selected**, 16 instant preference toggles |
| **Config** | Windows features (.NET 3.5, Hyper-V, WSL, Sandbox…), fixes (network reset, Windows Update reset, DISM+SFC, component cleanup, winget reset), DNS switcher, legacy control panels |
| **Updates** | Security-only (recommended), Default, or Disable all |

**Export/Import Config** saves your app, tweak and feature selections to JSON so you can reuse them on another PC.

## Undo

Before a tweak changes a registry value or service, the original is saved to
`%ProgramData%\PeakOptimizations\backup.json`. **Undo Selected** restores those exact values.
The activity log is written to `peak.log` in the same folder.
Tweaks that delete things (temp files, bloatware, disk cleanup) can't be undone. Use **Create Restore Point** first.

## Adding your own

Everything is data-driven near the top of the script:
- **Apps**: add `'Name|Winget.Id'` to `$AppCatalog`
- **Tweaks**: add an entry to `$Tweaks` with `Registry`, `Services`, `Tasks`, `Script` and/or `Undo`
- **Preferences**: add an entry to `$Toggles` with `On`/`Off` registry values

`.\PeakOptimizations.ps1 -SelfTest` builds the UI without showing it, to validate your edits.
