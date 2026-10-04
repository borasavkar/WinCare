#requires -Version 5.1
<#
    Creates a WinCare release end to end:
      1. sets the version in every place it appears
      2. runs the automated checks (stops on failure)
      3. builds WinCare.exe and dist\WinCare-<version>.zip
      4. commits, tags v<version>, pushes
      5. creates the GitHub release with the ZIP and generated notes

    Usage:
      powershell -NoProfile -STA -File build\Release.ps1 -Version 1.1.0
      powershell -NoProfile -STA -File build\Release.ps1 -Version 1.1.0 -NotesFile notes.md
      powershell -NoProfile -STA -File build\Release.ps1 -Version 1.1.0 -DryRun

    -DryRun checks everything and prints the plan without changing any file.
    Requires git and an authenticated GitHub CLI (gh).
#>
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$NotesFile = '',
    [switch]$DryRun
)
# 'Continue': in PowerShell 5.1 any stderr line of a native tool (git, gh) is a
# terminating error under 'Stop'. Every step checks $LASTEXITCODE explicitly instead.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root

function Step([string]$m) { Write-Host "`n== $m" -ForegroundColor Cyan }
function Die([string]$m)  { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# --- 1. Validate -------------------------------------------------------------
Step 'Checking'
if ($Version -notmatch '^\d+\.\d+\.\d+$') { Die "Version must look like 1.2.3 (got '$Version')." }
$tag = "v$Version"

$ui       = Join-Path $root 'src\WinCare.ps1'
$launcher = Join-Path $root 'launcher\WinCareLauncher.cs'
$manifest = Join-Path $root 'launcher\app.manifest'

$current = [regex]::Match([IO.File]::ReadAllText($ui), "\`$script:AppVersion = '([^']+)'").Groups[1].Value
if (-not $current) { Die 'Could not read the current version from src\WinCare.ps1.' }
if ([version]$Version -le [version]$current) { Die "New version $Version must be greater than the current $current." }

foreach ($tool in 'git', 'gh') { if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Die "$tool is not installed." } }
git fetch --tags --quiet origin 2>$null   # tags created by GitHub releases exist only on the remote
$dirty = git status --porcelain
if ($dirty) { Die "Working tree is not clean. Commit or stash first:`n$($dirty -join "`n")" }
if (git tag --list $tag) { Die "Tag $tag already exists." }
$null = gh auth status 2>&1; if ($LASTEXITCODE -ne 0) { Die 'GitHub CLI is not logged in (run: gh auth login).' }
$repo = (gh repo view --json nameWithOwner -q .nameWithOwner).Trim()
"Repository : $repo"
"Version    : $current -> $Version"

# --- Release notes -----------------------------------------------------------
$prevTag = (git tag --list 'v*' --sort=-v:refname | Select-Object -First 1)
if ($NotesFile) {
    if (-not (Test-Path -LiteralPath $NotesFile)) { Die "Notes file not found: $NotesFile" }
    $changes = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $NotesFile))
} else {
    $range = if ($prevTag) { "$prevTag..HEAD" } else { 'HEAD' }
    $subjects = @(git log $range --no-merges --pretty=format:'%s' | Where-Object { $_ -and $_ -notmatch '^Release v\d' })
    if (-not $subjects.Count) { Die "No commits since $prevTag - nothing to release." }
    $changes = "### Changes`n" + (($subjects | ForEach-Object { "- $_" }) -join "`n")
}
"Changes since $(if ($prevTag) { $prevTag } else { 'the beginning' }):"
$changes -split "`n" | ForEach-Object { "  $_" }

if ($DryRun) { Step 'Dry run - nothing was changed'; exit 0 }

# --- 2. Set version ----------------------------------------------------------
Step "Setting version $Version"
$v4 = "$Version.0"
function Update-File([string]$Path, [string]$Pattern, [string]$Replacement) {
    $t = [IO.File]::ReadAllText($Path)
    $n = [regex]::Replace($t, $Pattern, $Replacement)
    if ($n -eq $t) { Die "Version pattern not found in $Path" }
    [IO.File]::WriteAllText($Path, $n, (New-Object Text.UTF8Encoding($false)))
}
Update-File $ui       "\`$script:AppVersion = '[^']+'"                  "`$script:AppVersion = '$Version'"
Update-File $launcher 'AssemblyVersion\("[^"]+"\)'                     "AssemblyVersion(`"$v4`")"
Update-File $launcher 'AssemblyFileVersion\("[^"]+"\)'                 "AssemblyFileVersion(`"$v4`")"
Update-File $launcher 'AssemblyInformationalVersion\("[^"]+"\)'        "AssemblyInformationalVersion(`"$Version`")"
Update-File $manifest '(<assemblyIdentity version=")[^"]+(")'          "`${1}$v4`${2}"

# --- 3. Tests ----------------------------------------------------------------
Step 'Running automated checks'
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Test-WinCare.ps1')
if ($LASTEXITCODE -ne 0) { git checkout -- $ui $launcher $manifest; Die 'Checks failed - version changes were reverted.' }

# --- 4. Build ----------------------------------------------------------------
Step 'Building WinCare.exe and release package'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Build-Exe.ps1') -Package
if ($LASTEXITCODE -ne 0) { git checkout -- $ui $launcher $manifest; Die 'Build failed - version changes were reverted.' }
$zip = Join-Path $root "dist\WinCare-$Version.zip"
if (-not (Test-Path -LiteralPath $zip)) { Die "Package not found: $zip" }
$exeVer = (Get-Item (Join-Path $root 'WinCare.exe')).VersionInfo.ProductVersion
if ($exeVer -ne $Version) { Die "WinCare.exe reports version $exeVer, expected $Version." }
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash

# --- 5. Commit, tag, push ----------------------------------------------------
Step "Committing and tagging $tag"
git add -- $ui $launcher $manifest
git commit -q -m "Release $tag"
git tag -a $tag -m "WinCare $Version"
git push -q origin HEAD 2>$null
if ($LASTEXITCODE -ne 0) { Die 'Push of the release commit failed.' }
git push -q origin $tag 2>$null
if ($LASTEXITCODE -ne 0) { Die 'Push of the tag failed.' }

# --- 6. GitHub release -------------------------------------------------------
Step 'Creating GitHub release'
$notes = @"
$changes

### Install
Download **WinCare-$Version.zip**, extract it anywhere and run **WinCare.exe** (administrator rights are required).
If SmartScreen shows *"Windows protected your PC"*, choose **More info > Run anyway** - the launcher is not code-signed yet.

**SHA-256** ``WinCare-$Version.zip``: ``$hash``
"@
$notesPath = Join-Path $env:TEMP "wincare-notes-$Version.md"
[IO.File]::WriteAllText($notesPath, $notes, (New-Object Text.UTF8Encoding($false)))
gh release create $tag $zip --repo $repo --title "WinCare $Version" --notes-file $notesPath
if ($LASTEXITCODE -ne 0) { Die 'gh release create failed.' }

# Verify the uploaded asset
$check = Join-Path $env:TEMP "wincare-verify-$Version"
if (Test-Path $check) { Remove-Item -LiteralPath $check -Recurse -Force }
gh release download $tag --repo $repo --dir $check 2>$null
$remote = (Get-FileHash -LiteralPath (Join-Path $check "WinCare-$Version.zip") -Algorithm SHA256).Hash
if ($remote -ne $hash) { Die "Uploaded asset hash differs: $remote vs $hash" }

Step "Released WinCare $Version"
"https://github.com/$repo/releases/tag/$tag"
"SHA-256 verified: $hash"
