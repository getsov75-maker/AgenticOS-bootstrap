<#
.SYNOPSIS
    Single-file, self-contained AgenticOS bootstrap + installer for Windows.

    One-liner:
      Set-ExecutionPolicy Bypass -Scope Process -Force; `
      [Net.ServicePointManager]::SecurityProtocol = 3072; `
      iex ((New-Object Net.WebClient).DownloadString('<RAW_URL>/agenticos.ps1'))

    Everything is in this one file:
      * self-elevation via UAC
      * prerequisite check (git, node >= 20, npm, python, MSVC C++ Build Tools, disk)
      * auto-install of missing prereqs via winget
      * Windows long-path support (registry + git config)
      * clone patil-shubham-dev/AgenticOS
      * verify NSIS build assets
      * npm install + explicit electron-builder install-app-deps
      * npm run dist:win  (with -SkipTypecheck fallback)
      * open release\ in Explorer

.PARAMETER InstallRoot
    Target directory. Defaults to $env:USERPROFILE\Code\AgenticOS.

.PARAMETER SkipBuild
    Clone + install deps only, then exit (use `npm run dev` afterwards).

.PARAMETER SkipTypecheck
    Bypass strict `tsc --noEmit` (recommended fallback if dist:win fails).

.PARAMETER NoAutoInstall
    Do NOT auto-install missing prereqs via winget; exit with a list instead.
    By default, when invoked via iex, prereqs are auto-installed.

.PARAMETER NoElevate
    Do NOT self-elevate. Use if you are already Admin or want to run the
    non-privileged parts only.

.PARAMETER Force
    Delete an existing target directory before cloning.

.EXAMPLE
    # Public one-liner (fetches raw file over HTTPS and runs it):
    iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/patil-shubham-dev/AgenticOS-bootstrap/main/agenticos.ps1'))

    # With options via env var (before iex):
    $env:AGENTICOS_ARGS = '-SkipTypecheck -InstallRoot D:\Code\AgenticOS'
    iex ((New-Object Net.WebClient).DownloadString('https://.../agenticos.ps1'))

    # Or downloaded locally:
    .\agenticos.ps1 -SkipTypecheck
#>

[CmdletBinding()]
param(
    [string]$InstallRoot   = (Join-Path $env:USERPROFILE 'Code\AgenticOS'),
    [switch]$SkipBuild,
    [switch]$SkipTypecheck,
    [switch]$NoAutoInstall,
    [switch]$NoElevate,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoUrl   = 'https://github.com/patil-shubham-dev/AgenticOS.git'
$NodeMin   = [Version]'20.0.0'
$DiskMinGB = 8

# --------- helpers ---------------------------------------------------------

function Write-Section($msg) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host " $msg"     -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}
function Write-Ok($msg)   { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Write-Note($msg) { Write-Host "         $msg" -ForegroundColor DarkGray }

function Test-Command($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }
function Get-ToolVersion($exe, $arg = '--version') {
    try { (& $exe $arg 2>&1 | Select-Object -First 1).ToString().Trim() } catch { $null }
}
function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Refresh-Path {
    $machine = [System.Environment]::GetEnvironmentVariable('Path','Machine')
    $user    = [System.Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = ($machine, $user -join ';')
}
function Install-Winget-Package {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Name = $Id,
        [string[]]$ExtraArgs = @()
    )
    Write-Host "  -> winget install --id $Id" -ForegroundColor Cyan
    $wargs = @(
        'install', '--id', $Id, '-e',
        '--source', 'winget',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    ) + $ExtraArgs
    & winget @wargs
    $code = $LASTEXITCODE
    if ($code -eq 0 -or $code -eq -1978335189) {   # -1978335189 = already installed
        Refresh-Path
        Write-Ok "$Name installed / already present"
        return $true
    }
    Write-Err "winget failed for $Name (exit $code)"
    return $false
}

# --------- 0. banner -------------------------------------------------------

Write-Section 'AgenticOS one-shot installer'
Write-Host "  Repo         : $RepoUrl"
Write-Host "  Target       : $InstallRoot"
$modeText = if ($SkipBuild) { 'clone + install' } elseif ($SkipTypecheck) { 'dist:win (skip tsc)' } else { 'dist:win (full)' }
Write-Host "  Mode         : $modeText"

# --------- 0b. self-elevate ------------------------------------------------
# When invoked via `iex`, this whole file is executed from a memory string,
# so relaunching requires re-fetching it. We do that when the caller sets
# $env:AGENTICOS_SOURCE_URL (typically pointing back to the same raw URL).

if (-not (Test-IsAdmin) -and -not $NoElevate) {
    Write-Section 'Self-elevating to Administrator'
    Write-Note 'Required for: winget installs, HKLM long-path registry write.'

    # Build the arg list to forward (skip switches only relevant to non-elevated first pass).
    $forwardEnv = @{
        AGENTICOS_ARGS       = $env:AGENTICOS_ARGS
        AGENTICOS_SOURCE_URL = $env:AGENTICOS_SOURCE_URL
    }

    # Determine how to re-invoke self.
    $srcUrl = $env:AGENTICOS_SOURCE_URL
    if ($srcUrl) {
        # Streamed via iex - refetch and pipe into elevated pwsh.
        $inner = @"
`$env:AGENTICOS_ARGS='$($forwardEnv.AGENTICOS_ARGS)';
`$env:AGENTICOS_SOURCE_URL='$srcUrl';
[Net.ServicePointManager]::SecurityProtocol=3072;
iex ((New-Object Net.WebClient).DownloadString('$srcUrl'))
"@
        $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$inner)
    } elseif ($PSCommandPath) {
        # Loaded from disk - re-invoke the file directly.
        $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
        if ($env:AGENTICOS_ARGS) { $psArgs += $env:AGENTICOS_ARGS.Split(' ') }
    } else {
        Write-Err 'Cannot self-elevate: neither $PSCommandPath nor $env:AGENTICOS_SOURCE_URL is set.'
        Write-Note 'Download the file locally and run it from an elevated shell, or pass -NoElevate.'
        exit 1
    }

    try {
        $exe = (Get-Process -Id $PID).Path
        $p = Start-Process -FilePath $exe -Verb RunAs -ArgumentList $psArgs -PassThru -Wait
        exit $p.ExitCode
    } catch {
        Write-Err "UAC declined or elevation failed: $($_.Exception.Message)"
        exit 1
    }
}
if (Test-IsAdmin) { Write-Ok 'running as Administrator' } else { Write-Warn 'running WITHOUT admin (-NoElevate)' }

# Merge any $env:AGENTICOS_ARGS into $PSBoundParameters (only fires when iex-launched).
if ($env:AGENTICOS_ARGS -and -not $PSBoundParameters.Count) {
    try {
        $parsed = [System.Management.Automation.Language.Parser]::ParseInput(
            $env:AGENTICOS_ARGS, [ref]$null, [ref]$null
        ).EndBlock.Statements[0].PipelineElements[0].CommandElements |
            ForEach-Object { $_.Extent.Text.Trim('"',"'") }
        # Very small hand-parse: -Flag  or  -Key Value
        for ($i = 0; $i -lt $parsed.Count; $i++) {
            $tok = $parsed[$i]
            if ($tok -match '^-(\w+)$') {
                $name = $matches[1]
                if ($i + 1 -lt $parsed.Count -and $parsed[$i+1] -notmatch '^-') {
                    Set-Variable -Name $name -Value $parsed[$i+1] -Scope Script
                    $i++
                } else {
                    Set-Variable -Name $name -Value ([switch]::new($true)) -Scope Script
                }
            }
        }
        # Recompute mode banner after applying forwarded args
        Write-Note "  Forwarded args: $env:AGENTICOS_ARGS"
    } catch {
        Write-Warn "Could not parse AGENTICOS_ARGS: $($_.Exception.Message)"
    }
}

$AutoInstallPrereqs = -not $NoAutoInstall

# --------- 1. prerequisites -----------------------------------------------

Write-Section 'Step 1/6  Checking prerequisites'
$missing = @()

# Git
if (Test-Command git) {
    Write-Ok "git          $(Get-ToolVersion git --version)"
} else {
    $missing += 'Git for Windows'
    Write-Err 'git not found'
}

# Node
if (Test-Command node) {
    $nodeVerRaw = (node --version).TrimStart('v')
    try { $nodeVer = [Version]$nodeVerRaw } catch { $nodeVer = [Version]'0.0.0' }
    if ($nodeVer -lt $NodeMin) {
        Write-Err "node $nodeVerRaw is below required $NodeMin"
        $missing += 'Node.js LTS'
    } elseif ($nodeVer.Major -ge 23) {
        Write-Warn "node v$nodeVerRaw is newer than the pinned major (20)"
        Write-Note 'Electron 42 + node-pty prebuilds may not exist for very new Node.'
    } else {
        Write-Ok "node         v$nodeVerRaw"
    }
} else {
    $missing += 'Node.js LTS'
    Write-Err 'node not found'
}

# npm
if (Test-Command npm) {
    Write-Ok "npm          $(Get-ToolVersion npm --version)"
} elseif ($missing -notcontains 'Node.js LTS') {
    $missing += 'npm (bundled with Node.js)'
    Write-Err 'npm not found'
}

# Python
$py = $null
foreach ($cand in 'python','python3','py') { if (Test-Command $cand) { $py = $cand; break } }
if ($py) {
    Write-Ok "python       $(Get-ToolVersion $py --version)  ($py)"
} else {
    $missing += 'Python 3.x'
    Write-Err 'python not found (node-gyp requires it)'
}

# MSVC C++ Build Tools
# NOTE: ${env:ProgramFiles(x86)} is a parser error because '(x86)' is not a
# valid variable-name character sequence inside ${}. Use Get-Item instead.
$pfx86   = (Get-Item 'Env:ProgramFiles(x86)' -ErrorAction SilentlyContinue).Value
if (-not $pfx86) { $pfx86 = 'C:\Program Files (x86)' }
$vsWhere = Join-Path $pfx86 'Microsoft Visual Studio\Installer\vswhere.exe'
$hasBuildTools = $false
if (Test-Path $vsWhere) {
    $found = & $vsWhere -latest -products '*' `
        -requires 'Microsoft.VisualStudio.Workload.VCTools' `
        -property installationPath 2>$null
    if ($found) { $hasBuildTools = $true }
}
if ($hasBuildTools) {
    Write-Ok 'MSVC C++     build tools present'
} else {
    Write-Warn 'MSVC C++ Build Tools not detected (needed by node-pty)'
    $missing += 'VS Build Tools'
}

# Disk
$drive  = (Get-Item $env:USERPROFILE).PSDrive.Name
$freeGB = [math]::Round((Get-PSDrive $drive).Free / 1GB, 1)
# NOTE: `${var}:` inside a double-quoted string is a PS 5.1 parse error
# (the parser reads the colon as a scope-qualifier extension of the braces).
# Use $($var): to force expression evaluation, then a plain colon literal.
if ($freeGB -lt $DiskMinGB) {
    Write-Err ("Only {0} GB free on {1}: - need >= {2} GB" -f $freeGB, $drive, $DiskMinGB)
    $missing += ("Free disk space on {0}:" -f $drive)
} else {
    Write-Ok ("disk         {0} GB free on {1}:" -f $freeGB, $drive)
}

# Long-path detection (fix is applied in step 1c)
$script:LongPathsNeedsFix = $false
try {
    $lp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
    if ($lp -eq 1) {
        Write-Ok 'LongPaths    enabled in registry'
    } else {
        Write-Warn 'Windows long-path support is disabled (fix in step 1c)'
        $script:LongPathsNeedsFix = $true
    }
} catch {
    $script:LongPathsNeedsFix = $true
}

# Git long-path setting
$script:GitLongPathsNeedsFix = $false
if (Test-Command git) {
    if ((git config --global --get core.longpaths 2>$null) -eq 'true') {
        Write-Ok 'git core.longpaths=true'
    } else {
        $script:GitLongPathsNeedsFix = $true
    }
} else {
    $script:GitLongPathsNeedsFix = $true
}

# --------- 1b. auto-install missing prereqs -------------------------------

if ($missing.Count -gt 0 -and -not $AutoInstallPrereqs) {
    Write-Section 'Missing prerequisites - install these, then re-run'
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Note 'Or re-run without -NoAutoInstall to auto-install via winget.'
    exit 1
}

if ($missing.Count -gt 0) {
    Write-Section 'Step 1b  Auto-installing missing prerequisites via winget'

    if (-not (Test-Command winget)) {
        Write-Err 'winget is not available on this machine.'
        Write-Note 'Install "App Installer" from the Microsoft Store, then re-run.'
        exit 1
    }
    Write-Ok "winget       $(Get-ToolVersion winget --version)"

    $needGit    = $missing -contains 'Git for Windows'
    $needNode   = $missing -contains 'Node.js LTS' -or $missing -contains 'npm (bundled with Node.js)'
    $needPython = $missing -contains 'Python 3.x'
    $needVS     = $missing -contains 'VS Build Tools'
    $failed = @()

    if ($needGit    -and -not (Install-Winget-Package -Id 'Git.Git'                                -Name 'Git for Windows'))       { $failed += 'Git' }
    if ($needNode   -and -not (Install-Winget-Package -Id 'OpenJS.NodeJS.LTS'                      -Name 'Node.js LTS'))           { $failed += 'Node' }
    if ($needPython -and -not (Install-Winget-Package -Id 'Python.Python.3.12'                     -Name 'Python 3.12'))           { $failed += 'Python' }
    if ($needVS) {
        $vsOverride = '--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
        if (-not (Install-Winget-Package -Id 'Microsoft.VisualStudio.2022.BuildTools' -Name 'VS 2022 Build Tools' -ExtraArgs @('--override',$vsOverride))) {
            $failed += 'VS Build Tools'
        }
    }

    if ($failed.Count -gt 0) { Write-Err ('Failed installs: ' + ($failed -join ', ')); exit 1 }
    Write-Ok 'All missing prerequisites installed.'
    Refresh-Path

    # Re-check PATH
    $still = @()
    if ($needGit    -and -not (Test-Command git))    { $still += 'git' }
    if ($needNode   -and -not (Test-Command node))   { $still += 'node' }
    if ($needPython -and -not ((Test-Command python) -or (Test-Command python3) -or (Test-Command py))) { $still += 'python' }
    if ($needVS) {
        $ok = $false
        if (Test-Path $vsWhere) {
            if (& $vsWhere -latest -products '*' -requires 'Microsoft.VisualStudio.Workload.VCTools' -property installationPath 2>$null) { $ok = $true }
        }
        if (-not $ok) { $still += 'MSVC C++ Build Tools' }
    }
    if ($still.Count -gt 0) {
        Write-Warn ('Not on PATH in this session: ' + ($still -join ', '))
        Write-Note 'Close this window, open a fresh PowerShell, and re-run the same one-liner.'
        exit 2
    }
    Write-Ok 'All prerequisites now on PATH - continuing.'
}

# --------- 1c. long-path support -----------------------------------------

if ($script:LongPathsNeedsFix -or $script:GitLongPathsNeedsFix) {
    Write-Section 'Step 1c  Enabling long-path support'
    Write-Note 'Electron + AgenticOS node_modules paths exceed the 260-char MAX_PATH limit.'

    if ($script:LongPathsNeedsFix) {
        if (-not (Test-IsAdmin)) {
            Write-Err 'Admin required to set HKLM LongPathsEnabled.'
            exit 1
        }
        try {
            $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
            Set-ItemProperty -Path $regPath -Name 'LongPathsEnabled' -Value 1 -Type DWord -Force
            if ((Get-ItemProperty $regPath -Name LongPathsEnabled).LongPathsEnabled -eq 1) {
                Write-Ok 'LongPathsEnabled = 1 (HKLM registry)'
            } else {
                Write-Err 'Registry readback did not confirm the write'; exit 1
            }
        } catch {
            Write-Err "Failed to set LongPathsEnabled: $($_.Exception.Message)"
            exit 1
        }
    }
    if ($script:GitLongPathsNeedsFix -and (Test-Command git)) {
        git config --global core.longpaths true
        if ($LASTEXITCODE -eq 0) { Write-Ok 'git config --global core.longpaths true' }
    }
}

# --------- 2. clone --------------------------------------------------------

Write-Section 'Step 2/6  Cloning repository'
if (Test-Path $InstallRoot) {
    if ($Force) {
        Write-Warn "Removing existing $InstallRoot (-Force)"
        Remove-Item $InstallRoot -Recurse -Force
    } elseif ((Get-ChildItem $InstallRoot -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
        if (Test-Path (Join-Path $InstallRoot '.git')) {
            Push-Location $InstallRoot
            git fetch --all --prune; git pull --ff-only
            Pop-Location
            Write-Ok 'existing checkout updated'
        } else {
            Write-Err "$InstallRoot exists and is not a git checkout. Use -Force."
            exit 1
        }
    }
} else {
    New-Item -ItemType Directory -Path (Split-Path $InstallRoot -Parent) -Force | Out-Null
}
if (-not (Test-Path (Join-Path $InstallRoot '.git'))) {
    git clone --depth 1 $RepoUrl $InstallRoot
    if ($LASTEXITCODE -ne 0) { Write-Err 'git clone failed'; exit 1 }
    Write-Ok "cloned into $InstallRoot"
}
Set-Location $InstallRoot
if (Test-Path .nvmrc) { Write-Ok "repo pins Node $((Get-Content .nvmrc -Raw).Trim()) (.nvmrc)" }

# --------- 3. verify build assets ------------------------------------------

Write-Section 'Step 3/6  Verifying required build assets'
$assetChecks = @(
    'resources\branding\icon.ico',
    'build\assets\header.bmp',
    'build\assets\sidebar.bmp',
    'build\installer-redesign.nsh',
    'config\electron-builder.config.cjs'
)
$assetMissing = @()
foreach ($rel in $assetChecks) {
    if (Test-Path $rel) { Write-Ok $rel } else { Write-Err "missing: $rel"; $assetMissing += $rel }
}
if ($assetMissing.Count -gt 0) {
    Write-Err 'Cannot proceed - asset(s) missing from checkout (upstream repo issue).'
    exit 1
}

# --------- 4. npm install + native rebuild --------------------------------

Write-Section 'Step 4/6  Installing npm dependencies'
Write-Note 'This is where most Windows builds fail (node-pty native compile).'

$env:NODE_NO_WARNINGS                  = '1'
$env:npm_config_fetch_timeout          = '600000'
$env:npm_config_fetch_retries          = '5'
$env:npm_config_fetch_retry_maxtimeout = '120000'
$env:npm_config_loglevel               = 'warn'
$env:SKIP_CLEAN_WORKTREE_CHECK         = '1'

npm install
if ($LASTEXITCODE -ne 0) {
    Write-Err 'npm install failed.'
    Write-Note 'Check that Python and MSVC Build Tools are on PATH; retry with `npm install --verbose`.'
    exit 1
}
Write-Ok 'dependencies installed'

Write-Note 'Explicit electron-builder install-app-deps (npmRebuild:false in config)...'
npx --yes electron-builder install-app-deps
if ($LASTEXITCODE -ne 0) {
    Write-Warn 'install-app-deps non-zero - packaged app may crash on native import.'
} else {
    Write-Ok 'native modules rebuilt for Electron'
}

if ($SkipBuild) {
    Write-Section 'Done (-SkipBuild)'
    Write-Host "  cd `"$InstallRoot`"; npm run dev" -ForegroundColor Cyan
    exit 0
}

# --------- 5. build --------------------------------------------------------

Write-Section 'Step 5/6  Building Windows distribution'
Write-Note 'First build downloads Electron 42 + winCodeSign (~250 MB) into %LOCALAPPDATA%\electron-builder\Cache.'
$buildStart = Get-Date

if ($SkipTypecheck) {
    Write-Warn 'Skipping tsc --noEmit (repo has known TS strict issues).'
    npx --yes electron-vite build
    if ($LASTEXITCODE -ne 0) { Write-Err 'electron-vite build failed'; exit 1 }
    npx --yes electron-builder --config config/electron-builder.config.cjs --win
    if ($LASTEXITCODE -ne 0) { Write-Err 'electron-builder --win failed'; exit 1 }
} else {
    npm run dist:win
    if ($LASTEXITCODE -ne 0) {
        Write-Err 'npm run dist:win failed.'
        Write-Note 'Retry with:  -SkipTypecheck  (bypasses the strict TS 6 --noEmit pass).'
        exit 1
    }
}
Write-Ok ("build completed in {0:mm\:ss}" -f ((Get-Date) - $buildStart))

# --------- 6. results ------------------------------------------------------

Write-Section 'Step 6/6  Build artifacts'
$releaseDir = Join-Path $InstallRoot 'release'
if (Test-Path $releaseDir) {
    Get-ChildItem $releaseDir -File |
        Where-Object { $_.Extension -in '.exe','.msi','.zip','.blockmap' } |
        Sort-Object Length -Descending |
        ForEach-Object {
            $mb = [math]::Round($_.Length / 1MB, 1)
            Write-Host ("  {0,-58} {1,8} MB" -f $_.Name, $mb) -ForegroundColor Green
        }
    Write-Host ''
    Write-Host "  Folder: $releaseDir" -ForegroundColor Cyan
    Start-Process explorer.exe $releaseDir
} else {
    Write-Warn 'release\ not found - inspect logs above.'
    exit 1
}

Write-Host ''
Write-Host '  Install:   double-click  release\AgenticOS Setup 3.0.0.exe'   -ForegroundColor Cyan
Write-Host '  Portable:  release\AgenticOS-3.0.0-portable.exe'              -ForegroundColor Cyan
Write-Host '  First run  ->  Settings -> Providers -> add OpenAI / Anthropic / MCP key.' -ForegroundColor DarkGray
