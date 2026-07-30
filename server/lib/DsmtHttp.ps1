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

    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::RoundtripKind -bor [System.Globalization.DateTimeStyles]::AssumeLocal
    $ok = [datetime]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref] $parsed)

    if (-not $ok) {
        throw ('"' + $FieldName + '" is not a valid date/time: ' + $Value)
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
        [string] $DetailSuffix = ''
    )

    $controller = ''
    try { $controller = Get-DsmtServer -Credential $Session.Credential } catch { }

    $results = @()
    $okCount = 0

    foreach ($target in $Targets) {
        try {
            # Out-Null matters: anything the operation emits would otherwise
            # join this function's output stream and turn the returned result
            # object into an array.
            & $Operation $target | Out-Null
            $okCount++
            $results += [ordered]@{ target = $target; ok = $true; error = '' }
            Write-DsmtAudit -Action $Action -Target $target -Operator $Session.Account -Reason $Reason `
                            -Result 'Success' -Category $Category -Controller $controller -Detail $DetailSuffix
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
            ok      = $true
            version = $cfg.Version
            domain  = $cfg.Domain
            product = 'DSMT - Directory Service Management Tool'
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
            ok      = $true
            token   = $created.Token
            version = $cfg.Version
            user    = @{ sam = $session.Sam; display = $session.Display; account = $session.Account; upn = $session.Upn }
        }
        return
    }

    # ---- Everything below needs a session -------------------------------
    $session = Get-DsmtRequestSession -Request $Request
    if ($null -eq $session) {
        Send-DsmtError -Response $Response -Message 'Your session has expired. Sign in again.' -StatusCode 401
        return
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
            ok      = $true
            version = $cfg.Version
            user    = @{ sam = $session.Sam; display = $session.Display; account = $session.Account; upn = $session.Upn }
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
                        domain        = $cfg.Domain
                        server        = $cfg.Server
                        port          = $cfg.Port
                        listenAddress = $cfg.ListenAddress
                        sessionHours  = $cfg.SessionHours
                        pageSize      = $cfg.PageSize
                        dataPath      = $cfg.DataPath
                        sqlEnabled    = $sql.Enabled
                        sqlServer     = $sql.Server
                        sqlDatabase   = $sql.Database
                        sqlError      = $sql.LastError
                    }
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

                if ([string]::IsNullOrWhiteSpace($server)) {
                    Send-DsmtError -Response $Response -Message 'Enter the SQL Server instance to connect to.' -StatusCode 400
                    return
                }
                if ([string]::IsNullOrWhiteSpace($database)) { $database = 'DSMT' }

                Write-DsmtLog -Message ($session.Account + ' is configuring SQL storage: ' + $server + ' [' + $database + ']')

                $init = Initialize-DsmtSql -Server $server -Database $database -Username $user -Password $pass
                if (-not $init.Ok) {
                    Write-DsmtAudit -Action 'Configure SQL storage' -Target ($server + ' [' + $database + ']') `
                                    -Operator $session.Account -Reason 'Console configuration change' `
                                    -Result 'Failed' -Category 'session' -Detail $init.Error
                    Send-DsmtError -Response $Response -Message $init.Error -StatusCode 400
                    return
                }

                # Persist it so the database survives a restart of the server.
                $saved = Save-DsmtSavedSettings -RootPath $cfg.RootPath -Values @{
                    SqlServer   = $server
                    SqlDatabase = $database
                }

                Write-DsmtAudit -Action 'Configure SQL storage' -Target ($server + ' [' + $database + ']') `
                                -Operator $session.Account -Reason 'Console configuration change' `
                                -Result 'Success' -Category 'session' `
                                -Detail 'Database and tables verified'

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
                    $limit = 0
                    [int]::TryParse((Get-DsmtQueryValue -Request $Request -Name 'limit' -Default '0'), [ref] $limit) | Out-Null
                    $rows  = Get-DsmtGroups -Credential $session.Credential -Query $q -Limit $limit
                    Sync-DsmtGroupsToSql -Groups $rows | Out-Null
                    Send-DsmtJson -Response $Response -Data @{ ok = $true; items = @($rows); count = @($rows).Count; limit = $cfg.PageSize }
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
                            -Reason $reason -Category $category -DetailSuffix ('into ' + $ou) -Operation {
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
