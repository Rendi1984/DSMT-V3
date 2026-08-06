<#
.SYNOPSIS
    DSMT - group managed service account (gMSA) tooling.
.DESCRIPTION
    Everything the Tools -> gMSA screen needs, in one file.

    A gMSA is the right way to run DSMT: the domain generates and rotates the
    password, nobody ever types it, and it cannot expire. Standing one up for
    the first time is a five-step job that trips people up in the same three
    places every time, so this file is organised around reporting real state
    rather than around the happy path.

    WHAT THIS FILE CAN AND CANNOT DO, and why - read before extending it.

    Can, as the signed-in operator, against the domain:
      - read whether the forest has a KDS root key, and when it becomes usable
      - create the security group that will hold the permitted computers
      - add and remove computer accounts in that group
      - create the gMSA itself
      - report the true state of all of the above at any moment

    Cannot, and no amount of code here will change it:
      - Add-KdsRootKey takes neither -Credential nor -Server. It acts on the
        forest of the machine it runs on, as whoever is running it. So DSMT
        can only run it in-process, as the account the SERVER runs as - never
        as the operator - and only when the Kds module is present locally.
        That is a genuine attribution gap and the UI says so out loud.
      - Install-ADServiceAccount and Test-ADServiceAccount act on the LOCAL
        machine's LSA secret store and need local administrator. The server
        process deliberately does not have that, so those two stay generated
        commands the operator runs in an elevated shell.

    The 10-hour wait is the single most common surprise. A KDS root key
    created with -EffectiveImmediately is NOT usable immediately: domain
    controllers need up to 10 hours to converge on it. The lab shortcut
    (-EffectiveTime backdated) exists and is offered, clearly marked as
    unsafe outside a lab, because in a lab the alternative is losing a day.
.NOTES
    Author  : IT Team
    Runtime : Windows PowerShell 5.1
#>

# The KDS root keys live in the forest's configuration partition. Reading them
# there works with -Credential and -Server, which is why the CHECK is remote
# but the CREATE is not.
$script:DsmtKdsContainer = 'CN=Master Root Keys,CN=Group Key Distribution Service,CN=Services,CN=Configuration,'

# How long domain controllers may take to converge on a new root key.
$script:DsmtKdsWaitHours = 10

function Get-DsmtKdsStatus {
    <#
    .SYNOPSIS
        Does this forest have a usable KDS root key?
    .OUTPUTS
        Hashtable: Ok, Error, Exists, Usable, EffectiveUtc, UsableFromUtc,
        HoursRemaining, KeyCount.
    #>
    param($Credential)

    $result = @{
        Ok             = $false
        Error          = ''
        Exists         = $false
        Usable         = $false
        EffectiveUtc   = ''
        UsableFromUtc  = ''
        HoursRemaining = 0
        KeyCount       = 0
    }

    try {
        $ad     = Get-DsmtAdParams -Credential $Credential -Intent 'read'
        $domain = Get-ADDomain @ad -ErrorAction Stop

        # Build the configuration NC from the FOREST root, not the domain: in
        # a child domain they are not the same, and the keys only ever live in
        # the forest's.
        $forestDn = 'DC=' + ([string]$domain.Forest).Replace('.', ',DC=')
        $searchBase = $script:DsmtKdsContainer + $forestDn

        $keys = @(Get-ADObject @ad -SearchBase $searchBase -Filter { objectClass -eq 'msKds-ProvRootKey' } `
                                -Properties 'msKds-UseStartTime', 'whenCreated', 'name' -ErrorAction Stop)

        $result.KeyCount = $keys.Count
        $result.Exists   = ($keys.Count -gt 0)
        $result.Ok       = $true

        if (-not $result.Exists) { return $result }

        # The newest key decides. msKds-UseStartTime is a FILETIME; when it is
        # missing fall back to whenCreated, which is never later than the key
        # is actually usable.
        $best = $null
        foreach ($key in $keys) {
            $start = $null
            $raw = $key.'msKds-UseStartTime'
            if ($null -ne $raw) {
                try { $start = [datetime]::FromFileTimeUtc([int64]$raw) } catch { $start = $null }
            }
            if ($null -eq $start -and $null -ne $key.whenCreated) {
                try { $start = ([datetime]$key.whenCreated).ToUniversalTime() } catch { $start = $null }
            }
            if ($null -eq $start) { continue }
            if ($null -eq $best -or $start -lt $best) { $best = $start }
        }

        if ($null -eq $best) {
            # A key exists but its start time could not be read. Report it as
            # present and let the operator judge, rather than claiming usable.
            return $result
        }

        $usableFrom = $best.AddHours($script:DsmtKdsWaitHours)
        $now        = (Get-Date).ToUniversalTime()

        $result.EffectiveUtc  = $best.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $result.UsableFromUtc = $usableFrom.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $result.Usable        = ($now -ge $usableFrom)

        if (-not $result.Usable) {
            $result.HoursRemaining = [int][math]::Ceiling(($usableFrom - $now).TotalHours)
        }
    } catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Test-DsmtKdsModule {
    <#
    .SYNOPSIS
        Is the Kds module available on THIS host, so Add-KdsRootKey could run
        here at all? Present on a domain controller and anywhere the AD DS
        role or the matching RSAT tools are installed.
    #>
    $cmd = Get-Command -Name 'Add-KdsRootKey' -ErrorAction SilentlyContinue
    return ($null -ne $cmd)
}

function New-DsmtKdsRootKey {
    <#
    .SYNOPSIS
        Creates the forest's KDS root key.
    .DESCRIPTION
        Runs IN PROCESS, as the account the DSMT server runs as, because
        Add-KdsRootKey accepts no credential and no server. The caller must
        have told the operator this before getting here.

        -Backdate is the lab shortcut: it sets the effective time ten hours in
        the past so the key is usable at once. It is offered because in a lab
        the alternative is waiting a day, and refused-by-default because in
        production it means domain controllers can be asked for a key they
        have not yet replicated.
    .OUTPUTS
        Hashtable: Ok, Error, Backdated, Message.
    #>
    param([bool] $Backdate = $false)

    if (-not (Test-DsmtKdsModule)) {
        return @{
            Ok = $false; Backdated = $false; Message = ''
            Error = 'The Kds module is not available on this host, so the key cannot be created from here. Run the command shown above on a domain controller.'
        }
    }

    try {
        if ($Backdate) {
            $when = (Get-Date).AddHours(-1 * $script:DsmtKdsWaitHours)
            Add-KdsRootKey -EffectiveTime $when -ErrorAction Stop | Out-Null
            return @{ Ok = $true; Error = ''; Backdated = $true
                      Message = 'The KDS root key was created with a backdated effective time and is usable now. This is a lab shortcut - on a production forest the key should have been left to converge for ' + [string]$script:DsmtKdsWaitHours + ' hours.' }
        }

        Add-KdsRootKey -EffectiveImmediately -ErrorAction Stop | Out-Null
        return @{ Ok = $true; Error = ''; Backdated = $false
                  Message = 'The KDS root key was created. Domain controllers need up to ' + [string]$script:DsmtKdsWaitHours + ' hours to converge on it - gMSA creation will fail until then, and that is expected, not a fault.' }
    } catch {
        return @{ Ok = $false; Error = $_.Exception.Message; Backdated = $false; Message = '' }
    }
}

function Get-DsmtComputerAccount {
    <#
    .SYNOPSIS
        Resolves one computer name to its AD account, tolerating the three
        ways people type them: NAME, NAME$ and a full DNS host name.
    .OUTPUTS
        The AD object, or $null.
    #>
    param($Credential, [Parameter(Mandatory = $true)][string] $Name)

    $ad   = Get-DsmtAdParams -Credential $Credential -Intent 'read'
    $bare = $Name.Trim()

    if ($bare.EndsWith('$')) { $bare = $bare.Substring(0, $bare.Length - 1) }
    if ($bare.Contains('.'))  { $bare = $bare.Split('.')[0] }
    if ([string]::IsNullOrWhiteSpace($bare)) { return $null }

    $escaped = ConvertTo-DsmtLdapEscape -Value $bare
    $found = @(Get-ADComputer @ad -LDAPFilter ('(sAMAccountName=' + $escaped + '$)') `
                              -Properties 'dNSHostName', 'operatingSystem' -ErrorAction SilentlyContinue)

    if ($found.Count -gt 0) { return $found[0] }
    return $null
}

function New-DsmtGmsaGroup {
    <#
    .SYNOPSIS
        Creates the security group that will hold the computers permitted to
        retrieve the gMSA password.
    .DESCRIPTION
        A group rather than a list of computers on the account itself, because
        a list has to be rewritten - and the account taken offline - every time
        a host is added or replaced. The group is the whole point.
    #>
    param(
        $Credential,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Path,
        [string] $Description = ''
    )

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'write'

    if ([string]::IsNullOrWhiteSpace($Description)) {
        $Description = 'Computers permitted to retrieve a gMSA password. Managed by DSMT.'
    }

    New-ADGroup @ad -Name $Name -SamAccountName $Name -GroupCategory Security `
                -GroupScope Global -Path $Path -Description $Description -ErrorAction Stop
}

function Get-DsmtGmsaGroupMembers {
    <#
    .SYNOPSIS
        The computers currently in a group - name, DNS name and whether the
        account is enabled.
    #>
    param($Credential, [Parameter(Mandatory = $true)][string] $Group)

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'read'
    $members = @(Get-ADGroupMember @ad -Identity $Group -ErrorAction Stop)

    $rows = @()
    foreach ($m in $members) {
        $dns = ''
        $enabled = $true
        if ($m.objectClass -eq 'computer') {
            try {
                $c = Get-ADComputer @ad -Identity $m.distinguishedName -Properties 'dNSHostName' -ErrorAction Stop
                $dns = [string]$c.dNSHostName
                $enabled = [bool]$c.Enabled
            } catch { }
        }
        $rows += [ordered]@{
            name    = [string]$m.Name
            sam     = [string]$m.SamAccountName
            kind    = [string]$m.objectClass
            dns     = $dns
            enabled = $enabled
        }
    }

    return @($rows)
}

function Get-DsmtGmsaList {
    <#
    .SYNOPSIS
        Every gMSA in the domain, with the principals allowed to retrieve
        each password - which is the field people forget to set.
    #>
    param($Credential)

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'read'
    $accounts = @(Get-ADServiceAccount @ad -Filter * `
                    -Properties 'PrincipalsAllowedToRetrieveManagedPassword', 'DNSHostName', 'Created', 'Enabled' `
                    -ErrorAction Stop)

    $rows = @()
    foreach ($a in $accounts) {
        $principals = @()
        foreach ($p in @($a.PrincipalsAllowedToRetrieveManagedPassword)) {
            if ($null -eq $p) { continue }
            $principals += (Get-DsmtNameFromDn -Dn ([string]$p))
        }

        $rows += [ordered]@{
            name       = [string]$a.Name
            sam        = [string]$a.SamAccountName
            dns        = [string]$a.DNSHostName
            enabled    = [bool]$a.Enabled
            principals = @($principals)
            dn         = [string]$a.DistinguishedName
        }
    }

    return @($rows)
}

function New-DsmtGmsa {
    <#
    .SYNOPSIS
        Creates the gMSA against the permitted-computers group.
    .DESCRIPTION
        -PrincipalsAllowedToRetrieveManagedPassword is set at creation rather
        than left for later, because an account created without it looks
        perfectly healthy in AD and then fails to install on every host with
        an error that names none of this.
    #>
    param(
        $Credential,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $DnsHostName,
        [Parameter(Mandatory = $true)][string] $Group
    )

    $ad = Get-DsmtAdParams -Credential $Credential -Intent 'write'

    New-ADServiceAccount @ad -Name $Name -DNSHostName $DnsHostName `
                         -PrincipalsAllowedToRetrieveManagedPassword $Group `
                         -Enabled $true -ErrorAction Stop
}

function Get-DsmtGmsaState {
    <#
    .SYNOPSIS
        The whole picture in one call: KDS key, the group, its members, the
        account, and what is left to do.
    .DESCRIPTION
        Everything here is READ FRESH. Nothing is remembered from a previous
        call and nothing is inferred from what the operator clicked - a wizard
        that shows a green tick because a button was pressed last week is the
        fake-data failure wearing a different hat. After a reboot, after
        someone edits the group by hand, after the ten hours elapse, the only
        honest answer comes from asking the directory again.
    .OUTPUTS
        Hashtable describing every step, plus the commands that must be run
        elsewhere.
    #>
    param(
        $Credential,
        [string] $GroupName = '',
        [string] $GmsaName = ''
    )

    $state = @{
        Ok            = $true
        Error         = ''
        Kds           = (Get-DsmtKdsStatus -Credential $Credential)
        KdsLocal      = (Test-DsmtKdsModule)
        GroupName     = $GroupName
        GroupExists   = $false
        GroupDn       = ''
        Members       = @()
        GmsaName      = $GmsaName
        GmsaExists    = $false
        GmsaDns       = ''
        GmsaPrincipals = @()
        Accounts      = @()
        DefaultOu     = ''
        DomainDns     = ''
    }

    try {
        $ad     = Get-DsmtAdParams -Credential $Credential -Intent 'read'
        $domain = Get-ADDomain @ad -ErrorAction Stop
        $state.DomainDns = [string]$domain.DNSRoot
        $state.DefaultOu = [string]$domain.ComputersContainer
    } catch {
        $state.Ok = $false
        $state.Error = $_.Exception.Message
        return $state
    }

    if (-not [string]::IsNullOrWhiteSpace($GroupName)) {
        try {
            $ad = Get-DsmtAdParams -Credential $Credential -Intent 'read'
            $escaped = ConvertTo-DsmtLdapEscape -Value $GroupName
            $found = @(Get-ADGroup @ad -LDAPFilter ('(sAMAccountName=' + $escaped + ')') -ErrorAction SilentlyContinue)
            if ($found.Count -gt 0) {
                $state.GroupExists = $true
                $state.GroupDn = [string]$found[0].DistinguishedName
                $state.Members = @(Get-DsmtGmsaGroupMembers -Credential $Credential -Group $found[0].DistinguishedName)
            }
        } catch {
            # A group that cannot be read is reported as absent with the error
            # attached, never as present-and-empty.
            $state.Error = $_.Exception.Message
        }
    }

    try {
        $state.Accounts = @(Get-DsmtGmsaList -Credential $Credential)
    } catch {
        $state.Accounts = @()
    }

    if (-not [string]::IsNullOrWhiteSpace($GmsaName)) {
        $wanted = $GmsaName.Trim().TrimEnd('$')
        foreach ($a in $state.Accounts) {
            if ($a.name -eq $wanted) {
                $state.GmsaExists     = $true
                $state.GmsaDns        = $a.dns
                $state.GmsaPrincipals = @($a.principals)
            }
        }
    }

    return $state
}
