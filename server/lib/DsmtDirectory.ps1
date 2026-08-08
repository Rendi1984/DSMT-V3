<#
.SYNOPSIS
    DSMT - every read from and write to Active Directory.
.DESCRIPTION
    All directory access goes through this file. Two rules it exists to
    enforce:

    1. Everything returned here comes from the live directory. There is no
       demo mode, no sample data and no fallback list. If AD cannot be
       reached the call throws and the UI shows the error - it never shows
       invented rows. (See CLAUDE.md, "No fake/placeholder data".)

    2. Attribute names are mapped exactly once, here, at the boundary. AD
       hands back sAMAccountName / UserPrincipalName / DistinguishedName /
       LastLogonDate; the UI reads sam / upn / dn / logon. Doing the mapping
       in one place is what stops the silent "blank cells, no error" bug that
       a casing mismatch produces.

    3. Which identity performs an operation is decided in exactly one place:
       Get-DsmtAdParams. Never call an AD cmdlet in this file without
       splatting what it returns, and always declare -Intent 'read' or
       'write' - that is what the identity modes hang off.

    Every WRITE runs with the operator's own credentials in every mode, so the
    domain controller enforces permissions and records the change against
    their account. Reads may run as the service account, depending on
    IdentityMode.
.NOTES
    Author  : IT Team
    Requires: RSAT ActiveDirectory PowerShell module on the host running this
              server (Windows Server: Install-WindowsFeature RSAT-AD-PowerShell).
#>

$script:DsmtDcName = ''

function Assert-DsmtAdModule {
    <#
    .SYNOPSIS
        Loads the ActiveDirectory module, with an error message that names the
        one-time external fix rather than a generic failure.
    #>
    if (Get-Module -Name ActiveDirectory) { return }

    try {
        Import-Module ActiveDirectory -ErrorAction Stop
    } catch {
        throw ('The ActiveDirectory PowerShell module is not available on this host. ' +
               'Install it once with:  Install-WindowsFeature RSAT-AD-PowerShell  (Windows Server) ' +
               'or  Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0  (Windows 10/11). ' +
               'Underlying error: ' + $_.Exception.Message)
    }
}

function Get-DsmtServer {
    <#
    .SYNOPSIS
        Returns the domain controller this server talks to. Explicit, because
        every audit record names the controller that served the change.
    #>
    param($Credential)

    $cfg = Get-DsmtConfig
    if ($cfg.Server) { return $cfg.Server }
    if ($script:DsmtDcName) { return $script:DsmtDcName }

    Assert-DsmtAdModule
    $dc = Get-ADDomainController -DomainName $cfg.Domain -Discover -ErrorAction Stop

    # -Discover returns HostName as a string COLLECTION, not a string. Casting
    # the collection would produce "host1 host2" and every later -Server call
    # would fail on a name that does not exist.
    $name = $dc.HostName
    if ($name -isnot [string]) { $name = @($name)[0] }

    $script:DsmtDcName = [string]$name
    return $script:DsmtDcName
}

function Get-DsmtOperatorIdentity {
    <#
    .SYNOPSIS
        Looks up the operator's own AD object right after sign-in, so the
        console can show their real display name instead of the string they
        happened to type into the login box.
    .OUTPUTS
        Hashtable with DisplayName, Ou and Dn - or $null when the lookup fails
        (the caller falls back to the samAccountName and carries on).
    #>
    param(
        [Parameter(Mandatory = $true)][string] $SamAccountName,
        [Parameter(Mandatory = $true)] $Credential
    )

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'read'
    $me = Get-ADUser @ad -Identity $SamAccountName -Properties 'displayName', 'distinguishedName' -ErrorAction Stop

    $display = [string]$me.displayName
    if ([string]::IsNullOrWhiteSpace($display)) { $display = [string]$me.Name }

    return @{
        DisplayName = $display
        Dn          = [string]$me.distinguishedName
        Ou          = ConvertFrom-DsmtDn -DistinguishedName ([string]$me.distinguishedName)
    }
}

function Get-DsmtAdParams {
    <#
    .SYNOPSIS
        The -Server/-Credential pair every AD cmdlet call in this file splats.
        THE one place that decides which identity performs an operation.
    .DESCRIPTION
        Two identity modes, set by IdentityMode in the configuration:

          operator (default)
            Every read and every write runs as the signed-in operator. The
            domain controller enforces that operator's rights and records the
            change against their account. This is the 1.4.x behaviour.

          hybrid
            Reads run as the service account (the process identity), writes
            still run as the operator. Directory browsing then works for an
            operator with no broad read rights, and stays consistent for
            everyone - but WRITES DELIBERATELY STAY ON THE OPERATOR, because
            that is what makes the DC's own security log name the human who
            did it. Nothing can forge that attribution afterwards.

        "Runs as the service account" simply means not passing -Credential at
        all: the process is already running under that account. That is why
        this works with a gMSA or a machine account, where no password exists
        to hand over.
    .PARAMETER Intent
        'read' or 'write'. Defaults to 'write' on purpose: a call site that
        forgets to declare its intent keeps the operator's credentials, which
        is the conservative direction to fail in. The opposite default would
        silently promote a missed call to service-account rights.
    #>
    param(
        $Credential,
        [ValidateSet('read', 'write')][string] $Intent = 'write'
    )

    Assert-DsmtAdModule

    $cfg = Get-DsmtConfig
    $params = @{ Server = (Get-DsmtServer -Credential $Credential) }

    $useServiceIdentity = ($cfg.IdentityMode -eq 'hybrid' -and $Intent -eq 'read')
    if (-not $useServiceIdentity) {
        $params.Credential = $Credential
    }

    return $params
}

function Get-DsmtDomainInfo {
    <#
    .SYNOPSIS
        Real domain name and the real list of domain controllers. The console
        header shows this - it is not a hardcoded string.
    #>
    param($Credential)

    $ad  = Get-DsmtAdParams -Credential $Credential -Intent 'read'
    $cfg = Get-DsmtConfig

    $domain = Get-ADDomain @ad -ErrorAction Stop
    $dcs    = @(Get-ADDomainController @ad -Filter * -ErrorAction Stop)

    $dcList = @()
    foreach ($dc in $dcs) {
        $dcList += [ordered]@{
            name   = [string]$dc.HostName
            site   = [string]$dc.Site
            isGc   = [bool]$dc.IsGlobalCatalog
            os     = [string]$dc.OperatingSystem
        }
    }

    return [ordered]@{
        domain          = [string]$domain.DNSRoot
        netbios         = [string]$domain.NetBIOSName
        dn              = [string]$domain.DistinguishedName
        forest          = [string]$domain.Forest
        controllerCount = $dcList.Count
        controllers     = @($dcList)
        connectedTo     = $ad.Server
        usersContainer  = [string]$domain.UsersContainer
    }
}

# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------

$script:DsmtUserProperties = @(
    'displayName', 'sAMAccountName', 'userPrincipalName', 'distinguishedName',
    'department', 'title', 'Enabled', 'LockedOut', 'LastLogonDate',
    'PasswordNeverExpires', 'PasswordExpired', 'msDS-UserPasswordExpiryTimeComputed',
    'manager', 'memberOf', 'mail', 'telephoneNumber', 'whenCreated', 'description',
    'company', 'physicalDeliveryOfficeName', 'employeeID', 'objectGUID', 'objectSid'
)

function ConvertTo-DsmtUser {
    <#
    .SYNOPSIS
        THE user attribute mapping. AD attribute names in, UI field names out.
        Nothing else in the codebase may read a raw AD attribute name.
    #>
    param($AdUser, [bool] $IncludeDetail = $false)

    $status = 'Enabled'
    if ($AdUser.LockedOut) { $status = 'Locked out' }
    elseif (-not $AdUser.Enabled) { $status = 'Disabled' }

    $expiryRaw = $AdUser.'msDS-UserPasswordExpiryTimeComputed'
    $expiry    = $null
    if ($null -ne $expiryRaw -and $expiryRaw -gt 0 -and $expiryRaw -lt [Int64]::MaxValue) {
        try { $expiry = [datetime]::FromFileTime([Int64]$expiryRaw) } catch { $expiry = $null }
    }

    $managerName = ''
    if ($AdUser.manager) { $managerName = Get-DsmtNameFromDn -DistinguishedName ([string]$AdUser.manager) }

    $groupCount = 0
    if ($AdUser.memberOf) { $groupCount = @($AdUser.memberOf).Count }

    $map = [ordered]@{
        id       = [string]$AdUser.objectGUID
        name     = [string]$AdUser.displayName
        sam      = [string]$AdUser.sAMAccountName
        upn      = [string]$AdUser.userPrincipalName
        dn       = [string]$AdUser.distinguishedName
        ou       = ConvertFrom-DsmtDn -DistinguishedName ([string]$AdUser.distinguishedName)
        ouDn     = Get-DsmtParentDn -DistinguishedName ([string]$AdUser.distinguishedName)
        dept     = [string]$AdUser.department
        title    = [string]$AdUser.title
        status   = $status
        enabled  = [bool]$AdUser.Enabled
        locked   = [bool]$AdUser.LockedOut
        logon    = ConvertTo-DsmtDisplayTime -Value $AdUser.LastLogonDate
        logonRaw = ''
        pwd      = ConvertTo-DsmtRelativeExpiry -Value $expiry -NeverExpires ([bool]$AdUser.PasswordNeverExpires)
        groups   = $groupCount
        manager  = $managerName
        mail     = [string]$AdUser.mail
        source   = 'AD'
    }

    if ($AdUser.LastLogonDate) { $map.logonRaw = ([datetime]$AdUser.LastLogonDate).ToString('s') }

    # Empty displayName is common on service accounts - fall back so the row
    # is never blank, but keep it obvious which field was used.
    if ([string]::IsNullOrWhiteSpace($map.name)) { $map.name = $map.sam }

    if ($IncludeDetail) {
        $map.description = [string]$AdUser.description
        $map.phone       = [string]$AdUser.telephoneNumber
        $map.office      = [string]$AdUser.physicalDeliveryOfficeName
        $map.company     = [string]$AdUser.company
        $map.employeeId  = [string]$AdUser.employeeID
        $map.created     = ConvertTo-DsmtDisplayTime -Value $AdUser.whenCreated
        $map.sid         = [string]$AdUser.objectSid
        $map.pwdExpired  = [bool]$AdUser.PasswordExpired
    }

    return $map
}

function Get-DsmtNameFromDn {
    <#
    .SYNOPSIS
        Pulls the CN out of a DN for display, without a second AD round-trip.
    #>
    param([string] $DistinguishedName)

    if ([string]::IsNullOrWhiteSpace($DistinguishedName)) { return '' }
    $parts = [System.Text.RegularExpressions.Regex]::Split($DistinguishedName, '(?<!\\),')
    if ($parts.Count -eq 0) { return $DistinguishedName }
    $leaf = $parts[0].Trim()
    if ($leaf -match '^(?i)(?:CN|OU)=(.+)$') { return $Matches[1].Replace('\,', ',') }
    return $leaf
}

function Get-DsmtUsers {
    <#
    .SYNOPSIS
        Searches real users. An empty query lists the domain's users up to
        the page size; a query uses AD's ambiguous name resolution plus UPN
        and OU matching.
    #>
    param(
        $Credential,
        [string] $Query = '',
        [int] $Limit = 0
    )

    $ad  = Get-DsmtAdParams -Credential $Credential -Intent 'read'
    $cfg = Get-DsmtConfig
    if ($Limit -le 0) { $Limit = $cfg.PageSize }

    $q = ''
    if (-not [string]::IsNullOrWhiteSpace($Query)) { $q = ConvertTo-DsmtLdapEscape -Value $Query.Trim() }

    # No wildcard clause on distinguishedName: AD does not support substring
    # matching on DN-syntax attributes and the whole filter fails if one is
    # used. anr already covers name, samAccountName, UPN and mail.
    if ($q) {
        $ldap = '(&(objectCategory=person)(objectClass=user)(|(anr=' + $q + ')(userPrincipalName=*' + $q + '*)(department=*' + $q + '*)(title=*' + $q + '*)))'
    } else {
        $ldap = '(&(objectCategory=person)(objectClass=user))'
    }

    # Sorted as AD objects, before mapping: sorting the mapped hashtables by a
    # key is fragile, sorting real objects by a property is not.
    $found = @(Get-ADUser @ad -LDAPFilter $ldap -Properties $script:DsmtUserProperties -ResultSetSize $Limit -ErrorAction Stop) |
             Sort-Object -Property @{ Expression = { if ($_.displayName) { [string]$_.displayName } else { [string]$_.sAMAccountName } } }

    $rows = @()
    foreach ($u in $found) { $rows += ConvertTo-DsmtUser -AdUser $u }

    return @($rows)
}

function Get-DsmtUser {
    <#
    .SYNOPSIS
        One user with detail fields and the real list of groups they are in.
    #>
    param($Credential, [Parameter(Mandatory = $true)][string] $Identity)

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'read'
    $u  = Get-ADUser @ad -Identity $Identity -Properties $script:DsmtUserProperties -ErrorAction Stop

    $detail = ConvertTo-DsmtUser -AdUser $u -IncludeDetail $true

    $memberships = @()
    foreach ($dn in (@($u.memberOf) | Sort-Object)) {
        $memberships += [ordered]@{
            name = Get-DsmtNameFromDn -DistinguishedName ([string]$dn)
            meta = ConvertFrom-DsmtDn -DistinguishedName ([string]$dn)
            dn   = [string]$dn
        }
    }

    $detail.memberships = @($memberships)
    return $detail
}

# ---------------------------------------------------------------------------
# Groups
# ---------------------------------------------------------------------------

$script:DsmtGroupProperties = @(
    'name', 'sAMAccountName', 'distinguishedName', 'GroupCategory', 'GroupScope',
    'description', 'managedBy', 'whenCreated', 'member', 'mail', 'objectGUID', 'info',
    # objectSid identifies a privileged group; adminCount is the secondary
    # signal. Both are needed by the sensitive-group filter - see
    # Test-DsmtPrivilegedGroup for why the SID is the one that can be trusted.
    'objectSid', 'adminCount'
)

# ---------------------------------------------------------------------------
# Privileged groups.
#
# MATCHED ON SID, NEVER ON NAME. "Domain Admins" can be renamed by any
# administrator, and on a non-English installation it is localised out of the
# box - so a filter that looks for the string finds nothing on precisely the
# domain where finding it matters most. The RIDs below are fixed by Windows
# and are the same in every domain in the world.
#
# Domain-relative: the domain SID + RID.
# ---------------------------------------------------------------------------
$script:DsmtPrivilegedRids = @(
    512,   # Domain Admins
    516,   # Domain Controllers
    518,   # Schema Admins            (forest root domain only)
    519,   # Enterprise Admins        (forest root domain only)
    520,   # Group Policy Creator Owners
    521,   # Read-only Domain Controllers
    526,   # Key Admins
    527    # Enterprise Key Admins
)

# Built-in aliases. These live in the BUILTIN domain and always carry the
# fixed prefix S-1-5-32, in every domain, so they are matched whole.
$script:DsmtPrivilegedBuiltinSids = @(
    'S-1-5-32-544',   # Administrators
    'S-1-5-32-548',   # Account Operators
    'S-1-5-32-549',   # Server Operators
    'S-1-5-32-550',   # Print Operators
    'S-1-5-32-551',   # Backup Operators
    'S-1-5-32-552'    # Replicator
)

function Test-DsmtPrivilegedGroup {
    <#
    .SYNOPSIS
        Is this group one of the well-known privileged groups?
    .DESCRIPTION
        Takes the group's SID as a string. A domain group is privileged when
        its RID - the number after the last hyphen - is in the list above; a
        built-in alias is matched on the whole SID.

        adminCount is deliberately NOT used to decide this. It marks objects
        protected by AdminSDHolder, which is a useful signal, but it LINGERS
        on an account after it is removed from a privileged group. Filtering
        on it would over-report, and an over-reporting security filter is one
        that stops being read.
    #>
    param([string] $Sid)

    if ([string]::IsNullOrWhiteSpace($Sid)) { return $false }

    foreach ($builtin in $script:DsmtPrivilegedBuiltinSids) {
        if ($Sid -eq $builtin) { return $true }
    }

    $lastDash = $Sid.LastIndexOf('-')
    if ($lastDash -lt 0) { return $false }

    $rid = 0
    if (-not [int]::TryParse($Sid.Substring($lastDash + 1), [ref] $rid)) { return $false }

    foreach ($known in $script:DsmtPrivilegedRids) {
        if ($rid -eq $known) { return $true }
    }
    return $false
}

function ConvertTo-DsmtGroup {
    <#
    .SYNOPSIS
        THE group attribute mapping - the group-side twin of ConvertTo-DsmtUser.
    #>
    param($AdGroup, [bool] $IncludeDetail = $false)

    $memberCount = 0
    if ($AdGroup.member) { $memberCount = @($AdGroup.member).Count }

    $category = [string]$AdGroup.GroupCategory
    $scope    = [string]$AdGroup.GroupScope
    $scopeLabel = $scope
    if ($scope -eq 'DomainLocal') { $scopeLabel = 'Domain local' }

    $typeLabel = $category
    if ($category -and $scopeLabel) { $typeLabel = $category + ' - ' + $scopeLabel }

    # BOTH of these are wrapped, and the reason is a real bug rather than
    # caution: AD returns an absent attribute as an EMPTY
    # ADPropertyValueCollection, not as $null. Casting that to [int] throws,
    # and because these values sit inside the [ordered]@{ } literal below, a
    # throw here does not just lose one field - the whole hashtable assignment
    # fails, ConvertTo-DsmtGroup returns nothing, and the Groups tab renders
    # blank rows with no error anywhere. That is exactly what 1.15.0 shipped.
    $sid = ''
    try {
        if ($null -ne $AdGroup.objectSid) {
            $sid = [string]$AdGroup.objectSid.Value
            if ([string]::IsNullOrWhiteSpace($sid)) { $sid = [string]$AdGroup.objectSid }
        }
    } catch { $sid = '' }

    $isPrivileged = $false
    try { $isPrivileged = Test-DsmtPrivilegedGroup -Sid $sid } catch { $isPrivileged = $false }

    $isProtected = $false
    try {
        $ac = $AdGroup.adminCount
        if ($null -ne $ac -and -not [string]::IsNullOrWhiteSpace([string]$ac)) {
            $isProtected = ([int][string]$ac -eq 1)
        }
    } catch { $isProtected = $false }

    $map = [ordered]@{
        id       = [string]$AdGroup.objectGUID
        name     = [string]$AdGroup.name
        sam      = [string]$AdGroup.sAMAccountName
        dn       = [string]$AdGroup.distinguishedName
        ou       = ConvertFrom-DsmtDn -DistinguishedName ([string]$AdGroup.distinguishedName)
        ouDn     = Get-DsmtParentDn -DistinguishedName ([string]$AdGroup.distinguishedName)
        type     = $typeLabel
        category = $category
        scope    = $scopeLabel
        members  = $memberCount
        sid        = $sid
        privileged = $isPrivileged
        protected  = $isProtected
        source   = 'AD'
    }

    if ($IncludeDetail) {
        $map.description = [string]$AdGroup.description
        $map.managedBy   = Get-DsmtNameFromDn -DistinguishedName ([string]$AdGroup.managedBy)
        $map.created     = ConvertTo-DsmtDisplayTime -Value $AdGroup.whenCreated
        $map.mail        = [string]$AdGroup.mail
        $map.notes       = [string]$AdGroup.info
    }

    return $map
}

function Get-DsmtGroupFilters {
    <#
    .SYNOPSIS
        The filter chips the Groups screen offers.
    .DESCRIPTION
        Two kinds, and the difference is deliberate:

          BUILT-IN - facts about Active Directory, not configuration. They are
          defined in code because they cannot be got wrong by an operator and
          must not be editable into something misleading.

          CUSTOM - whatever this organisation cares about, defined once by an
          administrator and stored in the registry. NOT in the
          browser: a filter one person defines is a filter the whole team
          should see, and localStorage would make it personal to one machine.

        A custom filter matches a group when any of its terms appears in the
        group name, the sAMAccountName, the description or the OU.
    .OUTPUTS
        Array of hashtables: key, label, kind, terms.
    #>

    $filters = @(
        @{ key = 'all';        label = 'All';        kind = 'builtin'; terms = @() }
        @{ key = 'privileged'; label = 'Privileged'; kind = 'builtin'; terms = @() }
        @{ key = 'protected';  label = 'AdminSDHolder'; kind = 'builtin'; terms = @() }
    )

    $cfg = Get-DsmtConfig
    $saved = $null
    try { $saved = Get-DsmtSavedSettings } catch { $saved = $null }

    if ($null -ne $saved -and $saved.PSObject.Properties['GroupFilters']) {
        foreach ($f in @($saved.GroupFilters)) {
            if ($null -eq $f) { continue }
            $label = [string]$f.label
            if ([string]::IsNullOrWhiteSpace($label)) { continue }

            $terms = @()
            foreach ($t in @($f.terms)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$t)) { $terms += ([string]$t).Trim() }
            }
            if ($terms.Count -eq 0) { continue }

            $filters += @{ key = ('custom:' + $label); label = $label; kind = 'custom'; terms = @($terms) }
        }
    }

    # NOT ",@($filters)". The call site wraps in @( ), and the comma operator
    # then leaves the outer array in place - the whole list arrives as ONE
    # element that is itself an array. That is what made the Groups tab render
    # a single blank row: items serialised as [[ ...20 groups... ]].
    return @($filters)
}

function Select-DsmtGroupsByFilter {
    <#
    .SYNOPSIS
        Applies one filter key to a list of mapped group rows.
    .DESCRIPTION
        Applied AFTER the directory search rather than folded into the LDAP
        filter, because "privileged" is decided by SID arithmetic that LDAP
        cannot express, and because a custom filter has to match the OU, which
        is derived here rather than stored.
    #>
    param([array] $Rows, [string] $Filter = 'all')

    if ([string]::IsNullOrWhiteSpace($Filter) -or $Filter -eq 'all') { return @($Rows) }

    if ($Filter -eq 'privileged') {
        return @(@($Rows) | Where-Object { $_.privileged })
    }
    if ($Filter -eq 'protected') {
        return @(@($Rows) | Where-Object { $_.protected })
    }

    $defined = @(Get-DsmtGroupFilters)
    $wanted  = $null
    foreach ($f in $defined) { if ($f.key -eq $Filter) { $wanted = $f } }

    # An unknown key returns everything rather than nothing. A filter that
    # was deleted from the configuration while someone had it selected must
    # not silently produce an empty screen that reads as "there are none".
    if ($null -eq $wanted) { return @($Rows) }

    $terms = @($wanted.terms)
    if ($terms.Count -eq 0) { return @($Rows) }

    $kept = @()
    foreach ($row in @($Rows)) {
        $hay = (([string]$row.name) + ' ' + ([string]$row.sam) + ' ' +
                ([string]$row.description) + ' ' + ([string]$row.ou)).ToLower()
        foreach ($term in $terms) {
            if ($hay.Contains($term.ToLower())) { $kept += $row; break }
        }
    }
    return @($kept)
}

function Get-DsmtGroups {
    param($Credential, [string] $Query = '', [int] $Limit = 0)

    $ad  = Get-DsmtAdParams -Credential $Credential -Intent 'read'
    $cfg = Get-DsmtConfig
    if ($Limit -le 0) { $Limit = $cfg.PageSize }

    $q = ''
    if (-not [string]::IsNullOrWhiteSpace($Query)) { $q = ConvertTo-DsmtLdapEscape -Value $Query.Trim() }

    if ($q) {
        $ldap = '(&(objectCategory=group)(|(anr=' + $q + ')(description=*' + $q + '*)))'
    } else {
        $ldap = '(objectCategory=group)'
    }

    $found = @(Get-ADGroup @ad -LDAPFilter $ldap -Properties $script:DsmtGroupProperties -ResultSetSize $Limit -ErrorAction Stop) |
             Sort-Object -Property name

    $rows = @()
    foreach ($g in $found) { $rows += ConvertTo-DsmtGroup -AdGroup $g }

    return @($rows)
}

function Get-DsmtGroup {
    <#
    .SYNOPSIS
        One group with detail fields and its real member list.
    #>
    param($Credential, [Parameter(Mandatory = $true)][string] $Identity)

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'read'
    $g  = Get-ADGroup @ad -Identity $Identity -Properties $script:DsmtGroupProperties -ErrorAction Stop

    $detail = ConvertTo-DsmtGroup -AdGroup $g -IncludeDetail $true

    $members = @()
    foreach ($dn in (@($g.member) | Sort-Object)) {
        $members += [ordered]@{
            name = Get-DsmtNameFromDn -DistinguishedName ([string]$dn)
            meta = ConvertFrom-DsmtDn -DistinguishedName ([string]$dn)
            dn   = [string]$dn
        }
    }

    $detail.memberships = @($members)
    return $detail
}

# ---------------------------------------------------------------------------
# Organizational units - real containers, for the Move OU and Create dialogs
# ---------------------------------------------------------------------------

function Get-DsmtOus {
    param($Credential)

    $ad     = Get-DsmtAdParams -Credential $Credential -Intent 'read'
    $domain = Get-ADDomain @ad -ErrorAction Stop

    $ous = @(Get-ADOrganizationalUnit @ad -Filter * -Properties 'distinguishedName', 'name' -ErrorAction Stop)

    # ConvertFrom-DsmtDn drops the LEAF component, so to get the path OF a
    # container we hand it a dummy leaf in front of that container's DN.
    $rows = @()

    # The default Users container is not an OU but is a legitimate target.
    $rows += [ordered]@{
        dn   = [string]$domain.UsersContainer
        path = ConvertFrom-DsmtDn -DistinguishedName ('CN=x,' + [string]$domain.UsersContainer)
    }
    foreach ($ou in ($ous | Sort-Object -Property distinguishedName)) {
        $rows += [ordered]@{
            dn   = [string]$ou.distinguishedName
            path = ConvertFrom-DsmtDn -DistinguishedName ('CN=x,' + [string]$ou.distinguishedName)
        }
    }

    return @($rows)
}

# ---------------------------------------------------------------------------
# Writes - each one returns a plain result object and is audited by the caller
# ---------------------------------------------------------------------------

function Reset-DsmtPassword {
    param(
        $Credential,
        [Parameter(Mandatory = $true)][string] $Identity,
        [Parameter(Mandatory = $true)][string] $NewPassword,
        [bool] $MustChange = $true,
        [bool] $Unlock = $true
    )

    $ad     = Get-DsmtAdParams -Credential $Credential -Intent 'write'
    $secure = ConvertTo-SecureString -String $NewPassword -AsPlainText -Force

    Set-ADAccountPassword @ad -Identity $Identity -Reset -NewPassword $secure -ErrorAction Stop

    if ($MustChange) {
        Set-ADUser @ad -Identity $Identity -ChangePasswordAtLogon $true -ErrorAction Stop
    }
    if ($Unlock) {
        # Unlocking a non-locked account is a no-op, not an error worth failing on.
        try { Unlock-ADAccount @ad -Identity $Identity -ErrorAction Stop } catch { }
    }
}

function Unlock-DsmtAccount {
    param($Credential, [Parameter(Mandatory = $true)][string] $Identity)

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'write'
    Unlock-ADAccount @ad -Identity $Identity -ErrorAction Stop
}

function Set-DsmtAccountEnabled {
    param($Credential, [Parameter(Mandatory = $true)][string] $Identity, [Parameter(Mandatory = $true)][bool] $Enabled)

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'write'
    if ($Enabled) {
        Enable-ADAccount @ad -Identity $Identity -ErrorAction Stop
    } else {
        Disable-ADAccount @ad -Identity $Identity -ErrorAction Stop
    }
}

function Resolve-DsmtObjectDn {
    <#
    .SYNOPSIS
        Turns whatever the console holds for an object - normally a
        sAMAccountName - into a distinguishedName.
    .DESCRIPTION
        NOT every AD cmdlet takes the same kind of identity, and the split is
        not obvious:

          Get-ADUser, Set-ADUser, Enable-ADAccount, Unlock-ADAccount,
          Set-ADAccountPassword, Add-ADGroupMember -Members
              accept a sAMAccountName.

          Move-ADObject, Remove-ADObject and the other *-ADObject cmdlets
              DO NOT. Their -Identity takes a distinguishedName, a GUID or a
              SID, and nothing else.

        Passing a sAMAccountName to Move-ADObject fails with
        "Cannot find an object with identity: 'dv3' under: 'DC=LAB,DC=LOCAL'",
        which reads exactly like a missing object and sends the operator
        hunting for a user that is sitting right there. Every caller of an
        *-ADObject cmdlet resolves through here first.
    .OUTPUTS
        The distinguishedName. Throws a message naming the identity if the
        object cannot be found.
    #>
    param($Credential, [Parameter(Mandatory = $true)][string] $Identity)

    $value = $Identity.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { throw 'No object was given to resolve.' }

    # Already a DN - the only form with both an '=' and a ',' in it. Passed
    # straight through so a caller that already did the work is not charged
    # for a second lookup.
    if ($value -match '^\s*[A-Za-z]+=.+,.+$') { return $value }

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'read'
    $escaped = ConvertTo-DsmtLdapEscape -Value $value

    # One search across users, groups and computers: the console can hold any
    # of the three, and the caller should not have to say which.
    $found = @(Get-ADObject @ad -LDAPFilter ('(sAMAccountName=' + $escaped + ')') `
                            -Properties 'distinguishedName' -ErrorAction SilentlyContinue)

    if ($found.Count -eq 0) {
        # A computer account is stored with a trailing $ - accept the bare name.
        $found = @(Get-ADObject @ad -LDAPFilter ('(sAMAccountName=' + $escaped + '$)') `
                                -Properties 'distinguishedName' -ErrorAction SilentlyContinue)
    }

    if ($found.Count -eq 0) {
        throw ('No directory object found for "' + $value + '".')
    }
    if ($found.Count -gt 1) {
        throw ('"' + $value + '" matches ' + [string]$found.Count + ' objects; it cannot be resolved unambiguously.')
    }

    return [string]$found[0].DistinguishedName
}

function Get-DsmtObjectParent {
    <#
    .SYNOPSIS
        The DN of the container an object currently sits in.
    .DESCRIPTION
        Read BEFORE a move so the audit record can say where the object came
        from, which is the only thing that makes a move undoable later. A
        failure here must never block the move itself - the caller treats an
        empty string as "unknown" and simply records a less useful detail.
    #>
    param($Credential, [Parameter(Mandatory = $true)][string] $Identity)

    $dn = ''
    try {
        $dn = Resolve-DsmtObjectDn -Credential $Credential -Identity $Identity
    } catch {
        return ''
    }
    if ([string]::IsNullOrWhiteSpace($dn)) { return '' }

    $comma = $dn.IndexOf(',')
    if ($comma -lt 0) { return '' }
    return $dn.Substring($comma + 1)
}

function Move-DsmtObject {
    <#
    .SYNOPSIS
        Moves a user, group or computer into another OU.
    .DESCRIPTION
        Move-ADObject does not accept a sAMAccountName, so the identity is
        resolved to a distinguishedName first. See Resolve-DsmtObjectDn.
    #>
    param($Credential, [Parameter(Mandatory = $true)][string] $Identity, [Parameter(Mandatory = $true)][string] $TargetOu)

    $dn = Resolve-DsmtObjectDn -Credential $Credential -Identity $Identity

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'write'
    Move-ADObject @ad -Identity $dn -TargetPath $TargetOu -ErrorAction Stop
}

function Add-DsmtGroupMember {
    param($Credential, [Parameter(Mandatory = $true)][string] $Group, [Parameter(Mandatory = $true)][string[]] $Members)

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'write'
    Add-ADGroupMember @ad -Identity $Group -Members $Members -Confirm:$false -ErrorAction Stop
}

function Remove-DsmtGroupMember {
    param($Credential, [Parameter(Mandatory = $true)][string] $Group, [Parameter(Mandatory = $true)][string[]] $Members)

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'write'
    Remove-ADGroupMember @ad -Identity $Group -Members $Members -Confirm:$false -ErrorAction Stop
}

function New-DsmtUser {
    <#
    .SYNOPSIS
        Creates a real user account. Password is set and the account enabled
        only when a password was supplied - AD refuses to enable an account
        that has no compliant password.
    #>
    param(
        $Credential,
        [Parameter(Mandatory = $true)][string] $DisplayName,
        [Parameter(Mandatory = $true)][string] $SamAccountName,
        [Parameter(Mandatory = $true)][string] $TargetOu,
        [string] $GivenName = '',
        [string] $Surname = '',
        [string] $Department = '',
        [string] $Title = '',
        [string] $Password = '',
        [bool]   $Enabled = $true,
        [bool]   $MustChange = $true
    )

    $ad  = Get-DsmtAdParams -Credential $Credential -Intent 'write'
    $cfg = Get-DsmtConfig

    $upn = $SamAccountName + '@' + $cfg.Domain

    $new = @{
        Name              = $DisplayName
        DisplayName       = $DisplayName
        SamAccountName    = $SamAccountName
        UserPrincipalName = $upn
        Path              = $TargetOu
        Enabled           = $false
    }
    if ($GivenName)  { $new.GivenName  = $GivenName }
    if ($Surname)    { $new.Surname    = $Surname }
    if ($Department) { $new.Department = $Department }
    if ($Title)      { $new.Title      = $Title }

    New-ADUser @ad @new -ErrorAction Stop

    if ($Password) {
        $secure = ConvertTo-SecureString -String $Password -AsPlainText -Force
        Set-ADAccountPassword @ad -Identity $SamAccountName -Reset -NewPassword $secure -ErrorAction Stop
        if ($MustChange) {
            Set-ADUser @ad -Identity $SamAccountName -ChangePasswordAtLogon $true -ErrorAction Stop
        }
        if ($Enabled) {
            Enable-ADAccount @ad -Identity $SamAccountName -ErrorAction Stop
        }
    }

    return $upn
}

function New-DsmtGroup {
    param(
        $Credential,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $TargetOu,
        [ValidateSet('Security', 'Distribution')][string] $Category = 'Security',
        [ValidateSet('Global', 'Universal', 'DomainLocal')][string] $Scope = 'Global',
        [string] $Description = ''
    )

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'write'

    $new = @{
        Name          = $Name
        SamAccountName = $Name
        GroupCategory = $Category
        GroupScope    = $Scope
        Path          = $TargetOu
    }
    if ($Description) { $new.Description = $Description }

    New-ADGroup @ad @new -ErrorAction Stop
}

function Remove-DsmtObject {
    <#
    .SYNOPSIS
        Deletes a user or group. Uses -Recursive for objects that may have
        child objects so the call does not fail halfway.
    #>
    param($Credential, [Parameter(Mandatory = $true)][string] $Identity, [Parameter(Mandatory = $true)][ValidateSet('user', 'group')][string] $Type)

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'write'

    if ($Type -eq 'user') {
        $obj = Get-ADUser @ad -Identity $Identity -ErrorAction Stop
    } else {
        $obj = Get-ADGroup @ad -Identity $Identity -ErrorAction Stop
    }

    Remove-ADObject @ad -Identity $obj.DistinguishedName -Recursive -Confirm:$false -ErrorAction Stop
}
