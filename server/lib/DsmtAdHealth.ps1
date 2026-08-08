<#
.SYNOPSIS
    DSMT - health of the Active Directory service itself.
.DESCRIPTION
    Settings -> Health answers "can DSMT reach AD". This file answers a
    different and much larger question: "is AD healthy". Five checks, each
    chosen because it fails quietly:

      Replication      - the fault that goes unnoticed longest. Nothing breaks
                         visibly until a password change or a group membership
                         fails to appear on another controller.
      FSMO roles       - a role pointing at a decommissioned controller looks
                         perfectly healthy in a list. It is the list that is
                         wrong, not the domain.
      Reachability     - LDAP, LDAPS and Global Catalog, per controller. A DC
                         that answers ping and refuses 3268 breaks logons for
                         reasons nobody connects to DNS.
      Time skew        - Kerberos fails past five minutes, and the symptom
                         looks like anything except a clock.
      Replication
      failures         - the explicit failure list, when there is one.

    THREE RULES THIS FILE FOLLOWS, all learned the hard way elsewhere in this
    project:

    1. NEVER SHELL OUT TO repadmin. `repadmin /replsum` is the tool everybody
       knows, and its output is console text: localised, and reformatted
       between Windows versions. Parsing it is a bug waiting for a German
       server. Get-ADReplicationPartnerMetadata returns the same numbers as
       objects and takes -Credential, so the data is the same and the parsing
       problem disappears. The DISPLAY is laid out like replsum, because that
       is the view people know.

    2. EVERY CHECK DEGRADES TO "COULD NOT CHECK, AND WHY". These calls need
       rights the signed-in operator may not have, and controllers that may be
       unreachable. A check that cannot run must say so - never report green,
       and never take the whole page down with it. Each controller is wrapped
       individually for exactly this reason.

    3. THIS IS DIAGNOSTIC REPORTING WITH A NOTIFICATION ON TOP - NOT
       MONITORING. Until 1.21.0 this rule read "if it ever grows scheduling
       and alerting it has become a different product, and the answer at that
       point is no." It grew both, deliberately, and the rule is rewritten
       rather than quietly ignored: what it was guarding against is a product
       that claims to watch a directory nobody is looking at.

       So the line is drawn at honesty about coverage. The check is cached and
       runs on demand from an open console (see "SCHEDULED CHECKING AND THE
       BELL" below) - it does NOT run on an unattended server, and nothing in
       the UI may imply that it does. Real monitoring means a scheduled task
       with its own identity and AD read rights, and that remains a separate
       decision, not something to arrive at by degrees.

    Cost: several remote calls per domain controller. That is why nothing here
    runs on page load - see the explicit Run button in the Tools screen, and
    the interval cache that keeps the bell from turning every poll into a
    directory-wide sweep.
.NOTES
    Author  : IT Team
    Runtime : Windows PowerShell 5.1
#>

# Kerberos tolerates five minutes by default (the MaxClockSkew policy).
# Warn at half of that, so the report is useful before anything breaks.
$script:DsmtSkewWarnMinutes = 2
$script:DsmtSkewBadMinutes  = 5

# Long enough to cross a slow link, short enough that a dead controller does
# not hold the page. Applied per port, per controller.
$script:DsmtPortTimeoutMs = 2500

function Test-DsmtTcpPort {
    <#
    .SYNOPSIS
        Is a TCP port open? Used instead of Test-NetConnection, which is
        markedly slower and not present on every supported host.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $ComputerName,
        [Parameter(Mandatory = $true)][int] $Port
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne($script:DsmtPortTimeoutMs, $false)
        if (-not $ok) { return $false }

        # WaitOne returning true only means the wait ended; EndConnect is what
        # reports a refusal.
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Get-DsmtFsmoRoles {
    <#
    .SYNOPSIS
        The five FSMO role holders, and whether each one answers.
    .DESCRIPTION
        Three roles are domain-wide and come from Get-ADDomain; two are
        forest-wide and come from Get-ADForest. No extra tooling, and both
        cmdlets are already used elsewhere in this codebase.

        The holder NAME is not the useful part on its own - a role pointing at
        a controller that was decommissioned without transferring it reads as
        perfectly normal. So each holder is also probed on LDAP.
    #>
    param($Credential)

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'read'
    $roles = @()

    $domain = $null
    $forest = $null
    try { $domain = Get-ADDomain @ad -ErrorAction Stop } catch { }
    try { $forest = Get-ADForest @ad -ErrorAction Stop } catch { }

    $wanted = @()
    if ($null -ne $domain) {
        $wanted += @{ role = 'PDC Emulator';           holder = [string]$domain.PDCEmulator;          scope = 'Domain' }
        $wanted += @{ role = 'RID Master';             holder = [string]$domain.RIDMaster;            scope = 'Domain' }
        $wanted += @{ role = 'Infrastructure Master';  holder = [string]$domain.InfrastructureMaster; scope = 'Domain' }
    }
    if ($null -ne $forest) {
        $wanted += @{ role = 'Schema Master';          holder = [string]$forest.SchemaMaster;         scope = 'Forest' }
        $wanted += @{ role = 'Domain Naming Master';   holder = [string]$forest.DomainNamingMaster;   scope = 'Forest' }
    }

    foreach ($w in $wanted) {
        $answers = $false
        if (-not [string]::IsNullOrWhiteSpace($w.holder)) {
            $answers = Test-DsmtTcpPort -ComputerName $w.holder -Port 389
        }

        $status = 'ok'
        $note = ''
        if ([string]::IsNullOrWhiteSpace($w.holder)) {
            $status = 'bad'; $note = 'No holder could be read.'
        } elseif (-not $answers) {
            $status = 'bad'
            $note = 'The holder does not answer on LDAP 389. A role held by a controller that is gone blocks the operations that need it, and looks correct in every list.'
        }

        $roles += [ordered]@{
            role   = $w.role
            scope  = $w.scope
            holder = $w.holder
            status = $status
            note   = $note
        }
    }

    # NOT ",@($roles)". The comma operator protects a SINGLE-element list from
    # being unrolled, but on an EMPTY list it produces an array containing an
    # empty array - which serialises as [[]] and renders as one row of blanks
    # instead of no rows at all. Every call site here wraps in @( ) anyway,
    # which is the guard that actually matters.
    return @($roles)
}

function Get-DsmtControllerHealth {
    <#
    .SYNOPSIS
        Per controller: the ports that matter, and its clock.
    .DESCRIPTION
        Ports checked, and why each one is here rather than a generic ping:
          389  LDAP              - the directory itself
          636  LDAPS             - reported, never failed on. Plenty of
                                   healthy domains do not publish LDAPS, so a
                                   closed 636 is information, not a fault.
          3268 Global Catalog    - only expected on a controller that IS a GC,
                                   which is read from the directory rather
                                   than assumed.

        The clock comes from the controller's own RootDSE `currentTime`, which
        is an ordinary LDAP read that takes -Credential. That avoids
        w32tm and its console output entirely.
    #>
    param($Credential)

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'read'
    $dcs = @(Get-ADDomainController @ad -Filter * -ErrorAction Stop)

    $rows = @()
    $now = (Get-Date).ToUniversalTime()

    foreach ($dc in $dcs) {
        $name = [string]$dc.HostName
        $isGc = [bool]$dc.IsGlobalCatalog

        $ldap  = Test-DsmtTcpPort -ComputerName $name -Port 389
        $ldaps = Test-DsmtTcpPort -ComputerName $name -Port 636
        $gc    = $false
        if ($isGc) { $gc = Test-DsmtTcpPort -ComputerName $name -Port 3268 }

        # Clock. A controller that does not answer LDAP cannot be asked, and
        # saying "skew unknown" is honest where reporting 0 would not be.
        $skew = $null
        $skewError = ''
        if ($ldap) {
            try {
                $rootDse = Get-ADRootDSE -Server $name -Credential $Credential -ErrorAction Stop

                # currentTime comes back in one of two shapes and the code has
                # to handle both. Get-ADRootDSE usually converts it to a real
                # DateTime; a raw LDAP read leaves it as generalized time,
                # yyyyMMddHHmmss.0Z.
                #
                # 1.17.0 assumed the string form and cast with [string] first,
                # which on the DateTime form produces a CULTURE-FORMATTED date
                # like "08/07/2026 19:28:10". Slicing 14 characters off that
                # gives "08/07/2026 19:", and ParseExact rightly refuses it -
                # which is the "String was not recognized as a valid DateTime"
                # in the clock column.
                $value  = $rootDse.currentTime
                $dcTime = $null

                if ($value -is [datetime]) {
                    $dcTime = ([datetime]$value).ToUniversalTime()
                } else {
                    $raw = [string]$value
                    if ($raw.Length -ge 14) {
                        $dcTime = [datetime]::ParseExact($raw.Substring(0, 14), 'yyyyMMddHHmmss',
                                      [System.Globalization.CultureInfo]::InvariantCulture,
                                      ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor
                                       [System.Globalization.DateTimeStyles]::AdjustToUniversal))
                    } else {
                        throw ('currentTime was not a time this code understands: "' + $raw + '"')
                    }
                }

                $skew = [math]::Round((New-TimeSpan -Start $dcTime -End $now).TotalMinutes, 1)
            } catch {
                $skewError = $_.Exception.Message
            }
        }

        $status = 'ok'
        $notes = @()

        if (-not $ldap) {
            $status = 'bad'
            $notes += 'LDAP 389 is not answering. This controller cannot serve the directory.'
        }
        if ($isGc -and -not $gc) {
            $status = 'bad'
            $notes += 'Advertised as a Global Catalog but 3268 is closed. Logons that need a GC will fail here for reasons that look nothing like DNS.'
        }
        if (-not $ldaps) {
            $notes += 'LDAPS 636 is closed. Normal unless this domain issues controller certificates.'
        }

        if ($null -ne $skew) {
            $abs = [math]::Abs($skew)
            if ($abs -ge $script:DsmtSkewBadMinutes) {
                $status = 'bad'
                $notes += ('Clock is ' + [string]$skew + ' minutes from this host. Kerberos rejects past ' + [string]$script:DsmtSkewBadMinutes + ' minutes, and the symptom never mentions time.')
            } elseif ($abs -ge $script:DsmtSkewWarnMinutes) {
                if ($status -eq 'ok') { $status = 'warn' }
                $notes += ('Clock is ' + [string]$skew + ' minutes from this host - within tolerance, but drifting.')
            }
        } elseif ($ldap) {
            if ($status -eq 'ok') { $status = 'warn' }
            $notes += ('The clock could not be read: ' + $skewError)
        }

        $rows += [ordered]@{
            name    = $name
            site    = [string]$dc.Site
            os      = [string]$dc.OperatingSystem
            isGc    = $isGc
            ldap    = $ldap
            ldaps   = $ldaps
            gc      = $gc
            skew    = $skew
            status  = $status
            note    = ($notes -join ' ')
        }
    }

    return @($rows)
}

function Get-DsmtReplicationSummary {
    <#
    .SYNOPSIS
        The replsum view, from objects rather than from parsed console text.
    .DESCRIPTION
        One row per controller: the largest gap since a successful inbound
        replication, and the worst consecutive-failure count across its
        partners. Sorted worst first, which is the only order anyone reads
        this in.

        Get-ADReplicationPartnerMetadata is queried PER CONTROLLER and each
        call is wrapped: one unreachable controller must report itself and
        leave the rest of the report intact.
    #>
    param($Credential)

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'read'
    $dcs = @(Get-ADDomainController @ad -Filter * -ErrorAction Stop)

    $rows = @()
    $now = (Get-Date)

    foreach ($dc in $dcs) {
        $name = [string]$dc.HostName

        $row = [ordered]@{
            name          = $name
            partners      = 0
            worstFailures = 0
            largestGapMin = $null
            lastSuccess   = ''
            status        = 'ok'
            note          = ''
        }

        try {
            $meta = @(Get-ADReplicationPartnerMetadata -Target $name -Scope Server -Credential $Credential -ErrorAction Stop)
            $row.partners = $meta.Count

            if ($meta.Count -eq 0) {
                # A single-controller domain is the normal reason, and it is
                # not a fault - say which it is rather than showing a zero.
                $row.note = 'No replication partners. Normal in a single-controller domain.'
            }

            $worst = 0
            $newestSuccess = $null

            foreach ($m in $meta) {
                $failures = 0
                if ($null -ne $m.ConsecutiveReplicationFailures) { $failures = [int]$m.ConsecutiveReplicationFailures }
                if ($failures -gt $worst) { $worst = $failures }

                $success = $m.LastReplicationSuccess
                if ($null -ne $success) {
                    if ($null -eq $newestSuccess -or $success -gt $newestSuccess) { $newestSuccess = $success }
                }
            }

            $row.worstFailures = $worst

            if ($null -ne $newestSuccess) {
                $row.lastSuccess = ([datetime]$newestSuccess).ToString('yyyy-MM-dd HH:mm')
                $row.largestGapMin = [int][math]::Round((New-TimeSpan -Start ([datetime]$newestSuccess) -End $now).TotalMinutes)
            }

            if ($worst -gt 0) {
                $row.status = 'bad'
                $row.note = ([string]$worst + ' consecutive failure(s) with at least one partner.')
            } elseif ($null -ne $row.largestGapMin -and $row.largestGapMin -gt 180) {
                $row.status = 'warn'
                $row.note = 'No successful inbound replication for over three hours.'
            }

        } catch {
            # Cannot check is its own state. Not green, and not a red that
            # blames replication for what is a rights or reachability problem.
            $row.status = 'warn'
            $row.note = ('Could not read replication metadata: ' + $_.Exception.Message)
        }

        $rows += $row
    }

    # Worst first: failures, then the longest gap.
    $sorted = @($rows | Sort-Object -Property @{ Expression = { $_.worstFailures }; Descending = $true },
                                              @{ Expression = { if ($null -eq $_.largestGapMin) { -1 } else { $_.largestGapMin } }; Descending = $true })
    return @($sorted)
}

function Get-DsmtReplicationFailures {
    <#
    .SYNOPSIS
        The explicit failure list, when AD is keeping one.
    #>
    param($Credential)

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'read'
    $rows = @()

    try {
        $dcs = @(Get-ADDomainController @ad -Filter * -ErrorAction Stop)
    } catch {
        return @($rows)
    }

    foreach ($dc in $dcs) {
        $name = [string]$dc.HostName
        try {
            $failures = @(Get-ADReplicationFailure -Target $name -Credential $Credential -ErrorAction Stop)
            foreach ($f in $failures) {
                $rows += [ordered]@{
                    server     = $name
                    partner    = [string]$f.Partner
                    count      = [int]$f.FailureCount
                    firstAt    = ConvertTo-DsmtDisplayTime -Value $f.FirstFailureTime
                    reason     = [string]$f.LastError
                }
            }
        } catch { }
    }

    return @($rows)
}

function Get-DsmtAdHealth {
    <#
    .SYNOPSIS
        Everything above, in one call, with an overall verdict.
    .DESCRIPTION
        The overall result is the WORST individual result. A page that
        averages its checks into a comfortable green is worse than no page.
    #>
    param($Credential)

    $result = @{
        ok          = $true
        error       = ''
        checkedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        overall     = 'ok'
        fsmo        = @()
        controllers = @()
        replication = @()
        failures    = @()
        skewWarn    = $script:DsmtSkewWarnMinutes
        skewBad     = $script:DsmtSkewBadMinutes
    }

    # Each section reports its own failure. A section that cannot be produced
    # must say why - a silently empty card reads as "there is nothing wrong
    # here", which is the opposite of the truth.
    $problems = @()

    try   { $result.fsmo = @(Get-DsmtFsmoRoles -Credential $Credential) }
    catch { $problems += ('FSMO roles: ' + $_.Exception.Message) }

    try   { $result.controllers = @(Get-DsmtControllerHealth -Credential $Credential) }
    catch { $problems += ('Domain controllers: ' + $_.Exception.Message) }

    try   { $result.replication = @(Get-DsmtReplicationSummary -Credential $Credential) }
    catch { $problems += ('Replication: ' + $_.Exception.Message) }

    try   { $result.failures = @(Get-DsmtReplicationFailures -Credential $Credential) }
    catch { $problems += ('Replication failures: ' + $_.Exception.Message) }

    if (@($result.fsmo).Count -eq 0 -and $problems.Count -eq 0) {
        $problems += 'The FSMO role holders came back empty. Get-ADDomain and Get-ADForest both returned nothing, which usually means the operator cannot read the forest configuration.'
    }
    if (@($result.controllers).Count -eq 0 -and $problems.Count -eq 0) {
        $problems += 'No domain controllers were returned by Get-ADDomainController.'
    }

    if ($problems.Count -gt 0) { $result.error = ($problems -join '  |  ') }

    $worst = 'ok'
    foreach ($set in @($result.fsmo, $result.controllers, $result.replication)) {
        foreach ($item in @($set)) {
            if ($item.status -eq 'bad') { $worst = 'bad' }
            elseif ($item.status -eq 'warn' -and $worst -eq 'ok') { $worst = 'warn' }
        }
    }
    if (@($result.failures).Count -gt 0) { $worst = 'bad' }

    $result.overall = $worst
    return $result
}

# ---------------------------------------------------------------------------
# SCHEDULED CHECKING AND THE BELL
#
# WHAT "EVERY HOUR" HONESTLY MEANS HERE, because it is not a background timer
# and pretending otherwise would be the worst kind of feature.
#
# The server is a single-threaded System.Net.HttpListener loop: it blocks on
# GetContext() until a request arrives, so there is no thread free to fire a
# timer, and adding one would mean either a runspace or holding an operator's
# credentials for unattended use - and using a stored credential to read AD on
# a schedule is exactly the design decision CLAUDE.md records as deliberately
# NOT taken (see "Attempted and deliberately NOT pursued", item 1).
#
# So the check is CACHED AND DEMAND-DRIVEN. An open console asks for the alert
# state every few minutes; when the cached result is older than the configured
# interval, that request runs a fresh check as the operator who asked, and
# everyone sees the answer. In practice: while anyone has DSMT open, the
# directory is checked once an hour. While nobody does, it is not - and there
# is no bell for nobody to look at either.
#
# The one thing this does NOT do is alert an unattended machine. If that is
# wanted it needs a scheduled task with its own service identity and AD read
# rights, which is a separate decision, not a quiet side effect of this file.
# ---------------------------------------------------------------------------

# The interval bounds live in DsmtCommon.ps1 with the other bounds - see
# Get-DsmtAlertBounds below, which reads them.

# Last result, shared by every session. Empty CheckedUtc means "never run".
$script:DsmtAdHealthCache = @{
    CheckedUtc   = $null
    Overall      = 'unknown'
    Problems     = @()
    Signature    = ''
    Error        = ''
    RanBy        = ''
    AckSignature = ''
    AckUtc       = $null
}

function Get-DsmtAlertBounds {
    return @{
        Default = $script:DsmtAlertIntervalDefault
        Min     = $script:DsmtAlertIntervalMin
        Max     = $script:DsmtAlertIntervalMax
    }
}

function Get-DsmtHealthProblems {
    <#
    .SYNOPSIS
        Reduces a full health result to the short lines the bell shows.
    .DESCRIPTION
        One line per thing actually wrong, each naming the object and the
        reason. A count on its own ("3 problems") tells an operator to go
        looking; the point of the bell is to tell them what to look at.
    #>
    param([Parameter(Mandatory = $true)] $Health)

    $lines = New-Object System.Collections.Generic.List[string]

    # The field names below are the ones the rows in this file actually carry -
    # 'note', 'role', 'server'/'partner'/'reason' - not a generic name/detail
    # pair. Reading a property that does not exist yields $null in PowerShell
    # rather than an error, so a mismatch here would produce alert lines that
    # are silently blank after the colon.
    foreach ($dc in @($Health.controllers)) {
        if ($null -eq $dc) { continue }
        if ($dc.status -eq 'ok') { continue }
        $why = [string]$dc.note
        if ([string]::IsNullOrWhiteSpace($why)) { $why = 'not healthy' }
        $lines.Add(([string]$dc.name) + ': ' + $why)
    }

    foreach ($rep in @($Health.replication)) {
        if ($null -eq $rep) { continue }
        if ($rep.status -eq 'ok') { continue }
        $why = [string]$rep.note
        if ([string]::IsNullOrWhiteSpace($why)) { $why = 'replication is behind' }
        $lines.Add('Replication on ' + ([string]$rep.name) + ': ' + $why)
    }

    foreach ($fail in @($Health.failures)) {
        if ($null -eq $fail) { continue }
        $lines.Add('Replication failure: ' + ([string]$fail.server) + ' -> ' + ([string]$fail.partner) +
                   ' (' + [string]$fail.count + ' failures) ' + ([string]$fail.reason))
    }

    foreach ($role in @($Health.fsmo)) {
        if ($null -eq $role) { continue }
        if ($role.status -eq 'ok') { continue }
        $lines.Add('FSMO ' + ([string]$role.role) + ': ' + ([string]$role.note))
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Health.error)) {
        $lines.Add('The check itself could not complete: ' + [string]$Health.error)
    }

    # Empty is a normal outcome here - a healthy directory produces no lines -
    # so @() and not ,@(); see CLAUDE.md on one-element collections.
    return @($lines)
}

function Get-DsmtProblemSignature {
    <#
    .SYNOPSIS
        A stable fingerprint of the current problem set.
    .DESCRIPTION
        This is what makes "acknowledged" mean something. Acknowledging by
        timestamp would silence a NEW fault that appeared a minute later;
        acknowledging the exact set of problems means the bell goes quiet for
        what was read and lights up again the moment the set changes.
    #>
    param([string[]] $Problems)

    $joined = (@($Problems) -join "`n")
    if ([string]::IsNullOrEmpty($joined)) { return '' }

    $sha   = New-Object System.Security.Cryptography.SHA256Managed
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
    $hash  = $sha.ComputeHash($bytes)
    $sha.Dispose()

    return ([System.BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 16)
}

function Invoke-DsmtScheduledHealthCheck {
    <#
    .SYNOPSIS
        Returns the cached AD health verdict, refreshing it when it is older
        than the configured interval.
    .OUTPUTS
        The cache hashtable. -Force runs regardless of age (the Refresh
        button); -CacheOnly never runs a check, for callers that only want to
        report what is already known.
    #>
    param(
        $Credential,
        [int] $IntervalMinutes = 0,
        [string] $Account = '',
        [switch] $Force,
        [switch] $CacheOnly
    )

    if ($IntervalMinutes -le 0) { $IntervalMinutes = $script:DsmtAlertIntervalDefault }

    $cache = $script:DsmtAdHealthCache
    $now   = (Get-Date).ToUniversalTime()

    $stale = $true
    if ($null -ne $cache.CheckedUtc) {
        $age = ($now - $cache.CheckedUtc).TotalMinutes
        if ($age -lt $IntervalMinutes) { $stale = $false }
    }

    if ($CacheOnly) { return $cache }
    if (-not $stale -and -not $Force) { return $cache }

    try {
        $health   = Get-DsmtAdHealth -Credential $Credential
        $problems = @(Get-DsmtHealthProblems -Health $health)

        $cache.CheckedUtc = $now
        $cache.Overall    = [string]$health.overall
        $cache.Problems   = $problems
        $cache.Signature  = Get-DsmtProblemSignature -Problems $problems
        $cache.Error      = [string]$health.error
        $cache.RanBy      = $Account

        if ($problems.Count -gt 0) {
            Write-DsmtLog -Level 'WARN' -Message ('AD health check: ' + $problems.Count + ' problem(s) - ' + ($problems -join ' | '))
        } else {
            Write-DsmtLog -Message 'AD health check: no problems found.'
        }
    } catch {
        # A check that cannot run is itself worth a bell: silence here would
        # read as "everything is fine" for as long as the failure lasts.
        $cache.CheckedUtc = $now
        $cache.Overall    = 'bad'
        $cache.Problems   = @('The scheduled AD health check could not run: ' + $_.Exception.Message)
        $cache.Signature  = Get-DsmtProblemSignature -Problems $cache.Problems
        $cache.Error      = $_.Exception.Message
        $cache.RanBy      = $Account
        Write-DsmtLog -Level 'ERROR' -Message ('AD health check failed: ' + $_.Exception.Message)
    }

    return $script:DsmtAdHealthCache
}

function Set-DsmtHealthAcknowledged {
    <#
    .SYNOPSIS
        Marks the problem set currently in the cache as seen, which is what
        clears the bell's badge. A new or changed problem re-raises it.
    #>
    $script:DsmtAdHealthCache.AckSignature = $script:DsmtAdHealthCache.Signature
    $script:DsmtAdHealthCache.AckUtc       = (Get-Date).ToUniversalTime()
    return $script:DsmtAdHealthCache
}

function ConvertTo-DsmtAlertPayload {
    <#
    .SYNOPSIS
        The shape the bell reads. Kept in one place so the console and the
        server cannot disagree about what "unread" means.
    #>
    param([Parameter(Mandatory = $true)] $Cache, [int] $IntervalMinutes = 0)

    if ($IntervalMinutes -le 0) { $IntervalMinutes = $script:DsmtAlertIntervalDefault }

    $problems = @($Cache.Problems)

    $checked = ''
    if ($null -ne $Cache.CheckedUtc) { $checked = $Cache.CheckedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') }

    # Unread = there is something wrong AND this exact set has not been
    # acknowledged. An empty signature (nothing wrong) is never unread.
    $unread = $false
    if ($problems.Count -gt 0 -and $Cache.Signature -ne $Cache.AckSignature) { $unread = $true }

    return @{
        overall         = [string]$Cache.Overall
        problems        = $problems
        count           = $problems.Count
        unread          = $unread
        checkedUtc      = $checked
        ranBy           = [string]$Cache.RanBy
        intervalMinutes = $IntervalMinutes
    }
}
