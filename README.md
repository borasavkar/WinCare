# WinCare

A clean, minimal maintenance tool for **Windows 11**. It checks your PC's health and keeps it tidy using only tools built into Windows — no installers, no services, no telemetry.

## Features

- **Overview** — one glance tells you whether your PC is healthy, plus a short list of anything that needs attention
- **Quick care** (1-2 min) — safe cleanup and an instant integrity check, no questions asked
- **Deep care** (10-20 min) — adds DISM repair (only when needed), SFC, a read-only file system scan and SSD TRIM
- **Cleanup** — every location is measured first; only what you select is removed
- **System health** — check first, repair only when needed:
  `DISM /CheckHealth` `/ScanHealth` `/RestoreHealth`, `sfc /verifyonly` `/scannow` `/scanfile`,
  `winmgmt /verifyrepository` `/salvagerepository`, app update check (winget)
- **After Windows Update** — `DISM /StartComponentCleanup` removes superseded update files
- **Startup problems** — restart into the recovery environment with the right `bootrec` / `bcdboot` commands for your firmware
- **Disks** — free space, SMART health (temperature, wear, errors), read-only file system scan,
  `chkdsk /f` `/r` `/f /r /x`, media-aware optimization (TRIM for SSD, defrag for HDD only)
- **Network** — connection diagnosis, `ipconfig /flushdns`, adapter restart,
  `netsh winsock reset` and `netsh int ip reset` (opt-in, with warnings)
- **Multilingual** — English and Turkish included; adding a language is one JSON file
- Follows the Windows light/dark theme and accent color

## Safety principles

| Rule | Why |
|---|---|
| SSDs are **never** defragmented, only trimmed | Defragmentation writes data and wears flash memory |
| Read-only checks first, changes second | You always see the result before anything is modified |
| Irreversible actions always ask | Recycle Bin, image repair, component cleanup |
| Safety lock on every delete | Drive roots, Windows and profile folders can never be targets |
| No `/ResetBase`, no Prefetch deletion, no registry "cleaning" | Harmful or irreversible |
| `fsutil dirty set` is never used | It does not clear NTFS repair records and causes endless "disk error" loops |
| Network resets are never automatic | Winsock / TCP-IP resets remove VPN and custom IP settings |
| Thumbnail, icon, GPU shader, Prefetch and font caches are never cleaned | They make Windows and games faster; deleting them only forces a slow rebuild |
| Culture-invariant path checks | On Turkish Windows culture-aware matching breaks on the letter I |

## Requirements

- Windows 11 (Windows 10 21H2+ should work)
- Administrator rights
- Windows PowerShell 5.1 (built in)

## Usage

```
git clone https://github.com/borasavkar/WinCare.git
```

Then double-click **`WinCare.bat`**. Every command WinCare runs is shown next to its button and its output is written to the **Activity** page.

## Project layout

```
WinCare.bat        launcher (elevation + STA)
src/Core.psm1      UI-independent engine
src/WinCare.ps1    WPF user interface
lang/*.json        translations
tests/             automated checks
```

## Adding a language

1. Copy `lang/en.json` to `lang/<code>.json` (for example `de.json`).
2. Update the `_meta` block (`code`, `name`, `nativeName`, `culture`).
3. Translate the values. Keep `{0}`, `{1}` placeholders and `\n` line breaks.
4. Run `tests/Test-WinCare.ps1` — it reports missing or extra keys.

The new language appears in **Settings** automatically.

## Development notes

- `src/*.ps1` and `src/*.psm1` are kept **ASCII-only**; all text lives in `lang/`. This avoids code page problems with Windows PowerShell 5.1.
- All work runs in a background runspace; the UI thread only updates controls.
- Output of `dism`, `sfc` and `winget` is language dependent, so the code relies on exit codes and structure, never on parsing localized text.

## License

[MIT](LICENSE)
