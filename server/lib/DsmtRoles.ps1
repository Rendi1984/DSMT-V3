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

# Settings. RoleAdminGroups is the ORIGINAL admin-only list and is still read
# so an existing install keeps working; RoleAssignments is the permission model
# that replaces it. Both are structured, so both are registered in
# $script:DsmtJsonSettings in DsmtCommon.ps1 - a structured setting that is not
# round-trips as the literal string "@{...}" and renders as data, with no error.
$script:DsmtRoleSettingName       = 'RoleAdminGroups'
$script:DsmtAssignmentSettingName = 'RoleAssignments'

# ---------------------------------------------------------------------------
# THE PERMISSION CATALOGUE
#
# One list, here, and every gate reads it. A permission that exists in a route
# table and not in this catalogue is a permission nobody can grant, which is
# the quiet way a role stops working.
#
# Reads are deliberately NOT in the catalogue. Every signed-in operator can
# browse the directory - "cannot even look" is not one of the roles asked for,
# and gating reads would mean a console that shows an empty grid to someone
# who is allowed to be there, which reads as a bug rather than a policy.
# ---------------------------------------------------------------------------
$script:DsmtPermissionCatalogue = @(
    @{ key = 'settings.write';  label = 'Change DSMT settings'
       note = 'The database, identity mode, HTTPS, idle timeout, and this list.' }
    @{ key = 'password.reset';  label = 'Reset passwords';  note = 'Set or generate a new password.' }
    @{ key = 'account.unlock';  label = 'Unlock accounts';  note = 'Clear a lockout.' }
    @{ key = 'account.enable';  label = 'Enable / disable'; note = 'Switch an account on or off.' }
    @{ key = 'object.move';     label = 'Move between OUs'; note = 'Relocate a user or group.' }
    @{ key = 'group.members';   label = 'Group membership'; note = 'Add or remove members.' }
    @{ key = 'users.create';    label = 'Create users';     note = 'Including the CSV import.' }
    @{ key = 'users.delete';    label = 'Delete';           note = 'Users and groups. The irreversible one.' }
    @{ key = 'groups.create';   label = 'Create groups';    note = '' }
    @{ key = 'audit.read';      label = 'Read the audit log'; note = '' }
    @{ key = 'audit.undo';      label = 'Undo an action';   note = 'Reverse a recorded change.' }
    @{ key = 'reports.run';     label = 'Run reports';      note = 'Each one reads the whole directory.' }
    @{ key = 'tools.adhealth';  label = 'AD health checks'; note = '' }
    @{ key = 'tools.gmsa';      label = 'The gMSA tool';    note = 'Creates directory objects.' }
    @{ key = 'sessions.end';    label = "End another operator's session"; note = '' }
)

# Which screens a role can reach. Visibility is NOT a permission - it decides
# what is worth drawing, and the permission gate above is what actually
# refuses. They are separate because "sees the tab but cannot act" and "cannot
# see the tab" are both things that were asked for.
$script:DsmtModuleCatalogue = @(
    @{ key = 'overview'; label = 'Overview' }
    @{ key = 'users';    label = 'Users' }
    @{ key = 'groups';   label = 'Groups' }
    @{ key = 'audit';    label = 'Audit log' }
    @{ key = 'tools';    label = 'Tools' }
    @{ key = 'settings'; label = 'Settings' }
)

# ---------------------------------------------------------------------------
# THE ROLES
#
# Presets, not a free-form permission picker. Four named roles an operator can
# reason about beat fifteen checkboxes nobody audits - and a role whose meaning
# is written here can be explained on screen, which a hand-assembled set cannot.
# ---------------------------------------------------------------------------
$script:DsmtRoleCatalogue = @(
    @{ key = 'admin'; label = 'Administrator'
       summary = 'Everything, including DSMT own settings and this list.'
       modules = @('overview', 'users', 'groups', 'audit', 'tools', 'settings')
       permissions = @('settings.write', 'password.reset', 'account.unlock', 'account.enable',
                       'object.move', 'group.members', 'users.create', 'users.delete',
                       'groups.create', 'audit.read', 'audit.undo', 'reports.run',
                       'tools.adhealth', 'tools.gmsa', 'sessions.end') }

    @{ key = 'operator'; label = 'Operator'
       summary = 'Day-to-day directory work. Cannot change how DSMT itself is configured.'
       modules = @('overview', 'users', 'groups', 'audit', 'tools', 'settings')
       permissions = @('password.reset', 'account.unlock', 'account.enable', 'object.move',
                       'group.members', 'users.create', 'groups.create', 'audit.read',
                       'audit.undo', 'reports.run', 'tools.adhealth') }

    @{ key = 'readonly'; label = 'Read only'
       summary = 'Sees everything, changes nothing. Every action is disabled.'
       modules = @('overview', 'users', 'groups', 'audit', 'tools', 'settings')
       permissions = @('audit.read', 'reports.run') }

    @{ key = 'auditor'; label = 'Auditor'
       summary = 'The audit log and reports only. The directory tabs are not shown.'
       modules = @('audit', 'tools')
       permissions = @('audit.read', 'reports.run') }
)

# ---------------------------------------------------------------------------
# ROUTE -> PERMISSION
#
# Checked at ONE choke point, against this list, rather than inside each
# handler. A role enforced route by route is a role that is missing from the
# route somebody adds next week - and under a service identity (see the
# IdentityMode note below) a missing gate is a privilege escalation, not a
# cosmetic slip.
#
# A path with no entry here needs no permission beyond a valid session.
# ---------------------------------------------------------------------------
$script:DsmtRoutePermissions = @(
    @{ Pattern = '^/api/settings/session$';      Methods = @('POST');   Permission = 'settings.write' },
    @{ Pattern = '^/api/settings/network$';      Methods = @('POST');   Permission = 'settings.write' },
    @{ Pattern = '^/api/settings/https$';        Methods = @('POST');   Permission = 'settings.write' },
    @{ Pattern = '^/api/settings/identity$';     Methods = @('POST');   Permission = 'settings.write' },
    @{ Pattern = '^/api/settings/sql$';          Methods = @('POST');   Permission = 'settings.write' },
    @{ Pattern = '^/api/settings/groupfilters$'; Methods = @('POST');   Permission = 'settings.write' },
    @{ Pattern = '^/api/settings/alerts$';       Methods = @('POST');   Permission = 'settings.write' },
    @{ Pattern = '^/api/settings/pagesize$';     Methods = @('POST');   Permission = 'settings.write' },
    @{ Pattern = '^/api/settings/roles$';        Methods = @('POST');   Permission = 'settings.write' },

    # Both of these hand back configuration. The export reveals the SQL
    # instance and database names; the database listing takes an ARBITRARY
    # server and credentials from the request body and queries it, which is a
    # SQL instance prober if left open.
    @{ Pattern = '^/api/settings/export$';        Methods = @('GET');   Permission = 'settings.write' },
    @{ Pattern = '^/api/settings/sql/databases$'; Methods = @('POST');  Permission = 'settings.write' },

    @{ Pattern = '^/api/sessions/[a-f0-9]+$';    Methods = @('DELETE'); Permission = 'sessions.end' },

    @{ Pattern = '^/api/users$';                 Methods = @('POST');   Permission = 'users.create' },
    @{ Pattern = '^/api/users/import$';          Methods = @('POST');   Permission = 'users.create' },
    @{ Pattern = '^/api/groups$';                Methods = @('POST');   Permission = 'groups.create' },

    @{ Pattern = '^/api/audit$';                 Methods = @('GET');    Permission = 'audit.read' },
    @{ Pattern = '^/api/audit/undo$';            Methods = @('POST');   Permission = 'audit.undo' },

    @{ Pattern = '^/api/reports$';               Methods = @('GET');    Permission = 'reports.run' },
    @{ Pattern = '^/api/reports/[a-z]+$';        Methods = @('GET');    Permission = 'reports.run' },

    @{ Pattern = '^/api/tools/adhealth$';        Methods = @('GET', 'POST'); Permission = 'tools.adhealth' },
    @{ Pattern = '^/api/tools/gmsa/';            Methods = @('GET', 'POST'); Permission = 'tools.gmsa' }
)

# The bulk-action route carries one verb per directory operation, so the path
# alone cannot say what is being asked for. These are checked after the verb is
# parsed, by the same gate.
$script:DsmtActionPermissions = @{
    'reset-password' = 'password.reset'
    'unlock'         = 'account.unlock'
    'set-enabled'    = 'account.enable'
    'move-ou'        = 'object.move'
    'group-add'      = 'group.members'
    'group-remove'   = 'group.members'
    'delete'         = 'users.delete'
}

function Get-DsmtRoleCatalogue {
    <#
    .SYNOPSIS
        The roles, with what each one may do. Shown in Settings and used to
        resolve an operator's permission set.
    #>
    return @($script:DsmtRoleCatalogue)
}

function Get-DsmtPermissionCatalogue {
    <#
    .SYNOPSIS
        Every permission that exists, with a label and a note for the UI.
    #>
    return @($script:DsmtPermissionCatalogue)
}

function Get-DsmtRoleDefinition {
    <#
    .SYNOPSIS
        One role by key, or $null.
    #>
    param([string] $Key)
    foreach ($r in $script:DsmtRoleCatalogue) { if ($r.key -eq $Key) { return $r } }
    return $null
}

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

function Get-DsmtRoleAssignments {
    <#
    .SYNOPSIS
        Every AD group mapped to a role.
    .OUTPUTS
        Array of @{ Sid; Name; Role }. Empty means NOT CONFIGURED, which means
        every operator is an administrator - see Resolve-DsmtOperatorRole.
    .DESCRIPTION
        Reads the new RoleAssignments setting AND the original RoleAdminGroups
        list, so an install configured before the permission model existed
        keeps working untouched: every entry in the old list is an
        administrator assignment. The old list is never written again - saving
        from the new screen replaces both - but it is still honoured, because
        an upgrade that silently drops an existing admin mapping would lock a
        team out of their own console.

        Returns @($list), not ,@($list): empty is the normal shipped default
        and the comma operator would serialise it as [[]].
    #>
    $out = @()
    $saved = Get-DsmtSavedSettings
    if ($null -eq $saved) { return @($out) }

    $seen = @{}

    $prop = $saved.PSObject.Properties[$script:DsmtAssignmentSettingName]
    if ($null -ne $prop -and $null -ne $prop.Value) {
        foreach ($row in @($prop.Value)) {
            if ($null -eq $row) { continue }

            $sid = ''; $name = ''; $role = ''
            try { $sid  = [string]$row.Sid }  catch { $sid  = '' }
            try { $name = [string]$row.Name } catch { $name = '' }
            try { $role = [string]$row.Role } catch { $role = '' }

            if ([string]::IsNullOrWhiteSpace($sid)) { continue }
            # An unknown role key grants NOTHING rather than defaulting to
            # something. A mapping that silently became "administrator"
            # because its role was renamed is the wrong way to be wrong.
            if ($null -eq (Get-DsmtRoleDefinition -Key $role)) { continue }

            $sid = $sid.Trim()
            if ($seen.ContainsKey($sid)) { continue }
            $seen[$sid] = $true
            $out += @{ Sid = $sid; Name = $name; Role = $role }
        }
    }

    # Legacy admin list, second so a new assignment for the same group wins.
    $legacy = $saved.PSObject.Properties[$script:DsmtRoleSettingName]
    if ($null -ne $legacy -and $null -ne $legacy.Value) {
        foreach ($row in @($legacy.Value)) {
            if ($null -eq $row) { continue }
            $sid = ''; $name = ''
            try { $sid  = [string]$row.Sid }  catch { $sid  = '' }
            try { $name = [string]$row.Name } catch { $name = '' }
            if ([string]::IsNullOrWhiteSpace($sid)) { continue }

            $sid = $sid.Trim()
            if ($seen.ContainsKey($sid)) { continue }
            $seen[$sid] = $true
            $out += @{ Sid = $sid; Name = $name; Role = 'admin' }
        }
    }

    return @($out)
}

function Resolve-DsmtOperatorRole {
    <#
    .SYNOPSIS
        Works out what this operator may do. Called once at sign-in and cached
        on the session.
    .OUTPUTS
        Hashtable with IsAdmin, Roles, Permissions, Modules, Reason,
        Configured, Error.
    .DESCRIPTION
        Resolved at sign-in and not re-checked per request, which is a real
        tradeoff stated plainly: removing someone from a role takes effect at
        their next sign-in, not immediately. Re-reading tokenGroups on every
        request would put a directory round-trip in front of every action, and
        the idle timeout already bounds how long a stale session lives.

        AN OPERATOR IN SEVERAL ROLES GETS THE UNION of their permissions. Roles
        add, they never subtract - a "read only" assignment does not take away
        what an "operator" assignment granted. That is the only coherent answer
        for group membership, which is itself additive, and it is stated on the
        Settings screen so nobody expects a deny to win.

        FAIL OPEN when nothing is configured; fail CLOSED when something IS
        configured and the lookup cannot run. Granting rights because a lookup
        failed is not detectable; being locked out is obvious and recoverable
        at the registry key named in the error.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $SamAccountName,
        [Parameter(Mandatory = $true)] $Credential
    )

    $adminDef = Get-DsmtRoleDefinition -Key 'admin'

    $assignments = @(Get-DsmtRoleAssignments)

    if ($assignments.Count -eq 0) {
        return @{
            IsAdmin     = $true
            Configured  = $false
            Roles       = @('admin')
            Permissions = @($adminDef.permissions)
            Modules     = @($adminDef.modules)
            Reason      = 'No roles are configured, so every operator has full access to DSMT.'
            Error       = ''
        }
    }

    $token = Get-DsmtOperatorGroupSids -SamAccountName $SamAccountName -Credential $Credential
    if (-not $token.Ok) {
        Write-DsmtLog -Level 'WARN' -Message ('Could not read group membership for ' + $SamAccountName +
                                              ', so no permissions were granted for this session: ' + $token.Error)
        return @{
            IsAdmin     = $false
            Configured  = $true
            Roles       = @()
            Permissions = @()
            Modules     = @()
            Reason      = 'Your group membership could not be read, so no permissions were granted for ' +
                          'this session. ' + $token.Error
            Error       = $token.Error
        }
    }

    $roles = @()
    $perms = @{}
    $mods  = @{}
    $via   = @()

    foreach ($a in $assignments) {
        $hit = $false
        foreach ($sid in @($token.Sids)) { if ($sid -eq $a.Sid) { $hit = $true } }
        if (-not $hit) { continue }

        $def = Get-DsmtRoleDefinition -Key $a.Role
        if ($null -eq $def) { continue }

        $roles += $a.Role
        foreach ($p in @($def.permissions)) { $perms[$p] = $true }
        foreach ($m in @($def.modules))     { $mods[$m]  = $true }

        $label = $a.Name
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $a.Sid }
        $via += ($def.label + ' (via ' + $label + ')')
    }

    if ($roles.Count -eq 0) {
        return @{
            IsAdmin     = $false
            Configured  = $true
            Roles       = @()
            Permissions = @()
            Modules     = @()
            Reason      = 'You are not in any group mapped to a DSMT role, so you can sign in and look ' +
                          'but not act. Directory rights themselves are decided by Active Directory.'
            Error       = ''
        }
    }

    return @{
        IsAdmin     = [bool]$perms['settings.write']
        Configured  = $true
        Roles       = @($roles | Sort-Object -Unique)
        Permissions = @($perms.Keys | Sort-Object)
        Modules     = @($mods.Keys | Sort-Object)
        Reason      = ($via -join '; ') + '.'
        Error       = ''
    }
}

function Test-DsmtPermission {
    <#
    .SYNOPSIS
        Does this session hold this permission?
    #>
    param($Session, [Parameter(Mandatory = $true)][string] $Permission)

    if ($null -eq $Session) { return $false }
    foreach ($p in @($Session.Permissions)) { if ($p -eq $Permission) { return $true } }
    return $false
}

function Get-DsmtRequiredPermission {
    <#
    .SYNOPSIS
        The permission a request needs, or '' when it needs none beyond a
        valid session.
    .DESCRIPTION
        THE one place that answers this. The bulk-action route carries its
        verb in the path, so it is resolved from the action table; everything
        else is matched on path and method.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Method,
        [string] $Action = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Action)) {
        if ($script:DsmtActionPermissions.ContainsKey($Action)) {
            return [string]$script:DsmtActionPermissions[$Action]
        }
        # An action with no entry is refused rather than allowed. A new verb
        # added without a permission must fail loudly here, not ship ungated.
        return 'UNMAPPED'
    }

    foreach ($route in $script:DsmtRoutePermissions) {
        if ($Path -match $route.Pattern) {
            foreach ($m in @($route.Methods)) {
                if ($m -eq $Method) { return [string]$route.Permission }
            }
        }
    }
    return ''
}

function Test-DsmtRouteNeedsAdmin {
    <#
    .SYNOPSIS
        Kept so nothing that still calls it breaks. The permission model
        replaced it - use Get-DsmtRequiredPermission with Test-DsmtPermission.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Method
    )
    return ((Get-DsmtRequiredPermission -Path $Path -Method $Method) -eq 'settings.write')
}

function Get-DsmtRoleState {
    <#
    .SYNOPSIS
        What the Settings screen shows about roles.
    .DESCRIPTION
        Reports each assignment AND whether its group still resolves in the
        directory. A mapping naming a group that has been deleted looks
        perfectly healthy in a list and grants nobody anything - the same
        class of silent wrong answer this project has a whole section about.
    #>
    param($Credential)

    $assignments = @(Get-DsmtRoleAssignments)
    $rows = @()

    foreach ($a in $assignments) {
        $present = $false
        $name    = $a.Name
        $ouPath  = ''

        if ($null -ne $Credential) {
            try {
                $ad  = Get-DsmtAdParams -Credential $Credential -Intent 'read'
                $obj = Get-ADGroup @ad -Identity $a.Sid -ErrorAction Stop
                $present = $true
                $name    = [string]$obj.Name
                $ouPath  = ConvertFrom-DsmtDn -DistinguishedName ([string]$obj.distinguishedName)
            } catch {
                $present = $false
            }
        }

        $def   = Get-DsmtRoleDefinition -Key $a.Role
        $label = $a.Role
        if ($null -ne $def) { $label = [string]$def.label }

        $rows += [ordered]@{
            sid       = $a.Sid
            name      = $name
            ou        = $ouPath
            present   = $present
            role      = $a.Role
            roleLabel = $label
        }
    }

    # Which DC answered. Membership read from one controller can lag a change
    # made on another until replication catches up, and that shows up as "I
    # changed the group and DSMT still disagrees" - which looks exactly like a
    # bug in this code.
    $controller = ''
    try { $controller = Get-DsmtServer -Credential $Credential } catch { $controller = '' }

    # Whether the LEGACY admin list is still doing work. An install that has
    # never opened this screen is running entirely on it, and saying so beats
    # a screen that shows rows nobody can find in the new setting.
    $legacy = $false
    try {
        $saved = Get-DsmtSavedSettings
        if ($null -ne $saved) {
            $p = $saved.PSObject.Properties[$script:DsmtRoleSettingName]
            if ($null -ne $p -and $null -ne $p.Value -and @($p.Value).Count -gt 0) { $legacy = $true }
        }
    } catch {
        $legacy = $false
    }

    return [ordered]@{
        configured   = ($assignments.Count -gt 0)
        assignments  = @($rows)
        controller   = $controller
        legacyInUse  = $legacy
        identityMode = [string](Get-DsmtConfig).IdentityMode
    }
}
