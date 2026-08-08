<#
.SYNOPSIS
    DSMT - shared constants, configuration and helpers.
.DESCRIPTION
    Loaded by Start-DSMT.ps1 before every other lib file. Holds the single
    source of truth for the version number, the on-disk paths, logging and
    the small helpers the rest of the server uses.
.NOTES
    Author  : IT Team
    Version : see $script:DsmtVersion below - THE only place it is defined.
#>

# ---------------------------------------------------------------------------
# VERSION - SINGLE SOURCE OF TRUTH.
# Every place a version is shown (console header, login footer, API /api/meta,
# audit records, log lines) reads this one variable. Never paste the literal
# anywhere else; see CLAUDE.md "Versioning policy".
# ---------------------------------------------------------------------------
$script:DsmtVersion = '1.21.0'

# ---------------------------------------------------------------------------
# PUBLISHER - same rule as the version: defined once, read everywhere.
# Shown in the About dialog and the sign-in footer, both fed from /api/meta.
# Never type it into index.html or app.js.
# ---------------------------------------------------------------------------
$script:DsmtPublisher = 'Rendi Group'

# ---------------------------------------------------------------------------
# IDLE TIMEOUT bounds - defined once and enforced on every route that can set
# the value: the -SessionMinutes parameter, config\dsmt.config.json, and the
# runtime API. The maximum is deliberate: a session that can outlive a working
# day is not an idle control, it is a formality.
# ---------------------------------------------------------------------------
$script:DsmtSessionMinutesDefault = 15
$script:DsmtSessionMinutesMin     = 1
$script:DsmtSessionMinutesMax     = 480   # 8 hours

# ---------------------------------------------------------------------------
# SEARCH RESULT CAP bounds - same rule, one definition. The maximum is a
# browser limit, not a directory one: every row is a DOM row, and a table of
# tens of thousands stops being a console and becomes a hang with no error.
# The minimum keeps the cap from being set to something that hides results
# without explaining why.
# ---------------------------------------------------------------------------
$script:DsmtPageSizeDefault = 500
$script:DsmtPageSizeMin     = 25
$script:DsmtPageSizeMax     = 5000

# Filled in by Start-DSMT.ps1 at startup.
$script:DsmtConfig = @{
    Version       = $script:DsmtVersion
    Publisher     = $script:DsmtPublisher
    IdentityMode  = 'operator'
    ServiceAccount = ''
    AccountKind    = ''
    RootPath      = ''
    WebPath       = ''
    DataRoot      = ''
    ConfigPath    = ''
    DataPath      = ''
    DesignPath    = ''
    UploadsPath   = ''
    PathMode      = 'portable'
    Domain        = ''
    Server        = ''
    Port          = 8080
    ListenAddress = 'localhost'
    SessionMinutes = 15
    PageSize      = 500
    LogFile       = ''
    StartedUtc    = $null
}

# ---------------------------------------------------------------------------
# WHERE THINGS LIVE.
#
# Two roots, and the distinction is the whole point:
#
#   RootPath  - the CODE. server\, web\, _ds\, sql\. Replaced wholesale by an
#               upgrade. Nothing that must survive one may live here.
#   DataRoot  - the STATE. config\, data\, uploads\. Never touched by an
#               upgrade.
#
# Before 1.21.0 they were the same folder, so extracting a new build over the
# old one - or, more likely, extracting it NEXT to the old one and starting
# that instead - lost dsmt.config.json and the console came up with no SQL
# server configured, quietly falling back to JSONL. That is the bug this
# split exists to make impossible.
#
# The registry holds POINTERS to the two roots and nothing else. It is not a
# settings store: settings stay in JSON under DataRoot, where they can be
# read, diffed and mailed in a bug report. Two values answer the only
# question a fresh process cannot answer for itself - "where was I installed,
# and where is my state?" - and they are written once, by the installer.
# ---------------------------------------------------------------------------
$script:DsmtRegistryKey = 'HKLM:\SOFTWARE\Rendi Group\DSMT'

function Get-DsmtRegistryPaths {
    <#
    .SYNOPSIS
        Reads InstallPath and DataPath from HKLM\SOFTWARE\Rendi Group\DSMT.
    .DESCRIPTION
        Returns a hashtable with Found, InstallPath, DataPath and Error. An
        absent key is NOT an error - it is the normal state of a portable
        run straight out of an unzipped folder, which stays supported.

        Reading is deliberately tolerant: any failure returns Found = $false
        and the caller falls back to the folder layout. A registry hiccup
        must never stop the console from starting.
    #>

    $out = @{ Found = $false; InstallPath = ''; DataPath = ''; Error = '' }

    try {
        if (-not (Test-Path -LiteralPath $script:DsmtRegistryKey)) { return $out }

        $key = Get-ItemProperty -LiteralPath $script:DsmtRegistryKey -ErrorAction Stop

        if ($key.PSObject.Properties['InstallPath']) { $out.InstallPath = ([string]$key.InstallPath).Trim() }
        if ($key.PSObject.Properties['DataPath'])    { $out.DataPath    = ([string]$key.DataPath).Trim() }

        # A key holding neither value is the same as no key at all. Reporting
        # it as Found would send the caller off to resolve an empty path.
        if ($out.InstallPath -or $out.DataPath) { $out.Found = $true }
    } catch {
        $out.Error = $_.Exception.Message
    }

    return $out
}

function Set-DsmtRegistryPaths {
    <#
    .SYNOPSIS
        Writes the two pointer values. Called by Install-DSMT.ps1 only.
    .OUTPUTS
        Hashtable with Ok and Error. Needs an elevated process - HKLM is not
        writable by a standard user, and that is reported rather than thrown.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $InstallPath,
        [Parameter(Mandatory = $true)][string] $DataPath
    )

    try {
        if (-not (Test-Path -LiteralPath $script:DsmtRegistryKey)) {
            New-Item -Path $script:DsmtRegistryKey -Force -ErrorAction Stop | Out-Null
        }

        New-ItemProperty -LiteralPath $script:DsmtRegistryKey -Name 'InstallPath' -Value $InstallPath `
                         -PropertyType String -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -LiteralPath $script:DsmtRegistryKey -Name 'DataPath' -Value $DataPath `
                         -PropertyType String -Force -ErrorAction Stop | Out-Null

        # Recorded for a human reading the key, never read back by the server -
        # the running version comes from $script:DsmtVersion, one source only.
        New-ItemProperty -LiteralPath $script:DsmtRegistryKey -Name 'Version' -Value $script:DsmtVersion `
                         -PropertyType String -Force -ErrorAction Stop | Out-Null

        return @{ Ok = $true; Error = '' }
    } catch {
        return @{ Ok = $false; Error = $_.Exception.Message }
    }
}

function Resolve-DsmtDataRoot {
    <#
    .SYNOPSIS
        Decides where state lives, in a fixed order of precedence.
    .DESCRIPTION
        1. An explicit -DataRoot parameter        - always wins.
        2. HKLM\SOFTWARE\Rendi Group\DSMT\DataPath - written by the installer.
        3. The code folder itself                 - portable mode, unchanged
           behaviour for anyone running from an unzipped folder.

        Returns a hashtable: Path, Source ('parameter' | 'registry' |
        'portable'), Mode ('installed' | 'portable').
    #>
    param(
        [Parameter(Mandatory = $true)][string] $RootPath,
        [string] $DataRoot = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($DataRoot)) {
        return @{ Path = $DataRoot.Trim(); Source = 'parameter'; Mode = 'installed' }
    }

    $reg = Get-DsmtRegistryPaths
    if ($reg.Found -and -not [string]::IsNullOrWhiteSpace($reg.DataPath)) {
        return @{ Path = $reg.DataPath; Source = 'registry'; Mode = 'installed' }
    }

    return @{ Path = $RootPath; Source = 'portable'; Mode = 'portable' }
}

function Initialize-DsmtConfig {
    <#
    .SYNOPSIS
        Resolves all paths relative to the repository root and creates the
        data directory. Called once at startup.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $RootPath,
        [Parameter(Mandatory = $true)][string] $Domain,
        [string] $Server = '',
        [int]    $Port = 8080,
        [string] $ListenAddress = 'localhost',
        [int]    $SessionHours = 0,
        [int]    $SessionMinutes = 0,
        [int]    $PageSize = 500,
        [ValidateSet('operator', 'hybrid')][string] $IdentityMode = 'operator',
        [string] $DataRoot = '',
        [string] $PathMode = ''
    )

    # The idle timeout is held in MINUTES, in one field. -SessionHours is kept
    # because it was the original parameter, but it is converted here rather
    # than stored alongside: two fields that mean the same thing is how they
    # end up disagreeing.
    #
    # Bounds live here so they hold no matter which route set the value -
    # a parameter, the saved config file, or the runtime API.
    if ($SessionMinutes -le 0 -and $SessionHours -gt 0) { $SessionMinutes = $SessionHours * 60 }
    if ($SessionMinutes -le 0) { $SessionMinutes = $script:DsmtSessionMinutesDefault }

    if ($SessionMinutes -lt $script:DsmtSessionMinutesMin) { $SessionMinutes = $script:DsmtSessionMinutesMin }
    if ($SessionMinutes -gt $script:DsmtSessionMinutesMax) { $SessionMinutes = $script:DsmtSessionMinutesMax }

    $script:DsmtConfig.SessionMinutes = $SessionMinutes
    $script:DsmtConfig.IdentityMode  = $IdentityMode
    # Code paths hang off RootPath; state paths hang off DataRoot. In portable
    # mode the two roots are the same folder, which is why this split is
    # backward-compatible with every existing unzipped install.
    #
    # A caller that already resolved the root (Start-DSMT.ps1 must, because it
    # reads the settings file first) passes -PathMode alongside it. Without
    # that, re-resolving here would see a non-empty -DataRoot and call every
    # run "installed", including a portable one where the two roots are simply
    # the same folder.
    $resolved = Resolve-DsmtDataRoot -RootPath $RootPath -DataRoot $DataRoot
    if (-not [string]::IsNullOrWhiteSpace($PathMode)) { $resolved.Mode = $PathMode }

    $script:DsmtConfig.RootPath      = $RootPath
    $script:DsmtConfig.WebPath       = Join-Path $RootPath 'web'
    $script:DsmtConfig.DataRoot      = $resolved.Path
    $script:DsmtConfig.PathMode      = $resolved.Mode
    $script:DsmtConfig.ConfigPath    = Join-Path $resolved.Path 'config'
    $script:DsmtConfig.DataPath      = Join-Path $resolved.Path 'data'
    $script:DsmtConfig.UploadsPath   = Join-Path $resolved.Path 'uploads'
    $script:DsmtConfig.Domain        = $Domain
    $script:DsmtConfig.Server        = $Server
    $script:DsmtConfig.Port          = $Port
    $script:DsmtConfig.ListenAddress = $ListenAddress
    $script:DsmtConfig.PageSize      = $PageSize

    # The design system lives in a folder whose name carries the design tool's
    # GUID; resolve it rather than hardcoding the GUID in a second place.
    $dsRoot = Join-Path $RootPath '_ds'
    if (Test-Path -LiteralPath $dsRoot) {
        $first = Get-ChildItem -LiteralPath $dsRoot -Directory | Select-Object -First 1
        if ($null -ne $first) {
            $script:DsmtConfig.DesignPath = $first.FullName
        }
    }

    # All three state folders, not just data\. In installed mode DataRoot is a
    # brand-new %ProgramData%\DSMT that nothing has created yet, and the first
    # settings write must not be the thing that discovers config\ is missing.
    foreach ($needed in @($script:DsmtConfig.DataPath, $script:DsmtConfig.ConfigPath, $script:DsmtConfig.UploadsPath)) {
        if (-not (Test-Path -LiteralPath $needed)) {
            New-Item -ItemType Directory -Path $needed -Force | Out-Null
        }
    }
    $script:DsmtConfig.LogFile = Join-Path $script:DsmtConfig.DataPath ('dsmt-' + (Get-Date -Format 'yyyy-MM-dd') + '.log')

    # Stamped once, here, so the health page can report uptime. It answers the
    # question that matters after an unattended weekend: did the process stay
    # up, or did something restart it? See the 72-hour scheduled-task default
    # in CLAUDE.md for why that is not a theoretical concern.
    $script:DsmtConfig.StartedUtc = (Get-Date).ToUniversalTime()
}

function Get-DsmtConfig {
    return $script:DsmtConfig
}

function Get-DsmtSessionBounds {
    <#
    .SYNOPSIS
        The allowed idle-timeout range, so the API and the UI enforce and
        display exactly the numbers this file defines - rather than each
        repeating its own copy of them.
    #>
    return @{
        Default = $script:DsmtSessionMinutesDefault
        Min     = $script:DsmtSessionMinutesMin
        Max     = $script:DsmtSessionMinutesMax
    }
}

function Get-DsmtPageSizeBounds {
    <#
    .SYNOPSIS
        The allowed search-result-cap range, so the API and the UI enforce and
        display exactly the numbers this file defines.
    #>
    return @{
        Default = $script:DsmtPageSizeDefault
        Min     = $script:DsmtPageSizeMin
        Max     = $script:DsmtPageSizeMax
    }
}

function Get-DsmtAlertSettings {
    <#
    .SYNOPSIS
        Whether the scheduled AD health check runs, and how often.
    .DESCRIPTION
        Read from dsmt.config.json on every call rather than cached in memory:
        the file is small, the call is rare, and a cached copy is how a
        setting changed in one place goes on being ignored in another.

        Defaults to ENABLED at 60 minutes. A health check nobody switched on
        is a health check nobody benefits from, and it costs one AD read an
        hour while somebody has the console open.
    #>
    $cfg = Get-DsmtConfig

    $out = @{ Enabled = $true; IntervalMinutes = $script:DsmtAlertIntervalDefault }

    $saved = $null
    try { $saved = Get-DsmtSavedSettings -ConfigPath $cfg.ConfigPath } catch { $saved = $null }
    if ($null -eq $saved) { return $out }

    if ($saved.PSObject.Properties['HealthAlertsEnabled']) {
        $out.Enabled = [bool]$saved.HealthAlertsEnabled
    }
    if ($saved.PSObject.Properties['HealthAlertsInterval']) {
        $minutes = 0
        if ([int]::TryParse([string]$saved.HealthAlertsInterval, [ref] $minutes)) {
            if ($minutes -ge $script:DsmtAlertIntervalMin -and $minutes -le $script:DsmtAlertIntervalMax) {
                $out.IntervalMinutes = $minutes
            }
        }
    }

    return $out
}

function Get-DsmtSettingsFile {
    <#
    .SYNOPSIS
        The full path of dsmt.config.json for a given config directory.
        One function so the filename appears exactly once in the codebase.
    #>
    param([Parameter(Mandatory = $true)][string] $ConfigPath)
    return (Join-Path $ConfigPath 'dsmt.config.json')
}

function Move-DsmtLegacyState {
    <#
    .SYNOPSIS
        One-time migration of config\ and data\ from the code folder to the
        data root, for installs made before 1.21.0.
    .DESCRIPTION
        Without this, the very upgrade that introduces the code/state split is
        the one that loses the SQL settings - the new build looks in
        %ProgramData%\DSMT, finds nothing, and starts with file-only audit.

        Deliberately CONSERVATIVE:
          - does nothing when the two roots are the same folder (portable);
          - does nothing if the destination settings file already exists, so
            it can never overwrite newer state with older;
          - COPIES rather than moves. The old folder is left exactly as it
            was, so a failed upgrade can be rolled back by starting the old
            build again. Tidying it up is the operator's call, not ours.
    .OUTPUTS
        Hashtable: Migrated (bool), Items (string[]), Error.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $RootPath,
        [Parameter(Mandatory = $true)][string] $DataRoot
    )

    $out = @{ Migrated = $false; Items = @(); Error = '' }

    try {
        $rootFull = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\')
        $dataFull = [System.IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
        if ($rootFull -eq $dataFull) { return $out }

        $destSettings = Get-DsmtSettingsFile -ConfigPath (Join-Path $DataRoot 'config')
        if (Test-Path -LiteralPath $destSettings) { return $out }

        $moved = New-Object System.Collections.Generic.List[string]

        foreach ($name in @('config', 'data', 'uploads')) {
            $from = Join-Path $RootPath $name
            if (-not (Test-Path -LiteralPath $from)) { continue }

            $to = Join-Path $DataRoot $name
            if (-not (Test-Path -LiteralPath $to)) {
                New-Item -ItemType Directory -Path $to -Force -ErrorAction Stop | Out-Null
            }

            $items = @(Get-ChildItem -LiteralPath $from -Force -ErrorAction SilentlyContinue)
            if ($items.Count -eq 0) { continue }

            Copy-Item -LiteralPath $from -Destination $DataRoot -Recurse -Force -ErrorAction Stop
            $moved.Add($name + '\ (' + $items.Count + ' items)')
        }

        if ($moved.Count -gt 0) {
            $out.Migrated = $true
            $out.Items    = @($moved)
        }
    } catch {
        $out.Error = $_.Exception.Message
    }

    return $out
}

function Get-DsmtSavedSettings {
    <#
    .SYNOPSIS
        Reads dsmt.config.json - the settings Install-DSMT.ps1 chose - so the
        console can be started with no parameters at all.
    .DESCRIPTION
        Returns $null when the file is absent (a perfectly normal state: the
        installer was never run, or the operator passes everything on the
        command line). A malformed file is reported rather than ignored,
        because silently falling back to defaults is how a machine ends up
        pointing at the wrong domain without anyone noticing.
    #>
    param([Parameter(Mandatory = $true)][string] $ConfigPath)

    $path = Get-DsmtSettingsFile -ConfigPath $ConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return (ConvertFrom-Json -InputObject $raw -ErrorAction Stop)
    } catch {
        Write-Host ('  [warn] ' + $path + ' could not be read (' + $_.Exception.Message + '); using defaults and command-line parameters only.') -ForegroundColor Yellow
        return $null
    }
}

function Save-DsmtSavedSettings {
    <#
    .SYNOPSIS
        Writes dsmt.config.json, merging over whatever is already there so a
        value this call does not mention is preserved.
    .OUTPUTS
        Hashtable with Ok and Error.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $ConfigPath,
        # IDictionary, not hashtable: the installer builds its values as
        # [ordered]@{ } to keep the file readable, and an OrderedDictionary is
        # not a Hashtable. Typing this too narrowly fails the call outright.
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Values
    )

    $dir  = $ConfigPath
    $path = Get-DsmtSettingsFile -ConfigPath $dir

    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $merged = [ordered]@{}

        $existing = Get-DsmtSavedSettings -ConfigPath $dir
        if ($null -ne $existing) {
            foreach ($prop in $existing.PSObject.Properties) {
                $merged[$prop.Name] = $prop.Value
            }
        }
        foreach ($key in $Values.Keys) {
            $merged[$key] = $Values[$key]
        }

        ConvertTo-Json -InputObject $merged -Depth 4 |
            Set-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop

        return @{ Ok = $true; Error = '' }
    } catch {
        return @{ Ok = $false; Error = $_.Exception.Message }
    }
}

function Write-DsmtLog {
    <#
    .SYNOPSIS
        Writes one timestamped line to the console and to today's log file.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string] $Level = 'INFO'
    )

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = '[' + $stamp + '] [' + $Level + '] ' + $Message

    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line -ForegroundColor DarkGray }
    }

    if ($script:DsmtConfig.LogFile) {
        try {
            Add-Content -LiteralPath $script:DsmtConfig.LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch {
            # A failure to write the log must never take the server down.
        }
    }
}

function ConvertTo-DsmtLdapEscape {
    <#
    .SYNOPSIS
        Escapes a user-supplied value for safe use inside an LDAP filter
        (RFC 4515). Without this a search box is an LDAP injection point.
    #>
    param([string] $Value)

    if ([string]::IsNullOrEmpty($Value)) { return '' }

    $out = $Value
    $out = $out.Replace('\', '\5c')
    $out = $out.Replace('(', '\28')
    $out = $out.Replace(')', '\29')
    $out = $out.Replace('*', '\2a')
    $out = $out.Replace([string][char]0, '\00')
    $out = $out.Replace('/', '\2f')
    return $out
}

function ConvertFrom-DsmtDn {
    <#
    .SYNOPSIS
        Turns a distinguishedName into the readable container path the UI
        shows, e.g. "lab.local/HQ/IT". The leaf (the object itself) is
        dropped, so this is the object's container, not the object.
    #>
    param([string] $DistinguishedName)

    if ([string]::IsNullOrWhiteSpace($DistinguishedName)) { return '' }

    # Split on unescaped commas.
    $parts = [System.Text.RegularExpressions.Regex]::Split($DistinguishedName, '(?<!\\),')
    $containers = New-Object System.Collections.Generic.List[string]
    $dcParts    = New-Object System.Collections.Generic.List[string]

    $isFirst = $true
    foreach ($p in $parts) {
        $trimmed = $p.Trim()
        if ($trimmed -match '^(?i)DC=(.+)$') {
            $dcParts.Add($Matches[1])
            continue
        }
        if ($isFirst) {
            # The leaf is the object itself - not part of its container path.
            $isFirst = $false
            continue
        }
        if ($trimmed -match '^(?i)(?:OU|CN)=(.+)$') {
            $containers.Add($Matches[1].Replace('\,', ','))
        }
    }

    $ordered = @()
    for ($i = $containers.Count - 1; $i -ge 0; $i--) {
        $ordered += $containers[$i]
    }

    $domainPart = ($dcParts -join '.')
    if ($ordered.Count -eq 0) { return $domainPart }
    return $domainPart + '/' + ($ordered -join '/')
}

function Get-DsmtParentDn {
    <#
    .SYNOPSIS
        Returns the parent container DN of a distinguishedName.
    #>
    param([string] $DistinguishedName)

    if ([string]::IsNullOrWhiteSpace($DistinguishedName)) { return '' }
    $idx = [System.Text.RegularExpressions.Regex]::Match($DistinguishedName, '(?<!\\),')
    if (-not $idx.Success) { return '' }
    return $DistinguishedName.Substring($idx.Index + 1).Trim()
}

function ConvertTo-DsmtDisplayTime {
    <#
    .SYNOPSIS
        Formats a DateTime the way the UI shows it: "Today HH:mm",
        "Yesterday HH:mm", or "dd MMM HH:mm". Empty string for $null so the
        UI shows a blank cell rather than the word "Never" for "unknown".
    #>
    param($Value)

    if ($null -eq $Value) { return '' }

    $dt = $null
    if ($Value -is [datetime]) {
        $dt = $Value
    } else {
        try { $dt = [datetime]$Value } catch { return '' }
    }
    if ($dt.Year -lt 1990) { return '' }

    $today = (Get-Date).Date
    if ($dt.Date -eq $today) { return 'Today ' + $dt.ToString('HH:mm') }
    if ($dt.Date -eq $today.AddDays(-1)) { return 'Yesterday ' + $dt.ToString('HH:mm') }
    if ($dt.Year -eq $today.Year) { return $dt.ToString('dd MMM HH:mm') }
    return $dt.ToString('dd MMM yyyy')
}

function ConvertTo-DsmtRelativeExpiry {
    <#
    .SYNOPSIS
        Renders a password-expiry DateTime as "in N days" / "Expired" /
        "Never", matching the console's Password expiry column.
    #>
    param($Value, [bool] $NeverExpires = $false)

    if ($NeverExpires) { return 'Never' }
    if ($null -eq $Value) { return '' }

    $dt = $null
    if ($Value -is [datetime]) { $dt = $Value } else { try { $dt = [datetime]$Value } catch { return '' } }
    if ($dt.Year -ge 9999 -or $dt.Year -lt 1990) { return 'Never' }

    $days = [int][math]::Floor(($dt - (Get-Date)).TotalDays)
    if ($days -lt 0)  { return 'Expired' }
    if ($days -eq 0)  { return 'Today' }
    if ($days -eq 1)  { return 'in 1 day' }
    return 'in ' + $days + ' days'
}

function New-DsmtPassword {
    <#
    .SYNOPSIS
        Generates a random password that satisfies a default AD complexity
        policy (upper, lower, digit, symbol). Used when an operator asks the
        console to generate one instead of typing it.
    #>
    param([int] $Length = 16)

    if ($Length -lt 12) { $Length = 12 }

    $upper  = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower  = 'abcdefghijkmnopqrstuvwxyz'
    $digit  = '23456789'
    $symbol = '!@#$%^&*()-_=+'
    $all    = $upper + $lower + $digit + $symbol

    $rng   = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object 'byte[]' 4

    $pick = {
        param([string] $Set)
        $rng.GetBytes($bytes)
        $value = [System.BitConverter]::ToUInt32($bytes, 0)
        return $Set[[int]($value % [uint32]$Set.Length)]
    }

    $chars = New-Object System.Collections.Generic.List[char]
    $chars.Add((& $pick $upper))
    $chars.Add((& $pick $lower))
    $chars.Add((& $pick $digit))
    $chars.Add((& $pick $symbol))
    while ($chars.Count -lt $Length) {
        $chars.Add((& $pick $all))
    }

    # Fisher-Yates shuffle so the guaranteed characters are not always first.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $rng.GetBytes($bytes)
        $j = [int]([System.BitConverter]::ToUInt32($bytes, 0) % [uint32]($i + 1))
        $tmp = $chars[$i]
        $chars[$i] = $chars[$j]
        $chars[$j] = $tmp
    }

    $rng.Dispose()
    return -join $chars
}
