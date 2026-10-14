# ---------------------------------------------------------------------------
# DsmtHttps.ps1 - certificate discovery and the http.sys SSL binding.
#
# WHY THIS EXISTS
# The console asks operators for their domain password and then holds their
# credential in process memory for the session. Serving that over plain HTTP
# puts the password on the wire in clear text. This module is what turns that
# off, configured AFTER installation from Settings -> HTTPS rather than during
# the install, because a certificate usually does not exist yet at install
# time.
#
# WHAT IT DELIBERATELY DOES NOT DO
# It does not accept a .pfx upload from the browser, and it never sees a
# private key or its password. Two reasons, and the first one is decisive:
#
#   1. The console is on plain HTTP until HTTPS is switched on. Uploading a
#      .pfx and its password through that connection would send the private
#      key's password in clear text over the very channel this feature exists
#      to protect. The chicken-and-egg is not solvable by being careful.
#   2. "DSMT must never hold a private key" is already the recorded rule for
#      the certificate-services proposal in PROGRESS.md. Enrolling for the
#      DSMT host itself is the one case that proposal allows, and it allows it
#      precisely because the key stays on this machine.
#
# So the console READS the machine's certificate store, and where a
# certificate has to be put there first, it GENERATES the command for the
# operator to run on the server - the same choice already made for
# Install-ADServiceAccount in the gMSA tool.
#
# ELEVATION
# Both the store read and the netsh binding are machine-wide. The service runs
# as LocalSystem and is fine; a hand-started non-elevated Start-DSMT.ps1 can
# list certificates and cannot bind one. That case returns a sentence naming
# the fix, never a raw access-denied - same rule as the registry settings.
# ---------------------------------------------------------------------------

# The GUID http.sys records as the owner of a binding. It is not a secret and
# not a product code; it only has to be stable so that a binding DSMT created
# can be recognised as DSMT's and safely replaced. Chosen once, never change.
$script:DsmtSslAppId = '{6d9d1f2b-4a3c-4e7f-9b1a-2c8e5d0f7a41}'

# The EKU that says a certificate may authenticate a server. A certificate
# without it will bind and then fail in the browser.
$script:DsmtServerAuthOid = '1.3.6.1.5.5.7.3.1'

$script:DsmtCertStore = 'Cert:\LocalMachine\My'

function Test-DsmtElevated {
    <#
    .SYNOPSIS
        True when this process can write machine-wide state.
    #>
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function ConvertTo-DsmtCertificate {
    <#
    .SYNOPSIS
        One certificate, mapped to the field names the front end reads.
    .DESCRIPTION
        Every value that can throw is computed into its own variable BEFORE
        the [ordered]@{} literal. A hashtable literal is all-or-nothing: a
        cast that throws inside it loses the whole object, not one field, and
        the caller then renders blank rows with no error. That exact failure
        cost this project a release (see CLAUDE.md), and certificate objects
        are full of properties that are absent rather than empty.
    #>
    param([Parameter(Mandatory = $true)] $Cert)

    $thumb = ''
    try { $thumb = [string]$Cert.Thumbprint } catch { $thumb = '' }

    $subject = ''
    try { $subject = [string]$Cert.Subject } catch { $subject = '' }

    $issuer = ''
    try { $issuer = [string]$Cert.Issuer } catch { $issuer = '' }

    $friendly = ''
    try { $friendly = [string]$Cert.FriendlyName } catch { $friendly = '' }

    $notAfter  = ''
    $notBefore = ''
    $days      = 0
    $expired   = $false
    $notYet    = $false
    try {
        $notAfter  = $Cert.NotAfter.ToString('yyyy-MM-dd')
        $notBefore = $Cert.NotBefore.ToString('yyyy-MM-dd')
        $days      = [int]([math]::Floor(($Cert.NotAfter - (Get-Date)).TotalDays))
        $expired   = ((Get-Date) -gt $Cert.NotAfter)
        $notYet    = ((Get-Date) -lt $Cert.NotBefore)
    } catch {
        $notAfter = ''
    }

    $hasKey = $false
    try { $hasKey = [bool]$Cert.HasPrivateKey } catch { $hasKey = $false }

    # EnhancedKeyUsageList is absent on some certificates rather than empty,
    # so this is read defensively. A certificate with NO EKU at all is valid
    # for every purpose, which includes server authentication - treating an
    # empty list as "not usable" would hide a perfectly good certificate.
    $serverAuth = $false
    $ekuCount   = 0
    try {
        $ekus = @($Cert.EnhancedKeyUsageList)
        $ekuCount = $ekus.Count
        if ($ekuCount -eq 0) {
            $serverAuth = $true
        } else {
            foreach ($eku in $ekus) {
                if ([string]$eku.ObjectId -eq $script:DsmtServerAuthOid) { $serverAuth = $true }
            }
        }
    } catch {
        $serverAuth = $true
        $ekuCount   = 0
    }

    # The names a browser will actually check. Without a matching SAN, a
    # certificate that looks perfect here still fails in the address bar, so
    # this is shown rather than left for the operator to discover.
    $dnsNames = @()
    try {
        foreach ($n in @($Cert.DnsNameList)) {
            $v = [string]$n.Unicode
            if ([string]::IsNullOrWhiteSpace($v)) { $v = [string]$n }
            if (-not [string]::IsNullOrWhiteSpace($v)) { $dnsNames += $v }
        }
    } catch {
        $dnsNames = @()
    }

    $usable = ($hasKey -and $serverAuth -and -not $expired -and -not $notYet)

    $why = ''
    if (-not $hasKey)   { $why = 'No private key on this machine - import the .pfx, not the .cer.' }
    elseif ($expired)   { $why = 'Expired on ' + $notAfter + '.' }
    elseif ($notYet)    { $why = 'Not valid until ' + $notBefore + '.' }
    elseif (-not $serverAuth) { $why = 'No Server Authentication usage - a browser will refuse it.' }

    return [ordered]@{
        thumbprint = $thumb
        subject    = $subject
        issuer     = $issuer
        friendly   = $friendly
        notAfter   = $notAfter
        notBefore  = $notBefore
        days       = $days
        hasKey     = $hasKey
        serverAuth = $serverAuth
        expired    = $expired
        dnsNames   = @($dnsNames)
        usable     = $usable
        why        = $why
    }
}

function Get-DsmtCertificates {
    <#
    .SYNOPSIS
        Every certificate in the machine's personal store, mapped for display.
    .DESCRIPTION
        Returns unusable ones too, each carrying the reason. Hiding them would
        turn "my certificate is not in the list" into a support question with
        no answer on screen; showing it with "No private key on this machine"
        answers it.

        Returns @($list) and NOT ,@($list): an empty store is a normal
        outcome, and the comma operator on an empty list serialises as [[]] -
        one row of blanks in the UI. Every call site wraps this in @().
    #>
    $out = @()

    if (-not (Test-Path -LiteralPath $script:DsmtCertStore)) { return @($out) }

    $certs = @()
    try {
        $certs = @(Get-ChildItem -LiteralPath $script:DsmtCertStore -ErrorAction Stop)
    } catch {
        Write-DsmtLog -Level 'WARN' -Message ('Could not read ' + $script:DsmtCertStore + ': ' + $_.Exception.Message)
        return @($out)
    }

    foreach ($c in $certs) {
        $row = $null
        try {
            $row = ConvertTo-DsmtCertificate -Cert $c
        } catch {
            $row = $null
        }
        if ($null -ne $row) { $out += $row }
    }

    # Usable first, then soonest to expire - the order an operator picking one
    # actually wants.
    $sorted = @($out | Sort-Object -Property @{ Expression = { -not $_.usable } }, @{ Expression = { $_.days } })
    return @($sorted)
}

function Get-DsmtSslBinding {
    <#
    .SYNOPSIS
        The certificate currently bound to a port in http.sys, if any.
    .OUTPUTS
        Hashtable with Bound, Thumbprint, AppId, Mine, Error.
    .DESCRIPTION
        netsh output is console text and is localised, which this project has
        already decided not to parse for repadmin. The difference here is that
        there is no object API for http.sys bindings on PowerShell 5.1 at all,
        so netsh is the only way. It is isolated in THIS ONE FUNCTION and the
        match is on hex and GUID shapes rather than on any English label, so a
        German or French server still parses.
    #>
    param([Parameter(Mandatory = $true)][int] $Port)

    $result = @{ Bound = $false; Thumbprint = ''; AppId = ''; Mine = $false; Error = '' }

    # Every netsh argument is built as a complete string first. Unquoted
    # arguments containing a colon or a brace are parsed by PowerShell before
    # they reach the executable, and an appid written inline with its braces
    # is the kind of thing that works until it does not. Build, then pass.
    $ipport = 'ipport=0.0.0.0:' + [string]$Port

    $text = ''
    try {
        $text = (& netsh http show sslcert $ipport 2>&1 | Out-String)
    } catch {
        $result.Error = $_.Exception.Message
        return $result
    }

    if ([string]::IsNullOrWhiteSpace($text)) { return $result }

    # A 40-character hex run is a thumbprint in any language.
    $m = [regex]::Match($text, '\b([0-9a-fA-F]{40})\b')
    if (-not $m.Success) { return $result }

    $result.Bound      = $true
    $result.Thumbprint = $m.Groups[1].Value.ToUpper()

    $g = [regex]::Match($text, '\{[0-9a-fA-F\-]{36}\}')
    if ($g.Success) {
        $result.AppId = $g.Value
        $result.Mine  = ($g.Value.ToLower() -eq $script:DsmtSslAppId.ToLower())
    }

    return $result
}

function Set-DsmtSslBinding {
    <#
    .SYNOPSIS
        Binds a certificate to a port in http.sys, replacing DSMT's own
        binding if one is already there.
    .OUTPUTS
        Hashtable with Ok, Error, Replaced.
    .DESCRIPTION
        Refuses to replace a binding this project did not create. Another
        product on the same host - IIS, a monitoring agent - can legitimately
        own a binding, and silently taking its port is how an unrelated
        service goes down at 3am with no trace of what did it.
    #>
    param(
        [Parameter(Mandatory = $true)][int]    $Port,
        [Parameter(Mandatory = $true)][string] $Thumbprint
    )

    $out = @{ Ok = $false; Error = ''; Replaced = $false }

    if (-not (Test-DsmtElevated)) {
        $out.Error = 'Binding a certificate to a port is machine-wide and needs an elevated process. ' +
                     'DSMT running as a Windows service (LocalSystem) can do it; a hand-started ' +
                     'PowerShell window cannot. Either restart DSMT as the installed service, or run ' +
                     'this once in an elevated prompt: ' + (Get-DsmtSslCommand -Port $Port -Thumbprint $Thumbprint)
        return $out
    }

    $clean = ($Thumbprint -replace '[^0-9a-fA-F]', '').ToUpper()
    if ($clean.Length -ne 40) {
        $out.Error = 'That does not look like a certificate thumbprint (40 hex characters).'
        return $out
    }

    $existing = Get-DsmtSslBinding -Port $Port
    if ($existing.Bound) {
        if (-not $existing.Mine) {
            $out.Error = 'Port ' + $Port + ' already has a certificate bound by something else on this ' +
                         'host (application ID ' + $existing.AppId + '). DSMT will not replace a binding ' +
                         'it did not create. Choose a different port, or remove that binding deliberately ' +
                         'with: netsh http delete sslcert ipport=0.0.0.0:' + $Port
            return $out
        }

        try {
            (& netsh http delete sslcert ('ipport=0.0.0.0:' + [string]$Port) 2>&1) | Out-Null
            $out.Replaced = $true
        } catch {
            $out.Error = 'Could not remove the previous binding: ' + $_.Exception.Message
            return $out
        }
    }

    $argIpport   = 'ipport=0.0.0.0:' + [string]$Port
    $argCerthash = 'certhash=' + $clean
    $argAppid    = 'appid=' + $script:DsmtSslAppId

    $text = ''
    try {
        $text = (& netsh http add sslcert $argIpport $argCerthash $argAppid 2>&1 | Out-String)
    } catch {
        $out.Error = $_.Exception.Message
        return $out
    }

    # netsh does not set $LASTEXITCODE reliably across versions, so the result
    # is confirmed by reading the binding back rather than trusting the text.
    $check = Get-DsmtSslBinding -Port $Port
    if ($check.Bound -and $check.Thumbprint -eq $clean) {
        $out.Ok = $true
        return $out
    }

    $out.Error = 'The binding did not take. netsh said: ' + ($text.Trim())
    return $out
}

function Remove-DsmtSslBinding {
    <#
    .SYNOPSIS
        Removes DSMT's own binding from a port. Leaves anyone else's alone.
    #>
    param([Parameter(Mandatory = $true)][int] $Port)

    $out = @{ Ok = $false; Error = '' }

    $existing = Get-DsmtSslBinding -Port $Port
    if (-not $existing.Bound) {
        $out.Ok = $true
        return $out
    }
    if (-not $existing.Mine) {
        $out.Error = 'The certificate on port ' + $Port + ' was bound by something else on this host. ' +
                     'DSMT will not remove it.'
        return $out
    }
    if (-not (Test-DsmtElevated)) {
        $out.Error = 'Removing a certificate binding needs an elevated process. Run this once in an ' +
                     'elevated prompt: netsh http delete sslcert ipport=0.0.0.0:' + $Port
        return $out
    }

    try {
        (& netsh http delete sslcert ('ipport=0.0.0.0:' + [string]$Port) 2>&1) | Out-Null
        $out.Ok = $true
    } catch {
        $out.Error = $_.Exception.Message
    }
    return $out
}

function Get-DsmtSslCommand {
    <#
    .SYNOPSIS
        The elevated command that does by hand what this module does, for the
        case where DSMT cannot do it itself.
    #>
    param(
        [Parameter(Mandatory = $true)][int]    $Port,
        [Parameter(Mandatory = $true)][string] $Thumbprint
    )
    $clean = ($Thumbprint -replace '[^0-9a-fA-F]', '').ToUpper()
    return ('netsh http add sslcert ipport=0.0.0.0:' + $Port + ' certhash=' + $clean +
            ' appid=' + $script:DsmtSslAppId)
}

function Get-DsmtPfxImportCommand {
    <#
    .SYNOPSIS
        The command an operator runs ON THE SERVER to put a certificate into
        the store DSMT reads.
    .DESCRIPTION
        This is the whole reason the console does not take a .pfx upload. The
        file and its password stay on the machine that will use the key, and
        neither crosses the plain-HTTP connection this feature exists to
        replace.
    #>
    return 'Import-PfxCertificate -FilePath C:\path\to\certificate.pfx -CertStoreLocation Cert:\LocalMachine\My -Password (Read-Host -AsSecureString)'
}

function Get-DsmtHttpsState {
    <#
    .SYNOPSIS
        Everything the Settings screen needs about HTTPS, in one read.
    .DESCRIPTION
        The saved intent and the ACTUAL http.sys binding are reported as two
        separate facts, never merged into one "enabled" flag. They can
        disagree - a certificate can be deleted from the store, or a binding
        removed by hand, long after the setting was saved - and a screen that
        showed only the setting would report HTTPS as on while the console
        answers plain HTTP. That is the fake-data failure in CLAUDE.md wearing
        a different hat.
    #>
    $cfg = Get-DsmtConfig

    $saved = Get-DsmtSavedSettings

    $enabled    = $false
    $port       = 8443
    $thumbprint = ''

    if ($null -ne $saved) {
        if ($saved.PSObject.Properties['HttpsEnabled'])    { $enabled    = [bool]$saved.HttpsEnabled }
        if ($saved.PSObject.Properties['HttpsPort'])       { $port       = [int]$saved.HttpsPort }
        if ($saved.PSObject.Properties['HttpsThumbprint']) { $thumbprint = [string]$saved.HttpsThumbprint }
    }

    if ($port -lt 1 -or $port -gt 65535) { $port = 8443 }

    $binding = Get-DsmtSslBinding -Port $port

    # Read the store ONCE and use it for both the picker and the presence
    # check. Two reads could disagree with each other inside one response.
    $allCerts = @(Get-DsmtCertificates)

    # Is the certificate the setting names still in the store?
    $certPresent = $false
    $certRow     = $null
    if (-not [string]::IsNullOrWhiteSpace($thumbprint)) {
        foreach ($c in $allCerts) {
            if ($c.thumbprint -eq $thumbprint.ToUpper()) {
                $certPresent = $true
                $certRow     = $c
            }
        }
    }

    # What the process is ACTUALLY serving right now, which is decided at
    # startup and cannot change while it runs.
    $liveScheme = 'http'
    if ($cfg.Scheme) { $liveScheme = [string]$cfg.Scheme }

    $warning = ''
    if ($enabled -and -not $binding.Bound) {
        $warning = 'HTTPS is switched on in settings but no certificate is bound to port ' + $port +
                   ' on this host. DSMT will refuse to start in HTTPS mode until it is.'
    } elseif ($enabled -and -not $certPresent -and -not [string]::IsNullOrWhiteSpace($thumbprint)) {
        $warning = 'The certificate this setting names is no longer in ' + $script:DsmtCertStore + '.'
    } elseif ($enabled -and $liveScheme -ne 'https') {
        $warning = 'HTTPS is configured but this process is still serving plain HTTP - it has not been ' +
                   'restarted since the change.'
    }

    return [ordered]@{
        enabled      = $enabled
        port         = $port
        thumbprint   = $thumbprint
        certPresent  = $certPresent
        certificate  = $certRow
        certificateList = @($allCerts)
        bound        = $binding.Bound
        boundTo      = $binding.Thumbprint
        boundByDsmt  = $binding.Mine
        boundAppId   = $binding.AppId
        liveScheme   = $liveScheme
        livePort     = $cfg.Port
        elevated     = (Test-DsmtElevated)
        store        = $script:DsmtCertStore
        importCommand = (Get-DsmtPfxImportCommand)
        warning      = $warning
    }
}
