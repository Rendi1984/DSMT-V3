<#
.SYNOPSIS
    DSMT - installs every prerequisite and prepares the machine to run the
    console.
.DESCRIPTION
    Run this once on the machine that will host DSMT. It performs, in order:

      1. Elevation check (re-launches itself elevated unless -NoElevate)
      2. Windows PowerShell 5.1 check
      3. Domain membership check
      4. Installs the RSAT ActiveDirectory PowerShell module
      5. Verifies the domain answers
      6. Creates data\ and grants the run account write access
      7. Finds or installs SQL Server, then creates the DSMT database
         and its tables
      8. Reserves the HTTP URL so the console can listen without elevation
      9. Opens the firewall port
     10. Optionally registers a scheduled task that starts DSMT at boot
     11. Writes config\dsmt.config.json so Start-DSMT.ps1 remembers all of it
     12. Re-verifies everything and prints a summary

    Every step reports [ok], [skip] or [FAIL] with the reason. A step that
    fails does not silently continue - the summary at the end lists what is
    still outstanding and what to do about it.

    Safe to re-run: every step checks the current state first and does
    nothing when the machine is already correct.
.PARAMETER Domain
    Domain to manage. Default LAB.LOCAL.
.PARAMETER Port
    TCP port the console will listen on. Default 8080.
.PARAMETER ListenAddress
    'any' (default here) reserves the URL so other machines can reach the
    console. 'localhost' skips the reservation and the firewall rule.
.PARAMETER ServiceAccount
    Domain account that will run DSMT, e.g. 'LAB\svc-dsmt'. Used for the URL
    reservation, the data\ permissions and the scheduled task. Defaults to
    the account running this installer.
.PARAMETER SqlServer
    SQL Server instance to use, e.g. 'SQL01' or 'SQL01\LAB'. Omit to have the
    installer look for a local instance. Use -SkipSql to run without SQL.
.PARAMETER SqlDatabase
    Database to create. Default 'DSMT'.
.PARAMETER SkipSql
    Do not configure SQL at all. The audit log then goes to JSONL files.
.PARAMETER SqlExpressSetup
    Path to SQL Server Express setup media (SETUP.EXE or the downloaded
    installer). Supplied only when no SQL instance exists and you want the
    installer to install SQL Express unattended. Nothing is downloaded from
    the internet - point this at media you already have.
.PARAMETER FeatureSource
    Optional path to Windows Feature-on-Demand source (a mounted ISO's
    \sources\sxs, or a WSUS/local FOD share). Needed on Windows 10/11 hosts
    with no internet access, where Add-WindowsCapability cannot fetch RSAT.
.PARAMETER InstallScheduledTask
    Register a scheduled task that starts DSMT at boot under -ServiceAccount.
    The task is configured to run whether or not anyone is signed in, with no
    execution time limit, and to restart itself if it fails.
.PARAMETER InstallAsService
    Register DSMT as a real Windows service instead of a scheduled task, so it
    responds to Get-Service / Start-Service / Restart-Service and to the
    service manager's recovery settings.

    PowerShell cannot be a service directly - the service control manager
    terminates any process that does not answer its protocol - so the
    installer compiles a small C# host (DsmtService.exe) with the csc.exe that
    ships with the .NET Framework, and that host runs Start-DSMT.ps1 as a child
    process. Nothing is downloaded.

    If -ServiceAccount is given you are prompted for its password, because the
    service control manager has to store it. Without it the service runs as
    LocalSystem, which reaches AD and SQL as the computer account.
.PARAMETER StartWhenDone
    Start DSMT as soon as the installation finishes - the service, the
    scheduled task, or a plain background process, whichever was set up.
.PARAMETER NoElevate
    Do not attempt to re-launch elevated. The steps that need administrator
    rights will be reported as failures instead.
.EXAMPLE
    .\Install-DSMT.ps1
    Installs prerequisites for LAB.LOCAL on port 8080, finds a local SQL
    instance if there is one.
.EXAMPLE
    .\Install-DSMT.ps1 -Domain LAB.LOCAL -SqlServer SQL01 `
                       -ServiceAccount "LAB\svc-dsmt" -InstallScheduledTask
    The full lab setup, ready to start at boot.
.EXAMPLE
    .\Install-DSMT.ps1 -SkipSql
    No database: the console works, the audit log goes to files.
.NOTES
    Author  : IT Team
    Runtime : Windows PowerShell 5.1, run as administrator
#>
[CmdletBinding()]
param(
    [string] $Domain = 'LAB.LOCAL',
    [int]    $Port = 8080,
    [ValidateSet('localhost', 'any')][string] $ListenAddress = 'any',
    [string] $ServiceAccount = '',
    [string] $SqlServer = '',
    [string] $SqlDatabase = 'DSMT',
    [switch] $SkipSql,
    [string] $SqlExpressSetup = '',
    [string] $FeatureSource = '',
    [switch] $InstallScheduledTask,
    [switch] $InstallAsService,
    [switch] $StartWhenDone,
    [switch] $NoElevate
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir

. (Join-Path $scriptDir 'lib\DsmtCommon.ps1')

# ---------------------------------------------------------------------------
# Reporting helpers - one line per step, and a running list of what is left.
# ---------------------------------------------------------------------------

$script:Outstanding = New-Object System.Collections.Generic.List[string]
$script:StepNumber  = 0

function Write-Step {
    param([string] $Title)
    $script:StepNumber++
    Write-Host ''
    Write-Host ('  ' + $script:StepNumber + '. ' + $Title) -ForegroundColor White
}

function Write-Ok    { param([string] $Message) Write-Host ('       [ok]   ' + $Message) -ForegroundColor Green }
function Write-Skip  { param([string] $Message) Write-Host ('       [skip] ' + $Message) -ForegroundColor DarkGray }
function Write-Info  { param([string] $Message) Write-Host ('              ' + $Message) -ForegroundColor DarkGray }

function Write-Fail {
    param([string] $Message, [string] $Fix = '')
    Write-Host ('       [FAIL] ' + $Message) -ForegroundColor Red
    if ($Fix) { Write-Host ('              ' + $Fix) -ForegroundColor Yellow }
    $entry = $Message
    if ($Fix) { $entry = $Message + ' -> ' + $Fix }
    $script:Outstanding.Add($entry)
}

function Write-Warn2 {
    param([string] $Message)
    Write-Host ('       [warn] ' + $Message) -ForegroundColor Yellow
}

function Test-IsAdmin {
    $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  DSMT - Directory Service Management Tool' -ForegroundColor White
Write-Host ('  Installer for version ' + $script:DsmtVersion) -ForegroundColor DarkGray
Write-Host '  ---------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host ('  Target domain  : ' + $Domain) -ForegroundColor DarkGray
Write-Host ('  Install root   : ' + $repoRoot) -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 1. Elevation
# ---------------------------------------------------------------------------

Write-Step 'Administrator rights'

$isAdmin = Test-IsAdmin
if ($isAdmin) {
    Write-Ok 'Running elevated'
} elseif ($NoElevate) {
    Write-Warn2 'Not elevated and -NoElevate was given; steps needing administrator rights will fail.'
} else {
    Write-Info 'Not elevated - re-launching this installer as administrator...'

    # Rebuild the original invocation so nothing the operator typed is lost.
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $MyInvocation.MyCommand.Path + '"'))
    foreach ($key in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$key]
        if ($value -is [switch]) {
            if ($value.IsPresent) { $argList += ('-' + $key) }
        } else {
            $argList += ('-' + $key)
            $argList += ('"' + [string]$value + '"')
        }
    }

    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
        Write-Host ''
        Write-Host '  An elevated window has been opened. Continue there.' -ForegroundColor Cyan
        Write-Host ''
        exit 0
    } catch {
        Write-Fail 'Could not elevate automatically.' 'Right-click PowerShell, Run as administrator, and run this script again.'
    }
}

# ---------------------------------------------------------------------------
# 2. PowerShell version
# ---------------------------------------------------------------------------

Write-Step 'Windows PowerShell version'

$psVersion = $PSVersionTable.PSVersion
if ($psVersion.Major -ge 5) {
    Write-Ok ('PowerShell ' + $psVersion.ToString())
} else {
    Write-Fail ('PowerShell ' + $psVersion.ToString() + ' is too old.') 'DSMT needs Windows PowerShell 5.1 (built into Windows Server 2016+ and Windows 10+).'
}

# ---------------------------------------------------------------------------
# 3. Domain membership and machine role
# ---------------------------------------------------------------------------

Write-Step 'Domain membership'

$productType = 3
$osCaption   = 'Windows'
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $productType = [int]$os.ProductType   # 1 = workstation, 2 = domain controller, 3 = server
    $osCaption   = [string]$os.Caption
} catch {
    Write-Warn2 ('Could not read the OS product type: ' + $_.Exception.Message)
}
Write-Info $osCaption

try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($cs.PartOfDomain) {
        Write-Ok ('Joined to ' + $cs.Domain)
        if ($cs.Domain -notlike ('*' + $Domain.Split('.')[0] + '*')) {
            Write-Warn2 ('This machine is joined to ' + $cs.Domain + ' but you asked to manage ' + $Domain + '. That works only if there is a trust.')
        }
    } else {
        Write-Fail 'This machine is not joined to a domain.' ('Join it to ' + $Domain + ' before running DSMT.')
    }
} catch {
    Write-Fail ('Could not read domain membership: ' + $_.Exception.Message)
}

if ($productType -eq 2) {
    Write-Warn2 'This machine is a domain controller. DSMT runs fine here, but a member server is the better place for it.'
}

# ---------------------------------------------------------------------------
# 4. RSAT ActiveDirectory module - the one prerequisite that must be installed
# ---------------------------------------------------------------------------

Write-Step 'RSAT ActiveDirectory PowerShell module'

$adModuleReady = $false
if (Get-Module -ListAvailable -Name ActiveDirectory) {
    Write-Ok 'Already installed'
    $adModuleReady = $true
} elseif (-not (Test-IsAdmin)) {
    Write-Fail 'Not installed, and installing it needs administrator rights.' 'Re-run this installer elevated.'
} elseif ($productType -eq 1) {
    # Windows 10 / 11: Feature on Demand.
    Write-Info 'Windows client detected - installing the RSAT capability...'
    try {
        $cap = Get-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools*' -ErrorAction Stop |
               Select-Object -First 1

        if ($null -eq $cap) {
            Write-Fail 'The RSAT ActiveDirectory capability is not offered by this Windows build.' 'Install RSAT manually for this OS version.'
        } elseif ($cap.State -eq 'Installed') {
            Write-Ok 'Already installed'
            $adModuleReady = $true
        } else {
            if ($FeatureSource) {
                Add-WindowsCapability -Online -Name $cap.Name -Source $FeatureSource -LimitAccess -ErrorAction Stop | Out-Null
            } else {
                Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
            }
            Write-Ok ('Installed ' + $cap.Name)
            $adModuleReady = $true
        }
    } catch {
        Write-Fail ('Could not install the RSAT capability: ' + $_.Exception.Message) `
                   'On a machine with no internet access this needs a Feature-on-Demand source: re-run with -FeatureSource <path to FOD media or \sources\sxs>.'
    }
} else {
    # Windows Server: a Windows feature.
    Write-Info 'Windows Server detected - installing the RSAT-AD-PowerShell feature...'
    try {
        Import-Module ServerManager -ErrorAction Stop
        $feature = Get-WindowsFeature -Name RSAT-AD-PowerShell -ErrorAction Stop

        if ($feature.Installed) {
            Write-Ok 'Already installed'
            $adModuleReady = $true
        } else {
            $result = $null
            if ($FeatureSource) {
                $result = Install-WindowsFeature -Name RSAT-AD-PowerShell -Source $FeatureSource -ErrorAction Stop
            } else {
                $result = Install-WindowsFeature -Name RSAT-AD-PowerShell -ErrorAction Stop
            }

            if ($result.Success) {
                Write-Ok 'Installed RSAT-AD-PowerShell'
                $adModuleReady = $true
                if ($result.RestartNeeded -ne 'No') {
                    Write-Warn2 'Windows reports a restart is needed to finish this feature.'
                }
            } else {
                Write-Fail 'Install-WindowsFeature reported failure.' 'Check Windows Update / feature source availability.'
            }
        }
    } catch {
        Write-Fail ('Could not install RSAT-AD-PowerShell: ' + $_.Exception.Message) `
                   'If this host has no internet or WSUS, re-run with -FeatureSource <path to \sources\sxs>.'
    }
}

# ---------------------------------------------------------------------------
# 5. The domain actually answers
# ---------------------------------------------------------------------------

Write-Step 'Directory reachable'

if (-not $adModuleReady) {
    Write-Skip 'Skipped - the ActiveDirectory module is not available yet'
} else {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $probe = Get-ADDomain -Identity $Domain -ErrorAction Stop
        Write-Ok ($probe.DNSRoot + ' answers (' + $probe.NetBIOSName + ')')

        $dcs = @(Get-ADDomainController -Filter * -Server $probe.DNSRoot -ErrorAction Stop)
        Write-Info ($dcs.Count.ToString() + ' domain controller(s) visible')
    } catch {
        Write-Fail ('Cannot query ' + $Domain + ': ' + $_.Exception.Message) `
                   'Check DNS, network reachability to a domain controller, and that this account can read the directory.'
    }
}

# ---------------------------------------------------------------------------
# 6. Data directory and its permissions
# ---------------------------------------------------------------------------

Write-Step 'Data directory'

$dataPath   = Join-Path $repoRoot 'data'
$configPath = Join-Path $repoRoot 'config'

foreach ($dir in @($dataPath, $configPath)) {
    if (Test-Path -LiteralPath $dir) {
        Write-Ok ('Exists: ' + $dir)
    } else {
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Ok ('Created: ' + $dir)
        } catch {
            Write-Fail ('Could not create ' + $dir + ': ' + $_.Exception.Message)
        }
    }
}

$runAccount = $ServiceAccount
if ([string]::IsNullOrWhiteSpace($runAccount)) {
    $runAccount = $env:USERDOMAIN + '\' + $env:USERNAME
    Write-Info ('No -ServiceAccount given; using the current account: ' + $runAccount)
}

if ($ServiceAccount) {
    try {
        # Modify, inherited by files and folders, applied to the whole tree.
        $icacls = & icacls.exe $dataPath '/grant' ($ServiceAccount + ':(OI)(CI)M') '/T' 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok ('Granted modify on data\ to ' + $ServiceAccount)
        } else {
            Write-Fail ('icacls returned ' + $LASTEXITCODE + ': ' + ($icacls -join ' ')) `
                       ('Grant ' + $ServiceAccount + ' modify rights on ' + $dataPath + ' manually.')
        }
    } catch {
        Write-Fail ('Could not set permissions on data\: ' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# 7. SQL Server
# ---------------------------------------------------------------------------

Write-Step 'SQL Server'

$sqlTarget  = $SqlServer
$sqlReady   = $false

function Get-LocalSqlInstances {
    <#
    .SYNOPSIS
        Reads the installed SQL instance names from the registry. Returns an
        array of connectable names ('.\SQLEXPRESS', 'localhost', ...).
    #>
    $key = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if (-not (Test-Path -LiteralPath $key)) { return @() }

    $names = @()
    $props = Get-ItemProperty -LiteralPath $key
    foreach ($p in $props.PSObject.Properties) {
        if ($p.Name -like 'PS*') { continue }
        if ($p.Name -eq 'MSSQLSERVER') { $names += 'localhost' }
        else { $names += ('.\' + $p.Name) }
    }
    return @($names)
}

if ($SkipSql) {
    Write-Skip 'Skipped with -SkipSql. The audit log will be written to JSONL files under data\.'
    Write-Warn2 'Operators, sessions and the directory snapshot will NOT be stored anywhere.'
} else {

    if (-not $sqlTarget) {
        $local = Get-LocalSqlInstances
        if ($local.Count -gt 0) {
            $sqlTarget = $local[0]
            Write-Ok ('Found a local SQL instance: ' + $sqlTarget)
            if ($local.Count -gt 1) {
                Write-Info ('Other instances present: ' + (($local | Select-Object -Skip 1) -join ', ') + ' - use -SqlServer to pick one.')
            }
        } else {
            Write-Info 'No SQL instance found on this machine.'
        }
    }

    # Install SQL Express only from media the operator supplied. Nothing is
    # downloaded: DSMT hosts are usually on networks with no internet route.
    if (-not $sqlTarget -and $SqlExpressSetup) {
        if (-not (Test-Path -LiteralPath $SqlExpressSetup)) {
            Write-Fail ('SQL Express setup not found at ' + $SqlExpressSetup)
        } else {
            Write-Info 'Installing SQL Server Express unattended - this takes several minutes...'
            try {
                $sqlArgs = @(
                    '/Q', '/IACCEPTSQLSERVERLICENSETERMS', '/ACTION=Install',
                    '/FEATURES=SQLEngine', '/INSTANCENAME=SQLEXPRESS',
                    '/SQLSVCSTARTUPTYPE=Automatic', '/TCPENABLED=1',
                    ('/SQLSYSADMINACCOUNTS="' + $runAccount + '"')
                )
                $proc = Start-Process -FilePath $SqlExpressSetup -ArgumentList $sqlArgs -Wait -PassThru -NoNewWindow

                # 3010 = success, restart required.
                if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                    $sqlTarget = '.\SQLEXPRESS'
                    Write-Ok ('Installed SQL Server Express as ' + $sqlTarget)
                    if ($proc.ExitCode -eq 3010) { Write-Warn2 'SQL setup reports a restart is required.' }
                } else {
                    Write-Fail ('SQL Express setup exited with code ' + $proc.ExitCode) `
                               'Check the SQL setup logs under %ProgramFiles%\Microsoft SQL Server\...\Setup Bootstrap\Log.'
                }
            } catch {
                Write-Fail ('Could not run SQL Express setup: ' + $_.Exception.Message)
            }
        }
    }

    if (-not $sqlTarget) {
        Write-Fail 'No SQL Server to use.' `
                   'Either point -SqlServer at an existing instance, supply -SqlExpressSetup <path to SQL Express setup> to install one, or re-run with -SkipSql to run without a database.'
    } else {
        # Create the database and its tables by calling the server's own code,
        # so the schema created here can never drift from the one it expects.
        try {
            . (Join-Path $scriptDir 'lib\DsmtSql.ps1')
            Initialize-DsmtConfig -RootPath $repoRoot -Domain $Domain -Port $Port -ListenAddress $ListenAddress

            $init = Initialize-DsmtSql -Server $sqlTarget -Database $SqlDatabase
            if ($init.Ok) {
                Write-Ok ('Database [' + $SqlDatabase + '] on ' + $sqlTarget + ' is ready')

                $tables = Invoke-DsmtSqlCommand -Mode 'Query' -Sql @'
SELECT TABLE_NAME AS name FROM INFORMATION_SCHEMA.TABLES
 WHERE TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME;
'@
                Write-Info ('Tables: ' + ((@($tables) | ForEach-Object { $_.name }) -join ', '))
                $sqlReady = $true
            } else {
                Write-Fail ('Could not prepare the database: ' + $init.Error) `
                           ('Check that ' + $runAccount + ' can reach ' + $sqlTarget + ' and has rights to create a database (or pre-create it and grant db_datareader/db_datawriter).')
            }
        } catch {
            Write-Fail ('SQL preparation failed: ' + $_.Exception.Message)
        }
    }
}

# ---------------------------------------------------------------------------
# 8. HTTP URL reservation
# ---------------------------------------------------------------------------

Write-Step 'HTTP listener reservation'

if ($ListenAddress -eq 'localhost') {
    Write-Skip 'Not needed for -ListenAddress localhost'
} elseif (-not (Test-IsAdmin)) {
    Write-Fail 'Needs administrator rights.' 'Re-run this installer elevated.'
} else {
    $url = 'http://+:' + $Port + '/'
    try {
        $existing = & netsh.exe http show urlacl url=$url 2>&1 | Out-String
        if ($existing -match [regex]::Escape($url)) {
            Write-Ok ('Already reserved: ' + $url)
        } else {
            $add = & netsh.exe http add urlacl url=$url user=$runAccount 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                Write-Ok ('Reserved ' + $url + ' for ' + $runAccount)
            } else {
                Write-Fail ('netsh could not reserve ' + $url + ': ' + $add.Trim()) `
                           ('Run manually: netsh http add urlacl url=' + $url + ' user="' + $runAccount + '"')
            }
        }
    } catch {
        Write-Fail ('URL reservation failed: ' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# 9. Firewall
# ---------------------------------------------------------------------------

Write-Step 'Firewall rule'

if ($ListenAddress -eq 'localhost') {
    Write-Skip 'Not needed for -ListenAddress localhost'
} elseif (-not (Test-IsAdmin)) {
    Write-Fail 'Needs administrator rights.' 'Re-run this installer elevated.'
} else {
    $ruleName = 'DSMT console (TCP ' + $Port + ')'
    try {
        $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if ($null -ne $rule) {
            Write-Ok ('Rule already present: ' + $ruleName)
        } else {
            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP `
                                -LocalPort $Port -Action Allow -Profile Domain -ErrorAction Stop | Out-Null
            Write-Ok ('Created inbound rule for TCP ' + $Port + ' (domain profile)')
        }
    } catch {
        Write-Fail ('Could not create the firewall rule: ' + $_.Exception.Message) `
                   ('Create it manually for inbound TCP ' + $Port + '.')
    }
}

# ---------------------------------------------------------------------------
# 10. Scheduled task
# ---------------------------------------------------------------------------

Write-Step 'Start automatically'

$script:StartMode = 'none'          # none | task | service
$serviceName = 'DSMT'
$startPath   = Join-Path $scriptDir 'Start-DSMT.ps1'
$serviceExe  = Join-Path $scriptDir 'DsmtService.exe'

# Start-DSMT.ps1 reads config\dsmt.config.json, written a step later, so
# neither the task nor the service needs the settings on its command line.
$startArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $startPath + '"'

if ($InstallAsService) {

    if (-not (Test-IsAdmin)) {
        Write-Fail 'Registering a service needs administrator rights.' 'Re-run this installer elevated.'
    } else {
        try {
            # --- stop and remove any previous registration -----------------
            $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($null -ne $existingService) {
                if ($existingService.Status -ne 'Stopped') {
                    Stop-Service -Name $serviceName -Force -ErrorAction Stop
                    Write-Info 'Stopped the running service'
                }
                & sc.exe delete $serviceName | Out-Null
                Start-Sleep -Seconds 2
                Write-Info 'Removed the previous service registration'
            }

            # --- compile the service host ---------------------------------
            # PowerShell cannot be a service itself: the SCM kills any process
            # that does not answer its protocol within the start timeout. This
            # tiny host answers it and runs Start-DSMT.ps1 as a child. When the
            # child dies the host stops with a non-zero exit code, so the SCM
            # recovery settings below restart it.
            $csharp = @'
using System;
using System.Diagnostics;
using System.ServiceProcess;

public class DsmtServiceHost : ServiceBase
{
    private Process child;
    private bool stopping;

    public DsmtServiceHost()
    {
        this.ServiceName = "DSMT";
        this.CanStop = true;
        this.CanShutdown = true;
    }

    protected override void OnStart(string[] args)
    {
        stopping = false;

        ProcessStartInfo info = new ProcessStartInfo();
        info.FileName = "powershell.exe";
        info.Arguments = @"__ARGUMENTS__";
        info.WorkingDirectory = @"__WORKDIR__";
        info.UseShellExecute = false;
        info.CreateNoWindow = true;

        child = new Process();
        child.StartInfo = info;
        child.EnableRaisingEvents = true;
        child.Exited += new EventHandler(OnChildExited);
        child.Start();
    }

    private void OnChildExited(object sender, EventArgs e)
    {
        if (stopping) { return; }
        // The console died on its own. Report failure so the service manager
        // applies its recovery actions instead of leaving a service that
        // claims to be running with nothing behind it.
        this.ExitCode = 1;
        this.Stop();
    }

    protected override void OnStop()
    {
        stopping = true;
        try
        {
            if (child != null && !child.HasExited)
            {
                child.Kill();
                child.WaitForExit(15000);
            }
        }
        catch { }
    }

    protected override void OnShutdown()
    {
        OnStop();
    }

    public static void Main()
    {
        ServiceBase.Run(new DsmtServiceHost());
    }
}
'@
            # The C# uses verbatim string literals, where a double quote is
            # escaped by doubling it.
            $csharp = $csharp.Replace('__ARGUMENTS__', $startArguments.Replace('"', '""'))
            $csharp = $csharp.Replace('__WORKDIR__', $repoRoot)

            if (Test-Path -LiteralPath $serviceExe) { Remove-Item -LiteralPath $serviceExe -Force }

            Add-Type -TypeDefinition $csharp -Language CSharp `
                     -OutputAssembly $serviceExe -OutputType ConsoleApplication `
                     -ReferencedAssemblies 'System.ServiceProcess' -ErrorAction Stop

            Write-Ok ('Compiled the service host: ' + $serviceExe)

            # --- register --------------------------------------------------
            $newService = @{
                Name           = $serviceName
                BinaryPathName = ('"' + $serviceExe + '"')
                DisplayName    = 'DSMT - Directory Service Management Tool'
                Description    = 'Serves the DSMT web console for Active Directory operations.'
                StartupType    = 'Automatic'
            }

            if ($ServiceAccount) {
                Write-Info ('Enter the password for ' + $ServiceAccount + ' - the service manager has to store it.')
                $svcCred = Get-Credential -UserName $ServiceAccount -Message 'Password for the DSMT service account'
                if ($null -eq $svcCred) {
                    throw 'No credential was supplied, so the service cannot run under that account.'
                }
                $newService.Credential = $svcCred
            }

            New-Service @newService -ErrorAction Stop | Out-Null

            if ($ServiceAccount) {
                Write-Ok ('Registered service "' + $serviceName + '" running as ' + $ServiceAccount)
            } else {
                Write-Ok ('Registered service "' + $serviceName + '" running as LocalSystem')
                Write-Warn2 'As LocalSystem it reaches AD and SQL as the computer account. Grant that account SQL rights, or re-run with -ServiceAccount.'
            }

            # Restart after 5s, then 10s, then every 30s; reset the counter daily.
            & sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
            Write-Ok 'Recovery configured: restart automatically on failure'

            $script:StartMode = 'service'

        } catch {
            Write-Fail ('Could not register the service: ' + $_.Exception.Message) `
                       'Use -InstallScheduledTask instead, or register the service manually.'
        }
    }

} elseif ($InstallScheduledTask) {

    if (-not (Test-IsAdmin)) {
        Write-Fail 'Needs administrator rights.' 'Re-run this installer elevated.'
    } else {
        $taskName = 'DSMT Console'
        try {
            $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($null -ne $existingTask) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
                Write-Info 'Replaced the existing task'
            }

            $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $startArguments
            $trigger = New-ScheduledTaskTrigger -AtStartup

            # A console that must stay up needs all three of these: no time
            # limit (the default stops it after 72 hours), restart on failure,
            # and no dependency on mains power for laptops.
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
                            -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable

            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                                   -Settings $settings -User $runAccount -RunLevel Limited `
                                   -Description 'Starts the DSMT web console at boot.' -ErrorAction Stop | Out-Null

            Write-Ok ('Registered "' + $taskName + '" to start at boot as ' + $runAccount)
            Write-Info 'Configured to run whether or not anyone is signed in, with no time limit and restart on failure.'
            Write-Warn2 'A task running under a domain account needs that account''s password stored by Task Scheduler, or the "Log on as a batch job" right. Open the task once to confirm it is configured as you expect.'

            $script:StartMode = 'task'

        } catch {
            Write-Fail ('Could not register the scheduled task: ' + $_.Exception.Message) `
                       'Register it manually - the command line is in docs\deployment-guide.html, step 11.'
        }
    }

} else {
    Write-Skip 'Not requested. Use -InstallScheduledTask for a boot-time task, or -InstallAsService for a Windows service.'
}

# ---------------------------------------------------------------------------
# 11. Save the configuration
# ---------------------------------------------------------------------------

Write-Step 'Saved configuration'

$settings = [ordered]@{
    Domain        = $Domain
    Port          = $Port
    ListenAddress = $ListenAddress
    SqlServer     = ''
    SqlDatabase   = $SqlDatabase
    SessionHours  = 8
    PageSize      = 500
    InstalledOn   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    InstalledBy   = ($env:USERDOMAIN + '\' + $env:USERNAME)
    Version       = $script:DsmtVersion
}
if ($sqlReady) { $settings.SqlServer = $sqlTarget }

$settingsFile = Join-Path $configPath 'dsmt.config.json'
try {
    ConvertTo-Json -InputObject $settings -Depth 3 |
        Set-Content -LiteralPath $settingsFile -Encoding UTF8 -ErrorAction Stop
    Write-Ok ('Written to ' + $settingsFile)
    Write-Info 'Start-DSMT.ps1 reads this file, so it can now be started with no parameters.'
} catch {
    Write-Fail ('Could not write ' + $settingsFile + ': ' + $_.Exception.Message) `
               'DSMT still runs - pass the settings on the command line instead.'
}

# ---------------------------------------------------------------------------
# 12. Start it
# ---------------------------------------------------------------------------

Write-Step 'Start DSMT'

if (-not $StartWhenDone) {
    Write-Skip 'Not requested. Re-run with -StartWhenDone to start it as soon as the install finishes.'
} elseif ($script:Outstanding.Count -gt 0) {
    Write-Skip 'Skipped - fix the outstanding items first, then start it.'
} else {
    try {
        switch ($script:StartMode) {

            'service' {
                Start-Service -Name $serviceName -ErrorAction Stop
                Start-Sleep -Seconds 3
                $svc = Get-Service -Name $serviceName
                if ($svc.Status -eq 'Running') {
                    Write-Ok ('Service "' + $serviceName + '" is running')
                } else {
                    Write-Fail ('The service is ' + $svc.Status + ' rather than Running.') `
                               ('Check ' + (Join-Path $dataPath 'dsmt-*.log') + ' - the preflight failure is recorded there.')
                }
            }

            'task' {
                Start-ScheduledTask -TaskName 'DSMT Console' -ErrorAction Stop
                Start-Sleep -Seconds 3
                Write-Ok 'Scheduled task started'
                Write-Info ('If the console does not answer, check ' + (Join-Path $dataPath 'dsmt-*.log'))
            }

            default {
                # No service and no task: run it in its own window so closing
                # this installer does not take the console down with it.
                Start-Process -FilePath 'powershell.exe' `
                              -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $startPath + '"') `
                              -WorkingDirectory $repoRoot | Out-Null
                Write-Ok 'Started in a new PowerShell window'
            }
        }
    } catch {
        Write-Fail ('Could not start DSMT: ' + $_.Exception.Message) `
                   ('Start it by hand: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $startPath + '"')
    }
}

# ---------------------------------------------------------------------------
# 13. Summary
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  ---------------------------------------------------------------' -ForegroundColor DarkGray

if ($script:Outstanding.Count -eq 0) {
    Write-Host '  Installation complete. Nothing outstanding.' -ForegroundColor Green
    Write-Host ''

    switch ($script:StartMode) {
        'service' {
            Write-Host '  DSMT is registered as a Windows service. Manage it with:' -ForegroundColor White
            Write-Host ('    Get-Service ' + $serviceName) -ForegroundColor Cyan
            Write-Host ('    Start-Service ' + $serviceName + '   /   Restart-Service ' + $serviceName) -ForegroundColor Cyan
        }
        'task' {
            Write-Host '  DSMT starts at boot as a scheduled task. Manage it with:' -ForegroundColor White
            Write-Host '    Get-ScheduledTask "DSMT Console"' -ForegroundColor Cyan
            Write-Host '    Start-ScheduledTask "DSMT Console"   /   Stop-ScheduledTask "DSMT Console"' -ForegroundColor Cyan
        }
        default {
            Write-Host '  Start the console with:' -ForegroundColor White
            Write-Host ('    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $startPath + '"') -ForegroundColor Cyan
        }
    }

    Write-Host ''
    Write-Host ('  Then open  http://localhost:' + $Port + '/  and sign in with a domain account.') -ForegroundColor Cyan
    Write-Host '  There is no default account: any valid account in the domain can sign in,' -ForegroundColor DarkGray
    Write-Host '  and what it may change is decided entirely by its delegation in AD.' -ForegroundColor DarkGray
} else {
    Write-Host ('  Installation finished with ' + $script:Outstanding.Count + ' item(s) outstanding:') -ForegroundColor Yellow
    Write-Host ''
    $index = 1
    foreach ($item in $script:Outstanding) {
        Write-Host ('   ' + $index + ') ' + $item) -ForegroundColor Yellow
        $index++
    }
    Write-Host ''
    Write-Host '  Fix these and run this installer again - it is safe to re-run.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host ('  Full guide: ' + (Join-Path $repoRoot 'docs\deployment-guide.html')) -ForegroundColor DarkGray
Write-Host ''
