# AgenticOS one-shot installer

**Single self-contained PowerShell file.** No second HTTP fetch. No companion scripts. Everything — self-elevation, prereq install via winget, long-path fix, clone, build — lives in `agenticos.ps1`.

## The one-liner

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; `
[Net.ServicePointManager]::SecurityProtocol = 3072; `
$env:AGENTICOS_SOURCE_URL = 'https://raw.githubusercontent.com/patil-shubham-dev/AgenticOS-bootstrap/main/agenticos.ps1'; `
iex ((New-Object Net.WebClient).DownloadString($env:AGENTICOS_SOURCE_URL))
```

Or in one line:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=3072; $env:AGENTICOS_SOURCE_URL='https://raw.githubusercontent.com/patil-shubham-dev/AgenticOS-bootstrap/main/agenticos.ps1'; iex ((New-Object Net.WebClient).DownloadString($env:AGENTICOS_SOURCE_URL))
```

Why `AGENTICOS_SOURCE_URL`: when the script self-elevates, the elevated shell needs to re-fetch the same source (the original `iex` string is not visible to the child). Setting the env var lets it re-invoke itself. If you download `agenticos.ps1` locally instead, this variable is unnecessary — self-elevation uses `-File $PSCommandPath`.

## Local usage

```powershell
# Download and inspect first (recommended):
Invoke-WebRequest 'https://.../agenticos.ps1' -OutFile agenticos.ps1
notepad agenticos.ps1
# Then run:
.\agenticos.ps1
```

## Flags

Pass either as regular parameters (local) or via `$env:AGENTICOS_ARGS` (iex).

| Flag | Meaning |
|---|---|
| `-InstallRoot <path>` | Where to clone. Default `%USERPROFILE%\Code\AgenticOS`. |
| `-SkipBuild` | Clone + `npm install` only. Then use `npm run dev`. |
| `-SkipTypecheck` | Bypass strict `tsc --noEmit`. Use if `dist:win` fails on TS errors. |
| `-NoAutoInstall` | Do NOT auto-install missing prereqs. Exits with a list instead. |
| `-NoElevate` | Do NOT self-elevate. Use if already Admin or for the non-privileged parts. |
| `-Force` | Wipe existing target directory before cloning. |

Via env var:

```powershell
$env:AGENTICOS_ARGS = '-SkipTypecheck -Force -InstallRoot D:\Code\AgenticOS'
# then the one-liner above
```

## What runs (in order)

| Step | Action |
|---|---|
| 0b | Self-elevate via UAC (unless `-NoElevate` or already Admin). |
| 1 | Check: git, node ≥ 20, npm, python, MSVC C++ Build Tools, disk, long-path flags. |
| 1b | Install missing prereqs via `winget` (Git.Git, OpenJS.NodeJS.LTS, Python.Python.3.12, Microsoft.VisualStudio.2022.BuildTools with C++ workload). |
| 1c | Enable `HKLM\...\LongPathsEnabled=1` and `git config --global core.longpaths true`. |
| 2 | `git clone --depth 1` the AgenticOS repo (or pull if already present). |
| 3 | Verify NSIS build assets exist (`icon.ico`, `header.bmp`, `sidebar.bmp`, `.nsh`, `.config.cjs`). |
| 4 | `npm install` + explicit `npx electron-builder install-app-deps` (native modules for Electron ABI). |
| 5 | `npm run dist:win` (or fallback path with `-SkipTypecheck`). |
| 6 | Open `release\` in Explorer with the built installer + portable exe. |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success — installer built. |
| 1 | Fatal error. |
| 2 | Prereqs installed but PATH needs a fresh shell — close and re-run the same one-liner. |

## Hosting

Put `agenticos.ps1` at any HTTPS URL. Update the `AGENTICOS_SOURCE_URL` value in the one-liner. GitHub raw is easiest:

1. Push `agenticos.ps1` to a repo root (any repo, private or public).
2. Get the "Raw" URL from GitHub.
3. That URL is the one-liner's target.

## Safety notes

- Everything is auditable PowerShell in one file. Inspect once before pasting.
- Writes exactly one registry value (`LongPathsEnabled`). Documented, reversible.
- All temp files are avoided — the script runs from memory when iex'd.
- winget prompts are all suppressed (`--accept-package-agreements --accept-source-agreements --disable-interactivity`), so the Microsoft-controlled package agreements are auto-accepted; the actual installers still run under the elevated shell.
