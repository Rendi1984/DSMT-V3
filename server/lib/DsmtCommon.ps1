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
$script:DsmtVersion = '1.17.0'

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

# Filled in by Start-DSMT.ps1 at startup.
$script:DsmtConfig = @{
    Version       = $script:DsmtVersion
    Publisher     = $script:DsmtPublisher
    IdentityMode  = 'operator'
    ServiceAccount = ''
    AccountKind    = ''
    RootPath      = ''
    WebPath       = ''
    DataPath      = ''
    DesignPath    = ''
    UploadsPath   = ''
    Domain        = ''
    Server        = ''
    Port          = 8080
    ListenAddress = 'localhost'
    SessionMinutes = 15
    PageSize      = 500
    LogFile       = ''
    StartedUtc    = $null
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
        [ValidateSet('operator', 'hybrid')][string] $IdentityMode = 'operator'
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
    $script:DsmtConfig.RootPath      = $RootPath
    $script:DsmtConfig.WebPath       = Join-Path $RootPath 'web'
    $script:DsmtConfig.DataPath      = Join-Path $RootPath 'data'
    $script:DsmtConfig.UploadsPath   = Join-Path $RootPath 'uploads'
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

    if (-not (Test-Path -LiteralPath $script:DsmtConfig.DataPath)) {
        New-Item -ItemType Directory -Path $script:DsmtConfig.DataPath -Force | Out-Null
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

function Get-DsmtSavedSettings {
    <#
    .SYNOPSIS
        Reads config\dsmt.config.json - the settings Install-DSMT.ps1 chose -
        so the console can be started with no parameters at all.
    .DESCRIPTION
        Returns $null when the file is absent (a perfectly normal state: the
        installer was never run, or the operator passes everything on the
        command line). A malformed file is reported rather than ignored,
        because silently falling back to defaults is how a machine ends up
        pointing at the wrong domain without anyone noticing.
    #>
    param([Parameter(Mandatory = $true)][string] $RootPath)

    $path = Join-Path (Join-Path $RootPath 'config') 'dsmt.config.json'
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
        Writes config\dsmt.config.json, merging over whatever is already
        there so a value this call does not mention is preserved.
    .OUTPUTS
        Hashtable with Ok and Error.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $RootPath,
        [Parameter(Mandatory = $true)][hashtable] $Values
    )

    $dir  = Join-Path $RootPath 'config'
    $path = Join-Path $dir 'dsmt.config.json'

    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $merged = [ordered]@{}

        $existing = Get-DsmtSavedSettings -RootPath $RootPath
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
