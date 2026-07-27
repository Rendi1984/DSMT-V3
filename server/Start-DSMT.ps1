<#
.SYNOPSIS
    DSMT - Directory Service Management Tool. Starts the web console.
.DESCRIPTION
    Runs an HTTP listener that serves the DSMT front end and its JSON API.
    All directory data is read live from Active Directory using the signed-in
    operator's own credentials - there is no demo mode and no sample data.

    Run this on a domain-joined Windows host that has the RSAT
    ActiveDirectory PowerShell module installed.
.PARAMETER Domain
    The AD domain to manage. Defaults to LAB.LOCAL.
.PARAMETER Server
    Pin every query to one domain controller (FQDN). Omit to auto-discover.
.PARAMETER Port
    TCP port to listen on. Default 8080.
.PARAMETER ListenAddress
    'localhost' (default) serves only this machine and needs no extra rights.
    'any' listens on every interface so other machines can reach the console -
    that requires an administrative shell or a one-time URL ACL reservation:
      netsh http add urlacl url=http://+:8080/ user="DOMAIN\dsmt-svc"
.PARAMETER SessionHours
    Idle lifetime of an operator session. Default 8.
.PARAMETER PageSize
    Maximum objects returned by one directory search. Default 500.
.PARAMETER SqlServer
    SQL Server instance that holds the DSMT database, e.g. 'SQL01' or
    'SQL01\LAB'. The database and its tables are created on first start if
    they do not exist. Omit to run without SQL - the audit log then falls
    back to JSONL files under data\, which is announced at startup.
.PARAMETER SqlDatabase
    Database name to create/use. Default 'DSMT'.
.PARAMETER SqlUsername
    SQL authentication user. Omit to use Windows authentication as the
    account running this script (the usual choice on a domain).
.PARAMETER SqlPassword
    Password for -SqlUsername.
.EXAMPLE
    .\Start-DSMT.ps1
    Serves http://localhost:8080/ against LAB.LOCAL.
.EXAMPLE
    .\Start-DSMT.ps1 -Domain lab.local -ListenAddress any -Port 8080
.EXAMPLE
    .\Start-DSMT.ps1 -SqlServer SQL01 -SqlDatabase DSMT
    Creates the DSMT database on SQL01 if it is missing and stores operators,
    sessions, the directory snapshot and the audit log there.
.NOTES
    Author  : IT Team
    Runtime : Windows PowerShell 5.1
#>
[CmdletBinding()]
param(
    [string] $Domain = 'LAB.LOCAL',
    [string] $Server = '',
    [int]    $Port = 8080,
    [ValidateSet('localhost', 'any')][string] $ListenAddress = 'localhost',
    [int]    $SessionHours = 8,
    [int]    $PageSize = 500,
    [string] $SqlServer = '',
    [string] $SqlDatabase = 'DSMT',
    [string] $SqlUsername = '',
    [string] $SqlPassword = ''
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir

. (Join-Path $scriptDir 'lib\DsmtCommon.ps1')
. (Join-Path $scriptDir 'lib\DsmtSql.ps1')
. (Join-Path $scriptDir 'lib\DsmtSession.ps1')
. (Join-Path $scriptDir 'lib\DsmtAudit.ps1')
. (Join-Path $scriptDir 'lib\DsmtDirectory.ps1')
. (Join-Path $scriptDir 'lib\DsmtHttp.ps1')

# Settings chosen by Install-DSMT.ps1 fill in for anything not passed on the
# command line. An explicit parameter always wins over the saved file.
$saved = Get-DsmtSavedSettings -RootPath $repoRoot
if ($null -ne $saved) {
    foreach ($name in @('Domain', 'Server', 'Port', 'ListenAddress', 'SessionHours', 'PageSize', 'SqlServer', 'SqlDatabase')) {
        if ($PSBoundParameters.ContainsKey($name)) { continue }

        $prop = $saved.PSObject.Properties[$name]
        if ($null -eq $prop) { continue }
        if ($null -eq $prop.Value) { continue }
        if ($prop.Value -is [string] -and [string]::IsNullOrWhiteSpace($prop.Value)) { continue }

        Set-Variable -Name $name -Value $prop.Value -Scope 0
    }
}

Initialize-DsmtConfig -RootPath $repoRoot -Domain $Domain -Server $Server -Port $Port `
                      -ListenAddress $ListenAddress -SessionHours $SessionHours -PageSize $PageSize

$cfg = Get-DsmtConfig

Write-Host ''
Write-Host '  DSMT - Directory Service Management Tool' -ForegroundColor White
Write-Host ('  Version ' + $cfg.Version) -ForegroundColor DarkGray
if ($null -ne $saved) {
    Write-Host ('  Settings from config\dsmt.config.json (installed ' + $saved.InstalledOn + ')') -ForegroundColor DarkGray
}
Write-Host ''

# --- Preflight -------------------------------------------------------------
# Both of these are the "one-time external step" class of failure: the code is
# fine, the environment is not. Fail loudly here rather than in a request.

try {
    Assert-DsmtAdModule
    Write-Host '  [ok]   ActiveDirectory module loaded' -ForegroundColor Green
} catch {
    Write-Host '  [FAIL] ActiveDirectory module' -ForegroundColor Red
    Write-Host ('         ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

try {
    $probe = Get-ADDomain -Identity $cfg.Domain -ErrorAction Stop
    Write-Host ('  [ok]   Domain ' + $probe.DNSRoot + ' reachable (' + $probe.NetBIOSName + ')') -ForegroundColor Green
} catch {
    Write-Host ('  [FAIL] Cannot reach domain ' + $cfg.Domain) -ForegroundColor Red
    Write-Host ('         ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host '         Check that this host is domain-joined and a domain controller is reachable.' -ForegroundColor Yellow
    exit 1
}

if ($SqlServer) {
    $sqlInit = Initialize-DsmtSql -Server $SqlServer -Database $SqlDatabase -Username $SqlUsername -Password $SqlPassword
    if ($sqlInit.Ok) {
        Write-Host ('  [ok]   SQL Server ' + $SqlServer + ' - database [' + $SqlDatabase + '] ready') -ForegroundColor Green
    } else {
        Write-Host ('  [FAIL] SQL Server ' + $SqlServer + ' - ' + $sqlInit.Error) -ForegroundColor Red
        Write-Host '         DSMT will not start with a SQL target it cannot reach: fix the instance name,' -ForegroundColor Yellow
        Write-Host '         the firewall or the permissions, or start without -SqlServer to use file audit only.' -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host '  [warn] No -SqlServer given: operators, sessions and the directory snapshot are NOT stored,' -ForegroundColor Yellow
    Write-Host ('         and the audit log is written to JSONL files in ' + $cfg.DataPath) -ForegroundColor Yellow
}

if (-not (Test-Path -LiteralPath (Join-Path $cfg.WebPath 'index.html'))) {
    Write-Host ('  [FAIL] Front end not found at ' + $cfg.WebPath) -ForegroundColor Red
    exit 1
}
Write-Host '  [ok]   Front end found' -ForegroundColor Green

# --- Listener --------------------------------------------------------------

$host_ = 'localhost'
if ($ListenAddress -eq 'any') { $host_ = '+' }
$prefix = 'http://' + $host_ + ':' + $Port + '/'

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
} catch {
    Write-Host ('  [FAIL] Could not listen on ' + $prefix) -ForegroundColor Red
    Write-Host ('         ' + $_.Exception.Message) -ForegroundColor Red
    if ($ListenAddress -eq 'any') {
        Write-Host '         Listening on all interfaces needs an elevated shell, or a one-time reservation:' -ForegroundColor Yellow
        Write-Host ('         netsh http add urlacl url=http://+:' + $Port + '/ user="' + $env:USERDOMAIN + '\' + $env:USERNAME + '"') -ForegroundColor Yellow
    }
    exit 1
}

$browseUrl = 'http://localhost:' + $Port + '/'
Write-Host ''
Write-Host ('  Listening on ' + $prefix) -ForegroundColor Cyan
Write-Host ('  Open ' + $browseUrl) -ForegroundColor Cyan
Write-Host ('  Managing ' + $cfg.Domain + ' - operators sign in with their own domain account') -ForegroundColor DarkGray
Write-Host ('  Audit log: ' + $cfg.DataPath) -ForegroundColor DarkGray
Write-Host '  Ctrl+C to stop.' -ForegroundColor DarkGray
Write-Host ''

Write-DsmtLog -Message ('DSMT ' + $cfg.Version + ' started on ' + $prefix + ' for domain ' + $cfg.Domain)

$requestCount = 0
try {
    while ($listener.IsListening) {
        $context = $null
        try {
            $context = $listener.GetContext()
        } catch {
            if (-not $listener.IsListening) { break }
            Write-DsmtLog -Level 'WARN' -Message ('Listener error: ' + $_.Exception.Message)
            continue
        }

        $requestCount++
        # Drop idle sessions periodically rather than on a timer thread.
        if (($requestCount % 50) -eq 0) { Clear-DsmtExpiredSessions }

        try {
            Invoke-DsmtRequest -Context $context
        } catch {
            Write-DsmtLog -Level 'ERROR' -Message ('Unhandled request error: ' + $_.Exception.Message)
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"Internal server error"}')
                Send-DsmtBytes -Response $context.Response -Bytes $bytes -ContentType 'application/json; charset=utf-8' -StatusCode 500
            } catch { }
        }
    }
} finally {
    Write-DsmtLog -Message 'DSMT stopping'
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
    Write-Host ''
    Write-Host '  DSMT stopped.' -ForegroundColor DarkGray
}
