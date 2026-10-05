# Peak Optimizations

A lightweight Windows 10/11 optimization utility inspired by Chris Titus Tech's WinUtil.
One PowerShell file (~177 KB), no install, no dependencies — it uses the PowerShell 5.1 + WPF that ship with Windows.

## Run

Double-click **`Launch Peak Optimizations.bat`** and accept the UAC prompt.
(Or: `powershell -ExecutionPolicy Bypass -File .\PeakOptimizations.ps1`)

## Tabs

| Tab | What it does |
|---|---|
| **Home** | System overview (OS, CPU, GPU, RAM, disk, uptime, power plan) and quick actions |
| **Install** | ~70 curated apps via `winget`: install/upgrade, uninstall, upgrade all, detect installed, search |
| **Tweaks** | 13 essential, 9 competitive and 16 advanced tweaks, Standard / Minimal / Gaming presets, **Undo Selected**, 16 instant preference toggles. Competitive tweaks are **core-isolation safe**: they never turn off Memory Integrity, VBS, CPU mitigations, DEP or Defender, so anti-cheats like Vanguard and FACEIT keep working |
| **Games** | **Competitive / Max FPS / Balanced** presets for **Fortnite, Rust and Rainbow Six Siege** (e.g. Siege Competitive keeps shadows on High so you see enemy shadows). Edits each game's own settings file, sets Windows to use the high-performance GPU, and backs everything up so **Restore Original** puts it back. Resolution, sensitivity, keybinds and FPS cap are never changed |
| **Macros** | Full macro editor: **Start/Stop Recording** (choose to record delays, mouse moves, mouse clicks and click positions), steps shown as `f Hold` / `0.01 Delay` / `{LMouse} Release`, **Insert** keys, delays, mouse buttons and scrolls, **Delete / Move Up / Move Down**, edit any delay, **Bind to Key**, **Play once / Repeat N times / Repeat until stopped**, speed, Save/Cancel, and **import/export** as JSON (imports keep only key/mouse/delay steps). F8 stops recording. **Using macros in online games can get you banned by anti-cheat — use them where the game allows it** |
| **Drivers** | Detects your graphics card(s) and motherboard, shows driver/BIOS version and age, and links straight to the official driver page for your exact model (AMD Radeon RX and AMD chipset pages are model-specific). Scans Windows Update for drivers matched to your hardware and installs the ones you pick |
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
