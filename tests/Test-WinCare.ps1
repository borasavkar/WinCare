#requires -Version 5.1
<#
    WinCare automated checks. Run with:
        powershell -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-WinCare.ps1
    Does not need administrator rights and changes nothing on the system.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src  = Join-Path $root 'src'
$lang = Join-Path $root 'lang'
$script:Fail = 0

function Pass([string]$m) { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Fail([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

# --- 1. ASCII-only source -------------------------------------------------
Write-Host "`nSource files" -ForegroundColor Cyan
foreach ($f in Get-ChildItem $src -Include *.ps1, *.psm1 -Recurse) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $bad = @($bytes | Where-Object { $_ -gt 127 }).Count
    if ($bad) { Fail "$($f.Name): $bad non-ASCII bytes" } else { Pass "$($f.Name) is ASCII-only" }
    $err = $null; $tok = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$err)
    if ($err.Count) { $err | ForEach-Object { Fail "$($f.Name):$($_.Extent.StartLineNumber) $($_.Message)" } } else { Pass "$($f.Name) parses" }
}

# --- 2. Language files ----------------------------------------------------
Write-Host "`nLanguage files" -ForegroundColor Cyan
Import-Module (Join-Path $src 'Core.psm1') -Force -DisableNameChecking
$files = Get-ChildItem $lang -Filter *.json
$tables = @{}
foreach ($f in $files) {
    try { $tables[$f.BaseName] = (Read-LanguageFile -Path $f.FullName); Pass "$($f.Name) is valid JSON ($($tables[$f.BaseName].Strings.Count) strings)" }
    catch { Fail "$($f.Name): $($_.Exception.Message)" }
}
$en = $tables['en'].Strings
foreach ($code in $tables.Keys) {
    if ($code -eq 'en') { continue }
    $t = $tables[$code].Strings
    $missing = @($en.Keys | Where-Object { -not $t.ContainsKey($_) })
    $extra   = @($t.Keys  | Where-Object { -not $en.ContainsKey($_) })
    if ($missing.Count) { Fail "$code.json missing: $($missing -join ', ')" } else { Pass "$code.json has every key" }
    if ($extra.Count)   { Fail "$code.json unknown keys: $($extra -join ', ')" }
    $ph = @()
    foreach ($k in $en.Keys) {
        if (-not $t.ContainsKey($k)) { continue }
        $a = @([regex]::Matches($en[$k], '\{\d+\}') | ForEach-Object Value | Sort-Object -Unique) -join ','
        $b = @([regex]::Matches($t[$k],  '\{\d+\}') | ForEach-Object Value | Sort-Object -Unique) -join ','
        if ($a -ne $b) { $ph += "$k ($a vs $b)" }
    }
    if ($ph.Count) { Fail "$code.json placeholder mismatch: $($ph -join '; ')" } else { Pass "$code.json placeholders match" }
}

# --- 3. Every key used by the code exists ---------------------------------
Write-Host "`nKey usage" -ForegroundColor Cyan
$code = (Get-ChildItem $src -Include *.ps1, *.psm1 -Recurse | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
$used = New-Object System.Collections.Generic.HashSet[string]
foreach ($m in [regex]::Matches($code, "\bT\s+'([A-Za-z0-9_.]+)'"))     { [void]$used.Add($m.Groups[1].Value) }
foreach ($m in [regex]::Matches($code, '\[\[([A-Za-z0-9_.]+)\]\]'))      { [void]$used.Add($m.Groups[1].Value) }
foreach ($t in Get-CleanupTargets) { [void]$used.Add("clean.$($t.Key).name"); [void]$used.Add("clean.$($t.Key).desc") }
foreach ($k in 'Delivery','RecycleBin') { [void]$used.Add("clean.$k.name"); [void]$used.Add("clean.$k.desc") }
foreach ($s in 'OK','NoIp','NoGateway','NoInternet','NoAdapter') { [void]$used.Add("net.state.$s") }
foreach ($h in (& (Get-Module Core) { $script:AppHints.Keys })) { [void]$used.Add("perf.hint.$h") }
$missing = @($used | Where-Object { -not $en.ContainsKey($_) })
if ($missing.Count) { Fail "keys used in code but missing in en.json: $($missing -join ', ')" } else { Pass "$($used.Count) keys used, all defined" }
$unused = @($en.Keys | Where-Object { -not $used.Contains($_) })
if ($unused.Count) { Write-Host "  [INFO] unused keys: $($unused -join ', ')" -ForegroundColor DarkGray }

# --- 3b. Protected locations are never cleaned ----------------------------
Write-Host "`nProtected locations" -ForegroundColor Cyan
$protected = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'),          # thumbnail + icon cache
    (Join-Path $env:LOCALAPPDATA 'D3DSCache'),                           # DirectX shader cache
    (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'),
    (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache'),
    (Join-Path $env:LOCALAPPDATA 'AMD\DxCache'),
    (Join-Path $env:LOCALAPPDATA 'Intel\ShaderCache'),
    (Join-Path $env:SystemRoot 'Prefetch'),
    (Join-Path $env:SystemRoot 'Fonts'),
    $env:SystemRoot, $env:USERPROFILE, 'C:\', '',
    # Case variants: on Turkish Windows culture-aware matching breaks on "I"
    'C:\WINDOWS\PREFETCH', 'c:\windows\fonts', ($env:LOCALAPPDATA.ToUpperInvariant() + '\MICROSOFT\WINDOWS\EXPLORER'),
    ($env:LOCALAPPDATA.ToUpperInvariant() + '\NVIDIA\DXCACHE'), $env:SystemRoot.ToLowerInvariant()
)
foreach ($pp in $protected) {
    if (Test-SafePath $pp) { Fail "safety lock allows: '$pp'" }
}
if (-not ($protected | Where-Object { Test-SafePath $_ })) { Pass "$($protected.Count) protected locations are refused by the safety lock" }
foreach ($t in Get-CleanupTargets) {
    if (-not (Test-SafePath $t.Path)) { Fail "cleanup target $($t.Key) is blocked by the safety lock: $($t.Path)" }
}
Pass "every cleanup target passes the safety lock"

# --- 3c. Performance checks (read-only) -----------------------------------
Write-Host "`nPerformance checks" -ForegroundColor Cyan
Initialize-Language -Directory $lang -Code 'en'
$m = Get-MemoryStatus
if ($m.TotalBytes -gt 0 -and $m.AvailableBytes -gt 0 -and $m.AvailableBytes -le $m.TotalBytes -and
    $m.CommitLimitBytes -ge $m.CommitBytes -and $m.CommitBytes -gt 0) { Pass "memory: $([int]$m.AvailablePercent)% available, $([int]$m.CommitPercent)% of commit limit" }
else { Fail "memory figures are not plausible: $($m | Out-String)" }
if (@($m.TopApps).Count -gt 0 -and -not @($m.TopApps | Where-Object { -not $_.Title })) { Pass "memory: $(@($m.TopApps).Count) top programs named" }
else { Fail 'memory: top programs missing or unnamed' }
$g = Get-GamingReadiness -SampleSeconds 1 -PingCount 2
if ($g -isnot [array] -and $null -ne $g.Ok -and $g.Memory -and $g.CpuPercent -ge 0 -and $g.CpuPercent -le 100) { Pass "before-you-play check returns one result (warnings: $($g.Warnings))" }
else { Fail "before-you-play check returned: $($g | Out-String)" }
# Closing is refused for WinCare itself, the shell and processes without a window
$explorer = Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1
$targets = @($PID) + $(if ($explorer) { $explorer.Id } else { @() })
$states = @($targets | ForEach-Object { (Close-AppGracefully -Id $_ -WaitSeconds 0).State })
if (-not @($states | Where-Object { $_ -ne 'refused' }).Count) { Pass "closing is refused for $($targets.Count) protected process(es)" }
else { Fail "closing was not refused: $($states -join ', ')" }
if ((Close-AppGracefully -Id 2147483000).State -eq 'gone') { Pass 'closing a missing process reports it as gone' } else { Fail 'closing a missing process' }

# --- 4. UI loads in every language and theme ------------------------------
Write-Host "`nUser interface" -ForegroundColor Cyan
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$ui = [IO.File]::ReadAllText((Join-Path $src 'WinCare.ps1'))
$tpl = [regex]::Match($ui, "(?s)\`$script:XamlTemplate = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $tpl) { Fail 'XAML template not found' }
# method calls such as $script:Ui.ContainsKey(...) are not controls
$refs = @([regex]::Matches($ui, '\$script:Ui\.([A-Za-z][A-Za-z0-9]*)\b(?!\()') + [regex]::Matches($ui, '\$u\.([A-Za-z][A-Za-z0-9]*)\b(?!\()') |
          ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$palKeys = 'Bg','Side','Card','CardAlt','Stroke','StrokeSoft','Text','Text2','Text3','Hover','Selected','Good','GoodSoft',
           'Warn','WarnSoft','Bad','BadSoft','Btn','BtnHover','Scrim','Log','Accent'
foreach ($code in $tables.Keys) {
    Initialize-Language -Directory $lang -Code $code
    foreach ($theme in 'dark', 'light') {
        $x = $tpl.Replace('@AppName@', 'WinCare')
        foreach ($k in $palKeys) { $x = $x.Replace("@$k@", $(if ($k -eq 'Scrim') { '#66000000' } elseif ($theme -eq 'dark') { '#202020' } else { '#F3F3F3' })) }
        $x = [regex]::Replace($x, '\[\[([A-Za-z0-9_.]+)\]\]', [Text.RegularExpressions.MatchEvaluator]{ param($m) [Security.SecurityElement]::Escape((T $m.Groups[1].Value)) })
        try {
            [xml]$doc = $x
            $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))
            $missingCtl = @($refs | Where-Object { $null -eq $w.FindName($_) })
            if ($missingCtl.Count) { Fail "[$code/$theme] controls not in XAML: $($missingCtl -join ', ')" }
            else { Pass "[$code/$theme] XAML loads, $($refs.Count) referenced controls found" }
        } catch { Fail "[$code/$theme] XAML: $($_.Exception.Message)" }
    }
}

Write-Host ''
if ($script:Fail) { Write-Host "$($script:Fail) check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green
exit 0
