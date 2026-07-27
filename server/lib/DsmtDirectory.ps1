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

    Every write runs with the operator's own credentials, so the domain
    controller enforces permissions and records the change against their
    account.
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

    $ad = Get-DsmtAdParams -Credential $Credential
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
    #>
    param($Credential)

    Assert-DsmtAdModule
    return @{
        Server     = (Get-DsmtServer -Credential $Credential)
        Credential = $Credential
    }
}

function Get-DsmtDomainInfo {
    <#
    .SYNOPSIS
        Real domain name and the real list of domain controllers. The console
        header shows this - it is not a hardcoded string.
    #>
    param($Credential)

    $ad  = Get-DsmtAdParams -Credential $Credential
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

    $ad  = Get-DsmtAdParams -Credential $Credential
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

    $ad = Get-DsmtAdParams -Credential $Credential
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
    'description', 'managedBy', 'whenCreated', 'member', 'mail', 'objectGUID', 'info'
)

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

function Get-DsmtGroups {
    param($Credential, [string] $Query = '', [int] $Limit = 0)

    $ad  = Get-DsmtAdParams -Credential $Credential
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

    $ad = Get-DsmtAdParams -Credential $Credential
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

    $ad     = Get-DsmtAdParams -Credential $Credential
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

    $ad     = Get-DsmtAdParams -Credential $Credential
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

    $ad = Get-DsmtAdParams -Credential $Credential
    Unlock-ADAccount @ad -Identity $Identity -ErrorAction Stop
}

function Set-DsmtAccountEnabled {
    param($Credential, [Parameter(Mandatory = $true)][string] $Identity, [Parameter(Mandatory = $true)][bool] $Enabled)

    $ad = Get-DsmtAdParams -Credential $Credential
    if ($Enabled) {
        Enable-ADAccount @ad -Identity $Identity -ErrorAction Stop
    } else {
        Disable-ADAccount @ad -Identity $Identity -ErrorAction Stop
    }
}

function Move-DsmtObject {
    param($Credential, [Parameter(Mandatory = $true)][string] $Identity, [Parameter(Mandatory = $true)][string] $TargetOu)

    $ad = Get-DsmtAdParams -Credential $Credential
    Move-ADObject @ad -Identity $Identity -TargetPath $TargetOu -ErrorAction Stop
}

function Add-DsmtGroupMember {
    param($Credential, [Parameter(Mandatory = $true)][string] $Group, [Parameter(Mandatory = $true)][string[]] $Members)

    $ad = Get-DsmtAdParams -Credential $Credential
    Add-ADGroupMember @ad -Identity $Group -Members $Members -Confirm:$false -ErrorAction Stop
}

function Remove-DsmtGroupMember {
    param($Credential, [Parameter(Mandatory = $true)][string] $Group, [Parameter(Mandatory = $true)][string[]] $Members)

    $ad = Get-DsmtAdParams -Credential $Credential
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

    $ad  = Get-DsmtAdParams -Credential $Credential
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

    $ad = Get-DsmtAdParams -Credential $Credential

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

    $ad = Get-DsmtAdParams -Credential $Credential

    if ($Type -eq 'user') {
        $obj = Get-ADUser @ad -Identity $Identity -ErrorAction Stop
    } else {
        $obj = Get-ADGroup @ad -Identity $Identity -ErrorAction Stop
    }

    Remove-ADObject @ad -Identity $obj.DistinguishedName -Recursive -Confirm:$false -ErrorAction Stop
}
