#requires -Version 5.1
<#
    Builds WinCare.exe (the launcher) with the C# compiler that ships with
    Windows (.NET Framework 4.x). No SDK or Visual Studio needed.
    Run:  powershell -NoProfile -File build\Build-Exe.ps1 [-Package]
    -Package also creates dist\WinCare-<version>.zip, ready for a GitHub release.
#>
param([switch]$Package)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$csc  = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'C# compiler (.NET Framework 4.x) not found.' }

$ico = Join-Path $root 'assets\WinCare.ico'
if (-not (Test-Path $ico)) { & (Join-Path $PSScriptRoot 'New-Icon.ps1') }

$out = Join-Path $root 'WinCare.exe'
$cscArgs = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
    "/out:$out",
    "/win32icon:$ico",
    "/win32manifest:$(Join-Path $root 'launcher\app.manifest')",
    '/reference:System.Windows.Forms.dll',
    (Join-Path $root 'launcher\WinCareLauncher.cs')
)
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }
$f = Get-Item $out
"Built: $($f.FullName)  ($([math]::Round($f.Length / 1KB, 1)) KB, version $($f.VersionInfo.FileVersion))"

if ($Package) {
    $ver = $f.VersionInfo.ProductVersion
    $dist = Join-Path $root 'dist'
    $stage = Join-Path $dist "WinCare-$ver"
    if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($item in 'WinCare.exe', 'WinCare.bat', 'README.md', 'LICENSE', 'src', 'lang', 'assets') {
        Copy-Item -LiteralPath (Join-Path $root $item) -Destination $stage -Recurse
    }
    $zip = Join-Path $dist "WinCare-$ver.zip"
    if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
    # Compress-Archive in PowerShell 5.1 writes "\" separators, which violates the
    # ZIP spec and breaks some extractors. Entries are written with "/" instead.
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
    try {
        foreach ($file in Get-ChildItem -LiteralPath $stage -Recurse -File) {
            $entry = $file.FullName.Substring($stage.Length + 1).Replace('\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entry, 'Optimal')
        }
    } finally { $archive.Dispose() }
    Remove-Item -LiteralPath $stage -Recurse -Force
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    "Package: $zip  ($([math]::Round((Get-Item $zip).Length / 1KB)) KB)"
    "SHA256:  $hash"
}
