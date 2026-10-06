#requires -Version 5.1
<#
    WinCare - Core engine
    ---------------------------------------------------------------------------
    UI-independent maintenance engine. Used by the WPF front end and can be
    used from scripts. This file is intentionally ASCII-only: every
    user-facing string lives in ../lang/*.json and is resolved through T.

    Rules
      * No function writes to the console or asks questions.
      * Long-running functions accept -Notify (scriptblock) for progress.
      * Functions return objects; formatting is the caller's job.
      * Nothing irreversible happens unless the caller passes -Apply.
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
#  Localization
# =============================================================================
$script:Strings  = @{}
$script:Fallback = @{}
$script:Culture  = [Globalization.CultureInfo]::GetCultureInfo('en-US')
$script:LangCode = 'en'

function Read-LanguageFile {
    param([Parameter(Mandatory)][string]$Path)
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $obj = $raw | ConvertFrom-Json
    $map = @{}
    foreach ($p in $obj.PSObject.Properties) {
        if ($p.Value -is [string]) { $map[$p.Name] = $p.Value }
    }
    [pscustomobject]@{ Strings = $map; Meta = $obj._meta }
}

function Get-AvailableLanguages {
    param([Parameter(Mandatory)][string]$Directory)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($f in (Get-ChildItem -LiteralPath $Directory -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try {
            $l = Read-LanguageFile -Path $f.FullName
            $list.Add([pscustomobject]@{
                Code       = [string]$l.Meta.code
                Name       = [string]$l.Meta.name
                NativeName = [string]$l.Meta.nativeName
                Culture    = [string]$l.Meta.culture
                Path       = $f.FullName
            })
        } catch { }
    }
    $list
}

function Get-DefaultLanguageCode {
    param([Parameter(Mandatory)][string]$Directory)
    $code = (Get-UICulture).TwoLetterISOLanguageName
    if (Test-Path -LiteralPath (Join-Path $Directory "$code.json")) { return $code }
    'en'
}

function Initialize-Language {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string]$Code = 'en'
    )
    $enPath = Join-Path $Directory 'en.json'
    $en = Read-LanguageFile -Path $enPath
    $script:Fallback = $en.Strings
    $script:Strings  = $en.Strings
    $culture = 'en-US'
    $script:LangCode = 'en'

    $path = Join-Path $Directory "$Code.json"
    if ($Code -ne 'en' -and (Test-Path -LiteralPath $path)) {
        $l = Read-LanguageFile -Path $path
        $script:Strings  = $l.Strings
        $script:LangCode = $Code
        if ($l.Meta.culture) { $culture = [string]$l.Meta.culture }
    }
    try { $script:Culture = [Globalization.CultureInfo]::GetCultureInfo($culture) } catch { }
}

function T {
    <# Returns the localized string for Key, formatted with the remaining arguments. #>
    param(
        [Parameter(Position = 0)][string]$Key,
        [Parameter(Position = 1, ValueFromRemainingArguments = $true)]$Rest
    )
    $s = $script:Strings[$Key]
    if (-not $s) { $s = $script:Fallback[$Key] }
    if (-not $s) { return $Key }
    if ($null -ne $Rest -and @($Rest).Count -gt 0) {
        try { return [string]::Format($script:Culture, $s, [object[]]@($Rest)) } catch { return $s }
    }
    $s
}

function Get-AppCulture { $script:Culture }

# =============================================================================
#  Helpers
# =============================================================================
function Send-Progress {
    param(
        [scriptblock]$Notify,
        [string]$Text,
        [ValidateSet('info','ok','warn','error','step')][string]$Kind = 'info'
    )
    if ($null -eq $Notify) { return }
    try { & $Notify ([pscustomobject]@{ Text = $Text; Kind = $Kind; Time = Get-Date }) } catch { }
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -lt 0) { $Bytes = 0 }
    $c = $script:Culture
    if     ($Bytes -ge 1TB) { return ($Bytes / 1TB).ToString('N2', $c) + ' TB' }
    elseif ($Bytes -ge 1GB) { return ($Bytes / 1GB).ToString('N2', $c) + ' GB' }
    elseif ($Bytes -ge 1MB) { return ($Bytes / 1MB).ToString('N1', $c) + ' MB' }
    elseif ($Bytes -ge 1KB) { return ($Bytes / 1KB).ToString('N0', $c) + ' KB' }
    ($Bytes).ToString('N0', $c) + ' B'
}

function Get-FolderSize {
    param([string]$Path)
    $r = [pscustomobject]@{ Count = 0; Bytes = [double]0 }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $r }
    try {
        $files = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue
        if ($files) {
            $m = $files | Measure-Object -Property Length -Sum
            $r.Count = [int]$m.Count
            $r.Bytes = [double]$m.Sum
        }
    } catch { }
    $r
}

function Test-SafePath {
    <# Safety lock: drive roots, Windows and profile roots can never be cleaned. #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path.TrimEnd('\')
    if ($p -match '^[A-Za-z]:$') { return $false }
    if ($p.Length -lt 8) { return $false }
    # Comparisons are ORDINAL on purpose. -ieq / -like use the current culture,
    # and on Turkish Windows "WINDOWS" lower-cases to "w?ndows" with a dotless i (U+0131), so
    # "C:\WINDOWS\Prefetch" would NOT match "\Windows\Prefetch".
    $oic = [StringComparison]::OrdinalIgnoreCase
    foreach ($k in @($env:SystemRoot, $env:SystemDrive, $env:USERPROFILE,
                     $env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA, $env:ProgramFiles)) {
        if ($k -and [string]::Equals($p, $k.TrimEnd('\'), $oic)) { return $false }
    }
    foreach ($frag in $script:ProtectedFragments) { if ($p.IndexOf($frag, $oic) -ge 0) { return $false } }
    $true
}

# Caches that make Windows and games FASTER. Deleting them only forces a slow
# rebuild (thumbnails, icons, GPU shaders, Prefetch). WinCare never touches them.
$script:ProtectedFragments = @(
    '\Microsoft\Windows\Explorer'     # thumbcache_*.db, iconcache_*.db
    '\D3DSCache'                       # DirectX shader cache
    '\NVIDIA'                          # DXCache, GLCache, ComputeCache
    '\AMD\'                            # DxCache, GLCache, VkCache
    '\Intel\ShaderCache'
    '\ShaderCache'
    '\Windows\Prefetch'
    '\Windows\Fonts'
    '\FontCache'
)
function Get-ProtectedFragments { $script:ProtectedFragments }

function Test-IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# =============================================================================
#  Running Windows tools
# =============================================================================
function Invoke-WindowsTool {
    <#
        Runs a built-in Windows tool and streams its meaningful output lines.
        Progress bars and percentage lines are dropped. Results are judged by
        exit code only: the text is in the OS language and is never parsed.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$InputText,
        [switch]$Unicode,          # sfc.exe writes UTF-16
        [switch]$Quiet,
        [scriptblock]$Notify
    )
    $name = [IO.Path]::GetFileNameWithoutExtension($FilePath)
    $display = (@($name) + $Arguments) -join ' '
    Send-Progress $Notify "> $display" 'step'
    $lines = New-Object System.Collections.Generic.List[string]
    $code = -1
    $oldEnc = $null
    try {
        if ($Unicode) { try { $oldEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::Unicode } catch { $oldEnc = $null } }
        if ($InputText) { $raw = $InputText | & $FilePath @Arguments 2>&1 | Out-String }
        else            { $raw = & $FilePath @Arguments 2>&1 | Out-String }
        $code = $LASTEXITCODE
    } catch {
        $raw = $_.Exception.Message
    } finally {
        if ($oldEnc) { try { [Console]::OutputEncoding = $oldEnc } catch { } }
    }
    $seen = @{}
    foreach ($l in (("$raw" -replace "`0", '') -split "[`r`n]+")) {
        $t = $l.Trim()
        if (-not $t) { continue }
        if ($t -match '^\[[=\s\d.,%]*\]$') { continue }                  # DISM progress bar
        if ($t -match '(\d+([.,]\d+)?\s?%)|(%\s?\d+)') { continue }       # "Verification 45% complete"
        if ($seen.ContainsKey($t)) { continue }
        $seen[$t] = $true
        $lines.Add($t)
        if (-not $Quiet) { Send-Progress $Notify "    $t" 'info' }
    }
    [pscustomobject]@{ Command = $display; ExitCode = $code; Lines = $lines; Ok = ($code -eq 0) }
}

# =============================================================================
#  System information
# =============================================================================
function Get-SystemInfo {
    $r = [pscustomobject]@{
        OsName = ''; DisplayVersion = ''; Build = ''
        Model = ''; RamBytes = [double]0; MemoryPercent = 0
        Uptime = [timespan]::Zero
        ComputerName = $env:COMPUTERNAME; UserName = $env:USERNAME
        Firmware = [string]$env:firmware_type
    }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $r.OsName = $os.Caption
        $r.Uptime = (Get-Date) - $os.LastBootUpTime
        if ($os.TotalVisibleMemorySize -gt 0) {
            $r.MemoryPercent = [int](100 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100))
        }
    } catch { }
    # Note: registry ProductName says "Windows 10" even on Windows 11, so the
    # name comes from Win32_OperatingSystem; only version/build come from here.
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if ($cv.PSObject.Properties['DisplayVersion']) { $r.DisplayVersion = $cv.DisplayVersion }
        $ubr = if ($cv.PSObject.Properties['UBR']) { ".$($cv.UBR)" } else { '' }
        $r.Build = "$($cv.CurrentBuild)$ubr"
    } catch { }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $r.Model = ("{0} {1}" -f $cs.Manufacturer, $cs.Model).Trim()
        $r.RamBytes = [double]$cs.TotalPhysicalMemory
    } catch { }
    $r
}

# =============================================================================
#  Disks
# =============================================================================
function Get-DiskHealth {
    $list = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($d in (Get-PhysicalDisk -ErrorAction Stop | Sort-Object DeviceId)) {
            $item = [pscustomobject]@{
                Id = $d.DeviceId; Name = $d.FriendlyName; Media = [string]$d.MediaType
                Bus = [string]$d.BusType; Size = [double]$d.Size; Health = [string]$d.HealthStatus
                Temperature = $null; Wear = $null; PowerOnHours = $null; Errors = 0
                Problem = ($d.HealthStatus -ne 'Healthy'); Warnings = @()
            }
            try {
                $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop
                if ($rc) {
                    if ($rc.PSObject.Properties['Temperature']  -and $rc.Temperature -gt 0)      { $item.Temperature  = [int]$rc.Temperature }
                    if ($rc.PSObject.Properties['Wear']         -and $null -ne $rc.Wear)         { $item.Wear         = [int]$rc.Wear }
                    if ($rc.PSObject.Properties['PowerOnHours'] -and $null -ne $rc.PowerOnHours) { $item.PowerOnHours = [int]$rc.PowerOnHours }
                    $e = 0
                    foreach ($f in 'ReadErrorsUncorrected', 'WriteErrorsUncorrected') {
                        if ($rc.PSObject.Properties[$f] -and $null -ne $rc.$f) { $e += [int]$rc.$f }
                    }
                    $item.Errors = $e
                    $w = @()
                    if ($e -gt 0)                                                  { $w += (T 'disk.warn.errors' $e) }
                    if ($null -ne $item.Wear        -and $item.Wear -ge 80)        { $w += (T 'disk.warn.wear' $item.Wear) }
                    if ($null -ne $item.Temperature -and $item.Temperature -ge 70) { $w += (T 'disk.warn.temp' $item.Temperature) }
                    if ($w.Count) { $item.Problem = $true }
                    $item.Warnings = $w
                }
            } catch { }
            $list.Add($item)
        }
    } catch { }
    $list
}

function Get-MediaType {
    param([string]$Letter)
    try {
        $part = Get-Partition -DriveLetter $Letter -ErrorAction Stop
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq $part.DiskNumber }
        if ($pd) { return [pscustomobject]@{ Media = [string]$pd.MediaType; Name = $pd.FriendlyName; Bus = [string]$pd.BusType; DiskId = [string]$pd.DeviceId } }
    } catch { }
    [pscustomobject]@{ Media = 'Unknown'; Name = ''; Bus = ''; DiskId = '' }
}

function Get-VolumeInfo {
    $list = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($v in (Get-Volume -ErrorAction Stop |
                        Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 } |
                        Sort-Object DriveLetter)) {
            $free = $v.SizeRemaining / $v.Size * 100
            $mt = Get-MediaType -Letter $v.DriveLetter
            $list.Add([pscustomobject]@{
                Letter = [string]$v.DriveLetter; Label = $v.FileSystemLabel
                Free = [double]$v.SizeRemaining; Total = [double]$v.Size
                FreePercent = [math]::Round($free, 1); UsedPercent = [math]::Round(100 - $free, 1)
                FileSystem = $v.FileSystemType; Media = $mt.Media; DiskId = $mt.DiskId; Low = ($free -lt 10)
                IsSystem = ([string]$v.DriveLetter -ieq $env:SystemDrive.TrimEnd(':'))
            })
        }
    } catch { }
    $list
}

function Get-FreeSpace {
    param([string]$Letter = $env:SystemDrive.TrimEnd(':'))
    try { [double](Get-Volume -DriveLetter $Letter -ErrorAction Stop).SizeRemaining } catch { [double]0 }
}

# =============================================================================
#  Security / state
# =============================================================================
function Get-SecurityStatus {
    $r = [pscustomobject]@{
        ProtectionOn = $null; SignatureAge = $null
        RebootRequired = $false; RebootReasons = @(); PendingFiles = @()
        ErrorEvents = 0; TopSources = @(); UnexpectedShutdowns = 0
    }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $r.ProtectionOn = [bool]$mp.RealTimeProtectionEnabled
        $r.SignatureAge = [int]$mp.AntivirusSignatureAge
    } catch { }

    # Strong signals only. PendingFileRenameOperations is reported separately:
    # some apps leave permanent entries there that never clear after a reboot.
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
    $r.RebootReasons = $reasons
    $r.RebootRequired = ($reasons.Count -gt 0)

    try {
        $pfr = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop
        $r.PendingFiles = @($pfr.PendingFileRenameOperations | Where-Object { $_ -and $_.Trim() } |
                            ForEach-Object { Split-Path ($_ -replace '^[\*\d]*\\\?\?\\', '') -Leaf })
    } catch { }

    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -ErrorAction Stop)
        $r.ErrorEvents = $ev.Count
        $r.TopSources = @($ev | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 3 |
                          ForEach-Object { [pscustomobject]@{ Source = $_.Name; Count = $_.Count } })
        $r.UnexpectedShutdowns = @($ev | Where-Object { $_.Id -eq 41 }).Count
    } catch { }
    $r
}

function Get-OutdatedApps {
    <# winget, run as a job with a hard timeout. Counting is language independent. #>
    param([int]$TimeoutSeconds = 45)
    $r = [pscustomobject]@{ Supported = $false; Count = 0; TimedOut = $false }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $r }
    $r.Supported = $true
    $job = $null
    try {
        $job = Start-Job -ScriptBlock {
            & winget upgrade --include-unknown --disable-interactivity --accept-source-agreements 2>&1 | Out-String
        }
        if (Wait-Job $job -Timeout $TimeoutSeconds) {
            $out = Receive-Job $job -ErrorAction SilentlyContinue
            $inTable = $false; $n = 0
            foreach ($line in ("$out" -split "`r?`n")) {
                if (-not $inTable) { if ($line -match '^\s*-{5,}') { $inTable = $true }; continue }
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                # A table row has at least 4 columns separated by 2+ spaces;
                # the summary line ("3 upgrades available") does not.
                if (($line -split '\s{2,}' | Where-Object { $_.Trim() }).Count -ge 4) { $n++ }
            }
            $r.Count = $n
        } else {
            $r.TimedOut = $true
            Stop-Job $job -ErrorAction SilentlyContinue
        }
    } catch {
    } finally {
        if ($job) { Remove-Job $job -Force -ErrorAction SilentlyContinue }
    }
    $r
}

# =============================================================================
#  Cleanup
# =============================================================================
function Test-NameLike {
    <# Culture-invariant wildcard match (see the Turkish "I" note in Test-SafePath). #>
    param([string]$Name, [string]$Pattern)
    $opt = [System.Management.Automation.WildcardOptions]'IgnoreCase, CultureInvariant'
    (New-Object System.Management.Automation.WildcardPattern($Pattern, $opt)).IsMatch($Name)
}

function Get-CleanupTargets {
    <# Folder-based targets. None of them contain user documents. #>
    @(
        [pscustomobject]@{ Key = 'UserTemp';  Path = $env:TEMP;                                                             Days = 0;  Pattern = '' }
        [pscustomobject]@{ Key = 'WinTemp';   Path = (Join-Path $env:SystemRoot 'Temp');                                    Days = 0;  Pattern = '' }
        [pscustomobject]@{ Key = 'WUCache';   Path = (Join-Path $env:SystemRoot 'SoftwareDistribution\Download');           Days = 0;  Pattern = '' }
        [pscustomobject]@{ Key = 'WerArchive';Path = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive');    Days = 0;  Pattern = '' }
        [pscustomobject]@{ Key = 'WerQueue';  Path = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue');      Days = 0;  Pattern = '' }
        [pscustomobject]@{ Key = 'CrashDumps';Path = (Join-Path $env:LOCALAPPDATA 'CrashDumps');                            Days = 0;  Pattern = '' }
        [pscustomobject]@{ Key = 'INetCache'; Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache');           Days = 0;  Pattern = '' }
        # Only rotated archives older than 14 days. The live CBS.log is never touched:
        # SFC/DISM write their results there.
        [pscustomobject]@{ Key = 'CbsLogs';   Path = (Join-Path $env:SystemRoot 'Logs\CBS');                                Days = 14; Pattern = 'CbsPersist_*' }
    )
}

function Invoke-CleanupTarget {
    <#
        Without -Apply: measures only.
        With -Apply: removes the CONTENT of the folder (the folder itself stays).
        Each item is measured BEFORE deletion and counted only if it is really
        gone - measuring afterwards would count files created meanwhile.
    #>
    param(
        [Parameter(Mandatory)]$Target,
        [switch]$Apply,
        [scriptblock]$Notify
    )
    $r = [pscustomobject]@{ Key = $Target.Key; Count = 0; Bytes = [double]0; Kept = 0; Locked = 0; State = 'skipped' }

    if (-not (Test-SafePath $Target.Path)) {
        $r.State = 'refused'
        Send-Progress $Notify (T 'msg.clean.refused' (T "clean.$($Target.Key).name")) 'warn'
        return $r
    }
    if (-not (Test-Path -LiteralPath $Target.Path)) { $r.State = 'missing'; return $r }

    if (-not $Apply) {
        if ($Target.Pattern -or $Target.Days -gt 0) {
            # Measure exactly what would be removed
            $limit = if ($Target.Days -gt 0) { (Get-Date).AddDays(-$Target.Days) } else { $null }
            foreach ($f in (Get-ChildItem -LiteralPath $Target.Path -Force -File -ErrorAction SilentlyContinue)) {
                if ($Target.Pattern -and -not (Test-NameLike $f.Name $Target.Pattern)) { continue }
                if ($limit -and $f.LastWriteTime -gt $limit) { continue }
                $r.Count++; $r.Bytes += $f.Length
            }
        } else {
            $m = Get-FolderSize $Target.Path
            $r.Count = $m.Count; $r.Bytes = $m.Bytes
        }
        $r.State = 'measured'
        return $r
    }

    $limit = if ($Target.Days -gt 0) { (Get-Date).AddDays(-$Target.Days) } else { $null }
    try {
        foreach ($item in (Get-ChildItem -LiteralPath $Target.Path -Force -ErrorAction SilentlyContinue)) {
            if ($Target.Pattern -and -not (Test-NameLike $item.Name $Target.Pattern)) { $r.Kept++; continue }
            if ($limit) {
                # With an age filter, folders are never touched: an old folder
                # can contain new files that -Recurse would remove.
                if ($item.PSIsContainer) { $r.Kept++; continue }
                if ($item.LastWriteTime -gt $limit) { $r.Kept++; continue }
            }
            if ($item.PSIsContainer) {
                $before = Get-FolderSize $item.FullName
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                $after = Get-FolderSize $item.FullName
                $r.Bytes  += [math]::Max(0, $before.Bytes - $after.Bytes)
                $r.Count  += [math]::Max(0, $before.Count - $after.Count)
                $r.Locked += $after.Count
            } else {
                $b = [double]$item.Length
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $item.FullName) { $r.Locked++ } else { $r.Bytes += $b; $r.Count++ }
            }
        }
    } catch { }
    $r.State = 'cleaned'
    Send-Progress $Notify (T 'msg.clean.done' (T "clean.$($Target.Key).name") $r.Count (Format-Size $r.Bytes)) 'ok'
    $r
}

function Get-RecycleBinSize {
    $bytes = [double]0; $count = 0
    try {
        foreach ($v in (Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' })) {
            $m = Get-FolderSize ("{0}:\`$Recycle.Bin" -f $v.DriveLetter)
            $bytes += $m.Bytes; $count += $m.Count
        }
    } catch { }
    [pscustomobject]@{ Count = $count; Bytes = $bytes }
}

function Clear-RecycleBinSafe {
    param([scriptblock]$Notify)
    $before = Get-RecycleBinSize
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Send-Progress $Notify (T 'msg.recycle.done' (Format-Size $before.Bytes)) 'ok'
        [pscustomobject]@{ Ok = $true; Count = $before.Count; Bytes = $before.Bytes }
    } catch {
        Send-Progress $Notify (T 'msg.recycle.fail') 'warn'
        [pscustomobject]@{ Ok = $false; Count = 0; Bytes = [double]0 }
    }
}

function Get-DeliveryCacheSize {
    Get-FolderSize (Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization')
}

function Clear-DeliveryCache {
    <# Uses Windows' own cmdlet, which is safer than deleting files by hand. #>
    param([scriptblock]$Notify)
    $m = Get-DeliveryCacheSize
    try {
        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
        Send-Progress $Notify (T 'msg.clean.done' (T 'clean.Delivery.name') $m.Count (Format-Size $m.Bytes)) 'ok'
        [pscustomobject]@{ Count = $m.Count; Bytes = $m.Bytes }
    } catch {
        [pscustomobject]@{ Count = 0; Bytes = [double]0 }
    }
}

function Stop-UpdateServices {
    <# sc.exe does not block like "net stop"; we wait at most 20 seconds. #>
    param([scriptblock]$Notify)
    try {
        $null = sc.exe stop wuauserv 2>&1
        $null = sc.exe stop bits 2>&1
        $until = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $until) {
            if (-not (Get-Service wuauserv, bits -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Stopped' })) { break }
            Start-Sleep -Milliseconds 500
        }
        Send-Progress $Notify (T 'msg.services.stopped') 'info'
        $true
    } catch { $false }
}

function Start-UpdateServices {
    param([scriptblock]$Notify)
    try {
        $null = sc.exe start bits 2>&1
        $null = sc.exe start wuauserv 2>&1
        Send-Progress $Notify (T 'msg.services.started') 'info'
    } catch { }
}

# =============================================================================
#  System file integrity (DISM / SFC / WMI)
# =============================================================================
$script:Dism = Join-Path $env:SystemRoot 'System32\dism.exe'
$script:Sfc  = Join-Path $env:SystemRoot 'System32\sfc.exe'
$script:Wmi  = Join-Path $env:SystemRoot 'System32\wbem\winmgmt.exe'

function Test-ComponentStore {
    <# DISM /CheckHealth - instant, reads the corruption flag only. #>
    param([scriptblock]$Notify)
    $r = Invoke-WindowsTool $script:Dism @('/Online','/Cleanup-Image','/CheckHealth') -Notify $Notify
    if ($r.Ok) { Send-Progress $Notify (T 'msg.check.ok') 'ok' } else { Send-Progress $Notify (T 'msg.check.bad' $r.ExitCode) 'warn' }
    [pscustomobject]@{ Healthy = $r.Ok; Code = $r.ExitCode }
}

function Invoke-ScanHealth {
    <# DISM /ScanHealth - full scan, read-only. #>
    param([scriptblock]$Notify)
    $r = Invoke-WindowsTool $script:Dism @('/Online','/Cleanup-Image','/ScanHealth') -Notify $Notify
    if ($r.Ok) { Send-Progress $Notify (T 'msg.scan.ok') 'ok' } else { Send-Progress $Notify (T 'msg.scan.bad') 'warn' }
    [pscustomobject]@{ Healthy = $r.Ok; Code = $r.ExitCode }
}

function Repair-ComponentStore {
    <# DISM /RestoreHealth - repairs the component store, may use Windows Update. #>
    param([scriptblock]$Notify)
    $r = Invoke-WindowsTool $script:Dism @('/Online','/Cleanup-Image','/RestoreHealth') -Notify $Notify
    if ($r.Ok) { Send-Progress $Notify (T 'msg.repair.ok') 'ok' } else { Send-Progress $Notify (T 'msg.repair.bad' $r.ExitCode) 'error' }
    [pscustomobject]@{ Ok = $r.Ok; Code = $r.ExitCode }
}

function Get-ComponentStoreAnalysis {
    <# DISM /AnalyzeComponentStore - output is returned as-is, never parsed. #>
    param([scriptblock]$Notify)
    $r = Invoke-WindowsTool $script:Dism @('/Online','/Cleanup-Image','/AnalyzeComponentStore') -Notify $Notify -Quiet
    @($r.Lines | Where-Object { $_ -match '^\S.*:\s*\S' -and $_.Length -lt 90 -and $_ -notmatch '^(Deployment Image|Version|Image Version)' })
}

function Invoke-ComponentCleanup {
    <#
        DISM /StartComponentCleanup - removes superseded update files.
        /ResetBase is never used: it would make installed updates permanent.
    #>
    param([scriptblock]$Notify)
    $before = Get-FreeSpace
    $r = Invoke-WindowsTool $script:Dism @('/Online','/Cleanup-Image','/StartComponentCleanup') -Notify $Notify
    $gain = [math]::Max(0, (Get-FreeSpace) - $before)
    if ($r.Ok) { Send-Progress $Notify (T 'msg.comp.ok' (Format-Size $gain)) 'ok' } else { Send-Progress $Notify (T 'msg.comp.bad' $r.ExitCode) 'warn' }
    [pscustomobject]@{ Ok = $r.Ok; Code = $r.ExitCode; Bytes = $gain }
}

function Invoke-Sfc {
    <# sfc /scannow (verify + repair) or sfc /verifyonly (check only). #>
    param([ValidateSet('scannow','verifyonly')][string]$Mode = 'scannow', [scriptblock]$Notify)
    $r = Invoke-WindowsTool $script:Sfc @("/$Mode") -Unicode -Notify $Notify
    if ($r.Ok) { Send-Progress $Notify (T 'msg.sfc.ok') 'ok' } else { Send-Progress $Notify (T 'msg.sfc.bad' $r.ExitCode) 'warn' }
    [pscustomobject]@{ Ok = $r.Ok; Code = $r.ExitCode; Mode = $Mode }
}

function Invoke-SfcScanFile {
    <# sfc /scanfile=<path> - verifies and repairs a single protected file. #>
    param([Parameter(Mandatory)][string]$Path, [scriptblock]$Notify)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Send-Progress $Notify (T 'msg.scanfile.missing' $Path) 'warn'
        return [pscustomobject]@{ Ok = $false; Code = -2; Path = $Path }
    }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $r = Invoke-WindowsTool $script:Sfc @("/scanfile=$full") -Unicode -Notify $Notify
    if ($r.Ok) { Send-Progress $Notify (T 'msg.scanfile.ok' $full) 'ok' } else { Send-Progress $Notify (T 'msg.scanfile.bad' $full $r.ExitCode) 'warn' }
    [pscustomobject]@{ Ok = $r.Ok; Code = $r.ExitCode; Path = $full }
}

function Test-WmiRepository {
    <# winmgmt /verifyrepository - read-only consistency check. #>
    param([scriptblock]$Notify)
    $r = Invoke-WindowsTool $script:Wmi @('/verifyrepository') -Notify $Notify
    if ($r.Ok) { Send-Progress $Notify (T 'msg.wmi.ok') 'ok' } else { Send-Progress $Notify (T 'msg.wmi.bad' $r.ExitCode) 'warn' }
    [pscustomobject]@{ Consistent = $r.Ok; Code = $r.ExitCode }
}

function Repair-WmiRepository {
    <# winmgmt /salvagerepository - rebuilds an inconsistent repository, keeps consistent data. #>
    param([scriptblock]$Notify)
    $r = Invoke-WindowsTool $script:Wmi @('/salvagerepository') -Notify $Notify
    if ($r.Ok) { Send-Progress $Notify (T 'msg.wmifix.ok') 'ok' } else { Send-Progress $Notify (T 'msg.wmifix.bad' $r.ExitCode) 'error' }
    [pscustomobject]@{ Ok = $r.Ok; Code = $r.ExitCode }
}

# =============================================================================
#  File system
# =============================================================================
function Test-VolumeHealth {
    <# Repair-Volume -Scan: online and read-only. #>
    param([string]$Letter = $env:SystemDrive.TrimEnd(':'), [scriptblock]$Notify)
    Send-Progress $Notify (T 'msg.vol.running' $Letter) 'step'
    try {
        $res = "$(Repair-Volume -DriveLetter $Letter -Scan -ErrorAction Stop)"
        $clean = ($res -eq 'NoErrorsFound')
        if ($clean) { Send-Progress $Notify (T 'msg.vol.ok' $Letter) 'ok' } else { Send-Progress $Notify (T 'msg.vol.bad' $Letter) 'warn' }
        [pscustomobject]@{ Clean = $clean; Result = $res }
    } catch {
        Send-Progress $Notify (T 'msg.vol.fail' $Letter) 'error'
        [pscustomobject]@{ Clean = $null; Result = $_.Exception.Message }
    }
}

function Repair-VolumeSpotFix {
    <#
        Targeted spot fix, runs at next boot and takes seconds.
        "fsutil dirty set" is NOT used: it does not clear the NTFS corruption
        record and leads to an endless "disk error" loop.
    #>
    param([string]$Letter = $env:SystemDrive.TrimEnd(':'), [scriptblock]$Notify)
    try { $null = Repair-Volume -DriveLetter $Letter -SpotFix -ErrorAction Stop } catch { }
    Send-Progress $Notify (T 'msg.spotfix.scheduled') 'ok'
    [pscustomobject]@{ Ok = $true }
}

function Invoke-Chkdsk {
    <#
        chkdsk X: /f | /r | /f /r /x
          /f        fix file system errors
          /r        /f + locate bad sectors (reads the whole drive - hours on large disks)
          /f /r /x  same, and force the volume to dismount first
        The system drive cannot be locked while Windows runs, so chkdsk asks to
        schedule the check for the next restart; "Y" is answered automatically.
        On other drives "Y" answers the dismount question: open files on that
        drive lose their handles.
    #>
    param(
        [Parameter(Mandatory)][string]$Letter,
        [ValidateSet('f','r','frx')][string]$Mode = 'f',
        [scriptblock]$Notify
    )
    $args2 = switch ($Mode) { 'f' { @('/f') } 'r' { @('/r') } 'frx' { @('/f','/r','/x') } }
    $isSystem = ($Letter.TrimEnd(':') -ieq $env:SystemDrive.TrimEnd(':'))
    $exe = Join-Path $env:SystemRoot 'System32\chkdsk.exe'
    $r = Invoke-WindowsTool $exe (@("$($Letter.TrimEnd(':')):") + $args2) -InputText "Y`r`nY`r`n" -Notify $Notify
    if ($isSystem) { Send-Progress $Notify (T 'msg.chkdsk.scheduled' $Letter.TrimEnd(':')) 'ok' }
    elseif ($r.ExitCode -le 1) { Send-Progress $Notify (T 'msg.chkdsk.done' $Letter.TrimEnd(':')) 'ok' }
    else { Send-Progress $Notify (T 'msg.chkdsk.bad' $Letter.TrimEnd(':') $r.ExitCode) 'warn' }
    [pscustomobject]@{ Letter = $Letter.TrimEnd(':'); Mode = $Mode; Code = $r.ExitCode; Scheduled = $isSystem }
}

# =============================================================================
#  Optimization
# =============================================================================
function Get-OptimizeStatus {
    try {
        $i = Get-ScheduledTask -TaskName 'ScheduledDefrag' -TaskPath '\Microsoft\Windows\Defrag\' -ErrorAction Stop | Get-ScheduledTaskInfo -ErrorAction Stop
        if ($i.LastRunTime -and $i.LastRunTime -gt [datetime]'2000-01-01') {
            return [pscustomobject]@{ Known = $true; LastRun = $i.LastRunTime; DaysAgo = ((Get-Date) - $i.LastRunTime).Days }
        }
    } catch { }
    [pscustomobject]@{ Known = $false; LastRun = $null; DaysAgo = -1 }
}

function Invoke-Optimize {
    <#
        SSD / NVMe -> TRIM only (no wear). HDD -> defrag only if -Defrag.
        An SSD is NEVER defragmented.
    #>
    param([Parameter(Mandatory)][string]$Letter, [switch]$Defrag, [scriptblock]$Notify)
    $mt = Get-MediaType -Letter $Letter
    if ($mt.Media -eq 'SSD') {
        Send-Progress $Notify (T 'msg.opt.trim' $Letter) 'step'
        try { Optimize-Volume -DriveLetter $Letter -ReTrim -ErrorAction Stop; Send-Progress $Notify (T 'msg.opt.trimok' $Letter) 'ok'; return [pscustomobject]@{ Ok = $true; Media = 'SSD'; Action = 'trim' } }
        catch { return [pscustomobject]@{ Ok = $false; Media = 'SSD'; Action = 'trim' } }
    }
    if ($mt.Media -eq 'HDD') {
        if (-not $Defrag) { return [pscustomobject]@{ Ok = $true; Media = 'HDD'; Action = 'skipped' } }
        Send-Progress $Notify (T 'msg.opt.defrag' $Letter) 'step'
        try { Optimize-Volume -DriveLetter $Letter -Defrag -ErrorAction Stop; Send-Progress $Notify (T 'msg.opt.defragok' $Letter) 'ok'; return [pscustomobject]@{ Ok = $true; Media = 'HDD'; Action = 'defrag' } }
        catch { return [pscustomobject]@{ Ok = $false; Media = 'HDD'; Action = 'defrag' } }
    }
    [pscustomobject]@{ Ok = $true; Media = 'Unknown'; Action = 'skipped' }
}

# =============================================================================
#  Network
# =============================================================================
function Test-Network {
    <# OK | NoIp | NoGateway | NoInternet | NoAdapter #>
    $r = [pscustomobject]@{ Status = 'NoAdapter'; Adapter = ''; Description = ''; IP = ''; Speed = '' }
    try {
        $a = Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq 'Up' | Select-Object -First 1
        if (-not $a) { return $r }
        $r.Adapter = $a.Name; $r.Description = $a.InterfaceDescription; $r.Speed = "$($a.LinkSpeed)"
        $ip = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notmatch '^169\.254\.' -and $_.IPAddress -ne '0.0.0.0' } | Select-Object -First 1
        if (-not $ip) { $r.Status = 'NoIp'; return $r }
        $r.IP = $ip.IPAddress
        $gw = (Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue).IPv4DefaultGateway
        if ($gw -and -not (Test-Connection -ComputerName $gw.NextHop -Count 1 -Quiet -ErrorAction SilentlyContinue)) { $r.Status = 'NoGateway'; return $r }
        if (-not (Test-Connection -ComputerName '1.1.1.1' -Count 1 -Quiet -ErrorAction SilentlyContinue)) { $r.Status = 'NoInternet'; return $r }
        $r.Status = 'OK'
    } catch { }
    $r
}

function Clear-DnsCache {
    param([scriptblock]$Notify)
    $r = Invoke-WindowsTool (Join-Path $env:SystemRoot 'System32\ipconfig.exe') @('/flushdns') -Notify $Notify
    if ($r.Ok) { Send-Progress $Notify (T 'msg.dns.ok') 'ok' } else { Send-Progress $Notify (T 'msg.dns.fail') 'warn' }
    $r.Ok
}

function Reset-NetworkStack {
    <#
        netsh winsock reset | netsh int ip reset
        Resets network configuration to defaults (static IP/DNS, VPN and proxy
        layered providers are lost). Requires a restart. Never run automatically.
    #>
    param([ValidateSet('winsock','ip')][string]$Part, [scriptblock]$Notify)
    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    $a = if ($Part -eq 'winsock') { @('winsock','reset') } else { @('int','ip','reset') }
    $r = Invoke-WindowsTool $netsh $a -Notify $Notify
    if ($r.Ok) { Send-Progress $Notify (T 'msg.netreset.ok') 'ok' } else { Send-Progress $Notify (T 'msg.netreset.bad' $r.ExitCode) 'warn' }
    [pscustomobject]@{ Ok = $r.Ok; Code = $r.ExitCode; Part = $Part }
}

function Restart-NetworkAdapter {
    <# Same as Disable + Enable in Device Manager. Settings are not changed. #>
    param([scriptblock]$Notify)
    try {
        $a = Get-NetAdapter -ErrorAction Stop |
             Where-Object { $_.InterfaceDescription -notmatch 'Bluetooth|Virtual|VPN|TAP|Loopback|WAN Miniport|Hyper-V' } |
             Sort-Object @{ Expression = { $_.Status -eq 'Up' }; Descending = $true }, ifIndex | Select-Object -First 1
        if (-not $a) { Send-Progress $Notify (T 'msg.adapter.none') 'warn'; return $false }
        Send-Progress $Notify (T 'msg.adapter.restarting' $a.Name) 'step'
        Restart-NetAdapter -Name $a.Name -ErrorAction Stop
        $until = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $until) {
            Start-Sleep -Seconds 2
            if ((Test-Network).Status -eq 'OK') { Send-Progress $Notify (T 'msg.adapter.ok') 'ok'; return $true }
        }
        Send-Progress $Notify (T 'msg.adapter.still') 'warn'
        $false
    } catch {
        Send-Progress $Notify (T 'msg.adapter.fail' $_.Exception.Message) 'error'
        $false
    }
}

# =============================================================================
#  Run history (when each command last ran and how it ended)
# =============================================================================
function Get-RunHistoryPath {
    # WINCARE_HISTORY overrides the location (tests and screenshots use a throwaway file)
    if ($env:WINCARE_HISTORY) { return $env:WINCARE_HISTORY }
    Join-Path (Join-Path $env:APPDATA 'WinCare') 'history.json'
}

function Read-RunHistory {
    $h = @{}
    try {
        $p = Get-RunHistoryPath
        if (Test-Path -LiteralPath $p) {
            $j = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($pr in $j.PSObject.Properties) {
                $v = $pr.Value
                # PowerShell 7 turns ISO dates into DateTime, 5.1 keeps strings
                $t = if ($v.Time -is [datetime]) { $v.Time } else {
                    [datetime]::Parse([string]$v.Time, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
                $h[$pr.Name] = [pscustomobject]@{ Time = $t.ToLocalTime(); Ok = $v.Ok; Code = $v.Code }
            }
        }
    } catch { }
    $h
}

function Write-RunRecord {
    param([Parameter(Mandatory)][string]$Key, $Ok = $null, $Code = $null)
    $h = Read-RunHistory
    $h[$Key] = [pscustomobject]@{ Time = Get-Date; Ok = $Ok; Code = $Code }
    $o = [ordered]@{}
    foreach ($k in ($h.Keys | Sort-Object)) {
        $r = $h[$k]
        $o[$k] = [ordered]@{ Time = $r.Time.ToUniversalTime().ToString('o'); Ok = $r.Ok; Code = $r.Code }
    }
    try {
        $p = Get-RunHistoryPath
        $d = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        [IO.File]::WriteAllText($p, ([pscustomobject]$o | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function Get-LastUpdateDate {
    <# Date of the most recently installed Windows update (hotfix list). #>
    try {
        $last = $null
        foreach ($q in (Get-CimInstance Win32_QuickFixEngineering -ErrorAction Stop)) {
            $v = $q.InstalledOn
            if (-not $v) { continue }
            # Get-CimInstance already returns a DateTime; older providers give "M/d/yyyy" text
            $d = $null
            if ($v -is [datetime]) { $d = $v }
            else {
                $p = [datetime]::MinValue
                if ([datetime]::TryParseExact(([string]$v).Trim(), @('M/d/yyyy', 'MM/dd/yyyy', 'yyyyMMdd', 'M/d/yyyy H:mm:ss'),
                        [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$p)) { $d = $p }
            }
            if ($d -and (-not $last -or $d -gt $last)) { $last = $d }
        }
        return $last
    } catch { return $null }
}

function Get-ComponentCleanupTask {
    <# Windows runs StartComponentCleanup on its own; this returns when it last did. #>
    try {
        $i = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Servicing\' -TaskName 'StartComponentCleanup' -ErrorAction Stop |
             Get-ScheduledTaskInfo -ErrorAction Stop
        if ($i.LastRunTime -and $i.LastRunTime -gt [datetime]'2000-01-01') { return $i.LastRunTime }
    } catch { }
    $null
}

Export-ModuleMember -Function @(
    'Read-LanguageFile','Get-AvailableLanguages','Get-DefaultLanguageCode','Initialize-Language','T','Get-AppCulture',
    'Send-Progress','Format-Size','Get-FolderSize','Test-SafePath','Test-IsAdmin',
    'Get-SystemInfo','Get-DiskHealth','Get-MediaType','Get-VolumeInfo','Get-FreeSpace',
    'Get-SecurityStatus','Get-OutdatedApps',
    'Get-CleanupTargets','Invoke-CleanupTarget','Get-RecycleBinSize','Clear-RecycleBinSafe',
    'Get-DeliveryCacheSize','Clear-DeliveryCache','Stop-UpdateServices','Start-UpdateServices',
    'Test-ComponentStore','Invoke-ScanHealth','Repair-ComponentStore','Invoke-Sfc',
    'Get-ComponentStoreAnalysis','Invoke-ComponentCleanup',
    'Test-VolumeHealth','Repair-VolumeSpotFix','Get-OptimizeStatus','Invoke-Optimize',
    'Test-Network','Clear-DnsCache','Restart-NetworkAdapter',
    'Invoke-WindowsTool','Get-ProtectedFragments','Invoke-SfcScanFile','Test-WmiRepository','Repair-WmiRepository',
    'Invoke-Chkdsk','Reset-NetworkStack',
    'Get-RunHistoryPath','Read-RunHistory','Write-RunRecord','Get-LastUpdateDate','Get-ComponentCleanupTask'
)
