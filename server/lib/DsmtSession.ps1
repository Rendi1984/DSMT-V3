<#
.SYNOPSIS
    DSMT - operator sessions.
.DESCRIPTION
    An operator signs in with a real domain account. The credentials are
    validated against the domain and then held in memory for the lifetime of
    the session, because every directory read and write is performed AS THAT
    OPERATOR (-Credential on the AD cmdlets). That is deliberate: it means AD
    itself enforces what the operator may do, and the change is attributed to
    their account on the domain controller - not to a shared service account.

    SECURITY NOTE: holding the operator's password in the server process for
    the session lifetime is what makes per-operator attribution possible
    without Kerberos delegation. It also means this server must run on a
    trusted, restricted host and should be exposed over HTTPS only. See
    README.md "Security model".
.NOTES
    Author  : IT Team
#>

$script:DsmtSessions = @{}

function New-DsmtSession {
    <#
    .SYNOPSIS
        Validates domain credentials and, on success, creates a session.
    .OUTPUTS
        Hashtable with Ok, Token, Error.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Username,
        [Parameter(Mandatory = $true)][string] $Password
    )

    $cfg = Get-DsmtConfig

    # Accept DOMAIN\user, user@domain and bare user.
    $bare = $Username
    if ($bare -match '^(?<dom>[^\\]+)\\(?<user>.+)$') { $bare = $Matches['user'] }
    elseif ($bare -match '^(?<user>[^@]+)@(?<dom>.+)$') { $bare = $Matches['user'] }

    $ctx = $null
    try {
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
        if ($cfg.Server) {
            $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
                [System.DirectoryServices.AccountManagement.ContextType]::Domain, $cfg.Server)
        } else {
            $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
                [System.DirectoryServices.AccountManagement.ContextType]::Domain, $cfg.Domain)
        }
    } catch {
        Write-DsmtLog -Level 'ERROR' -Message ('Cannot reach domain ' + $cfg.Domain + ': ' + $_.Exception.Message)
        return @{ Ok = $false; Error = 'Cannot reach the domain (' + $cfg.Domain + '). ' + $_.Exception.Message }
    }

    $valid = $false
    try {
        # Negotiate + signing + sealing is the default for a Domain context,
        # which is what lets Set-ADAccountPassword work later without LDAPS.
        $valid = $ctx.ValidateCredentials($bare, $Password)
    } catch {
        $ctx.Dispose()
        Write-DsmtLog -Level 'WARN' -Message ('Credential validation failed for ' + $bare + ': ' + $_.Exception.Message)
        return @{ Ok = $false; Error = 'Sign-in failed: ' + $_.Exception.Message }
    }

    if (-not $valid) {
        $ctx.Dispose()
        Write-DsmtLog -Level 'WARN' -Message ('Rejected sign-in for ' + $bare)
        return @{ Ok = $false; Error = 'The user name or password is incorrect.' }
    }

    # Look the operator up so the UI can show their real display name.
    $upnUser = $bare + '@' + $cfg.Domain
    $secure  = ConvertTo-SecureString -String $Password -AsPlainText -Force
    $cred    = New-Object System.Management.Automation.PSCredential($upnUser, $secure)

    $identity = $null
    try {
        $identity = Get-DsmtOperatorIdentity -SamAccountName $bare -Credential $cred
    } catch {
        Write-DsmtLog -Level 'WARN' -Message ('Signed in as ' + $bare + ' but could not read their own AD object: ' + $_.Exception.Message)
    }

    $ctx.Dispose()

    $token = [guid]::NewGuid().ToString('N')
    $now   = Get-Date

    $displayName = $bare
    $ouPath      = ''
    $dn          = ''
    if ($null -ne $identity) {
        if ($identity.DisplayName) { $displayName = $identity.DisplayName }
        $ouPath = $identity.Ou
        $dn     = $identity.Dn
    }

    $netbios = $cfg.Domain.Split('.')[0].ToUpper()

    $script:DsmtSessions[$token] = @{
        Token       = $token
        Sam         = $bare
        Upn         = $upnUser
        Display     = $displayName
        Account     = $netbios + '\' + $bare
        Dn          = $dn
        Ou          = $ouPath
        Credential  = $cred
        CreatedUtc  = $now.ToUniversalTime()
        LastSeenUtc = $now.ToUniversalTime()
    }

    # Record who signed in. Only identity and timestamps go to SQL - the
    # password stays in this process and is never persisted anywhere.
    Register-DsmtOperator -Account ($netbios + '\' + $bare) -Sam $bare -Display $displayName -Upn $upnUser -Token $token

    Write-DsmtLog -Message ('Session opened for ' + $netbios + '\' + $bare)
    return @{ Ok = $true; Token = $token }
}

function Get-DsmtSession {
    <#
    .SYNOPSIS
        Returns the session for a token, or $null when it is unknown or has
        gone idle past the configured lifetime. Touches LastSeenUtc.
    #>
    param([string] $Token)

    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    if (-not $script:DsmtSessions.ContainsKey($Token)) { return $null }

    $cfg = Get-DsmtConfig
    $s   = $script:DsmtSessions[$Token]
    $age = (Get-Date).ToUniversalTime() - $s.LastSeenUtc

    if ($age.TotalHours -ge $cfg.SessionHours) {
        Remove-DsmtSession -Token $Token -Reason 'idle timeout'
        return $null
    }

    $s.LastSeenUtc = (Get-Date).ToUniversalTime()
    return $s
}

function Remove-DsmtSession {
    param([string] $Token, [string] $Reason = 'signed out')

    if ([string]::IsNullOrWhiteSpace($Token)) { return }
    if ($script:DsmtSessions.ContainsKey($Token)) {
        $who = $script:DsmtSessions[$Token].Account
        $script:DsmtSessions.Remove($Token)
        Close-DsmtSqlSession -Token $Token -Reason $Reason
        Write-DsmtLog -Message ('Session closed for ' + $who + ' (' + $Reason + ')')
    }
}

function Clear-DsmtExpiredSessions {
    <#
    .SYNOPSIS
        Drops idle sessions. Called from the request loop so credentials are
        not held in memory longer than the configured window.
    #>
    $cfg = Get-DsmtConfig
    $now = (Get-Date).ToUniversalTime()

    $stale = @()
    foreach ($key in $script:DsmtSessions.Keys) {
        if (($now - $script:DsmtSessions[$key].LastSeenUtc).TotalHours -ge $cfg.SessionHours) {
            $stale += $key
        }
    }
    foreach ($key in $stale) { Remove-DsmtSession -Token $key -Reason 'idle timeout' }
}
