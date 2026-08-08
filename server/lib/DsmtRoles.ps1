# ---------------------------------------------------------------------------
# DsmtRoles.ps1 - who may change DSMT's OWN settings.
#
# READ THIS BEFORE EXTENDING IT. The scope is deliberately narrow and the
# reason is a decision recorded in CLAUDE.md: DSMT has no permission model of
# its own. Every directory read and write runs as the signed-in operator, so
# Active Directory is the authority on what they may do.
#
# That decision is NOT overturned here, and the distinction is the whole
# design:
#
#   * For DIRECTORY operations a role could only ever SUBTRACT. Putting
#     someone in "DSMT Admins" cannot give them rights AD has not granted -
#     the write still runs as them and still fails. And a read-only role
#     would constrain THIS CONSOLE, not the person: the same operator can
#     open ADUC or a PowerShell prompt and do whatever AD permits. Presenting
#     that as a security control would be presenting a lie. So this module
#     does not touch directory routes at all.
#
#   * For DSMT'S OWN SETTINGS a role has real teeth, because nothing in AD
#     governs them. Who may repoint the console at a different database,
#     change the identity mode, change the idle timeout, or create the forest
#     KDS root key - these are application decisions with no AD equivalent,
#     and until now any operator who could sign in could make all of them.
#     THAT is the gap this closes, and it is the whole feature.
#
# FAIL OPEN, ON PURPOSE
# With no groups configured, every operator is an administrator - exactly the
# behaviour before this existed. An upgrade must not lock everyone out of
# their own console. The one case that fails CLOSED is a mapping that IS
# configured while the operator's group membership cannot be read: granting
# admin because a lookup failed is not detectable, whereas being locked out is
# obvious and recoverable at the registry key named in the error.
# ---------------------------------------------------------------------------

# Structured setting - a list, stored as JSON text. It is registered in
# $script:DsmtJsonSettings in DsmtCommon.ps1; without that it round-trips as
# the literal string "@{...}" and renders as data with no error.
$script:DsmtRoleSettingName = 'RoleAdminGroups'

# Routes that change DSMT's own configuration. Matched against the request
# path, and only for the methods listed - a GET that merely displays state is
# not gated, because hiding the current port from a non-admin helps nobody.
#
# This is a CENTRAL list checked at one choke point rather than a test
# sprinkled through each handler. A role enforced route-by-route is a role
# that is missing from the route somebody adds next week.
$script:DsmtAdminOnlyRoutes = @(
    @{ Pattern = '^/api/settings/session$';      Methods = @('POST') },
    @{ Pattern = '^/api/settings/network$';      Methods = @('POST') },
    @{ Pattern = '^/api/settings/https$';        Methods = @('POST') },
    @{ Pattern = '^/api/settings/identity$';     Methods = @('POST') },
    @{ Pattern = '^/api/settings/sql$';          Methods = @('POST') },
    @{ Pattern = '^/api/settings/groupfilters$'; Methods = @('POST') },
    @{ Pattern = '^/api/settings/alerts$';       Methods = @('POST') },
    @{ Pattern = '^/api/settings/pagesize$';     Methods = @('POST') },
    @{ Pattern = '^/api/settings/roles$';        Methods = @('POST') },

    # The settings export is a READ, and it is gated anyway: it hands back the
    # whole configuration store, including the SQL instance and database
    # names. That is reconnaissance, not display.
    @{ Pattern = '^/api/settings/export$';       Methods = @('GET') },

    # Creating the forest KDS root key is a one-way, forest-wide act. AD does
    # gate it (it needs Enterprise Admin), so this is belt and braces rather
    # than the only control - but it is named in the feature request and it
    # costs nothing.
    @{ Pattern = '^/api/tools/gmsa/kds$';        Methods = @('POST') }
)

function Get-DsmtRoleGroups {
    <#
    .SYNOPSIS
        The configured administrator groups.
    .OUTPUTS
        An array of hashtables with Sid and Name. Empty means "not
        configured", which means everyone is an administrator.
    .DESCRIPTION
        Returns @($list) and not ,@($list): empty is the normal, shipped
        default, and the comma operator on an empty list serialises as [[]] -
        one row of blanks in the UI. Every call site wraps in @().
    #>
    $out = @()

    $saved = Get-DsmtSavedSettings
    if ($null -eq $saved) { return @($out) }

    $prop = $saved.PSObject.Properties[$script:DsmtRoleSettingName]
    if ($null -eq $prop) { return @($out) }
    if ($null -eq $prop.Value) { return @($out) }

    foreach ($row in @($prop.Value)) {
        if ($null -eq $row) { continue }

        $sid  = ''
        $name = ''
        try { $sid  = [string]$row.Sid }  catch { $sid  = '' }
        try { $name = [string]$row.Name } catch { $name = '' }

        if ([string]::IsNullOrWhiteSpace($sid)) { continue }
        $out += @{ Sid = $sid.Trim(); Name = $name }
    }

    return @($out)
}

function Resolve-DsmtGroupSid {
    <#
    .SYNOPSIS
        Turns a group the operator typed into the SID that will be stored.
    .OUTPUTS
        Hashtable with Ok, Sid, Name, Error.
    .DESCRIPTION
        THE SID IS THE STORED VALUE, NEVER THE NAME. A group called
        "DSMT Admins" can be renamed, and built-in groups are localised on a
        non-English install - a mapping matched on name is a mapping that
        silently grants nobody anything on exactly the day it matters. The
        name is kept alongside it for display only, and is re-read rather than
        trusted.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Identity,
        [Parameter(Mandatory = $true)] $Credential
    )

    $out = @{ Ok = $false; Sid = ''; Name = ''; Error = '' }

    $name = $Identity.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        $out.Error = 'Enter a group name.'
        return $out
    }

    # Accept DOMAIN\Group as well as a bare name.
    if ($name -match '^(?<dom>[^\\]+)\\(?<grp>.+)$') { $name = $Matches['grp'] }

    $group = $null
    try {
        $ad = Get-DsmtAdParams -Credential $Credential -Intent 'read'
        $group = Get-ADGroup @ad -Identity $name -ErrorAction Stop
    } catch {
        $out.Error = 'No group called "' + $name + '" was found in ' + (Get-DsmtConfig).Domain + '.'
        return $out
    }

    # Computed outside the return literal - a cast that throws inside a
    # hashtable literal loses the whole object, not one field.
    $sid = ''
    try { $sid = [string]$group.SID.Value } catch { $sid = '' }
    if ([string]::IsNullOrWhiteSpace($sid)) {
        $out.Error = 'That group was found but has no readable SID.'
        return $out
    }

    $out.Ok   = $true
    $out.Sid  = $sid
    $out.Name = [string]$group.Name
    return $out
}

function Get-DsmtOperatorGroupSids {
    <#
    .SYNOPSIS
        Every group SID the operator carries, including nested membership.
    .OUTPUTS
        Hashtable with Ok, Sids, Error.
    .DESCRIPTION
        Reads the constructed attribute tokenGroups rather than memberOf.
        memberOf lists DIRECT membership only, so an operator who is an
        administrator through a nested group - which is how most real
        directories are arranged - would not be recognised. tokenGroups is
        what the domain controller itself computes, and it includes nested
        groups and the primary group.

        TWO STEPS, AND THE SECOND ONE IS THE WHOLE POINT.

        tokenGroups is CONSTRUCTED: the DC computes it per request, and it can
        only be retrieved by a BASE-SCOPE search bound to that one object.
        Asking for it any other way fails with

            The requested search operation is only supported for base searches

        which is exactly what 1.26.1 did in the lab. The first version passed
        -Identity <samAccountName> to Get-ADUser; a non-DN identity makes the
        AD module run a SUBTREE search to find the object, and requesting
        tokenGroups in a subtree search is the unsupported case.

        So: resolve the account to its distinguishedName with an ordinary
        search first, then read tokenGroups with an explicit
        -SearchScope Base bound to that DN. -SearchScope Base is stated
        outright rather than relying on "-Identity with a DN happens to bind
        directly", because that is an implementation detail and this is the
        one attribute where getting the scope wrong fails outright.

        HOW BADLY THIS FAILED, so nobody weakens the guard that caught it:
        with no admin groups configured the role check short-circuits and
        never calls this, so everything looked fine. The moment a group was
        configured, EVERY sign-in would have failed this lookup and every
        operator would have been locked out of Settings - recoverable only
        with regedit on the host. The "refuse to save a list you are not a
        member of" check is what caught it, because it runs this lookup
        BEFORE writing anything. That guard earned its place; do not remove it.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $SamAccountName,
        [Parameter(Mandatory = $true)] $Credential
    )

    $out = @{ Ok = $false; Sids = @(); Error = '' }

    try {
        $ad = Get-DsmtAdParams -Credential $Credential -Intent 'read'

        # Step 1 - find the object. An ordinary search, no constructed
        # attributes, so scope does not matter here.
        $me = Get-ADUser @ad -Identity $SamAccountName -Properties 'distinguishedName' -ErrorAction Stop
        $dn = [string]$me.distinguishedName
        if ([string]::IsNullOrWhiteSpace($dn)) {
            $out.Error = 'The account ' + $SamAccountName + ' has no readable distinguishedName.'
            return $out
        }

        # Step 2 - base-scope read of the constructed attribute.
        $obj = Get-ADObject @ad -SearchBase $dn -SearchScope Base -LDAPFilter '(objectClass=*)' `
                           -Properties 'tokenGroups' -ErrorAction Stop

        $sids = @()
        foreach ($t in @($obj.tokenGroups)) {
            $v = ''
            try { $v = [string]$t.Value } catch { $v = [string]$t }
            if (-not [string]::IsNullOrWhiteSpace($v)) { $sids += $v }
        }

        # An empty tokenGroups is not a normal answer - every account is at
        # least in Domain Users. Treating it as "member of nothing" would
        # silently deny a real administrator, so it is reported as a failure.
        if ($sids.Count -eq 0) {
            $out.Error = 'tokenGroups came back empty for ' + $SamAccountName +
                         ', which should not happen - every account is at least in Domain Users.'
            return $out
        }

        $out.Ok   = $true
        $out.Sids = @($sids)
    } catch {
        $out.Error = $_.Exception.Message
    }

    return $out
}

function Resolve-DsmtOperatorRole {
    <#
    .SYNOPSIS
        Decides whether this operator administers DSMT's settings. Called once
        at sign-in and cached on the session.
    .OUTPUTS
        Hashtable with IsAdmin, Reason, Configured, Error.
    .DESCRIPTION
        Resolved at sign-in and not re-checked per request, which is a real
        tradeoff stated plainly: removing someone from the admin group takes
        effect at their next sign-in, not immediately. Re-reading tokenGroups
        on every request would put a directory round-trip in front of every
        settings write, and the idle timeout already bounds how long a stale
        session lives.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $SamAccountName,
        [Parameter(Mandatory = $true)] $Credential
    )

    $groups = @(Get-DsmtRoleGroups)

    # Not configured: everyone administers, exactly as before this existed.
    if ($groups.Count -eq 0) {
        return @{
            IsAdmin    = $true
            Configured = $false
            Reason     = 'No administrator groups are configured, so every operator can change DSMT settings.'
            Error      = ''
        }
    }

    $token = Get-DsmtOperatorGroupSids -SamAccountName $SamAccountName -Credential $Credential
    if (-not $token.Ok) {
        # Fail CLOSED - see the header. Being locked out is obvious and
        # recoverable; being wrongly granted admin is neither.
        Write-DsmtLog -Level 'WARN' -Message ('Could not read group membership for ' + $SamAccountName +
                                              ', so DSMT settings are denied for this session: ' + $token.Error)
        return @{
            IsAdmin    = $false
            Configured = $true
            Reason     = 'Your group membership could not be read, so changing DSMT settings is denied for ' +
                         'this session. ' + $token.Error
            Error      = $token.Error
        }
    }

    $matched = ''
    foreach ($g in $groups) {
        foreach ($s in @($token.Sids)) {
            if ($s -eq $g.Sid) {
                $matched = $g.Name
                if ([string]::IsNullOrWhiteSpace($matched)) { $matched = $g.Sid }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($matched)) {
        return @{
            IsAdmin    = $true
            Configured = $true
            Reason     = 'You administer DSMT settings through the group "' + $matched + '".'
            Error      = ''
        }
    }

    return @{
        IsAdmin    = $false
        Configured = $true
        Reason     = 'You are not a member of any group allowed to change DSMT settings. Directory ' +
                     'operations are unaffected - those are decided by Active Directory, not by DSMT.'
        Error      = ''
    }
}

function Test-DsmtRouteNeedsAdmin {
    <#
    .SYNOPSIS
        True when this path and method change DSMT's own configuration.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Method
    )

    foreach ($route in $script:DsmtAdminOnlyRoutes) {
        if ($Path -match $route.Pattern) {
            foreach ($m in @($route.Methods)) {
                if ($m -eq $Method) { return $true }
            }
        }
    }
    return $false
}

function Get-DsmtRoleState {
    <#
    .SYNOPSIS
        What the Settings screen shows about roles.
    .DESCRIPTION
        Reports the configured groups AND whether each still resolves in the
        directory. A mapping naming a group that has been deleted looks
        perfectly healthy in a list and grants nobody anything - which is the
        same class of silent-wrong-answer this project has a whole section
        about.
    #>
    param($Credential)

    $groups = @(Get-DsmtRoleGroups)
    $rows   = @()

    foreach ($g in $groups) {
        $present = $false
        $name    = $g.Name
        $ouPath  = ''

        if ($null -ne $Credential) {
            try {
                $ad  = Get-DsmtAdParams -Credential $Credential -Intent 'read'
                $obj = Get-ADGroup @ad -Identity $g.Sid -ErrorAction Stop
                $present = $true
                $name    = [string]$obj.Name
                $ouPath  = ConvertFrom-DsmtDn -DistinguishedName ([string]$obj.distinguishedName)
            } catch {
                $present = $false
            }
        }

        $rows += [ordered]@{
            sid     = $g.Sid
            name    = $name
            ou      = $ouPath
            present = $present
        }
    }

    # Which DC answered. Group membership read from one controller can lag
    # a change made on another until replication catches up, and that shows up
    # as "I removed them from the group and DSMT still says they are in it" -
    # which looks exactly like a bug in this code. Naming the controller turns
    # that into something the operator can check in seconds.
    $controller = ''
    try { $controller = Get-DsmtServer -Credential $Credential } catch { $controller = '' }

    return [ordered]@{
        configured = ($groups.Count -gt 0)
        groups     = @($rows)
        controller = $controller
    }
}
