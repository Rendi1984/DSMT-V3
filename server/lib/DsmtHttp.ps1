<#
.SYNOPSIS
    DSMT - HTTP layer: static files, the JSON API and request routing.
.DESCRIPTION
    Serves the web/ front end and the /api/* endpoints it calls. Every API
    handler that writes to the directory:
      * requires a valid session token,
      * requires a non-empty reason string (rejected with 400 otherwise),
      * runs the change as the signed-in operator,
      * writes an audit record whether it succeeded or failed.
.NOTES
    Author  : IT Team
#>

$script:DsmtMimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.gif'  = 'image/gif'
    '.svg'  = 'image/svg+xml'
    '.webp' = 'image/webp'
    '.ico'  = 'image/x-icon'
    '.woff' = 'font/woff'
    '.woff2'= 'font/woff2'
    '.txt'  = 'text/plain; charset=utf-8'
    '.md'   = 'text/plain; charset=utf-8'
}

function Send-DsmtBytes {
    param($Response, [byte[]] $Bytes, [string] $ContentType, [int] $StatusCode = 200)

    try {
        $Response.StatusCode  = $StatusCode
        $Response.ContentType = $ContentType
        $Response.Headers.Add('Cache-Control', 'no-store')
        $Response.Headers.Add('X-Content-Type-Options', 'nosniff')
        $Response.ContentLength64 = $Bytes.Length
        $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    } catch {
        Write-DsmtLog -Level 'WARN' -Message ('Could not write response: ' + $_.Exception.Message)
    } finally {
        try { $Response.OutputStream.Close() } catch { }
    }
}

function Send-DsmtJson {
    param($Response, $Data, [int] $StatusCode = 200)

    $json  = ConvertTo-Json -InputObject $Data -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Send-DsmtBytes -Response $Response -Bytes $bytes -ContentType 'application/json; charset=utf-8' -StatusCode $StatusCode
}

function Send-DsmtError {
    param($Response, [string] $Message, [int] $StatusCode = 400)

    Send-DsmtJson -Response $Response -StatusCode $StatusCode -Data @{ ok = $false; error = $Message }
}

function Read-DsmtBody {
    <#
    .SYNOPSIS
        Reads the request body and parses it as JSON. Returns $null when the
        body is empty or not valid JSON.
    #>
    param($Request)

    if (-not $Request.HasEntityBody) { return $null }

    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    $text   = $reader.ReadToEnd()
    $reader.Close()

    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try {
        return ConvertFrom-Json -InputObject $text -ErrorAction Stop
    } catch {
        return $null
    }
}

function Get-DsmtBodyValue {
    <#
    .SYNOPSIS
        Reads a property from a parsed JSON body without throwing when the
        body or the property is missing.
    #>
    param($Body, [string] $Name, $Default = '')

    if ($null -eq $Body) { return $Default }
    $prop = $Body.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    if ($null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function ConvertTo-DsmtUtcOrNull {
    <#
    .SYNOPSIS
        Parses an ISO 8601 timestamp from the query string into UTC.
    .DESCRIPTION
        Returns $null for an empty value. THROWS on a value that is present
        but unparseable, so a malformed range is reported as a 400 instead of
        being silently ignored - a filter that quietly does nothing is how an
        operator ends up believing a window is empty when it is not.
    #>
    param([string] $Value, [string] $FieldName)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    # RoundtripKind CANNOT be combined with AssumeLocal, AssumeUniversal or
    # AdjustToUniversal - .NET throws ArgumentException on the call itself,
    # not on the value. So every time-bounded audit query failed with a
    # message about "styles" that named nothing an operator could act on,
    # while "All time" - which sends no bounds and never reaches here - worked
    # perfectly. That is why it looked like the filter chips were broken
    # rather than the parser.
    #
    # RoundtripKind alone is the right choice: the browser sends
    # toISOString(), which always carries a Z, and RoundtripKind honours the
    # offset that is there. A value with no offset is then treated as
    # unspecified and read as local, which is the sane reading of a
    # hand-typed datetime-local field.
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
    $ok = [datetime]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref] $parsed)

    if (-not $ok) {
        throw ('"' + $FieldName + '" is not a valid date/time: ' + $Value)
    }

    # An unspecified kind would make ToUniversalTime() a no-op on some hosts
    # and a local conversion on others. State the assumption instead.
    if ($parsed.Kind -eq [System.DateTimeKind]::Unspecified) {
        $parsed = [datetime]::SpecifyKind($parsed, [System.DateTimeKind]::Local)
    }
    return $parsed.ToUniversalTime()
}

function Get-DsmtQueryValue {
    param($Request, [string] $Name, [string] $Default = '')

    $value = $Request.QueryString[$Name]
    if ([string]::IsNullOrEmpty($value)) { return $Default }
    return $value
}

function Send-DsmtStaticFile {
    <#
    .SYNOPSIS
        Serves a file from disk, refusing any path that escapes the roots the
        server is allowed to publish.
    #>
    param($Response, [string] $UrlPath)

    $cfg = Get-DsmtConfig

    $relative = $UrlPath.TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($relative)) { $relative = 'index.html' }
    $relative = [System.Uri]::UnescapeDataString($relative)

    # Roots the server may publish, in the order they are tried.
    $roots = @($cfg.WebPath, $cfg.RootPath)

    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }

        $candidate = Join-Path $root $relative
        $full = $null
        try {
            $full = [System.IO.Path]::GetFullPath($candidate)
        } catch {
            continue
        }

        $rootFull = [System.IO.Path]::GetFullPath($root)
        if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }

        # Only publish the design system, uploads and the web app itself out
        # of the repository root - never server code, data or logs.
        if ($rootFull -eq [System.IO.Path]::GetFullPath($cfg.RootPath)) {
            $allowed = $false
            foreach ($prefix in @('_ds', 'uploads')) {
                if ($relative.Replace('\', '/').StartsWith($prefix + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $allowed = $true
                }
            }
            if (-not $allowed) { continue }
        }

        $ext = [System.IO.Path]::GetExtension($full).ToLower()
        $type = 'application/octet-stream'
        if ($script:DsmtMimeTypes.ContainsKey($ext)) { $type = $script:DsmtMimeTypes[$ext] }

        $bytes = [System.IO.File]::ReadAllBytes($full)
        Send-DsmtBytes -Response $Response -Bytes $bytes -ContentType $type
        return $true
    }

    return $false
}

function Get-DsmtRequestSession {
    <#
    .SYNOPSIS
        Resolves the session from the Authorization header. Returns $null when
        there is no valid session.
    #>
    param($Request)

    $header = $Request.Headers['Authorization']
    if ([string]::IsNullOrWhiteSpace($header)) { return $null }
    if ($header -notmatch '^(?i)Bearer\s+(?<token>\S+)$') { return $null }
    return Get-DsmtSession -Token $Matches['token']
}

function Get-DsmtTargetList {
    <#
    .SYNOPSIS
        Normalises the "targets" field of a write request into a string array,
        so single-target and bulk actions share one code path.
    #>
    param($Body)

    $targets = Get-DsmtBodyValue -Body $Body -Name 'targets' -Default $null
    if ($null -eq $targets) {
        $single = Get-DsmtBodyValue -Body $Body -Name 'target' -Default ''
        if ([string]::IsNullOrWhiteSpace($single)) { return @() }
        return @([string]$single)
    }

    $list = @()
    foreach ($t in @($targets)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$t)) { $list += [string]$t }
    }
    return $list
}

function New-DsmtCheck {
    <#
    .SYNOPSIS
        One health check result. Status is ok | warn | bad.
    .DESCRIPTION
        Every check carries a Fix string when it is not ok. A health page that
        reports a red light without saying what to do about it has moved the
        problem, not helped with it - see the Shape 2 entries in CLAUDE.md,
        every one of which is a failure whose fix is a known external step.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][ValidateSet('ok', 'warn', 'bad')][string] $Status,
        [Parameter(Mandatory = $true)][string] $Detail,
        [string] $Fix = ''
    )

    return [ordered]@{ name = $Name; status = $Status; detail = $Detail; fix = $Fix }
}

function Get-DsmtHealth {
    <#
    .SYNOPSIS
        Answers, in one request: is AD reachable, is SQL reachable, is RSAT
        present, how long has this process been up, and who is signed in.
    .DESCRIPTION
        Each check is wrapped in its own try/catch so one failure reports
        itself rather than taking the page down - a health page that cannot
        render when something is wrong is exactly the wrong shape.

        Reads only. Nothing here changes state, so it is safe to press
        repeatedly while diagnosing.
    #>
    param([Parameter(Mandatory = $true)] $Session)

    $cfg    = Get-DsmtConfig
    $checks = @()

    # --- the RSAT module -----------------------------------------------
    try {
        Assert-DsmtAdModule
        $checks += New-DsmtCheck -Name 'ActiveDirectory module' -Status 'ok' `
                                 -Detail 'The RSAT ActiveDirectory module is loaded.'
    } catch {
        $checks += New-DsmtCheck -Name 'ActiveDirectory module' -Status 'bad' `
                                 -Detail $_.Exception.Message `
                                 -Fix 'Install-WindowsFeature RSAT-AD-PowerShell   (or Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools on a client OS), then restart Start-DSMT.ps1.'
    }

    # --- the domain ------------------------------------------------------
    $controller = ''
    try {
        $info = Get-DsmtDomainInfo -Credential $Session.Credential
        $controller = [string]$info.connectedTo
        $checks += New-DsmtCheck -Name 'Domain' -Status 'ok' `
                                 -Detail ($info.domain + ' - answering on ' + $controller + ', ' +
                                          [string]$info.controllerCount + ' controller(s) in the domain.')
    } catch {
        $checks += New-DsmtCheck -Name 'Domain' -Status 'bad' `
                                 -Detail $_.Exception.Message `
                                 -Fix 'Check that this host can reach a domain controller for the configured domain (DNS first, then port 389/636). The domain is set in HKLM\SOFTWARE\Rendi Group\DSMT\Settings.'
    }

    # --- a real directory read -------------------------------------------
    # Reaching the domain and being ALLOWED to read it are different things,
    # and the second is what the console actually needs.
    try {
        $probe = @(Get-DsmtUsers -Credential $Session.Credential -Query '' -Limit 1)
        $checks += New-DsmtCheck -Name 'Directory read' -Status 'ok' `
                                 -Detail ('A search as ' + $Session.Account + ' returned ' + [string]$probe.Count + ' object(s).')
    } catch {
        $checks += New-DsmtCheck -Name 'Directory read' -Status 'bad' `
                                 -Detail $_.Exception.Message `
                                 -Fix 'The domain answered but the search failed. If this says access is denied, it is the signed-in operator''s AD rights - DSMT has no permission model of its own.'
    }

    # --- SQL --------------------------------------------------------------
    $sql = Get-DsmtSqlState
    if (-not $sql.Enabled) {
        $checks += New-DsmtCheck -Name 'SQL Server' -Status 'warn' `
                                 -Detail 'No database is configured. The audit log is written to files only, and operators, sessions and the directory snapshot are not stored.' `
                                 -Fix 'Settings -> Database: enter the instance, then Connect.'
    } else {
        try {
            $n = [int](Invoke-DsmtSqlCommand -Sql 'SELECT COUNT(*) FROM dbo.AuditLog' -Mode 'Scalar')
            $checks += New-DsmtCheck -Name 'SQL Server' -Status 'ok' `
                                     -Detail ($sql.Server + ' [' + $sql.Database + '] - ' + [string]$n + ' audit record(s).')
        } catch {
            $checks += New-DsmtCheck -Name 'SQL Server' -Status 'bad' `
                                     -Detail $_.Exception.Message `
                                     -Fix 'The connection was configured but is not answering now. Settings -> Database -> Reconnect shows the verbatim SQL error.'
        }
    }

    # --- the data folder --------------------------------------------------
    # The JSONL audit fallback lives here. If this is not writable, an audit
    # record can be lost silently, which is the one failure this tool must not
    # have.
    try {
        $probeFile = Join-Path $cfg.DataPath ('.health-' + [guid]::NewGuid().ToString('N') + '.tmp')
        Set-Content -LiteralPath $probeFile -Value 'ok' -Encoding UTF8 -ErrorAction Stop
        Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
        $checks += New-DsmtCheck -Name 'Data folder' -Status 'ok' `
                                 -Detail ($cfg.DataPath + ' is writable.')
    } catch {
        $checks += New-DsmtCheck -Name 'Data folder' -Status 'bad' `
                                 -Detail $_.Exception.Message `
                                 -Fix 'The account DSMT runs as needs Modify on the data folder. Install-DSMT.ps1 -ChangeServiceAccount sets this, or grant it by hand.'
    }

    # --- the last write DSMT actually performed ---------------------------
    $lastWrite = ''
    try {
        $recent = Get-DsmtAuditEntries -Query '' -Filter 'All' -Limit 200
        foreach ($entry in @($recent.entries)) {
            if ($entry.result -eq 'Success' -and $entry.category -ne 'session') {
                $lastWrite = [string]$entry.time + ' - ' + [string]$entry.action + ' on ' + [string]$entry.target
                break
            }
        }
    } catch { }

    if ([string]::IsNullOrWhiteSpace($lastWrite)) {
        $checks += New-DsmtCheck -Name 'Last successful write' -Status 'warn' `
                                 -Detail 'No successful directory write in the recent audit entries. That is normal on a fresh install, and a red flag on one that is in use.'
    } else {
        $checks += New-DsmtCheck -Name 'Last successful write' -Status 'ok' -Detail $lastWrite
    }

    # --- uptime -----------------------------------------------------------
    $uptime = 'unknown'
    if ($null -ne $cfg.StartedUtc) {
        $span = (Get-Date).ToUniversalTime() - [datetime]$cfg.StartedUtc
        $uptime = [string][int]$span.TotalDays + 'd ' + [string]$span.Hours + 'h ' + [string]$span.Minutes + 'm'
    }
    $checks += New-DsmtCheck -Name 'Uptime' -Status 'ok' `
                             -Detail ('This process has been running for ' + $uptime + '. Restarting ends every session by design.')

    # --- sessions ---------------------------------------------------------
    $summary = Get-DsmtSessionSummary
    $checks += New-DsmtCheck -Name 'Open sessions' -Status 'ok' `
                             -Detail ([string]$summary.Count + ' operator session(s) open; they expire after ' +
                                      [string]$cfg.SessionMinutes + ' minutes of inactivity.')

    # --- overall ----------------------------------------------------------
    # The worst individual result wins. A page that averages its checks into a
    # comfortable green is worse than no page.
    $overall = 'ok'
    foreach ($check in $checks) {
        if ($check.status -eq 'bad') { $overall = 'bad' }
        elseif ($check.status -eq 'warn' -and $overall -eq 'ok') { $overall = 'warn' }
    }

    return @{
        ok         = $true
        overall    = $overall
        checkedAt  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        controller = $controller
        sessions   = @($summary.Sessions)
        checks     = @($checks)
    }
}

function Get-DsmtUndoPlan {
    <#
    .SYNOPSIS
        Works out how to reverse one audit record, or says why it cannot be.
    .DESCRIPTION
        An action is undoable only when reversing it restores the directory to
        what it was, using nothing but the record itself. That is a much
        smaller set than "actions that have an opposite":

          Disable user        -> Enable user
          Enable user         -> Disable user
          Add to group        -> Remove from group      (detail: "into X")
          Remove from group   -> Add to group           (detail: "from X")
          Move OU             -> Move back              (detail: "from A into B")

        Everything else is refused ON PURPOSE, and the reason is returned so
        the console can say it out loud:

          Reset password / Unlock account - the previous password is not known
            to DSMT and never was. There is nothing to restore.
          Create user / Create group      - "undo" would be a delete, and a
            delete is not the inverse of a create.
          Delete user / Delete group      - recreating the object gives it a
            NEW SID. Every ACL, group membership and profile that referenced
            the old one still does not. An "undo" that produces a
            same-named stranger is a lie, and a dangerous one.
          Bulk CSV import                 - many objects, one record each,
            created not modified; see above.
          Sign in / settings changes      - not directory state.

        Note what this function does NOT do: it does not check that the
        directory still looks the way the record left it. If someone else has
        since changed the same object, the undo simply applies on top, exactly
        as the equivalent button would. The audit log remains the record of
        both events - the undo never rewrites or removes the original entry.
    .OUTPUTS
        Hashtable: Ok, Reason (when not Ok), Action, Category, Label, Group, Ou.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Action,
        [string] $Detail = ''
    )

    $no = {
        param($why)
        return @{ Ok = $false; Reason = $why; Action = ''; Category = 'user'; Label = ''; Group = ''; Ou = '' }
    }

    switch -Regex ($Action) {

        '^Disable user$' {
            return @{ Ok = $true; Action = 'enable'; Category = 'user'
                      Label = 'Undo: Disable user'; Group = ''; Ou = '' }
        }

        '^Enable user$' {
            return @{ Ok = $true; Action = 'disable'; Category = 'user'
                      Label = 'Undo: Enable user'; Group = ''; Ou = '' }
        }

        '^Add to group$' {
            if ($Detail -notmatch '^into\s+(?<g>.+)$') {
                return (& $no 'The record does not name the group that was joined.')
            }
            return @{ Ok = $true; Action = 'group-remove'; Category = 'group'
                      Label = 'Undo: Add to group'; Group = $Matches['g'].Trim(); Ou = '' }
        }

        '^Remove from group$' {
            if ($Detail -notmatch '^from\s+(?<g>.+)$') {
                return (& $no 'The record does not name the group that was left.')
            }
            return @{ Ok = $true; Action = 'group-add'; Category = 'group'
                      Label = 'Undo: Remove from group'; Group = $Matches['g'].Trim(); Ou = '' }
        }

        '^Move OU$' {
            # Records written before 1.11.0 only say "into X" - the source was
            # never captured, so there is nothing to move back to. Say that
            # plainly rather than guessing at a container.
            if ($Detail -notmatch '^from\s+(?<a>.+?)\s+into\s+(?<b>.+)$') {
                return (& $no 'The record does not say which OU the object came from, so there is nowhere to move it back to. Moves recorded from 1.11.0 onwards can be undone.')
            }
            return @{ Ok = $true; Action = 'move-ou'; Category = 'user'
                      Label = 'Undo: Move OU'; Group = ''; Ou = $Matches['a'].Trim() }
        }

        '^Reset password$' {
            return (& $no 'A password cannot be undone - DSMT never knew the previous one. Reset it again if it was set in error.')
        }

        '^Unlock account$' {
            return (& $no 'An unlock cannot be undone. A lockout is produced by failed sign-ins, not by an administrator, so there is no previous state to put back.')
        }

        '^(Create|Delete) (user|group)$' {
            return (& $no 'Creating and deleting are not reversible here. A recreated object gets a NEW SID, so every permission and membership that pointed at the old one would still be broken - restore it from the AD Recycle Bin instead.')
        }

        '^Bulk CSV import$' {
            return (& $no 'An import creates objects; see the note on creating and deleting.')
        }
    }

    return (& $no ('There is no defined way to reverse "' + $Action + '".'))
}

function Invoke-DsmtBulkAction {
    <#
    .SYNOPSIS
        Runs one write action across a list of targets, auditing each target
        individually and returning a per-target result the UI can display.
        This is the single place bulk semantics live: one failure does not
        abort the rest, and the overall result is Success / Partial / Failed.
    #>
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)][string[]] $Targets,
        [Parameter(Mandatory = $true)][string] $Action,
        [Parameter(Mandatory = $true)][string] $Reason,
        [Parameter(Mandatory = $true)][ValidateSet('user', 'group')][string] $Category,
        [Parameter(Mandatory = $true)][scriptblock] $Operation,
        [string] $DetailSuffix = '',
        # Evaluated per target BEFORE the operation runs, when the detail
        # depends on the state the operation is about to change - a move has
        # to record where the object came FROM, and after the move that is
        # gone. Never allowed to break the action: a throw here falls back to
        # $DetailSuffix.
        [scriptblock] $DetailBuilder = $null
    )

    $controller = ''
    try { $controller = Get-DsmtServer -Credential $Session.Credential } catch { }

    $results = @()
    $okCount = 0

    foreach ($target in $Targets) {
        $detail = $DetailSuffix
        if ($null -ne $DetailBuilder) {
            try {
                $built = [string](& $DetailBuilder $target)
                if (-not [string]::IsNullOrWhiteSpace($built)) { $detail = $built }
            } catch {
                Write-DsmtLog -Level 'WARN' -Message ('Could not build the audit detail for ' + $target + ': ' + $_.Exception.Message)
            }
        }

        try {
            # Out-Null matters: anything the operation emits would otherwise
            # join this function's output stream and turn the returned result
            # object into an array.
            & $Operation $target | Out-Null
            $okCount++
            $results += [ordered]@{ target = $target; ok = $true; error = '' }
            Write-DsmtAudit -Action $Action -Target $target -Operator $Session.Account -Reason $Reason `
                            -Result 'Success' -Category $Category -Controller $controller -Detail $detail
        } catch {
            $message = $_.Exception.Message
            $results += [ordered]@{ target = $target; ok = $false; error = $message }

            # An access-denied from AD is a Denied record, not a Failed one -
            # the difference matters when reviewing the log.
            $outcome = 'Failed'
            if ($message -match '(?i)access is denied|insufficient (access )?rights|unauthorized') { $outcome = 'Denied' }

            Write-DsmtAudit -Action $Action -Target $target -Operator $Session.Account -Reason $Reason `
                            -Result $outcome -Category $Category -Controller $controller -Detail $message
            Write-DsmtLog -Level 'WARN' -Message ($Action + ' failed for ' + $target + ': ' + $message)
        }
    }

    $overall = 'Success'
    if ($okCount -eq 0) { $overall = 'Failed' }
    elseif ($okCount -lt $Targets.Count) { $overall = 'Partial' }

    return @{
        ok        = ($okCount -gt 0)
        result    = $overall
        succeeded = $okCount
        failed    = ($Targets.Count - $okCount)
        results   = @($results)
    }
}

function Invoke-DsmtApi {
    <#
    .SYNOPSIS
        Routes one API request. Returns nothing; always writes a response.
    #>
    param($Request, $Response, [string] $Path)

    $method = $Request.HttpMethod.ToUpper()
    $cfg    = Get-DsmtConfig

    # ---- Unauthenticated endpoints -------------------------------------
    if ($Path -eq '/api/meta') {
        $sql = Get-DsmtSqlState
        Send-DsmtJson -Response $Response -Data @{
            ok        = $true
            version   = $cfg.Version
            publisher = $cfg.Publisher
            domain    = $cfg.Domain
            product   = 'DSMT - Directory Service Management Tool'
            identity  = @{
                mode        = $cfg.IdentityMode
                serviceUser = ($env:USERDOMAIN + '\' + $env:USERNAME)
                accountKind = $cfg.AccountKind
            }
            # The browser needs this to run its own idle countdown, so the
            # operator is warned before the server drops them rather than
            # discovering it on their next click. The bounds travel with it so
            # the Settings form validates against the same numbers the server
            # enforces.
            sessionMinutes = $cfg.SessionMinutes
            sessionBounds  = Get-DsmtSessionBounds
            storage = @{
                sqlEnabled  = $sql.Enabled
                sqlServer   = $sql.Server
                sqlDatabase = $sql.Database
                sqlError    = $sql.LastError
            }
        }
        return
    }

    if ($Path -eq '/api/session' -and $method -eq 'POST') {
        $body = Read-DsmtBody -Request $Request
        $user = [string](Get-DsmtBodyValue -Body $body -Name 'username')
        $pass = [string](Get-DsmtBodyValue -Body $body -Name 'password')

        if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($pass)) {
            Send-DsmtError -Response $Response -Message 'Enter a user name and password.' -StatusCode 400
            return
        }

        $created = New-DsmtSession -Username $user -Password $pass
        if (-not $created.Ok) {
            Write-DsmtAudit -Action 'Sign in' -Target $user -Operator $user -Reason 'Console sign-in' `
                            -Result 'Denied' -Category 'session' -Detail $created.Error
            Send-DsmtError -Response $Response -Message $created.Error -StatusCode 401
            return
        }

        $session = Get-DsmtSession -Token $created.Token
        Write-DsmtAudit -Action 'Sign in' -Target $session.Account -Operator $session.Account `
                        -Reason 'Console sign-in' -Result 'Success' -Category 'session'

        Send-DsmtJson -Response $Response -Data @{
            ok        = $true
            token     = $created.Token
            version   = $cfg.Version
            publisher = $cfg.Publisher
            user      = @{ sam = $session.Sam; display = $session.Display; account = $session.Account; upn = $session.Upn }
        }
        return
    }

    # ---- Everything below needs a session -------------------------------
    $session = Get-DsmtRequestSession -Request $Request
    if ($null -eq $session) {
        Send-DsmtError -Response $Response -Message 'Your session has expired. Sign in again.' -StatusCode 401
        return
    }

    # ---- DSMT's own settings need the administrator role ------------------
    # Checked HERE, once, against a central list - not sprinkled through the
    # handlers. A role enforced route by route is a role that is missing from
    # the route somebody adds next week. Hiding a button in app.js is a
    # convenience, never the enforcement: the API is reachable directly.
    #
    # This gates DSMT's OWN configuration only. Directory routes are
    # deliberately untouched: there, AD is the authority and a DSMT role could
    # only ever subtract. See DsmtRoles.ps1.
    if (Test-DsmtRouteNeedsAdmin -Path $Path -Method $method) {
        if (-not $session.IsAdmin) {
            Write-DsmtAudit -Action 'Denied - not a DSMT administrator' -Target ($method + ' ' + $Path) `
                            -Operator $session.Account -Reason 'Role check' `
                            -Result 'Denied' -Category 'session'
            Send-DsmtError -Response $Response -StatusCode 403 -Message (
                'Changing DSMT settings needs the DSMT administrator role. ' + $session.RoleReason)
            return
        }
    }

    if ($Path -eq '/api/session' -and $method -eq 'DELETE') {
        Write-DsmtAudit -Action 'Sign out' -Target $session.Account -Operator $session.Account `
                        -Reason 'Console sign-out' -Result 'Success' -Category 'session'
        Remove-DsmtSession -Token $session.Token
        Send-DsmtJson -Response $Response -Data @{ ok = $true }
        return
    }

    if ($Path -eq '/api/session' -and $method -eq 'GET') {
        Send-DsmtJson -Response $Response -Data @{
            ok             = $true
            version        = $cfg.Version
            publisher      = $cfg.Publisher
            sessionMinutes = $cfg.SessionMinutes
            user           = @{ sam = $session.Sam; display = $session.Display; account = $session.Account; upn = $session.Upn }
            isAdmin        = $session.IsAdmin
            roleReason     = $session.RoleReason
            roleConfigured = $session.RoleConfigured
        }
        return
    }

    try {
        switch -Regex ($Path) {

            '^/api/settings$' {
                if ($method -ne 'GET') { break }

                $sql = Get-DsmtSqlState
                Send-DsmtJson -Response $Response -Data @{
                    ok = $true
                    settings = @{
                        version       = $cfg.Version
                        publisher     = $cfg.Publisher
                        identityMode   = $cfg.IdentityMode
                        serviceUser    = ($env:USERDOMAIN + '\' + $env:USERNAME)
                        serviceAccount = $cfg.ServiceAccount
                        accountKind    = $cfg.AccountKind
                        domain        = $cfg.Domain
                        server        = $cfg.Server
                        port          = $cfg.Port
                        listenAddress = $cfg.ListenAddress
                        scheme        = $cfg.Scheme
                        https         = Get-DsmtHttpsState
                        isAdmin       = $session.IsAdmin
                        roleReason    = $session.RoleReason
                        roles         = Get-DsmtRoleState -Credential $session.Credential
                        sessionMinutes = $cfg.SessionMinutes
                        sessionBounds  = Get-DsmtSessionBounds
                        pageSize      = $cfg.PageSize
                        pageSizeBounds = Get-DsmtPageSizeBounds
                        dataPath      = $cfg.DataPath
                        dataRoot      = $cfg.DataRoot
                        settingsKey   = (Get-DsmtSettingsKeyPath)
                        installPath   = $cfg.RootPath
                        pathMode      = $cfg.PathMode
                        registryKey   = 'HKLM\SOFTWARE\Rendi Group\DSMT'
                        alerts        = Get-DsmtAlertSettings
                        alertBounds   = Get-DsmtAlertBounds
                        sqlEnabled    = $sql.Enabled
                        sqlServer     = $sql.Server
                        sqlDatabase   = $sql.Database
                        sqlError      = $sql.LastError
                    }
                }
                return
            }

            '^/api/settings/session$' {
                if ($method -ne 'POST') { break }

                $body = Read-DsmtBody -Request $Request
                $raw  = Get-DsmtBodyValue -Body $body -Name 'sessionMinutes' -Default 0

                $minutes = 0
                if (-not [int]::TryParse([string]$raw, [ref] $minutes)) {
                    Send-DsmtError -Response $Response -Message 'The idle timeout must be a whole number of minutes.' -StatusCode 400
                    return
                }

                # Bounds come from DsmtCommon so the API cannot drift from what
                # the parameter and the config file allow.
                $bounds = Get-DsmtSessionBounds
                if ($minutes -lt $bounds.Min -or $minutes -gt $bounds.Max) {
                    Send-DsmtError -Response $Response -StatusCode 400 `
                        -Message ('The idle timeout must be between ' + $bounds.Min + ' and ' + $bounds.Max +
                                  ' minutes (' + [int]($bounds.Max / 60) + ' hours).')
                    return
                }

                $previous = $cfg.SessionMinutes
                $script:DsmtConfig.SessionMinutes = $minutes

                $saved = Save-DsmtSavedSettings -Values @{ SessionMinutes = $minutes }

                # [string] on the left: $previous is an int, and "int + string"
                # makes PowerShell try to parse the string AS an int, which
                # threw "Cannot convert value ' -> ' to type System.Int32".
                Write-DsmtAudit -Action 'Change idle timeout' -Target ([string]$previous + ' -> ' + [string]$minutes + ' minutes') `
                                -Operator $session.Account -Reason 'Console configuration change' `
                                -Result 'Success' -Category 'session'

                Write-DsmtLog -Message ($session.Account + ' changed the idle timeout from ' + $previous + ' to ' + $minutes + ' minutes')

                # Applies to every session immediately, including ones already
                # open: the check is made against this value on each request.
                Send-DsmtJson -Response $Response -Data @{
                    ok             = $true
                    sessionMinutes = $minutes
                    persisted       = $saved.Ok
                    persistError    = $saved.Error
                    databaseCreated = $init.DatabaseCreated
                    tablesCreated   = $init.TablesCreated
                    tablesFound     = $init.TablesFound
                }
                return
            }

            '^/api/settings/groupfilters$' {
                if ($method -ne 'POST') { break }

                $body    = Read-DsmtBody -Request $Request
                $incoming = Get-DsmtBodyValue -Body $body -Name 'filters' -Default @()

                $clean = @()
                foreach ($f in @($incoming)) {
                    if ($null -eq $f) { continue }
                    $label = ([string]$f.label).Trim()
                    if ([string]::IsNullOrWhiteSpace($label)) { continue }

                    $terms = @()
                    foreach ($t in @($f.terms)) {
                        $text = ([string]$t).Trim()
                        if (-not [string]::IsNullOrWhiteSpace($text)) { $terms += $text }
                    }
                    if ($terms.Count -eq 0) { continue }

                    $clean += [ordered]@{ label = $label; terms = @($terms) }
                }

                $saved = Save-DsmtSavedSettings -Values @{ GroupFilters = @($clean) }
                if (-not $saved.Ok) {
                    Send-DsmtError -Response $Response -Message ('Could not save the filters: ' + $saved.Error) -StatusCode 500
                    return
                }

                Write-DsmtAudit -Action 'Change group filters' -Target ([string]$clean.Count + ' custom filter(s)') `
                                -Operator $session.Account -Reason 'Settings change' -Result 'Success' `
                                -Category 'session' -Detail 'Group filter presets updated'

                Write-DsmtLog -Message ($session.Account + ' updated the group filters (' + [string]$clean.Count + ' custom)')
                Send-DsmtJson -Response $Response -Data @{ ok = $true; filters = @(Get-DsmtGroupFilters) }
                return
            }

            '^/api/settings/network$' {
                if ($method -ne 'POST') { break }

                $body = Read-DsmtBody -Request $Request
                $raw  = Get-DsmtBodyValue -Body $body -Name 'port' -Default 0

                $port = 0
                if (-not [int]::TryParse([string]$raw, [ref] $port)) {
                    Send-DsmtError -Response $Response -Message 'The port must be a whole number.' -StatusCode 400
                    return
                }
                if ($port -lt 1 -or $port -gt 65535) {
                    Send-DsmtError -Response $Response -Message 'The port must be between 1 and 65535.' -StatusCode 400
                    return
                }

                $previous = $cfg.Port
                $saved = Save-DsmtSavedSettings -Values @{ Port = $port }

                Write-DsmtAudit -Action 'Change listening port' -Target ([string]$previous + ' -> ' + [string]$port) `
                                -Operator $session.Account -Reason 'Console configuration change' `
                                -Result 'Success' -Category 'session'

                Write-DsmtLog -Message ($session.Account + ' set the listening port to ' + $port + ' (takes effect on restart)')

                # An HttpListener cannot move to another port without being
                # torn down, so this is saved and applied on the next start -
                # said plainly rather than pretending it took effect.
                $reservation = ''
                if ($cfg.ListenAddress -eq 'any') {
                    $reservation = 'netsh http add urlacl url=http://+:' + $port + '/ user="' +
                                   $env:USERDOMAIN + '\' + $env:USERNAME + '"'
                }

                Send-DsmtJson -Response $Response -Data @{
                    ok            = $true
                    port          = $port
                    previousPort  = $previous
                    needsRestart  = $true
                    persisted     = $saved.Ok
                    persistError  = $saved.Error
                    reservation   = $reservation
                    firewall      = ('New-NetFirewallRule -DisplayName "DSMT console (TCP ' + $port +
                                     ')" -Direction Inbound -Protocol TCP -LocalPort ' + $port +
                                     ' -Action Allow -Profile Domain')
                }
                return
            }

            '^/api/settings/roles$' {
                if ($method -eq 'GET') {
                    Send-DsmtJson -Response $Response -Data @{
                        ok    = $true
                        roles = (Get-DsmtRoleState -Credential $session.Credential)
                    }
                    return
                }
                if ($method -ne 'POST') { break }

                $body  = Read-DsmtBody -Request $Request
                $names = @(Get-DsmtBodyValue -Body $body -Name 'groups' -Default @())

                # Every name is resolved to a SID BEFORE anything is saved, so
                # a typo in the third group cannot leave the first two written
                # and the mapping half-applied.
                $resolved = @()
                foreach ($n in $names) {
                    $text = ([string]$n).Trim()
                    if ([string]::IsNullOrWhiteSpace($text)) { continue }

                    $r = Resolve-DsmtGroupSid -Identity $text -Credential $session.Credential
                    if (-not $r.Ok) {
                        Send-DsmtError -Response $Response -Message $r.Error -StatusCode 400
                        return
                    }
                    $resolved += @{ Sid = $r.Sid; Name = $r.Name }
                }

                # Refusing to save a mapping that locks the author out. Every
                # other guard here is recoverable from the console; this one
                # would not be - it would need regedit on the DSMT host.
                if ($resolved.Count -gt 0) {
                    $check = Get-DsmtOperatorGroupSids -SamAccountName $session.Sam -Credential $session.Credential
                    if (-not $check.Ok) {
                        Send-DsmtError -Response $Response -StatusCode 400 -Message (
                            'Your own group membership could not be read, so DSMT cannot confirm this ' +
                            'mapping would not lock you out. Nothing was saved. ' + $check.Error)
                        return
                    }

                    $selfIn = $false
                    foreach ($g in $resolved) {
                        foreach ($s in @($check.Sids)) {
                            if ($s -eq $g.Sid) { $selfIn = $true }
                        }
                    }
                    if (-not $selfIn) {
                        Send-DsmtError -Response $Response -StatusCode 400 -Message (
                            'You are not a member of any of those groups, so saving this would lock you ' +
                            'out of DSMT settings immediately and the only way back would be regedit on ' +
                            'the DSMT host. Add a group you belong to. Nothing was saved.')
                        return
                    }
                }

                $saved = Save-DsmtSavedSettings -Values @{ RoleAdminGroups = $resolved }

                $summary = 'none (every operator administers)'
                if ($resolved.Count -gt 0) {
                    $summary = (@($resolved | ForEach-Object { $_.Name }) -join ', ')
                }

                Write-DsmtAudit -Action 'Change DSMT administrator groups' -Target $summary `
                                -Operator $session.Account -Reason 'Console configuration change' `
                                -Result 'Success' -Category 'session'
                Write-DsmtLog -Message ($session.Account + ' set the DSMT administrator groups to: ' + $summary)

                Send-DsmtJson -Response $Response -Data @{
                    ok           = $true
                    count        = $resolved.Count
                    groups       = @($resolved)
                    persisted    = $saved.Ok
                    persistError = $saved.Error
                    needsSignIn  = $true
                }
                return
            }

            '^/api/settings/https/certificates$' {
                if ($method -ne 'GET') { break }

                # Wrapped at the call site as well as in the callee - a
                # one-certificate store must not serialise as a bare object.
                $certs = @(Get-DsmtCertificates)

                Send-DsmtJson -Response $Response -Data @{
                    ok           = $true
                    certificates = $certs
                    store        = 'Cert:\LocalMachine\My'
                    importCommand = (Get-DsmtPfxImportCommand)
                }
                return
            }

            '^/api/settings/https$' {
                if ($method -eq 'GET') {
                    Send-DsmtJson -Response $Response -Data @{
                        ok    = $true
                        https = (Get-DsmtHttpsState)
                    }
                    return
                }
                if ($method -ne 'POST') { break }

                $body    = Read-DsmtBody -Request $Request
                $enabled = [bool](Get-DsmtBodyValue -Body $body -Name 'enabled' -Default $false)

                # ---- switching HTTPS off ----
                if (-not $enabled) {
                    $state   = Get-DsmtHttpsState
                    $removed = Remove-DsmtSslBinding -Port $state.port
                    $saved   = Save-DsmtSavedSettings -Values @{ HttpsEnabled = $false }

                    Write-DsmtAudit -Action 'Disable HTTPS' -Target ('port ' + $state.port) `
                                    -Operator $session.Account -Reason 'Console configuration change' `
                                    -Result 'Success' -Category 'session'
                    Write-DsmtLog -Message ($session.Account + ' switched HTTPS off (takes effect on restart)')

                    Send-DsmtJson -Response $Response -Data @{
                        ok           = $true
                        enabled      = $false
                        needsRestart = $true
                        persisted    = $saved.Ok
                        persistError = $saved.Error
                        bindingRemoved = $removed.Ok
                        bindingError = $removed.Error
                        message      = 'HTTPS is switched off. DSMT goes back to plain HTTP on port ' +
                                       [string]$cfg.Port + ' the next time it starts.'
                    }
                    return
                }

                # ---- switching HTTPS on ----
                $rawPort = Get-DsmtBodyValue -Body $body -Name 'port' -Default 8443
                $port    = 0
                if (-not [int]::TryParse([string]$rawPort, [ref] $port)) {
                    Send-DsmtError -Response $Response -Message 'The HTTPS port must be a whole number.' -StatusCode 400
                    return
                }
                if ($port -lt 1 -or $port -gt 65535) {
                    Send-DsmtError -Response $Response -Message 'The HTTPS port must be between 1 and 65535.' -StatusCode 400
                    return
                }

                $thumb = ([string](Get-DsmtBodyValue -Body $body -Name 'thumbprint' -Default '')).Trim()
                $thumb = ($thumb -replace '[^0-9a-fA-F]', '').ToUpper()
                if ($thumb.Length -ne 40) {
                    Send-DsmtError -Response $Response -Message 'Choose a certificate. A thumbprint is 40 hexadecimal characters.' -StatusCode 400
                    return
                }

                # The certificate must be in the store, and usable, BEFORE
                # anything is written. Binding an expired certificate or one
                # with no private key succeeds in netsh and then fails in
                # every browser, with nothing on this screen to explain it.
                $match = $null
                foreach ($c in @(Get-DsmtCertificates)) {
                    if ($c.thumbprint -eq $thumb) { $match = $c }
                }
                if ($null -eq $match) {
                    Send-DsmtError -Response $Response -StatusCode 400 -Message (
                        'No certificate with that thumbprint is in Cert:\LocalMachine\My on this host. ' +
                        'Import it there first - the console never receives a private key.')
                    return
                }
                if (-not $match.usable) {
                    Send-DsmtError -Response $Response -StatusCode 400 -Message (
                        'That certificate cannot serve HTTPS. ' + $match.why)
                    return
                }

                $bind = Set-DsmtSslBinding -Port $port -Thumbprint $thumb
                if (-not $bind.Ok) {
                    Write-DsmtAudit -Action 'Enable HTTPS' -Target ('port ' + [string]$port + ', ' + $thumb) `
                                    -Operator $session.Account -Reason 'Console configuration change' `
                                    -Result 'Failed' -Category 'session'
                    Send-DsmtError -Response $Response -Message $bind.Error -StatusCode 400
                    return
                }

                $saved = Save-DsmtSavedSettings -Values @{
                    HttpsEnabled    = $true
                    HttpsPort       = $port
                    HttpsThumbprint = $thumb
                }

                Write-DsmtAudit -Action 'Enable HTTPS' -Target ('port ' + [string]$port + ', ' + $thumb) `
                                -Operator $session.Account -Reason 'Console configuration change' `
                                -Result 'Success' -Category 'session'
                Write-DsmtLog -Message ($session.Account + ' bound certificate ' + $thumb + ' to port ' +
                                        $port + ' and switched HTTPS on (takes effect on restart)')

                $reservation = ''
                if ($cfg.ListenAddress -eq 'any') {
                    $reservation = 'netsh http add urlacl url=https://+:' + $port + '/ user="' +
                                   $env:USERDOMAIN + '\' + $env:USERNAME + '"'
                }

                Send-DsmtJson -Response $Response -Data @{
                    ok           = $true
                    enabled      = $true
                    port         = $port
                    thumbprint   = $thumb
                    subject      = $match.subject
                    replaced     = $bind.Replaced
                    needsRestart = $true
                    persisted    = $saved.Ok
                    persistError = $saved.Error
                    url          = ('https://' + $env:COMPUTERNAME + ':' + [string]$port + '/')
                    reservation  = $reservation
                    firewall     = ('New-NetFirewallRule -DisplayName "DSMT console (TCP ' + $port +
                                    ')" -Direction Inbound -Protocol TCP -LocalPort ' + $port +
                                    ' -Action Allow -Profile Domain')
                }
                return
            }

            '^/api/settings/identity$' {
                if ($method -ne 'POST') { break }

                $body = Read-DsmtBody -Request $Request
                $mode = ([string](Get-DsmtBodyValue -Body $body -Name 'mode')).Trim().ToLower()

                if ($mode -ne 'operator' -and $mode -ne 'hybrid') {
                    Send-DsmtError -Response $Response -Message 'Identity mode must be "operator" or "hybrid".' -StatusCode 400
                    return
                }

                $previous = $cfg.IdentityMode
                $script:DsmtConfig.IdentityMode = $mode

                $saved = Save-DsmtSavedSettings -Values @{ IdentityMode = $mode }

                # A change to who reads the directory is a security-relevant
                # change, so it is audited like any other.
                Write-DsmtAudit -Action 'Change identity mode' -Target ($previous + ' -> ' + $mode) `
                                -Operator $session.Account -Reason 'Console configuration change' `
                                -Result 'Success' -Category 'session' `
                                -Detail ('Service account: ' + $env:USERDOMAIN + '\' + $env:USERNAME)

                Write-DsmtLog -Message ($session.Account + ' changed the identity mode from ' + $previous + ' to ' + $mode)

                Send-DsmtJson -Response $Response -Data @{
                    ok           = $true
                    identityMode = $mode
                    persisted    = $saved.Ok
                    persistError = $saved.Error
                }
                return
            }

            '^/api/settings/sql/databases$' {
                if ($method -ne 'POST') { break }

                $body   = Read-DsmtBody -Request $Request
                $server = ([string](Get-DsmtBodyValue -Body $body -Name 'server')).Trim()
                $user   = [string](Get-DsmtBodyValue -Body $body -Name 'username')
                $pass   = [string](Get-DsmtBodyValue -Body $body -Name 'password')

                if ([string]::IsNullOrWhiteSpace($server)) {
                    Send-DsmtError -Response $Response -Message 'Enter the SQL Server instance first.' -StatusCode 400
                    return
                }

                $listed = Get-DsmtSqlDatabases -Server $server -Username $user -Password $pass
                if (-not $listed.Ok) {
                    Send-DsmtError -Response $Response -Message $listed.Error -StatusCode 400
                    return
                }

                Send-DsmtJson -Response $Response -Data @{
                    ok        = $true
                    databases = @($listed.Databases)
                }
                return
            }

            '^/api/settings/sql$' {
                if ($method -ne 'POST') { break }

                $body     = Read-DsmtBody -Request $Request
                $server   = ([string](Get-DsmtBodyValue -Body $body -Name 'server')).Trim()
                $database = ([string](Get-DsmtBodyValue -Body $body -Name 'database' -Default 'DSMT')).Trim()
                $user     = [string](Get-DsmtBodyValue -Body $body -Name 'username')
                $pass     = [string](Get-DsmtBodyValue -Body $body -Name 'password')

                # Creating a database is not something to do as a side effect
                # of a typo in an instance name, so the caller has to ask.
                $createIfMissing = [bool](Get-DsmtBodyValue -Body $body -Name 'createIfMissing' -Default $false)

                if ([string]::IsNullOrWhiteSpace($server)) {
                    Send-DsmtError -Response $Response -Message 'Enter the SQL Server instance to connect to.' -StatusCode 400
                    return
                }
                if ([string]::IsNullOrWhiteSpace($database)) { $database = 'DSMT' }

                Write-DsmtLog -Message ($session.Account + ' is configuring SQL storage: ' + $server + ' [' + $database + ']')

                $init = Initialize-DsmtSql -Server $server -Database $database -Username $user `
                                           -Password $pass -CreateIfMissing $createIfMissing

                # Not an error: the database simply is not there yet, and the
                # operator has not said to create it.
                if ($init.NeedsCreate) {
                    Send-DsmtJson -Response $Response -Data @{
                        ok          = $false
                        needsCreate = $true
                        server      = $server
                        database    = $database
                        error       = $init.Error
                    }
                    return
                }

                if (-not $init.Ok) {
                    Write-DsmtAudit -Action 'Configure SQL storage' -Target ($server + ' [' + $database + ']') `
                                    -Operator $session.Account -Reason 'Console configuration change' `
                                    -Result 'Failed' -Category 'session' -Detail $init.Error
                    Send-DsmtError -Response $Response -Message $init.Error -StatusCode 400
                    return
                }

                # Persist it so the database survives a restart of the server.
                $saved = Save-DsmtSavedSettings -Values @{
                    SqlServer   = $server
                    SqlDatabase = $database
                }

                $detail = 'Database existed, ' + $init.TablesFound + ' tables found'
                if ($init.DatabaseCreated) { $detail = 'Database created' }
                if ($init.TablesCreated -gt 0) { $detail = $detail + ', ' + $init.TablesCreated + ' tables created' }

                Write-DsmtAudit -Action 'Configure SQL storage' -Target ($server + ' [' + $database + ']') `
                                -Operator $session.Account -Reason 'Console configuration change' `
                                -Result 'Success' -Category 'session' -Detail $detail

                # Backfill the operator and this session so the new database is
                # not born with a gap where the current sign-in should be.
                Register-DsmtOperator -Account $session.Account -Sam $session.Sam `
                                      -Display $session.Display -Upn $session.Upn -Token $session.Token

                $sql = Get-DsmtSqlState
                Send-DsmtJson -Response $Response -Data @{
                    ok      = $true
                    storage = @{
                        sqlEnabled  = $sql.Enabled
                        sqlServer   = $sql.Server
                        sqlDatabase = $sql.Database
                        sqlError    = ''
                    }
                    persisted      = $saved.Ok
                    persistError   = $saved.Error
                }
                return
            }

            '^/api/domain$' {
                $info = Get-DsmtDomainInfo -Credential $session.Credential
                Send-DsmtJson -Response $Response -Data @{ ok = $true; domain = $info }
                return
            }

            '^/api/users$' {
                if ($method -eq 'GET') {
                    $q     = Get-DsmtQueryValue -Request $Request -Name 'q'
                    $limit = 0
                    [int]::TryParse((Get-DsmtQueryValue -Request $Request -Name 'limit' -Default '0'), [ref] $limit) | Out-Null
                    $rows  = Get-DsmtUsers -Credential $session.Credential -Query $q -Limit $limit
                    # The grid is served from the live read above; the SQL
                    # snapshot is written afterwards and never read back into it.
                    Sync-DsmtUsersToSql -Users $rows | Out-Null
                    Send-DsmtJson -Response $Response -Data @{ ok = $true; items = @($rows); count = @($rows).Count; limit = $cfg.PageSize }
                    return
                }

                if ($method -eq 'POST') {
                    $body   = Read-DsmtBody -Request $Request
                    $reason = [string](Get-DsmtBodyValue -Body $body -Name 'reason')
                    if ([string]::IsNullOrWhiteSpace($reason)) {
                        Send-DsmtError -Response $Response -Message 'A reason is required for every change.' -StatusCode 400
                        return
                    }

                    $display = [string](Get-DsmtBodyValue -Body $body -Name 'displayName')
                    $sam     = [string](Get-DsmtBodyValue -Body $body -Name 'sam')
                    $ou      = [string](Get-DsmtBodyValue -Body $body -Name 'ou')
                    if ([string]::IsNullOrWhiteSpace($display) -or [string]::IsNullOrWhiteSpace($sam) -or [string]::IsNullOrWhiteSpace($ou)) {
                        Send-DsmtError -Response $Response -Message 'Display name, samAccountName and target OU are required.' -StatusCode 400
                        return
                    }

                    $password = [string](Get-DsmtBodyValue -Body $body -Name 'password')
                    $generated = ''
                    if ([string]::IsNullOrWhiteSpace($password)) {
                        $password  = New-DsmtPassword
                        $generated = $password
                    }

                    $outcome = Invoke-DsmtBulkAction -Session $session -Targets @($sam) -Action 'Create user' `
                        -Reason $reason -Category 'user' -DetailSuffix ('into ' + $ou) -Operation {
                            param($target)
                            New-DsmtUser -Credential $session.Credential -DisplayName $display -SamAccountName $target `
                                -TargetOu $ou `
                                -GivenName  ([string](Get-DsmtBodyValue -Body $body -Name 'givenName')) `
                                -Surname    ([string](Get-DsmtBodyValue -Body $body -Name 'surname')) `
                                -Department ([string](Get-DsmtBodyValue -Body $body -Name 'department')) `
                                -Title      ([string](Get-DsmtBodyValue -Body $body -Name 'title')) `
                                -Password   $password `
                                -Enabled    ([bool](Get-DsmtBodyValue -Body $body -Name 'enabled' -Default $true)) `
                                -MustChange ([bool](Get-DsmtBodyValue -Body $body -Name 'mustChange' -Default $true)) | Out-Null
                        }

                    $outcome.generatedPassword = $generated
                    Send-DsmtJson -Response $Response -Data $outcome
                    return
                }
            }

            '^/api/users/import$' {
                if ($method -ne 'POST') { break }

                $body   = Read-DsmtBody -Request $Request
                $reason = [string](Get-DsmtBodyValue -Body $body -Name 'reason')
                $csv    = [string](Get-DsmtBodyValue -Body $body -Name 'csv')
                $ou     = [string](Get-DsmtBodyValue -Body $body -Name 'ou')

                if ([string]::IsNullOrWhiteSpace($reason)) {
                    Send-DsmtError -Response $Response -Message 'A reason is required for every change.' -StatusCode 400
                    return
                }
                if ([string]::IsNullOrWhiteSpace($csv)) {
                    Send-DsmtError -Response $Response -Message 'The CSV is empty.' -StatusCode 400
                    return
                }

                $rows = @()
                try {
                    # Single-quoted pattern on purpose: a double-quoted string
                    # would expand the escapes and stop being a regex.
                    $rows = @(ConvertFrom-Csv -InputObject ($csv -split '\r?\n') -ErrorAction Stop)
                } catch {
                    Send-DsmtError -Response $Response -Message ('The CSV could not be parsed: ' + $_.Exception.Message) -StatusCode 400
                    return
                }
                if ($rows.Count -eq 0) {
                    Send-DsmtError -Response $Response -Message 'The CSV has a header but no rows.' -StatusCode 400
                    return
                }

                # ---- DRY RUN --------------------------------------------
                # An import that half-succeeds with no preview is the worst
                # possible shape for this feature: the operator finds out what
                # it was going to do by reading what it already did. So every
                # row is checked against the live directory FIRST, nothing is
                # written, and the verdict comes back per row.
                #
                # This is a preview, not a guarantee. It says so on the screen:
                # the directory can change between the check and the write, and
                # AD still has the last word on the password policy and on
                # whether this operator may create anything in that OU.
                $dryRun = [bool](Get-DsmtBodyValue -Body $body -Name 'dryRun' -Default $false)

                if ($dryRun) {
                    $preview = @()
                    $wouldCreate = 0
                    $seen = @{}

                    foreach ($row in $rows) {
                        $rowSam     = ([string]$row.SamAccountName).Trim()
                        $rowDisplay = ([string]$row.DisplayName).Trim()
                        $rowOu      = ([string]$row.OU).Trim()
                        if ([string]::IsNullOrWhiteSpace($rowOu)) { $rowOu = $ou }
                        if ([string]::IsNullOrWhiteSpace($rowDisplay)) { $rowDisplay = $rowSam }

                        $verdict = 'create'
                        $why     = ''

                        if ([string]::IsNullOrWhiteSpace($rowSam)) {
                            $verdict = 'skip'
                            $why     = 'SamAccountName column is empty.'
                        } elseif ($seen.ContainsKey($rowSam.ToLower())) {
                            # Caught here and nowhere else: AD would create the
                            # first and reject the second with a duplicate
                            # error that names the account but not the file.
                            $verdict = 'skip'
                            $why     = 'This samAccountName appears earlier in the same file.'
                        } elseif ([string]::IsNullOrWhiteSpace($rowOu)) {
                            $verdict = 'skip'
                            $why     = 'No OU on the row and no target OU selected.'
                        } else {
                            $seen[$rowSam.ToLower()] = $true

                            $exists = $false
                            try {
                                $exists = Test-DsmtUserExists -SamAccountName $rowSam -Credential $session.Credential
                            } catch {
                                $exists = $false
                            }
                            if ($exists) {
                                $verdict = 'skip'
                                $why     = 'An account with this samAccountName already exists.'
                            } else {
                                $ouOk = $false
                                try {
                                    $ouOk = Test-DsmtOuExists -DistinguishedName $rowOu -Credential $session.Credential
                                } catch {
                                    $ouOk = $false
                                }
                                if (-not $ouOk) {
                                    $verdict = 'skip'
                                    $why     = 'The target OU could not be found: ' + $rowOu
                                }
                            }
                        }

                        if ($verdict -eq 'create') { $wouldCreate++ }

                        $preview += [ordered]@{
                            sam       = $rowSam
                            display   = $rowDisplay
                            ou        = $rowOu
                            generated = [string]::IsNullOrWhiteSpace([string]$row.Password)
                            verdict   = $verdict
                            why       = $why
                        }
                    }

                    Write-DsmtLog -Message ($session.Account + ' previewed a CSV import of ' +
                                            [string]$rows.Count + ' row(s): ' + [string]$wouldCreate + ' would be created')

                    Send-DsmtJson -Response $Response -Data @{
                        ok          = $true
                        dryRun      = $true
                        rows        = @($preview)
                        total       = $rows.Count
                        wouldCreate = $wouldCreate
                        wouldSkip   = ($rows.Count - $wouldCreate)
                    }
                    return
                }

                $controller = ''
                try { $controller = Get-DsmtServer -Credential $session.Credential } catch { }

                $results = @()
                $okCount = 0
                foreach ($row in $rows) {
                    $rowSam     = [string]$row.SamAccountName
                    $rowDisplay = [string]$row.DisplayName
                    $rowOu      = [string]$row.OU
                    if ([string]::IsNullOrWhiteSpace($rowOu)) { $rowOu = $ou }
                    if ([string]::IsNullOrWhiteSpace($rowDisplay)) { $rowDisplay = $rowSam }

                    if ([string]::IsNullOrWhiteSpace($rowSam)) {
                        $results += [ordered]@{ target = '(blank)'; ok = $false; error = 'SamAccountName column is empty.' }
                        continue
                    }
                    if ([string]::IsNullOrWhiteSpace($rowOu)) {
                        $results += [ordered]@{ target = $rowSam; ok = $false; error = 'No OU on the row and no target OU selected.' }
                        Write-DsmtAudit -Action 'Bulk CSV import' -Target $rowSam -Operator $session.Account -Reason $reason `
                                        -Result 'Failed' -Category 'user' -Controller $controller -Detail 'No target OU'
                        continue
                    }

                    $rowPassword = [string]$row.Password
                    if ([string]::IsNullOrWhiteSpace($rowPassword)) { $rowPassword = New-DsmtPassword }

                    try {
                        New-DsmtUser -Credential $session.Credential -DisplayName $rowDisplay -SamAccountName $rowSam `
                            -TargetOu $rowOu -GivenName ([string]$row.GivenName) -Surname ([string]$row.Surname) `
                            -Department ([string]$row.Department) -Title ([string]$row.Title) `
                            -Password $rowPassword -Enabled $true -MustChange $true | Out-Null

                        $okCount++
                        $results += [ordered]@{ target = $rowSam; ok = $true; error = '' }
                        Write-DsmtAudit -Action 'Bulk CSV import' -Target $rowSam -Operator $session.Account -Reason $reason `
                                        -Result 'Success' -Category 'user' -Controller $controller -Detail ('into ' + $rowOu)
                    } catch {
                        $message = $_.Exception.Message
                        $results += [ordered]@{ target = $rowSam; ok = $false; error = $message }
                        Write-DsmtAudit -Action 'Bulk CSV import' -Target $rowSam -Operator $session.Account -Reason $reason `
                                        -Result 'Failed' -Category 'user' -Controller $controller -Detail $message
                    }
                }

                $overall = 'Success'
                if ($okCount -eq 0) { $overall = 'Failed' }
                elseif ($okCount -lt $rows.Count) { $overall = 'Partial' }

                Send-DsmtJson -Response $Response -Data @{
                    ok = ($okCount -gt 0); result = $overall; succeeded = $okCount
                    failed = ($rows.Count - $okCount); results = @($results)
                }
                return
            }

            '^/api/users/(?<id>.+)$' {
                if ($method -ne 'GET') { break }
                $id   = [System.Uri]::UnescapeDataString($Matches['id'])
                $user = Get-DsmtUser -Credential $session.Credential -Identity $id
                Send-DsmtJson -Response $Response -Data @{ ok = $true; item = $user }
                return
            }

            '^/api/groups$' {
                if ($method -eq 'GET') {
                    $q     = Get-DsmtQueryValue -Request $Request -Name 'q'
                    $groupFilter = [string](Get-DsmtQueryValue -Request $Request -Name 'filter' -Default 'all')
                    $limit = 0
                    [int]::TryParse((Get-DsmtQueryValue -Request $Request -Name 'limit' -Default '0'), [ref] $limit) | Out-Null

                    $rows = @(Get-DsmtGroups -Credential $session.Credential -Query $q -Limit $limit)

                    # The snapshot is written from the UNFILTERED read, so a
                    # filtered view never truncates what SQL believes the
                    # directory contains.
                    Sync-DsmtGroupsToSql -Groups $rows | Out-Null

                    $total = @($rows).Count
                    $rows  = @(Select-DsmtGroupsByFilter -Rows $rows -Filter $groupFilter)

                    Send-DsmtJson -Response $Response -Data @{
                        ok      = $true
                        items   = @($rows)
                        count   = @($rows).Count
                        total   = $total
                        filter  = $groupFilter
                        filters = @(Get-DsmtGroupFilters)
                        limit   = $cfg.PageSize
                    }
                    return
                }

                if ($method -eq 'POST') {
                    $body   = Read-DsmtBody -Request $Request
                    $reason = [string](Get-DsmtBodyValue -Body $body -Name 'reason')
                    $name   = [string](Get-DsmtBodyValue -Body $body -Name 'name')
                    $ou     = [string](Get-DsmtBodyValue -Body $body -Name 'ou')

                    if ([string]::IsNullOrWhiteSpace($reason)) {
                        Send-DsmtError -Response $Response -Message 'A reason is required for every change.' -StatusCode 400
                        return
                    }
                    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($ou)) {
                        Send-DsmtError -Response $Response -Message 'Group name and target OU are required.' -StatusCode 400
                        return
                    }

                    $category = [string](Get-DsmtBodyValue -Body $body -Name 'category' -Default 'Security')
                    $scope    = [string](Get-DsmtBodyValue -Body $body -Name 'scope'    -Default 'Global')

                    $outcome = Invoke-DsmtBulkAction -Session $session -Targets @($name) -Action 'Create group' `
                        -Reason $reason -Category 'group' -DetailSuffix ($category + ' - ' + $scope + ' into ' + $ou) -Operation {
                            param($target)
                            New-DsmtGroup -Credential $session.Credential -Name $target -TargetOu $ou `
                                -Category $category -Scope $scope `
                                -Description ([string](Get-DsmtBodyValue -Body $body -Name 'description'))
                        }

                    Send-DsmtJson -Response $Response -Data $outcome
                    return
                }
            }

            '^/api/groups/(?<id>.+)$' {
                if ($method -ne 'GET') { break }
                $id    = [System.Uri]::UnescapeDataString($Matches['id'])
                $group = Get-DsmtGroup -Credential $session.Credential -Identity $id
                Send-DsmtJson -Response $Response -Data @{ ok = $true; item = $group }
                return
            }

            '^/api/ous$' {
                if ($method -ne 'GET') { break }
                $ous = Get-DsmtOus -Credential $session.Credential
                Send-DsmtJson -Response $Response -Data @{ ok = $true; items = @($ous) }
                return
            }

            '^/api/audit/undo$' {
                if ($method -ne 'POST') { break }

                $body    = Read-DsmtBody -Request $Request
                $oAction = ([string](Get-DsmtBodyValue -Body $body -Name 'action')).Trim()
                $oTarget = ([string](Get-DsmtBodyValue -Body $body -Name 'target')).Trim()
                $oDetail = ([string](Get-DsmtBodyValue -Body $body -Name 'detail')).Trim()
                $reason  = ([string](Get-DsmtBodyValue -Body $body -Name 'reason')).Trim()

                if ([string]::IsNullOrWhiteSpace($oAction) -or [string]::IsNullOrWhiteSpace($oTarget)) {
                    Send-DsmtError -Response $Response -Message 'The audit entry to undo was not identified.' -StatusCode 400
                    return
                }
                # An undo is a directory write like any other, so it carries a
                # reason like any other. "Undoing a mistake" is still a reason
                # someone has to type.
                if ([string]::IsNullOrWhiteSpace($reason)) {
                    Send-DsmtError -Response $Response -Message 'Give a reason for the undo.' -StatusCode 400
                    return
                }

                $plan = Get-DsmtUndoPlan -Action $oAction -Detail $oDetail
                if (-not $plan.Ok) {
                    Send-DsmtError -Response $Response -Message $plan.Reason -StatusCode 400
                    return
                }

                # The undo runs as the signed-in operator, exactly like the
                # button that would perform the same change by hand - so it can
                # never do anything this operator is not already allowed to do,
                # and the DC records their name against it.
                $undoDetail = 'Reverses "' + $oAction + '" on ' + $oTarget
                if (-not [string]::IsNullOrWhiteSpace($oDetail)) { $undoDetail += ' (' + $oDetail + ')' }

                switch ($plan.Action) {

                    'enable' {
                        $outcome = Invoke-DsmtBulkAction -Session $session -Targets @($oTarget) -Action $plan.Label `
                            -Reason $reason -Category 'user' -DetailSuffix $undoDetail -Operation {
                                param($target)
                                Set-DsmtAccountEnabled -Credential $session.Credential -Identity $target -Enabled $true
                            }
                    }

                    'disable' {
                        $outcome = Invoke-DsmtBulkAction -Session $session -Targets @($oTarget) -Action $plan.Label `
                            -Reason $reason -Category 'user' -DetailSuffix $undoDetail -Operation {
                                param($target)
                                Set-DsmtAccountEnabled -Credential $session.Credential -Identity $target -Enabled $false
                            }
                    }

                    'group-add' {
                        $undoGroup = $plan.Group
                        $outcome = Invoke-DsmtBulkAction -Session $session -Targets @($oTarget) -Action $plan.Label `
                            -Reason $reason -Category 'group' -DetailSuffix $undoDetail -Operation {
                                param($target)
                                Add-DsmtGroupMember -Credential $session.Credential -Group $undoGroup -Members @($target)
                            }
                    }

                    'group-remove' {
                        $undoGroup = $plan.Group
                        $outcome = Invoke-DsmtBulkAction -Session $session -Targets @($oTarget) -Action $plan.Label `
                            -Reason $reason -Category 'group' -DetailSuffix $undoDetail -Operation {
                                param($target)
                                Remove-DsmtGroupMember -Credential $session.Credential -Group $undoGroup -Members @($target)
                            }
                    }

                    'move-ou' {
                        $undoOu = $plan.Ou
                        $outcome = Invoke-DsmtBulkAction -Session $session -Targets @($oTarget) -Action $plan.Label `
                            -Reason $reason -Category 'user' -DetailSuffix $undoDetail -Operation {
                                param($target)
                                Move-DsmtObject -Credential $session.Credential -Identity $target -TargetOu $undoOu
                            }
                    }

                    default {
                        Send-DsmtError -Response $Response -Message 'That undo is not implemented.' -StatusCode 400
                        return
                    }
                }

                Write-DsmtLog -Message ($session.Account + ' undid "' + $oAction + '" on ' + $oTarget)
                Send-DsmtJson -Response $Response -Data $outcome
                return
            }

            # ---------------------------------------------------------------
            # Tools -> gMSA
            # ---------------------------------------------------------------

            '^/api/tools/gmsa/state$' {
                if ($method -ne 'GET') { break }

                $groupName = [string](Get-DsmtQueryValue -Request $Request -Name 'group')
                $gmsaName  = [string](Get-DsmtQueryValue -Request $Request -Name 'gmsa')

                $state = Get-DsmtGmsaState -Credential $session.Credential -GroupName $groupName -GmsaName $gmsaName
                Send-DsmtJson -Response $Response -Data @{
                    ok             = $state.Ok
                    error          = $state.Error
                    kds            = $state.Kds
                    kdsLocal       = $state.KdsLocal
                    groupName      = $state.GroupName
                    groupExists    = $state.GroupExists
                    groupDn        = $state.GroupDn
                    members        = @($state.Members)
                    gmsaName       = $state.GmsaName
                    gmsaExists     = $state.GmsaExists
                    gmsaDns        = $state.GmsaDns
                    gmsaPrincipals = @($state.GmsaPrincipals)
                    accounts       = @($state.Accounts)
                    defaultOu      = $state.DefaultOu
                    domain         = $state.DomainDns
                    waitHours      = $script:DsmtKdsWaitHours
                }
                return
            }

            '^/api/tools/gmsa/kds$' {
                if ($method -ne 'POST') { break }

                $body     = Read-DsmtBody -Request $Request
                $reason   = ([string](Get-DsmtBodyValue -Body $body -Name 'reason')).Trim()
                $backdate = [bool](Get-DsmtBodyValue -Body $body -Name 'backdate' -Default $false)

                # Two independent confirmations, both required, both checked
                # here rather than only in the browser. This writes an object
                # to the FOREST configuration partition - the blast radius is
                # every domain in the forest, and it is not a thing to do
                # because one button was clicked by accident.
                $ack1 = [bool](Get-DsmtBodyValue -Body $body -Name 'confirmUnderstood' -Default $false)
                $ack2 = [bool](Get-DsmtBodyValue -Body $body -Name 'confirmAuthorised' -Default $false)

                if (-not $ack1 -or -not $ack2) {
                    Send-DsmtError -Response $Response -StatusCode 400 `
                        -Message 'Both confirmations are required before a KDS root key is created.'
                    return
                }
                if ([string]::IsNullOrWhiteSpace($reason)) {
                    Send-DsmtError -Response $Response -Message 'Give a reason for the audit log.' -StatusCode 400
                    return
                }

                $existing = Get-DsmtKdsStatus -Credential $session.Credential
                if ($existing.Ok -and $existing.Exists) {
                    Send-DsmtError -Response $Response -StatusCode 400 `
                        -Message 'This forest already has a KDS root key. A second one is not needed and will not help - if gMSA creation is failing, the cause is elsewhere.'
                    return
                }

                $controller = ''
                try { $controller = Get-DsmtServer -Credential $session.Credential } catch { }

                # ATTRIBUTION GAP, recorded rather than hidden: Add-KdsRootKey
                # takes no credential, so this one call runs as the account the
                # server runs as. The audit record names the operator who
                # initiated it and says so explicitly.
                $whoRan = $env:USERDOMAIN + '\' + $env:USERNAME
                $created = New-DsmtKdsRootKey -Backdate $backdate

                $detail = 'Initiated by ' + $session.Account + '; executed in the server process as ' + $whoRan +
                          ' because Add-KdsRootKey accepts no credential.'
                if ($backdate) { $detail += ' Effective time backdated (lab shortcut).' }
                if (-not $created.Ok) { $detail += ' ' + $created.Error }

                $outcome = 'Success'
                if (-not $created.Ok) { $outcome = 'Failed' }

                $forestLabel = 'the forest'
                try { $forestLabel = 'forest of ' + (Get-DsmtConfig).Domain } catch { }

                Write-DsmtAudit -Action 'Create KDS root key' -Target $forestLabel `
                                -Operator $session.Account -Reason $reason -Result $outcome `
                                -Category 'session' -Controller $controller -Detail $detail

                if (-not $created.Ok) {
                    Send-DsmtError -Response $Response -Message $created.Error -StatusCode 400
                    return
                }

                Write-DsmtLog -Message ($session.Account + ' created the forest KDS root key (backdated: ' + [string]$backdate + ')')
                Send-DsmtJson -Response $Response -Data @{
                    ok        = $true
                    backdated = $created.Backdated
                    message   = $created.Message
                    ranAs     = $whoRan
                }
                return
            }

            '^/api/tools/gmsa/group$' {
                if ($method -ne 'POST') { break }

                $body   = Read-DsmtBody -Request $Request
                $name   = ([string](Get-DsmtBodyValue -Body $body -Name 'name')).Trim()
                $path   = ([string](Get-DsmtBodyValue -Body $body -Name 'ou')).Trim()
                $reason = ([string](Get-DsmtBodyValue -Body $body -Name 'reason')).Trim()

                if ([string]::IsNullOrWhiteSpace($name)) {
                    Send-DsmtError -Response $Response -Message 'Name the group.' -StatusCode 400
                    return
                }
                if ([string]::IsNullOrWhiteSpace($path)) {
                    Send-DsmtError -Response $Response -Message 'Choose the OU to create the group in.' -StatusCode 400
                    return
                }
                if ([string]::IsNullOrWhiteSpace($reason)) {
                    Send-DsmtError -Response $Response -Message 'Give a reason for the audit log.' -StatusCode 400
                    return
                }

                $outcome = Invoke-DsmtBulkAction -Session $session -Targets @($name) -Action 'Create gMSA group' `
                    -Reason $reason -Category 'group' -DetailSuffix ('in ' + $path) -Operation {
                        param($target)
                        New-DsmtGmsaGroup -Credential $session.Credential -Name $target -Path $path
                    }

                Send-DsmtJson -Response $Response -Data $outcome
                return
            }

            '^/api/tools/gmsa/members$' {
                if ($method -ne 'POST') { break }

                $body    = Read-DsmtBody -Request $Request
                $group   = ([string](Get-DsmtBodyValue -Body $body -Name 'group')).Trim()
                $mode    = ([string](Get-DsmtBodyValue -Body $body -Name 'mode' -Default 'add')).Trim()
                $reason  = ([string](Get-DsmtBodyValue -Body $body -Name 'reason')).Trim()
                $names   = Get-DsmtBodyValue -Body $body -Name 'computers' -Default @()

                if ([string]::IsNullOrWhiteSpace($group)) {
                    Send-DsmtError -Response $Response -Message 'Name the group first.' -StatusCode 400
                    return
                }
                if ([string]::IsNullOrWhiteSpace($reason)) {
                    Send-DsmtError -Response $Response -Message 'Give a reason for the audit log.' -StatusCode 400
                    return
                }

                $wanted = @()
                foreach ($n in @($names)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$n)) { $wanted += ([string]$n).Trim() }
                }
                if ($wanted.Count -eq 0) {
                    Send-DsmtError -Response $Response -Message 'Name at least one computer.' -StatusCode 400
                    return
                }

                # Resolve every name to a real computer account BEFORE changing
                # anything. A typo that silently adds nothing is the failure
                # this whole screen exists to prevent - the account would look
                # correct and refuse to install on the host that was missed.
                $resolved = @()
                $missing  = @()
                foreach ($n in $wanted) {
                    $c = Get-DsmtComputerAccount -Credential $session.Credential -Name $n
                    if ($null -eq $c) { $missing += $n } else { $resolved += [string]$c.DistinguishedName }
                }

                if ($missing.Count -gt 0) {
                    Send-DsmtError -Response $Response -StatusCode 400 `
                        -Message ('No computer account found for: ' + ($missing -join ', ') + '. Nothing was changed.')
                    return
                }

                $label = 'Add computer to gMSA group'
                if ($mode -eq 'remove') { $label = 'Remove computer from gMSA group' }

                $outcome = Invoke-DsmtBulkAction -Session $session -Targets $resolved -Action $label `
                    -Reason $reason -Category 'group' -DetailSuffix ($mode + ' ' + $group) -Operation {
                        param($target)
                        if ($mode -eq 'remove') {
                            Remove-DsmtGroupMember -Credential $session.Credential -Group $group -Members @($target)
                        } else {
                            Add-DsmtGroupMember -Credential $session.Credential -Group $group -Members @($target)
                        }
                    }

                Send-DsmtJson -Response $Response -Data $outcome
                return
            }

            '^/api/tools/gmsa/account$' {
                if ($method -ne 'POST') { break }

                $body   = Read-DsmtBody -Request $Request
                $name   = ([string](Get-DsmtBodyValue -Body $body -Name 'name')).Trim().TrimEnd('$')
                $dns    = ([string](Get-DsmtBodyValue -Body $body -Name 'dns')).Trim()
                $group  = ([string](Get-DsmtBodyValue -Body $body -Name 'group')).Trim()
                $reason = ([string](Get-DsmtBodyValue -Body $body -Name 'reason')).Trim()

                if ([string]::IsNullOrWhiteSpace($name)) {
                    Send-DsmtError -Response $Response -Message 'Name the gMSA.' -StatusCode 400
                    return
                }
                if ([string]::IsNullOrWhiteSpace($group)) {
                    Send-DsmtError -Response $Response -Message 'Choose the group of permitted computers.' -StatusCode 400
                    return
                }
                if ([string]::IsNullOrWhiteSpace($reason)) {
                    Send-DsmtError -Response $Response -Message 'Give a reason for the audit log.' -StatusCode 400
                    return
                }

                # Refuse early and explain, rather than letting AD return
                # "Key does not exist" - which names none of this.
                $kds = Get-DsmtKdsStatus -Credential $session.Credential
                if ($kds.Ok -and -not $kds.Exists) {
                    Send-DsmtError -Response $Response -StatusCode 400 `
                        -Message 'This forest has no KDS root key, so no gMSA can be created. Create the key first - it is the step above.'
                    return
                }
                if ($kds.Ok -and $kds.Exists -and -not $kds.Usable) {
                    Send-DsmtError -Response $Response -StatusCode 400 `
                        -Message ('The KDS root key exists but is not usable yet: about ' + [string]$kds.HoursRemaining +
                                  ' hour(s) remain of the ' + [string]$script:DsmtKdsWaitHours +
                                  '-hour convergence window. This is expected, not a fault.')
                    return
                }

                if ([string]::IsNullOrWhiteSpace($dns)) {
                    $domainDns = ''
                    try { $domainDns = (Get-DsmtDomainInfo -Credential $session.Credential).domain } catch { }
                    if (-not [string]::IsNullOrWhiteSpace($domainDns)) { $dns = $name + '.' + $domainDns }
                }
                if ([string]::IsNullOrWhiteSpace($dns)) {
                    Send-DsmtError -Response $Response -Message 'Give the DNS host name for the account.' -StatusCode 400
                    return
                }

                $outcome = Invoke-DsmtBulkAction -Session $session -Targets @($name) -Action 'Create gMSA' `
                    -Reason $reason -Category 'user' -DetailSuffix ('retrievable by ' + $group) -Operation {
                        param($target)
                        New-DsmtGmsa -Credential $session.Credential -Name $target -DnsHostName $dns -Group $group
                    }

                Send-DsmtJson -Response $Response -Data $outcome
                return
            }

            '^/api/tools/adhealth$' {
                if ($method -ne 'GET') { break }
                # Deliberately slow and deliberately on demand: several remote
                # calls per domain controller. Never called on page load.
                Write-DsmtLog -Message ($session.Account + ' ran the AD health checks')
                Send-DsmtJson -Response $Response -Data (Get-DsmtAdHealth -Credential $session.Credential)
                return
            }

            '^/api/health$' {
                if ($method -ne 'GET') { break }
                Send-DsmtJson -Response $Response -Data (Get-DsmtHealth -Session $session)
                return
            }

            '^/api/settings/export$' {
                if ($method -ne 'GET') { break }

                # The whole settings store as readable JSON. Generated on
                # demand and never written back - the registry is the only
                # store, and a second one that could disagree with it is the
                # exact drift this project keeps a rule about. This exists so
                # a configuration can still be read at a glance, diffed
                # between two hosts, or pasted into a ticket.
                Send-DsmtJson -Response $Response -Data @{
                    ok          = $true
                    settingsKey = (Get-DsmtSettingsKeyPath)
                    json        = (Export-DsmtSettings)
                }
                return
            }

            '^/api/alerts$' {
                if ($method -ne 'GET') { break }

                # The polling endpoint behind the bell. Cheap on almost every
                # call: it returns the cached verdict and only runs the real
                # checks when that verdict is older than the interval. The
                # console polls this every few minutes, so "hourly" costs one
                # actual check per hour, not one per poll.
                $settings = Get-DsmtAlertSettings
                $force    = ((Get-DsmtQueryValue -Request $Request -Name 'force') -eq '1')

                if (-not $settings.Enabled -and -not $force) {
                    Send-DsmtJson -Response $Response -Data @{
                        ok      = $true
                        enabled = $false
                        alert   = (ConvertTo-DsmtAlertPayload -Cache (Invoke-DsmtScheduledHealthCheck -CacheOnly) `
                                                             -IntervalMinutes $settings.IntervalMinutes)
                    }
                    return
                }

                $cache = Invoke-DsmtScheduledHealthCheck -Credential $session.Credential `
                                                         -IntervalMinutes $settings.IntervalMinutes `
                                                         -Account $session.Account -Force:$force

                Send-DsmtJson -Response $Response -Data @{
                    ok      = $true
                    enabled = $true
                    alert   = (ConvertTo-DsmtAlertPayload -Cache $cache -IntervalMinutes $settings.IntervalMinutes)
                }
                return
            }

            '^/api/alerts/ack$' {
                if ($method -ne 'POST') { break }

                $settings = Get-DsmtAlertSettings
                $cache    = Set-DsmtHealthAcknowledged

                Send-DsmtJson -Response $Response -Data @{
                    ok    = $true
                    alert = (ConvertTo-DsmtAlertPayload -Cache $cache -IntervalMinutes $settings.IntervalMinutes)
                }
                return
            }

            '^/api/settings/alerts$' {
                if ($method -ne 'POST') { break }

                $body    = Read-DsmtBody -Request $Request
                $enabled = [bool](Get-DsmtBodyValue -Body $body -Name 'enabled' -Default $true)

                $bounds  = Get-DsmtAlertBounds
                $minutes = 0
                $raw     = Get-DsmtBodyValue -Body $body -Name 'intervalMinutes' -Default $bounds.Default
                if (-not [int]::TryParse([string]$raw, [ref] $minutes)) {
                    Send-DsmtError -Response $Response -Message 'The check interval must be a whole number of minutes.' -StatusCode 400
                    return
                }
                if ($minutes -lt $bounds.Min -or $minutes -gt $bounds.Max) {
                    Send-DsmtError -Response $Response -StatusCode 400 `
                        -Message ('The check interval must be between ' + $bounds.Min + ' and ' + $bounds.Max + ' minutes.')
                    return
                }

                $saved = Save-DsmtSavedSettings -Values @{
                    HealthAlertsEnabled  = $enabled
                    HealthAlertsInterval = $minutes
                }

                Write-DsmtAudit -Action 'Change health alerts' -Target 'AD health' -Operator $session.Account `
                                -Reason 'Console configuration change' -Result 'Success' -Category 'session' `
                                -Detail ('Enabled=' + $enabled + ', every ' + $minutes + ' minutes')

                Send-DsmtJson -Response $Response -Data @{
                    ok              = $true
                    enabled         = $enabled
                    intervalMinutes = $minutes
                    persisted       = $saved.Ok
                    persistError    = $saved.Error
                }
                return
            }

            '^/api/settings/pagesize$' {
                if ($method -ne 'POST') { break }

                $body = Read-DsmtBody -Request $Request
                $raw  = Get-DsmtBodyValue -Body $body -Name 'pageSize' -Default 0

                $size = 0
                if (-not [int]::TryParse([string]$raw, [ref] $size)) {
                    Send-DsmtError -Response $Response -Message 'The search result cap must be a whole number.' -StatusCode 400
                    return
                }

                # The ceiling is not arbitrary. Every row is an AD read plus a
                # row of DOM, and past a few thousand the browser, not the
                # directory, is what falls over. A cap that can be set to
                # "unlimited" is a cap that will one day be set to unlimited.
                $bounds = Get-DsmtPageSizeBounds
                if ($size -lt $bounds.Min -or $size -gt $bounds.Max) {
                    Send-DsmtError -Response $Response -StatusCode 400 `
                        -Message ('The search result cap must be between ' + $bounds.Min + ' and ' + $bounds.Max + '.')
                    return
                }

                $previous = $cfg.PageSize
                $script:DsmtConfig.PageSize = $size

                $saved = Save-DsmtSavedSettings -Values @{ PageSize = $size }

                Write-DsmtAudit -Action 'Change search result cap' -Target 'Console' -Operator $session.Account `
                                -Reason 'Console configuration change' -Result 'Success' -Category 'session' `
                                -Detail ('From ' + $previous + ' to ' + $size)

                Send-DsmtJson -Response $Response -Data @{
                    ok           = $true
                    pageSize     = $size
                    persisted    = $saved.Ok
                    persistError = $saved.Error
                }
                return
            }

            '^/api/audit$' {
                if ($method -ne 'GET') { break }
                $q      = Get-DsmtQueryValue -Request $Request -Name 'q'
                $filter = Get-DsmtQueryValue -Request $Request -Name 'filter' -Default 'All'
                $limit  = 500
                [int]::TryParse((Get-DsmtQueryValue -Request $Request -Name 'limit' -Default '500'), [ref] $limit) | Out-Null

                # Time window. Both bounds are optional and independent.
                $fromUtc = $null
                $toUtc   = $null
                try {
                    $fromUtc = ConvertTo-DsmtUtcOrNull -Value (Get-DsmtQueryValue -Request $Request -Name 'from') -FieldName 'from'
                    $toUtc   = ConvertTo-DsmtUtcOrNull -Value (Get-DsmtQueryValue -Request $Request -Name 'to')   -FieldName 'to'
                } catch {
                    Send-DsmtError -Response $Response -Message $_.Exception.Message -StatusCode 400
                    return
                }

                if ($null -ne $fromUtc -and $null -ne $toUtc -and $fromUtc -gt $toUtc) {
                    Send-DsmtError -Response $Response -Message 'The start of the range is after its end.' -StatusCode 400
                    return
                }

                $audit = Get-DsmtAuditEntries -Query $q -Filter $filter -Limit $limit -FromUtc $fromUtc -ToUtc $toUtc

                $fromEcho = ''
                $toEcho   = ''
                if ($null -ne $fromUtc) { $fromEcho = ([datetime]$fromUtc).ToString('o') }
                if ($null -ne $toUtc)   { $toEcho   = ([datetime]$toUtc).ToString('o') }

                Send-DsmtJson -Response $Response -Data @{
                    ok      = $true
                    items   = @($audit.entries)
                    total   = $audit.total
                    source  = $audit.source
                    from    = $fromEcho
                    to      = $toEcho
                }
                return
            }

            '^/api/actions/(?<action>[a-z-]+)$' {
                if ($method -ne 'POST') { break }

                $action  = $Matches['action']
                $body    = Read-DsmtBody -Request $Request
                $reason  = [string](Get-DsmtBodyValue -Body $body -Name 'reason')
                $targets = Get-DsmtTargetList -Body $body

                if ([string]::IsNullOrWhiteSpace($reason)) {
                    Send-DsmtError -Response $Response -Message 'A reason is required for every change.' -StatusCode 400
                    return
                }
                if ($targets.Count -eq 0) {
                    Send-DsmtError -Response $Response -Message 'No target was selected.' -StatusCode 400
                    return
                }

                switch ($action) {

                    'reset-password' {
                        $password  = [string](Get-DsmtBodyValue -Body $body -Name 'password')
                        $generated = ''
                        if ([string]::IsNullOrWhiteSpace($password)) {
                            $password  = New-DsmtPassword
                            $generated = $password
                        }
                        $mustChange = [bool](Get-DsmtBodyValue -Body $body -Name 'mustChange' -Default $true)

                        $outcome = Invoke-DsmtBulkAction -Session $session -Targets $targets -Action 'Reset password' `
                            -Reason $reason -Category 'user' -Operation {
                                param($target)
                                Reset-DsmtPassword -Credential $session.Credential -Identity $target `
                                    -NewPassword $password -MustChange $mustChange -Unlock $true
                            }

                        # Returned once, to the operator who asked for it, so they
                        # can hand it over. It is never written to the audit log.
                        $outcome.generatedPassword = $generated
                        Send-DsmtJson -Response $Response -Data $outcome
                        return
                    }

                    'unlock' {
                        $outcome = Invoke-DsmtBulkAction -Session $session -Targets $targets -Action 'Unlock account' `
                            -Reason $reason -Category 'user' -Operation {
                                param($target)
                                Unlock-DsmtAccount -Credential $session.Credential -Identity $target
                            }
                        Send-DsmtJson -Response $Response -Data $outcome
                        return
                    }

                    'set-enabled' {
                        $enabled = [bool](Get-DsmtBodyValue -Body $body -Name 'enabled' -Default $true)
                        $label   = 'Disable user'
                        if ($enabled) { $label = 'Enable user' }

                        $outcome = Invoke-DsmtBulkAction -Session $session -Targets $targets -Action $label `
                            -Reason $reason -Category 'user' -Operation {
                                param($target)
                                Set-DsmtAccountEnabled -Credential $session.Credential -Identity $target -Enabled $enabled
                            }
                        Send-DsmtJson -Response $Response -Data $outcome
                        return
                    }

                    'move-ou' {
                        $ou = [string](Get-DsmtBodyValue -Body $body -Name 'ou')
                        if ([string]::IsNullOrWhiteSpace($ou)) {
                            Send-DsmtError -Response $Response -Message 'Choose the OU to move into.' -StatusCode 400
                            return
                        }
                        $category = [string](Get-DsmtBodyValue -Body $body -Name 'type' -Default 'user')

                        $outcome = Invoke-DsmtBulkAction -Session $session -Targets $targets -Action 'Move OU' `
                            -Reason $reason -Category $category -DetailSuffix ('into ' + $ou) `
                            -DetailBuilder {
                                param($target)
                                # Read the source container before the move, so
                                # the record can be reversed afterwards.
                                $from = Get-DsmtObjectParent -Credential $session.Credential -Identity $target
                                if ([string]::IsNullOrWhiteSpace($from)) { return ('into ' + $ou) }
                                return ('from ' + $from + ' into ' + $ou)
                            } -Operation {
                                param($target)
                                Move-DsmtObject -Credential $session.Credential -Identity $target -TargetOu $ou
                            }
                        Send-DsmtJson -Response $Response -Data $outcome
                        return
                    }

                    'group-add' {
                        $group = [string](Get-DsmtBodyValue -Body $body -Name 'group')
                        if ([string]::IsNullOrWhiteSpace($group)) {
                            Send-DsmtError -Response $Response -Message 'Choose the group to add to.' -StatusCode 400
                            return
                        }

                        $outcome = Invoke-DsmtBulkAction -Session $session -Targets $targets -Action 'Add to group' `
                            -Reason $reason -Category 'group' -DetailSuffix ('into ' + $group) -Operation {
                                param($target)
                                Add-DsmtGroupMember -Credential $session.Credential -Group $group -Members @($target)
                            }
                        Send-DsmtJson -Response $Response -Data $outcome
                        return
                    }

                    'group-remove' {
                        $group = [string](Get-DsmtBodyValue -Body $body -Name 'group')
                        if ([string]::IsNullOrWhiteSpace($group)) {
                            Send-DsmtError -Response $Response -Message 'Choose the group to remove from.' -StatusCode 400
                            return
                        }

                        $outcome = Invoke-DsmtBulkAction -Session $session -Targets $targets -Action 'Remove from group' `
                            -Reason $reason -Category 'group' -DetailSuffix ('from ' + $group) -Operation {
                                param($target)
                                Remove-DsmtGroupMember -Credential $session.Credential -Group $group -Members @($target)
                            }
                        Send-DsmtJson -Response $Response -Data $outcome
                        return
                    }

                    'delete' {
                        $type = [string](Get-DsmtBodyValue -Body $body -Name 'type' -Default 'user')
                        if ($type -ne 'user' -and $type -ne 'group') { $type = 'user' }
                        $label = 'Delete user'
                        if ($type -eq 'group') { $label = 'Delete group' }

                        $outcome = Invoke-DsmtBulkAction -Session $session -Targets $targets -Action $label `
                            -Reason $reason -Category $type -Operation {
                                param($target)
                                Remove-DsmtObject -Credential $session.Credential -Identity $target -Type $type
                            }
                        Send-DsmtJson -Response $Response -Data $outcome
                        return
                    }

                    default {
                        Send-DsmtError -Response $Response -Message ('Unknown action: ' + $action) -StatusCode 404
                        return
                    }
                }
            }
        }

        Send-DsmtError -Response $Response -Message ('No API route for ' + $method + ' ' + $Path) -StatusCode 404

    } catch {
        $message = $_.Exception.Message
        Write-DsmtLog -Level 'ERROR' -Message ($method + ' ' + $Path + ' failed: ' + $message)
        Send-DsmtError -Response $Response -Message $message -StatusCode 500
    }
}

function Invoke-DsmtRequest {
    <#
    .SYNOPSIS
        Entry point for one HTTP request: API routes first, then static files,
        then the SPA fallback.
    #>
    param($Context)

    $request  = $Context.Request
    $response = $Context.Response
    $path     = $request.Url.AbsolutePath

    if ($path.StartsWith('/api/', [System.StringComparison]::OrdinalIgnoreCase)) {
        Invoke-DsmtApi -Request $request -Response $response -Path $path.TrimEnd('/')
        return
    }

    if ($path -eq '/' -or [string]::IsNullOrWhiteSpace($path)) {
        if (Send-DsmtStaticFile -Response $response -UrlPath 'index.html') { return }
    }

    if (Send-DsmtStaticFile -Response $response -UrlPath $path) { return }

    # Unknown non-API path: hand back the app shell so a refresh on a deep
    # link still lands somewhere useful.
    if (Send-DsmtStaticFile -Response $response -UrlPath 'index.html') { return }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes('Not found')
    Send-DsmtBytes -Response $response -Bytes $bytes -ContentType 'text/plain; charset=utf-8' -StatusCode 404
}
