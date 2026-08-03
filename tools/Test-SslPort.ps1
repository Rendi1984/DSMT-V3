<#
.SYNOPSIS
    Checks the SSL/TLS certificate served on a specific host and port.

.EXAMPLE
    .\Test-SslPort.ps1 -ComputerName dc01.lab.local -Port 636
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ComputerName,
    [Parameter(Mandatory = $true)][int]$Port,
    [int]$TimeoutMs = 5000
)

$ErrorActionPreference = 'Stop'
$client = New-Object System.Net.Sockets.TcpClient
try {
    $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
        throw "Connection to ${ComputerName}:${Port} timed out after $TimeoutMs ms."
    }
    $client.EndConnect($async)

    $callback = { param($sn, $cert, $chain, $errors) return $true }
    $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, $callback)
    $ssl.AuthenticateAsClient($ComputerName)

    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
    $now = Get-Date

    $names = @()
    if ($cert.PSObject.Properties['DnsNameList']) { $names = @($cert.DnsNameList | ForEach-Object { $_.Unicode }) }
    if (-not $names) { $names = @($cert.GetNameInfo('DnsName', $false)) }

    [pscustomobject]@{
        Host        = $ComputerName
        Port        = $Port
        Protocol    = $ssl.SslProtocol
        Cipher      = $ssl.CipherAlgorithm
        Subject     = $cert.Subject
        Issuer      = $cert.Issuer
        Thumbprint  = $cert.Thumbprint
        NotBefore   = $cert.NotBefore
        NotAfter    = $cert.NotAfter
        DaysLeft    = [int]($cert.NotAfter - $now).TotalDays
        Expired     = ($cert.NotAfter -lt $now)
        NameMatch   = ($names -contains $ComputerName)
        Valid       = $cert.Verify()
    }
}
finally {
    if ($ssl) { $ssl.Dispose() }
    $client.Close()
}
