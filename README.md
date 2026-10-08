# Peak Optimizations

A lightweight Windows 10/11 optimization utility inspired by Chris Titus Tech's WinUtil.
One PowerShell file (~267 KB) plus a tiny installer, no dependencies — it uses the PowerShell 5.1 + WPF that ship with Windows.

## Install

1. Download **PeakOptimizations-vX.Y.Z.zip** from [Releases](https://github.com/rxst0/peak-optimizations/releases/latest) and extract it.
2. Double-click **`Install Peak Optimizations.bat`** and accept the admin prompt.

That's it — search **"Peak"** in the Start menu to open it (there's a desktop shortcut too).
It installs to `C:\Program Files\Peak Optimizations`, appears in **Settings › Apps**, and can be uninstalled from there.
Installing a new version replaces the old one completely: the old program files are removed, and older Peak Optimizations downloads (zips and extracted folders in Downloads, Desktop and Documents) are deleted after asking. Your settings, tweak backups and macros are kept.

**Without installing:** double-click `Launch Peak Optimizations.bat` instead.

## Community

Join the Discord: **https://discord.gg/C4junEJ6mk**

## Tabs

| Tab | What it does |
|---|---|
| **Home** | **Boost Performance** in one click: clears temp files, browser caches (not history, passwords or logins), old crash reports, leftover update downloads and the DNS cache, and releases cached RAM that isn't in use. Plus a system overview (OS, CPU, GPU, RAM, disk, uptime, power plan, core isolation) and quick actions |
| **Background** | Shows apps running in the background without a window and how much memory each uses, with safe ones pre-selected — **End Selected** closes them. Also finds closed apps Windows keeps **frozen in memory doing nothing** (suspended). **Auto-end useless background tasks** does it for you every 5–60 minutes, optionally even while the app is closed (a hidden scheduled task that runs a quick clean and exits). Windows itself, apps you have open, security, anti-cheat and drivers are never touched. Plus a **Start with Windows** list to stop apps launching at sign-in (same switch as Task Manager) |
| **Install** | ~70 curated apps via `winget`: install/upgrade, uninstall, upgrade all, detect installed, search |
| **Tweaks** | 13 essential, 9 competitive and 16 advanced tweaks, Standard / Minimal / Gaming presets, **Undo Selected**, 16 instant preference toggles. Competitive tweaks are **core-isolation safe**: they never turn off Memory Integrity, VBS, CPU mitigations, DEP or Defender, so anti-cheats like Vanguard and FACEIT keep working |
| **Games** | One-click presets for **Fortnite, Rust, Rainbow Six Siege, Arc Raiders, Valorant, Marvel Rivals, The Finals, Satisfactory, Minecraft (Java), Roblox, GTA V and Skyrim Special Edition** — Competitive / Max FPS / Balanced for shooters, Max FPS / Balanced / Best Looking for the rest (e.g. Siege Competitive keeps shadows on High so you see enemy shadows). Edits each game's own settings file (only settings already in it), sets Windows to use the high-performance GPU, shows whether the game kept the preset after you play, and backs everything up so **Restore Original** puts it back. Resolution, sensitivity, keybinds and FPS cap are never changed |
| **Macros** | Full macro editor: **Start/Stop Recording** (choose to record delays, mouse moves, mouse clicks and click positions), steps shown as `f Hold` / `0.01 Delay` / `{LMouse} Release`, **Insert** keys, delays, mouse buttons and scrolls, **Delete / Move Up / Move Down**, edit any delay, **Bind to Key**, **Play once / Repeat N times / Repeat until stopped**, speed, Save/Cancel, and **import/export** as JSON (imports keep only key/mouse/delay steps). F8 stops recording. **Using macros in online games can get you banned by anti-cheat — use them where the game allows it** |
| **Display** | Every monitor's resolution and refresh rate, picked from the modes it really supports, plus **Max Refresh Rate**. Changes switch back by themselves after 15 seconds unless you click Keep |
| **Peripherals** | Mouse pointer speed, acceleration, scroll lines, double-click speed and button swap; keyboard repeat delay and rate (applied instantly); list of connected keyboards and mice |
| **Drivers** | Detects your graphics card(s) and motherboard, shows driver/BIOS version and age, and links straight to the official driver page for your exact model (AMD Radeon RX and AMD chipset pages are model-specific). Scans Windows Update for drivers matched to your hardware and installs the ones you pick |
| **Config** | Windows features (.NET 3.5, Hyper-V, WSL, Sandbox…), fixes (network reset, Windows Update reset, DISM+SFC, component cleanup, winget reset), DNS switcher, legacy control panels |
| **Updates** | Security-only (recommended), Default, or Disable all |
| **Discord** | Join the community server for help, FPS results, game requests and update news |

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
