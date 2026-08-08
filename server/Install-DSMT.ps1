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
      7. SQL Server, only when asked for with -UseSql or -SqlServer:
         finds or installs the instance and creates the DSMT database
      8. Reserves the HTTP URL so the console can listen without elevation
      9. Opens the firewall port
     10. Registers DSMT to run unattended - a Windows service by default
     11. Writes every setting into HKLM\SOFTWARE\Rendi Group\DSMT\Settings
         so Start-DSMT.ps1 remembers all of it
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
    The account DSMT will run as. Used for the URL reservation, the data\
    permissions, and the service or scheduled task. Four forms are accepted
    and the right handling is chosen automatically:

      (omitted)             LocalSystem - the default, and the only one with
                            no password to store or expire. Directory reads
                            and writes still run as the signed-in operator, so
                            attribution is unaffected; the machine account
                            needs rights on SQL if a database is used.
                            With -NoAutoStart there is no service, so DSMT
                            simply runs in your own window as you.
      LAB\svc-dsmt          a dedicated account. Prompts for the password.
      LAB\gmsa-dsmt$        a group managed service account - detected by the
                            trailing $. No password exists or is asked for.
      LocalSystem           the machine account. No password. Reaches AD and
                            SQL as LAB\COMPUTERNAME$.

    Whatever you pick, it can be changed later with -ChangeServiceAccount.
.PARAMETER ChangeServiceAccount
    Move an existing installation to a different account, without
    reinstalling. Takes the same four forms as -ServiceAccount and updates
    all five things that depend on the identity: the service or task, the URL
    reservation, the data\ permissions, the SQL login and the saved settings.
.PARAMETER IdentityMode
    'operator' (default) - every directory read and write runs as the
    signed-in operator. 'hybrid' - reads run as the service account, writes
    still run as the operator. See Start-DSMT.ps1 for the full explanation.
.PARAMETER SqlServer
    SQL Server instance to use, e.g. 'SQL01' or 'SQL01\LAB'. Supplying this
    turns SQL on - see -UseSql for what happens when you do not.
.PARAMETER SqlDatabase
    Database to create. Default 'DSMT'.
.PARAMETER UseSql
    Configure SQL Server storage, finding a local instance automatically.

    SQL IS OFF BY DEFAULT. DSMT is fully functional without it: every user,
    group, membership and OU is read live from the directory either way, and
    the audit log is written to JSONL files under data\. What a database adds
    is history that survives a restart - stored operators, sessions and a
    directory snapshot, and an audit log that can be queried rather than
    grepped.

    The default is off because it is the only part of the installation that
    depends on a machine other than this one. Making it required turned a
    ten-minute evaluation into a SQL support call, so it is now opt-in, it can
    be turned on at any time from Settings -> Database without reinstalling,
    and the console says on every screen that no database is configured.

    -SqlServer implies -UseSql.
.PARAMETER SkipSql
    Explicitly skip SQL. Now the default, so this switch only documents the
    intent; it is kept because existing scripts and the deployment guide use
    it. If both -UseSql and -SkipSql are given, -SkipSql wins.
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
    Register a scheduled task instead of a Windows service. The task runs
    whether or not anyone is signed in, with no execution time limit, and
    restarts itself if it fails.
.PARAMETER NoAutoStart
    Do not register DSMT to run on its own.

    READ THIS BEFORE USING IT. Without a service or a task, DSMT only exists
    while a PowerShell window is open. Closing that window - or simply signing
    out of Windows - stops the console for everybody, with no error message
    anywhere and nothing in the event log that names DSMT. Somebody tidying up
    a stray window takes the tool down and nobody knows why.

    Use it for a five-minute look at the console, and for nothing else.
.PARAMETER InstallAsService
    Register DSMT as a real Windows service. THIS IS NOW THE DEFAULT and the
    switch is only needed to state the intent explicitly; pass
    -InstallScheduledTask for a task instead, or -NoAutoStart for neither.

    The service responds to Get-Service / Start-Service / Restart-Service and
    to the service manager's recovery settings, starts at boot, and survives
    sign-out.

    PowerShell cannot be a service directly - the service control manager
    terminates any process that does not answer its protocol - so the
    installer compiles a small C# host (DsmtService.exe) with the csc.exe that
    ships with the .NET Framework, and that host runs Start-DSMT.ps1 as a child
    process. Nothing is downloaded.

    If -ServiceAccount is given you are prompted for its password, because the
    service control manager has to store it. Without it the service runs as
    LocalSystem, which reaches AD and SQL as the computer account.
.PARAMETER NoStart
    Do not start DSMT when the installation finishes.

    STARTING IS NOW THE DEFAULT. An installer that registers a service and
    leaves it stopped has not finished the job - it has left the operator to
    work out the last step from a skip message, which is exactly what
    happened before 1.20.0.
.PARAMETER StartWhenDone
    Kept for compatibility. Starting is the default since 1.20.0, so this
    switch now only states the intent; -NoStart is the way to opt out.
.PARAMETER OpenBrowser
    Kept for compatibility. Opening the console is the default since 1.20.0;
    -NoBrowser is the way to opt out.
.PARAMETER NoBrowser
    Do not open a browser when the installation finishes. Use in unattended
    runs.

    The browser only ever opens when the console actually answered on its
    port and nothing is outstanding - opening one at a dead port teaches the
    operator that the install failed when it did not.
.PARAMETER NoElevate
    Do not attempt to re-launch elevated. The steps that need administrator
    rights will be reported as failures instead.
.EXAMPLE
    .\Install-DSMT.ps1 -StartWhenDone
    The quick start, and what most installations want: prerequisites for
    LAB.LOCAL on port 8080, registered as a Windows service running as
    LocalSystem, started immediately. No database - add one later from
    Settings -> Database, with no reinstall.
.EXAMPLE
    .\Install-DSMT.ps1 -Domain LAB.LOCAL -SqlServer SQL01 `
                       -ServiceAccount "LAB\svc-dsmt" -StartWhenDone
    The full lab setup: a database, and the service running as a named account
    instead of LocalSystem.
.EXAMPLE
    .\Install-DSMT.ps1 -UseSql
    The same, plus a DSMT database on whatever local SQL instance is found.
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
    [string] $ChangeServiceAccount = '',
    [ValidateSet('operator', 'hybrid')][string] $IdentityMode = 'operator',
    [string] $SqlServer = '',
    [string] $SqlDatabase = 'DSMT',
    [switch] $UseSql,
    [switch] $SkipSql,
    [string] $SqlExpressSetup = '',
    [string] $FeatureSource = '',
    [switch] $InstallScheduledTask,
    [switch] $InstallAsService,
    [switch] $NoAutoStart,
    [switch] $StartWhenDone,
    [switch] $NoStart,
    [switch] $OpenBrowser,
    [switch] $NoBrowser,
    [switch] $NoElevate,
    [string] $InstallPath = '',
    [string] $DataPath = '',
    [switch] $Portable
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

function Wait-DsmtConsole {
    <#
    .SYNOPSIS
        Waits until the console actually answers on its port.
    .DESCRIPTION
        "The service reported Running" is not the same as "DSMT is working".
        The service host starts, launches PowerShell, which loads six library
        files, runs three preflight checks and only then opens the listener -
        several seconds on a cold start, and it can fail at any point in that
        sequence while the service still says Running.

        So the installer waits for the PORT, which is the only thing that
        proves the console is serving. Without this, opening a browser
        immediately after Start-Service shows a connection error and teaches
        the operator that the install failed when it did not.
    .OUTPUTS
        $true when the port answers within the timeout.
    #>
    param([int] $Port, [int] $TimeoutSeconds = 45)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(1500, $false)) {
                $client.EndConnect($async)
                return $true
            }
        } catch {
        } finally {
            try { $client.Close() } catch { }
        }
        Start-Sleep -Milliseconds 800
    }
    return $false
}

function Get-DsmtAccountKind {
    <#
    .SYNOPSIS
        Classifies an account string so every later step knows how to treat it.
    .OUTPUTS
        'gmsa'    - group managed service account (trailing $). No password.
        'machine' - LocalSystem / the computer account. No password.
        'user'    - an ordinary domain or local account. Needs a password.
    #>
    param([string] $Account)

    if ([string]::IsNullOrWhiteSpace($Account)) { return 'user' }

    $trimmed = $Account.Trim()
    if ($trimmed.EndsWith('$')) { return 'gmsa' }

    $wellKnown = @('LocalSystem', 'NT AUTHORITY\SYSTEM', 'SYSTEM',
                   'NT AUTHORITY\NETWORK SERVICE', 'NetworkService')
    foreach ($name in $wellKnown) {
        if ($trimmed -eq $name) { return 'machine' }
    }

    return 'user'
}

function Get-DsmtServiceLogonName {
    <#
    .SYNOPSIS
        The string the service control manager wants for an account.
    #>
    param([string] $Account, [string] $Kind)

    if ($Kind -eq 'machine') { return 'LocalSystem' }
    return $Account
}

function Test-DsmtAccountReady {
    <#
    .SYNOPSIS
        Checks an account before anything is registered against it, so a
        problem surfaces here rather than as a service that will not start.
    .OUTPUTS
        Hashtable with Ok, Message and Warning.
    #>
    param([string] $Account, [string] $Kind)

    if ($Kind -eq 'machine') {
        return @{ Ok = $true; Message = 'LocalSystem - no password, reaches the network as the computer account'; Warning = '' }
    }

    if ($Kind -eq 'gmsa') {
        # A gMSA has to be installed on THIS host before anything can run as
        # it. Test-ADServiceAccount is the only reliable way to know.
        $name = $Account.Trim().TrimEnd('$')
        if ($name.Contains('\')) { $name = $name.Split('\')[-1] }

        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            if (Test-ADServiceAccount -Identity $name -ErrorAction Stop) {
                return @{ Ok = $true; Message = ('gMSA ' + $Account + ' is installed on this host - no password needed'); Warning = '' }
            }
            return @{ Ok = $false
                      Message = ('The gMSA ' + $Account + ' is not usable on this host.')
                      Warning = ('Run:  Install-ADServiceAccount -Identity ' + $name + '   and make sure this computer is in the group named by -PrincipalsAllowedToRetrieveManagedPassword.') }
        } catch {
            return @{ Ok = $false
                      Message = ('Could not verify the gMSA ' + $Account + ': ' + $_.Exception.Message)
                      Warning = 'A gMSA needs Add-KdsRootKey in the forest (once, with a 10 hour propagation delay), New-ADServiceAccount, and Install-ADServiceAccount on this host.' }
        }
    }

    # Ordinary account: the password is the thing that bites later.
    $warning = ''
    $sam = $Account
    if ($sam.Contains('\')) { $sam = $sam.Split('\')[-1] }
    if ($sam.Contains('@')) { $sam = $sam.Split('@')[0] }

    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $adUser = Get-ADUser -Identity $sam -Properties PasswordNeverExpires, memberOf -ErrorAction Stop

        if (-not $adUser.PasswordNeverExpires) {
            $warning = 'This account''s password CAN EXPIRE. When it does, DSMT stops starting and the cause is not obvious. Set PasswordNeverExpires, or use a gMSA.'
        }

        # Running a service that holds operator credentials as a highly
        # privileged account is worth objecting to out loud.
        foreach ($groupDn in @($adUser.memberOf)) {
            if ($groupDn -match '(?i)CN=(Domain Admins|Enterprise Admins|Schema Admins)') {
                $extra = 'This account is a member of ' + $Matches[1] + '. DSMT holds operator credentials in memory; running it as a privileged account makes that much more attractive to steal. Use a dedicated low-privilege account or a gMSA.'
                if ($warning) { $warning = $warning + ' ' + $extra } else { $warning = $extra }
            }
        }

        return @{ Ok = $true; Message = ('Account ' + $Account + ' found in the directory'); Warning = $warning }

    } catch {
        # A local (non-domain) account is legitimate; do not fail on it.
        return @{ Ok = $true
                  Message = ('Could not look up ' + $Account + ' in the directory - continuing (it may be a local account)')
                  Warning = ('Directory lookup failed: ' + $_.Exception.Message) }
    }
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

# Echo what this run actually received. It costs one line and it turns
# "the parameters do not work" into a fact rather than a guess: either they
# are listed here or they never arrived, and those are different faults with
# different fixes. It also survives the elevation relaunch, so the elevated
# window proves for itself what it was handed.
if ($PSBoundParameters.Count -eq 0) {
    Write-Host '  Parameters     : none given - every default applies, including no database' -ForegroundColor DarkGray
} else {
    $echo = @()
    foreach ($key in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$key]
        if ($v -is [System.Management.Automation.SwitchParameter]) { $echo += ('-' + $key) }
        else { $echo += ('-' + $key + ' ' + [string]$v) }
    }
    Write-Host ('  Parameters     : ' + ($echo -join '  ')) -ForegroundColor DarkGray
}

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
    #
    # ONE STRING, not an array. Start-Process -Verb RunAs hands the argument
    # list to ShellExecute, and when it is given an array it re-quotes the
    # elements itself - which is how a forwarded parameter can arrive mangled
    # or not at all, and the operator sees an installer that ignores
    # everything they typed. Building the command line here means what is
    # printed below is exactly what runs.
    $scriptPath = $MyInvocation.MyCommand.Path
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '"'

    foreach ($key in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$key]

        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $argLine += ' -' + $key }
            continue
        }

        $text = [string]$value
        # Escape any embedded double quote before wrapping, or the command
        # line ends early and every parameter after it is lost.
        $text = $text.Replace('"', '\"')
        $argLine += ' -' + $key + ' "' + $text + '"'
    }

    # Printed before the relaunch, so "the parameters do not work" is a
    # one-line diagnosis instead of a guess: what is on screen here is what
    # the elevated window receives.
    Write-Info ('Forwarding: powershell.exe ' + $argLine)

    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Verb RunAs | Out-Null
        Write-Host ''
        Write-Host '  An elevated window has been opened. Continue there.' -ForegroundColor Cyan
        Write-Host '  This window is finished - nothing else happens here.' -ForegroundColor DarkGray
        Write-Host ''
        exit 0
    } catch {
        Write-Fail 'Could not elevate automatically.' `
                   'Right-click PowerShell, Run as administrator, then run the script again with the same parameters. Or pass -NoElevate to see exactly which steps need administrator rights.'
    }
}

# ---------------------------------------------------------------------------
# 1a. Where the code and the state will live
#
# THE PROBLEM THIS SOLVES. Until 1.21.0 DSMT ran out of whatever folder it was
# unzipped into, with config\ and data\ inside it. Upgrading meant extracting
# a new build - over the old folder, or more often beside it - and the console
# came back up with no SQL server configured, quietly writing JSONL instead.
# Nothing errored. The settings were simply in the folder that got replaced.
#
# So the two are separated, and the separation is enforced by where Windows
# lets you write:
#
#   %ProgramFiles%\DSMT   - the code. Replaced wholesale by an upgrade, and
#                           not writable by a standard user, so nobody edits
#                           the running server by accident.
#   %ProgramData%\DSMT    - the state. config\, data\, uploads\. An upgrade
#                           never touches it.
#
# HKLM\SOFTWARE\Rendi Group\DSMT holds two pointers to those roots and nothing
# else - it is not a settings store. Settings stay in JSON where they can be
# read, diffed and mailed in a bug report; the registry answers the one
# question a freshly started process cannot answer for itself.
#
# -Portable keeps the old single-folder behaviour for a USB stick or a lab
# scratch copy, and says so at the end rather than leaving it implied.
# ---------------------------------------------------------------------------

Write-Step 'Install location'

$sourceRoot   = $repoRoot
$sourceServer = $scriptDir

# An existing install decides the default: re-running the installer must land
# on the same folders it used last time, whatever this run was told.
$regPaths = Get-DsmtRegistryPaths

$installRoot = ''
$dataRoot    = ''

if ($Portable) {
    $installRoot = $sourceRoot
    $dataRoot    = $sourceRoot
    Write-Info 'Portable mode: code and state both stay in this folder.'
    Write-Warn2 'An upgrade that replaces this folder will take config\ and data\ with it.'
} else {
    if ($InstallPath) {
        $installRoot = $InstallPath.Trim()
    } elseif ($regPaths.Found -and $regPaths.InstallPath) {
        $installRoot = $regPaths.InstallPath
    } else {
        $installRoot = Join-Path $env:ProgramFiles 'DSMT'
    }

    if ($DataPath) {
        $dataRoot = $DataPath.Trim()
    } elseif ($regPaths.Found -and $regPaths.DataPath) {
        $dataRoot = $regPaths.DataPath
    } else {
        $dataRoot = Join-Path $env:ProgramData 'DSMT'
    }
}

Write-Info ('Code  : ' + $installRoot)
Write-Info ('State : ' + $dataRoot)

# Copy the code, unless it is already where it belongs. Comparing full paths
# rather than the strings matters: "C:\Program Files\DSMT" and
# "C:\Program Files\DSMT\" are the same folder, and copying a folder onto
# itself deletes it.
$sourceFull  = [System.IO.Path]::GetFullPath($sourceRoot).TrimEnd('\')
$installFull = [System.IO.Path]::GetFullPath($installRoot).TrimEnd('\')

if ($sourceFull -eq $installFull) {
    Write-Ok ('Already running from ' + $installRoot)
} else {
    # A running service holds DsmtService.exe open, so the copy fails with a
    # sharing violation unless it is stopped first. Restarted at the end of
    # the install, by the step that already knows how.
    $running = Get-Service -Name 'DSMT' -ErrorAction SilentlyContinue
    if ($null -ne $running -and $running.Status -eq 'Running') {
        try {
            Stop-Service -Name 'DSMT' -Force -ErrorAction Stop
            Write-Info 'Stopped the running DSMT service so its files can be replaced.'
        } catch {
            Write-Warn2 ('Could not stop the DSMT service: ' + $_.Exception.Message)
        }
    }

    try {
        if (-not (Test-Path -LiteralPath $installRoot)) {
            New-Item -ItemType Directory -Path $installRoot -Force -ErrorAction Stop | Out-Null
        }

        # Only the folders DSMT needs to run. Copying the whole source tree
        # would drag config\ and data\ from a portable copy into Program
        # Files - the exact mixing this step exists to prevent.
        $copied = New-Object System.Collections.Generic.List[string]
        foreach ($part in @('server', 'web', '_ds', 'sql', 'docs')) {
            $from = Join-Path $sourceRoot $part
            if (-not (Test-Path -LiteralPath $from)) { continue }

            $to = Join-Path $installRoot $part
            if (Test-Path -LiteralPath $to) { Remove-Item -LiteralPath $to -Recurse -Force -ErrorAction Stop }
            Copy-Item -LiteralPath $from -Destination $installRoot -Recurse -Force -ErrorAction Stop
            $copied.Add($part)
        }
        foreach ($file in @('README.md', 'CHANGELOG.md')) {
            $from = Join-Path $sourceRoot $file
            if (Test-Path -LiteralPath $from) {
                Copy-Item -LiteralPath $from -Destination $installRoot -Force -ErrorAction SilentlyContinue
            }
        }

        Write-Ok ('Copied ' + ($copied -join ', ') + ' to ' + $installRoot)
    } catch {
        Write-Fail ('Could not copy the files to ' + $installRoot + ': ' + $_.Exception.Message) `
                   'Run this installer elevated, or pass -InstallPath <folder> to install somewhere writable, or -Portable to run from this folder.'
    }
}

# Everything after this point installs and configures the COPY. Rebinding the
# two anchors here means the service path, the working directory, the docs
# link and the config file all follow automatically instead of each one
# needing to remember which root it wanted.
$repoRoot  = $installRoot
$scriptDir = Join-Path $installRoot 'server'

# The pointers. Written even in portable mode - a portable install is still
# the one on this machine, and Start-DSMT.ps1 reading a stale registry entry
# from a previous install is worse than reading a correct one.
if (Test-IsAdmin) {
    $regWrite = Set-DsmtRegistryPaths -InstallPath $installRoot -DataPath $dataRoot
    if ($regWrite.Ok) {
        Write-Ok 'Recorded both paths in HKLM\SOFTWARE\Rendi Group\DSMT'
    } else {
        Write-Warn2 ('Could not write the registry pointers: ' + $regWrite.Error)
        Write-Info  'DSMT still runs - Start-DSMT.ps1 falls back to the folder it sits in.'
    }
} else {
    Write-Skip 'Not elevated - the registry pointers were not written.'
}

# ---------------------------------------------------------------------------
# 1b. Change the run account and stop - a maintenance operation, not an install
# ---------------------------------------------------------------------------

if ($ChangeServiceAccount) {

    Write-Host ''
    Write-Host ('  Moving DSMT to a different account: ' + $ChangeServiceAccount) -ForegroundColor White
    Write-Host '  ---------------------------------------------------------------' -ForegroundColor DarkGray

    if (-not (Test-IsAdmin)) {
        Write-Host '  [FAIL] This needs administrator rights.' -ForegroundColor Red
        exit 1
    }

    $newAccount = $ChangeServiceAccount.Trim()
    $newKind    = Get-DsmtAccountKind -Account $newAccount

    $dataPath   = Join-Path $dataRoot 'data'
    $serviceNm  = 'DSMT'
    $taskNm     = 'DSMT Console'

    # --- verify the target account before touching anything ------------------
    Write-Step ('Verifying ' + $newAccount)
    $check = Test-DsmtAccountReady -Account $newAccount -Kind $newKind
    if (-not $check.Ok) {
        Write-Fail $check.Message $check.Warning
        Write-Host ''
        Write-Host '  Nothing was changed.' -ForegroundColor Yellow
        Write-Host ''
        exit 1
    }
    Write-Ok $check.Message
    if ($check.Warning) { Write-Warn2 $check.Warning }

    # The password is collected once, up front. Failing here leaves the
    # installation exactly as it was.
    $newCred = $null
    if ($newKind -eq 'user') {
        Write-Info ('Enter the password for ' + $newAccount + '.')
        $newCred = Get-Credential -UserName $newAccount -Message 'Password for the new DSMT account'
        if ($null -eq $newCred) {
            Write-Host ''
            Write-Host '  No password supplied. Nothing was changed.' -ForegroundColor Yellow
            Write-Host ''
            exit 1
        }
    }

    $previous = ''
    $saved = Get-DsmtSavedSettings
    if ($null -ne $saved -and $saved.PSObject.Properties['ServiceAccount']) {
        $previous = [string]$saved.ServiceAccount
    }
    $changePort = $Port
    if ($null -ne $saved -and $saved.PSObject.Properties['Port'] -and -not $PSBoundParameters.ContainsKey('Port')) {
        $changePort = [int]$saved.Port
    }

    # --- 1 of 5: the service or the scheduled task ---------------------------
    Write-Step 'Service / scheduled task logon account'

    $svc = Get-Service -Name $serviceNm -ErrorAction SilentlyContinue
    $tsk = Get-ScheduledTask -TaskName $taskNm -ErrorAction SilentlyContinue

    if ($null -ne $svc) {
        try {
            $wasRunning = ($svc.Status -eq 'Running')
            if ($wasRunning) { Stop-Service -Name $serviceNm -Force -ErrorAction Stop }

            $logon = Get-DsmtServiceLogonName -Account $newAccount -Kind $newKind
            if ($newKind -eq 'gmsa' -and -not $logon.EndsWith('$')) { $logon = $logon + '$' }

            if ($newKind -eq 'user') {
                $plain = $newCred.GetNetworkCredential().Password
                $scOut = & sc.exe config $serviceNm obj= $newAccount password= $plain 2>&1 | Out-String
                $plain = $null
            } else {
                $scOut = & sc.exe config $serviceNm obj= $logon password= "" 2>&1 | Out-String
            }

            if ($LASTEXITCODE -ne 0) { throw $scOut.Trim() }
            Write-Ok ('Service "' + $serviceNm + '" now logs on as ' + $logon)

            if ($wasRunning) {
                Start-Service -Name $serviceNm -ErrorAction Stop
                Write-Ok 'Service restarted'
            }
        } catch {
            Write-Fail ('Could not change the service logon account: ' + $_.Exception.Message) `
                       ('Set it by hand in services.msc, then re-run the remaining steps.')
        }
    } elseif ($null -ne $tsk) {
        try {
            if ($newKind -eq 'gmsa') {
                $logon = $newAccount
                if (-not $logon.EndsWith('$')) { $logon = $logon + '$' }
                $principal = New-ScheduledTaskPrincipal -UserId $logon -LogonType Password -RunLevel Limited
                Set-ScheduledTask -TaskName $taskNm -Principal $principal -ErrorAction Stop | Out-Null
            } elseif ($newKind -eq 'machine') {
                $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
                Set-ScheduledTask -TaskName $taskNm -Principal $principal -ErrorAction Stop | Out-Null
            } else {
                Set-ScheduledTask -TaskName $taskNm -User $newAccount `
                                  -Password $newCred.GetNetworkCredential().Password -ErrorAction Stop | Out-Null
            }
            Write-Ok ('Scheduled task "' + $taskNm + '" now runs as ' + $newAccount)
        } catch {
            Write-Fail ('Could not change the scheduled task principal: ' + $_.Exception.Message)
        }
    } else {
        Write-Skip 'No DSMT service or scheduled task is registered on this machine'
    }

    # --- 2 of 5: the URL reservation -----------------------------------------
    # THE one that bites. The reservation names an account; leaving the old one
    # in place means the new account cannot listen, and the failure appears
    # much later as "Could not listen on http://+:8080/".
    Write-Step 'HTTP URL reservation'

    $url = 'http://+:' + $changePort + '/'
    try {
        $existing = & netsh.exe http show urlacl url=$url 2>&1 | Out-String
        if ($existing -match [regex]::Escape($url)) {
            & netsh.exe http delete urlacl url=$url 2>&1 | Out-Null
            Write-Info ('Removed the previous reservation for ' + $url)
        }

        $aclAccount = $newAccount
        if ($newKind -eq 'machine') { $aclAccount = 'NT AUTHORITY\SYSTEM' }
        if ($newKind -eq 'gmsa' -and -not $aclAccount.EndsWith('$')) { $aclAccount = $aclAccount + '$' }

        $add = & netsh.exe http add urlacl url=$url user=$aclAccount 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            Write-Ok ('Reserved ' + $url + ' for ' + $aclAccount)
        } else {
            Write-Fail ('Could not reserve ' + $url + ' for ' + $aclAccount + ': ' + $add.Trim()) `
                       ('Run: netsh http add urlacl url=' + $url + ' user="' + $aclAccount + '"')
        }
    } catch {
        Write-Fail ('URL reservation step failed: ' + $_.Exception.Message)
    }

    # --- 3 of 5: data\ permissions -------------------------------------------
    Write-Step 'Data folder permissions'

    if ($newKind -eq 'machine') {
        Write-Skip 'LocalSystem already has full access'
    } else {
        try {
            $grantee = $newAccount
            if ($newKind -eq 'gmsa' -and -not $grantee.EndsWith('$')) { $grantee = $grantee + '$' }

            $icacls = & icacls.exe $dataPath '/grant' ($grantee + ':(OI)(CI)M') '/T' 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Ok ('Granted modify on data\ to ' + $grantee)
            } else {
                Write-Fail ('icacls returned ' + $LASTEXITCODE + ': ' + ($icacls -join ' '))
            }
        } catch {
            Write-Fail ('Could not update data\ permissions: ' + $_.Exception.Message)
        }
    }

    # --- 4 of 5: SQL login ----------------------------------------------------
    Write-Step 'SQL Server login'

    $sqlName = ''
    $sqlDb   = 'DSMT'
    if ($null -ne $saved) {
        if ($saved.PSObject.Properties['SqlServer'])   { $sqlName = [string]$saved.SqlServer }
        if ($saved.PSObject.Properties['SqlDatabase']) { $sqlDb   = [string]$saved.SqlDatabase }
    }

    if (-not $sqlName) {
        Write-Skip 'No SQL Server is configured, so there is no login to move'
    } else {
        $sqlPrincipal = $newAccount
        if ($newKind -eq 'machine') { $sqlPrincipal = $env:USERDOMAIN + '\' + $env:COMPUTERNAME + '$' }
        if ($newKind -eq 'gmsa' -and -not $sqlPrincipal.EndsWith('$')) { $sqlPrincipal = $sqlPrincipal + '$' }

        # Granting SQL rights needs rights on the SQL instance that this
        # installer may not have, so this step reports rather than assumes.
        Write-Warn2 ('DSMT cannot grant SQL rights on your behalf. Run this on ' + $sqlName + ':')
        Write-Host ''
        Write-Host ('    USE master;') -ForegroundColor Cyan
        Write-Host ("    IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '" + $sqlPrincipal + "')") -ForegroundColor Cyan
        Write-Host ('        CREATE LOGIN [' + $sqlPrincipal + '] FROM WINDOWS;') -ForegroundColor Cyan
        Write-Host ('    USE [' + $sqlDb + '];') -ForegroundColor Cyan
        Write-Host ('    CREATE USER [' + $sqlPrincipal + '] FOR LOGIN [' + $sqlPrincipal + '];') -ForegroundColor Cyan
        Write-Host ('    ALTER ROLE db_datareader ADD MEMBER [' + $sqlPrincipal + '];') -ForegroundColor Cyan
        Write-Host ('    ALTER ROLE db_datawriter ADD MEMBER [' + $sqlPrincipal + '];') -ForegroundColor Cyan
        Write-Host ''
        $script:Outstanding.Add('Grant ' + $sqlPrincipal + ' access to ' + $sqlDb + ' on ' + $sqlName + ' (SQL script printed above)')
    }

    # --- 5 of 5: saved settings ----------------------------------------------
    Write-Step 'Saved configuration'

    $update = Save-DsmtSavedSettings -Values @{
        ServiceAccount = $newAccount
        AccountKind    = $newKind
        AccountChangedOn = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        AccountChangedBy = ($env:USERDOMAIN + '\' + $env:USERNAME)
    }
    if ($update.Ok) {
        Write-Ok ('Recorded the new account' + $(if ($previous) { ' (was ' + $previous + ')' } else { '' }))
    } else {
        Write-Fail ('Could not update the saved settings: ' + $update.Error)
    }

    # --- summary --------------------------------------------------------------
    Write-Host ''
    Write-Host '  ---------------------------------------------------------------' -ForegroundColor DarkGray
    if ($script:Outstanding.Count -eq 0) {
        Write-Host ('  DSMT now runs as ' + $newAccount + '. Nothing outstanding.') -ForegroundColor Green
    } else {
        Write-Host ('  Account changed, with ' + $script:Outstanding.Count + ' item(s) outstanding:') -ForegroundColor Yellow
        Write-Host ''
        $idx = 1
        foreach ($item in $script:Outstanding) {
            Write-Host ('   ' + $idx + ') ' + $item) -ForegroundColor Yellow
            $idx++
        }
    }
    Write-Host ''
    Write-Host '  Restart DSMT for the change to take effect.' -ForegroundColor White
    Write-Host ''
    exit 0
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

# Under the data root, never under the code root - see step 1a.
$dataPath    = Join-Path $dataRoot 'data'
$configPath  = Join-Path $dataRoot 'config'
$uploadsPath = Join-Path $dataRoot 'uploads'

# An install made before 1.21.0 keeps config\ and data\ beside the code. Bring
# them across before anything reads or writes settings, or this upgrade is the
# one that loses the SQL server, the port and the group filters. Copies, never
# moves - the old folder stays intact so a bad upgrade can be walked back.
if (-not $Portable) {
    $legacy = Move-DsmtLegacyState -RootPath $sourceRoot -DataRoot $dataRoot
    if ($legacy.Migrated) {
        Write-Ok ('Brought forward the previous configuration from ' + $sourceRoot)
        foreach ($item in @($legacy.Items)) { Write-Info ('  ' + $item) }
    } elseif ($legacy.Error) {
        Write-Warn2 ('Could not migrate the previous configuration: ' + $legacy.Error)
    }
}

foreach ($dir in @($dataPath, $configPath, $uploadsPath)) {
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

Write-Step 'Run account'

# WHICH ACCOUNT DSMT RUNS AS, when -ServiceAccount was not given.
#
# Until 1.18.3 this was always the account running the installer. That made
# sense when the default was "run in a window as me" - but 1.16.0 made a
# Windows service the default, and a service needs its password STORED by the
# service control manager. So the installer was asking a Domain Admin to hand
# over their password to be kept on disk, three lines after warning that
# running DSMT as a privileged account is a bad idea. The installer was
# arguing with itself.
#
# LocalSystem instead: no password exists, so none is stored and none expires.
# It costs nothing in attribution, because in the default 'operator' identity
# mode every directory read and write already runs as the SIGNED-IN OPERATOR -
# the host identity never touches AD. It shows in exactly one place, SQL,
# where the machine account needs rights, and that is called out below.
#
# -NoAutoStart keeps the old behaviour: with nothing registered, DSMT runs in
# the operator's own window as them, and no password is stored either way.
$runAccount = $ServiceAccount
$accountWasChosen = $true
if ([string]::IsNullOrWhiteSpace($runAccount)) {
    $accountWasChosen = $false
    if ($NoAutoStart) {
        $runAccount = $env:USERDOMAIN + '\' + $env:USERNAME
    } else {
        $runAccount = 'LocalSystem'
    }
}

$runAccountKind = Get-DsmtAccountKind -Account $runAccount

switch ($runAccountKind) {
    'gmsa'    { Write-Info ('Group managed service account: ' + $runAccount) }
    'machine' {
        if ($accountWasChosen) {
            Write-Info 'Machine account (LocalSystem)'
        } else {
            Write-Info 'No -ServiceAccount given; DSMT will run as LocalSystem.'
            Write-Info 'No password is stored and none can expire. Directory reads and writes still'
            Write-Info 'run as the signed-in operator, so the domain controller records the human.'
        }
    }
    default   {
        if ($accountWasChosen) {
            Write-Info ('Dedicated account: ' + $runAccount)
        } else {
            Write-Info ('No -ServiceAccount given; using the account running this installer: ' + $runAccount)
        }
    }
}

$accountCheck = Test-DsmtAccountReady -Account $runAccount -Kind $runAccountKind
if ($accountCheck.Ok) {
    Write-Ok $accountCheck.Message
} else {
    Write-Fail $accountCheck.Message $accountCheck.Warning
}
if ($accountCheck.Warning -and $accountCheck.Ok) {
    Write-Warn2 $accountCheck.Warning
}

if (-not $accountWasChosen -and $runAccountKind -eq 'user') {
    Write-Info 'This is a personal account. For production, move DSMT to a dedicated account or a gMSA:'
    Write-Info ('  .\Install-DSMT.ps1 -ChangeServiceAccount "' + $Domain.Split('.')[0].ToUpper() + '\svc-dsmt"')
    Write-Info 'The console will also raise this as a notification until it is changed.'
}

# --- data\ permissions for that account -------------------------------------

if ($runAccountKind -ne 'machine') {
    try {
        # Modify, inherited by files and folders, applied to the whole tree.
        $icacls = & icacls.exe $dataPath '/grant' ($runAccount + ':(OI)(CI)M') '/T' 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok ('Granted modify on data\ to ' + $runAccount)
        } else {
            Write-Fail ('icacls returned ' + $LASTEXITCODE + ': ' + ($icacls -join ' ')) `
                       ('Grant ' + $runAccount + ' modify rights on ' + $dataPath + ' manually.')
        }
    } catch {
        Write-Fail ('Could not set permissions on data\: ' + $_.Exception.Message)
    }
} else {
    Write-Skip 'LocalSystem already has full access to the file system'
}

# ---------------------------------------------------------------------------
# 7. SQL Server
# ---------------------------------------------------------------------------

Write-Step 'SQL Server (optional)'

$sqlTarget  = $SqlServer
$sqlReady   = $false

function Get-LocalSqlInstances {
    <#
    .SYNOPSIS
        Reads the installed SQL instance names from the registry. Returns an
        array of connectable names ('.\SQLEXPRESS', 'localhost', ...).
    .NOTES
        ALWAYS AN ARRAY, even with one element - hence the comma operator on
        the return. Without it PowerShell unrolls a single-element array and
        the caller receives a bare string, which indexes as characters. That
        produced a real bug: one installed instance became an instance named
        "l". Callers should still wrap the call in @( ) as a second guard.
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
    return ,@($names)
}

# SQL is OPT-IN. It is the only step that depends on a machine other than this
# one, and requiring it turned a ten-minute evaluation into a SQL support call.
# Everything the console DISPLAYS is read live from the directory either way -
# a database adds history that survives a restart, not correctness - so the
# honest default is off, said out loud, and changeable at any time from
# Settings -> Database without reinstalling.
$sqlWanted = ($UseSql -or -not [string]::IsNullOrWhiteSpace($SqlServer) -or -not [string]::IsNullOrWhiteSpace($SqlExpressSetup))
if ($SkipSql) { $sqlWanted = $false }

if (-not $sqlWanted) {
    Write-Skip 'Not configured - this is the default.'
    Write-Info 'DSMT is fully usable like this: users, groups, membership and OUs are read live'
    Write-Info 'from the directory, and every change is still audited to JSONL files under data\.'
    Write-Warn2 'Without a database, operators, sessions and the directory snapshot are not stored,'
    Write-Warn2 'and the audit log lives only as files on this machine.'
    Write-Info ''
    Write-Info 'To add one later, with no reinstall: sign in, then Settings -> Database.'
    Write-Info 'To add one now: re-run this installer with -UseSql, or -SqlServer <instance>.'

    # Said even when skipping, because "there was already a database here" is
    # exactly what someone re-running the installer needs to be told.
    $seen = @(Get-LocalSqlInstances)
    if ($seen.Count -gt 0) {
        Write-Info ('A local SQL instance is present (' + ($seen -join ', ') + ') if you want to use it.')
    }
} else {

    if (-not $sqlTarget) {
        # @( ) IS LOAD-BEARING, do not remove it.
        #
        # A PowerShell function that returns a one-element array unrolls it on
        # assignment, so with exactly one SQL instance installed $local became
        # the STRING 'localhost' rather than a one-element array. .Count on a
        # string is 1, and $local[0] is its first CHARACTER - so the installer
        # cheerfully announced 'Found a local SQL instance: l' and then tried
        # to connect to a server called "l". Wrapping the call forces an array
        # whatever the count. Same family as the ConvertTo-Json single-element
        # collapse in CLAUDE.md.
        $local = @(Get-LocalSqlInstances)

        if ($local.Count -gt 0) {
            $sqlTarget = [string]$local[0]
            Write-Ok ('Found a local SQL instance: ' + $sqlTarget)
            if ($local.Count -gt 1) {
                Write-Info ('Other instances present: ' + (($local | Select-Object -Skip 1) -join ', ') + ' - use -SqlServer to pick one.')
            }
        } else {
            Write-Info 'No SQL instance found on this machine.'
        }
    }

    # A one-character instance name is never real, and it is precisely what the
    # bug above produced. Refuse it loudly rather than spending the next twenty
    # minutes reading a "server was not found" message that names nothing.
    if ($sqlTarget -and $sqlTarget.Length -le 1) {
        Write-Fail ('Refusing to use "' + $sqlTarget + '" as a SQL Server instance name - that is not a real name. Pass -SqlServer explicitly, or drop -UseSql to install without a database.')
        $sqlTarget = ''
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
        Write-Fail 'SQL was requested but no instance could be used.' `
                   'Point -SqlServer at an existing instance, or supply -SqlExpressSetup <path to SQL Express setup> to install one. Re-running with no SQL switch at all installs without a database, which is the default and is fully usable.'
    } else {
        # Create the database and its tables by calling the server's own code,
        # so the schema created here can never drift from the one it expects.
        try {
            . (Join-Path $scriptDir 'lib\DsmtSql.ps1')
            Initialize-DsmtConfig -RootPath $repoRoot -Domain $Domain -Port $Port -ListenAddress $ListenAddress `
                                  -DataRoot $dataRoot -PathMode $(if ($Portable) { 'portable' } else { 'installed' })

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

Write-Step 'How DSMT will run'

$script:StartMode = 'none'          # none | task | service
$script:ConsoleUp = $false          # set once the port actually answers
$serviceName = 'DSMT'
$startPath   = Join-Path $scriptDir 'Start-DSMT.ps1'
$serviceExe  = Join-Path $scriptDir 'DsmtService.exe'

# Start-DSMT.ps1 reads the settings from the registry, written a step later,
# so neither the task nor the service needs them on its command line.
#
# -DataRoot IS passed, rather than left to the registry pointer, because the
# registry write can fail (it needs elevation) while everything else succeeds.
# Falling back to portable mode there would put the state under Program Files,
# which the service account cannot write - a service that starts and dies with
# nothing useful in the log. Belt and braces on the one value that cannot be
# recovered from anywhere else.
$startArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $startPath + '" -DataRoot "' + $dataRoot + '"'

# ---------------------------------------------------------------------------
# WHAT RUNS DSMT, and why the default is a service.
#
# Until 1.16.0 the default was nothing: DSMT ran in whatever PowerShell window
# happened to start it. That is not a lighter option, it is a fragile one -
# closing the window, or signing out of Windows, stopped the console for
# everybody, with no error anywhere and nothing in the event log naming DSMT.
# A default should be the thing that survives Monday morning.
#
# So: a Windows service unless the operator says otherwise, and if the service
# cannot be registered, a scheduled task rather than silently falling back to
# the fragile option.
#
# The service runs as LOCALSYSTEM unless -ServiceAccount names something else.
# That is deliberate: no password to store, nothing to expire, and nothing to
# re-enter when a service account's password is rotated. It costs nothing in
# attribution, because in the default 'operator' identity mode every directory
# read and write already runs as the signed-in operator - the host identity
# never touches AD. The one place it shows is SQL, where the machine account
# needs rights; the installer says so when it applies.
# ---------------------------------------------------------------------------
$script:ServiceFailed = $false

$wantService = $false
$wantTask    = $false

if ($NoAutoStart) {
    # Explicitly asked for nothing.
} elseif ($InstallScheduledTask) {
    $wantTask = $true
} else {
    $wantService = $true
}

if ($wantService) {

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

            # A gMSA has no password, and New-Service has no way to express
            # that - so the service is created first and the logon account is
            # set afterwards with sc.exe, where an empty password is the
            # documented way to say "managed account".
            $needsScConfig = ($runAccountKind -eq 'gmsa')

            if ($runAccountKind -eq 'user') {
                Write-Info ('Enter the password for ' + $runAccount + ' - the service manager has to store it to log on at boot.')
                $svcCred = Get-Credential -UserName $runAccount -Message 'Password for the DSMT service account'
                if ($null -eq $svcCred) {
                    throw 'No credential was supplied, so the service cannot run under that account.'
                }
                $newService.Credential = $svcCred
            }

            New-Service @newService -ErrorAction Stop | Out-Null

            if ($needsScConfig) {
                $logon = $runAccount
                if (-not $logon.EndsWith('$')) { $logon = $logon + '$' }

                $scOut = & sc.exe config $serviceName obj= $logon password= "" 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) {
                    throw ('Could not set the gMSA as the service logon account: ' + $scOut.Trim())
                }
                Write-Ok ('Registered service "' + $serviceName + '" running as ' + $logon + ' (no password stored)')
            } elseif ($runAccountKind -eq 'machine') {
                Write-Ok ('Registered service "' + $serviceName + '" running as LocalSystem')
                Write-Warn2 ('It reaches AD and SQL as the computer account. Grant ' + $env:COMPUTERNAME + '$ rights on the SQL instance.')
            } else {
                Write-Ok ('Registered service "' + $serviceName + '" running as ' + $runAccount)
                Write-Info 'Starts at boot, survives sign-out, and restarts itself if it fails.'
            }

            # Restart after 5s, then 10s, then every 30s; reset the counter daily.
            & sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
            Write-Ok 'Recovery configured: restart automatically on failure'

            $script:StartMode = 'service'

        } catch {
            # Not a hard failure yet: a scheduled task achieves the same thing
            # and is attempted next. Only if that also fails is DSMT left with
            # no way to run on its own, and that IS reported as a failure.
            Write-Warn2 ('Could not register the service: ' + $_.Exception.Message)
            Write-Info  'Falling back to a scheduled task, which does the same job.'
            $script:ServiceFailed = $true
            $wantTask = $true
        }
    }

}

if ($wantTask) {

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

            $register = @{
                TaskName    = $taskName
                Action      = $action
                Trigger     = $trigger
                Settings    = $settings
                Description = 'Starts the DSMT web console at boot.'
            }

            if ($runAccountKind -eq 'machine') {
                $register.User = 'SYSTEM'
                $register.RunLevel = 'Highest'
            } elseif ($runAccountKind -eq 'gmsa') {
                # A gMSA in Task Scheduler needs a principal object; -User
                # alone cannot express a passwordless managed account.
                $logon = $runAccount
                if (-not $logon.EndsWith('$')) { $logon = $logon + '$' }
                $register.Principal = New-ScheduledTaskPrincipal -UserId $logon -LogonType Password -RunLevel Limited
            } else {
                $register.User = $runAccount
                $register.RunLevel = 'Limited'
            }

            Register-ScheduledTask @register -ErrorAction Stop | Out-Null

            Write-Ok ('Registered "' + $taskName + '" to start at boot as ' + $runAccount)
            Write-Info 'Configured to run whether or not anyone is signed in, with no time limit and restart on failure.'

            if ($runAccountKind -eq 'user') {
                Write-Warn2 'A task running under a domain account needs that account''s password stored by Task Scheduler, or the "Log on as a batch job" right. Open the task once to confirm it is configured as you expect.'
            }

            $script:StartMode = 'task'

        } catch {
            Write-Fail ('Could not register the scheduled task: ' + $_.Exception.Message) `
                       'Register it manually - the command line is in docs\deployment-guide.html, step 11.'
        }
    }

} elseif ($NoAutoStart) {
    Write-Skip 'Skipped with -NoAutoStart.'
    Write-Warn2 'DSMT will only run while a PowerShell window is open. Closing that window, or signing'
    Write-Warn2 'out of Windows, stops the console for everyone - with no error and nothing in the event log.'
    Write-Info  'Re-run without -NoAutoStart to register it as a service. Safe to do at any time.'
}

# Whatever happened above, the summary must be able to state plainly how DSMT
# will run - so record the one case where the answer is "it will not".
if ($script:StartMode -eq 'none' -and -not $NoAutoStart) {
    Write-Fail 'DSMT is not registered to run on its own.' `
               'Neither a service nor a scheduled task could be registered. Until one is, DSMT stops when the window running it closes.'
}

# ---------------------------------------------------------------------------
# 11. Save the configuration
# ---------------------------------------------------------------------------

Write-Step 'Saved configuration'

# Values an operator tuned in the console - the idle timeout, the search cap,
# the group filter chips - are NOT the installer's to reset. Re-running the
# installer to change the port used to silently put the idle timeout back to
# 15 minutes, and now that the previous configuration is migrated forward,
# overwriting it would defeat the migration a few steps above. So: read what
# is there, and only fill in what is missing.
# A pre-1.22.0 install keeps its settings in dsmt.config.json. Import once,
# before reading them, or this installer writes a fresh set over the top of a
# configuration it never saw.
$legacySettings = Import-DsmtLegacySettings -ConfigPath $configPath
if ($legacySettings.Imported) {
    Write-Ok ('Imported ' + $legacySettings.Count + ' settings from dsmt.config.json into the registry')
} elseif ($legacySettings.Error) {
    Write-Warn2 ('Could not import the previous settings file: ' + $legacySettings.Error)
}

$existing = Get-DsmtSavedSettings

$keepSession = 15
$keepPage    = 500
if ($null -ne $existing) {
    if ($existing.PSObject.Properties['SessionMinutes'] -and $existing.SessionMinutes) { $keepSession = [int]$existing.SessionMinutes }
    if ($existing.PSObject.Properties['PageSize'] -and $existing.PageSize)             { $keepPage    = [int]$existing.PageSize }
}

$settings = [ordered]@{
    Domain         = $Domain
    Port           = $Port
    ListenAddress  = $ListenAddress
    IdentityMode   = $IdentityMode
    ServiceAccount = $runAccount
    AccountKind    = $runAccountKind
    SqlServer      = ''
    SqlDatabase    = $SqlDatabase
    SessionMinutes = $keepSession
    PageSize       = $keepPage
    InstallPath    = $installRoot
    DataPath       = $dataRoot
    PathMode       = $(if ($Portable) { 'portable' } else { 'installed' })
    InstalledOn    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    InstalledBy    = ($env:USERDOMAIN + '\' + $env:USERNAME)
    Version        = $script:DsmtVersion
}
if ($sqlReady) { $settings.SqlServer = $sqlTarget }

$settingsKey = Get-DsmtSettingsKeyPath

# Merged, not overwritten: a value this installer does not mention - the group
# filter chips, the health alert settings - survives untouched.
$write = Save-DsmtSavedSettings -Values $settings
if ($write.Ok) {
    Write-Ok ('Written to ' + $settingsKey)
    Write-Info 'Start-DSMT.ps1 reads them from there, so it can now be started with no parameters.'
    Write-Info 'To review or edit them by hand: regedit, or'
    Write-Info ('    reg query "' + $settingsKey + '"')
} else {
    Write-Fail ('Could not write ' + $settingsKey + ': ' + $write.Error) `
               'DSMT still runs - pass the settings on the command line instead.'
}

# ---------------------------------------------------------------------------
# 12. Start it
# ---------------------------------------------------------------------------

Write-Step 'Start DSMT'

# Starting is the default. -NoStart opts out; -StartWhenDone is now a no-op
# kept so existing command lines keep working.
$shouldStart = (-not $NoStart)

if (-not $shouldStart) {
    # Name the command that starts what was just registered. The old message
    # only mentioned re-running the installer, so an operator who had a
    # perfectly good service sitting there stopped reading and started
    # Start-DSMT.ps1 by hand in a window - the exact thing the service exists
    # to avoid. A skip message has to say what to do instead, not only what
    # was not done.
    switch ($script:StartMode) {
        'service' {
            Write-Skip 'Not started. The service is registered and ready:'
            Write-Info ('    Start-Service ' + $serviceName)
            Write-Info 'Or re-run this installer with -StartWhenDone.'
        }
        'task' {
            Write-Skip 'Not started. The task is registered and starts at the next boot:'
            Write-Info '    Start-ScheduledTask "DSMT Console"'
            Write-Info 'Or re-run this installer with -StartWhenDone.'
        }
        default {
            Write-Skip 'Skipped with -NoStart.'
        }
    }
} elseif ($script:Outstanding.Count -gt 0) {
    Write-Skip 'Skipped - fix the outstanding items first, then start it.'
} else {
    try {
        switch ($script:StartMode) {

            'service' {
                $existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                if ($null -ne $existing -and $existing.Status -eq 'Running') {
                    Restart-Service -Name $serviceName -Force -ErrorAction Stop
                    Write-Info 'Restarted the running service so it picks up these files'
                } else {
                    Start-Service -Name $serviceName -ErrorAction Stop
                }

                Write-Info 'Waiting for the console to answer...'
                if (Wait-DsmtConsole -Port $Port) {
                    Write-Ok ('Service "' + $serviceName + '" is running and answering on port ' + $Port)
                    $script:ConsoleUp = $true
                } else {
                    $svc = Get-Service -Name $serviceName
                    Write-Fail ('The service is ' + $svc.Status + ' but nothing answered on port ' + $Port + ' within 45 seconds.') `
                               ('Read ' + (Join-Path $dataPath 'dsmt-*.log') + ' - the preflight failure is recorded there. A port already in use by another process is the other common cause.')
                }
            }

            'task' {
                Start-ScheduledTask -TaskName 'DSMT Console' -ErrorAction Stop
                Write-Info 'Waiting for the console to answer...'
                if (Wait-DsmtConsole -Port $Port) {
                    Write-Ok ('Scheduled task started and answering on port ' + $Port)
                    $script:ConsoleUp = $true
                } else {
                    Write-Fail ('The task started but nothing answered on port ' + $Port + ' within 45 seconds.') `
                               ('Read ' + (Join-Path $dataPath 'dsmt-*.log') + '.')
                }
            }

            default {
                # No service and no task: run it in its own window so closing
                # this installer does not take the console down with it.
                Start-Process -FilePath 'powershell.exe' `
                              -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $startPath + '"') `
                              -WorkingDirectory $repoRoot | Out-Null
                Write-Info 'Waiting for the console to answer...'
                if (Wait-DsmtConsole -Port $Port) {
                    Write-Ok ('Started in a new PowerShell window, answering on port ' + $Port)
                    $script:ConsoleUp = $true
                } else {
                    Write-Warn2 ('Nothing answered on port ' + $Port + ' within 45 seconds. The window it opened will show why.')
                }

                # Said here AND in the summary, because this is the one
                # outcome where the console dies without anyone touching DSMT:
                # a colleague closes a stray window, or the operator signs out,
                # and the tool is simply gone with no error anywhere.
                Write-Warn2 'That window IS the console. Close it, or sign out of Windows, and DSMT stops.'
                Write-Info  'For anything but a quick look, register it properly instead:'
                Write-Info  '  .\server\Install-DSMT.ps1 -InstallAsService -StartWhenDone'
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

    # How it will run once this window is gone. Stated as its own line
    # because it is the difference between a tool that is there on Monday and
    # one that is not, and until now the installer never mentioned it.
    Write-Host ''
    switch ($script:StartMode) {
        'service' {
            Write-Host '  Runs unattended: registered as a Windows service.' -ForegroundColor Green
            if (-not $StartWhenDone) {
                Write-Host '  It is NOT running yet. Start it, then this window can be closed:' -ForegroundColor Yellow
                Write-Host ('    Start-Service ' + $serviceName) -ForegroundColor Cyan
                Write-Host '  Do not run Start-DSMT.ps1 by hand as well - two instances collide on the port.' -ForegroundColor DarkGray
            }
        }
        'task'    { Write-Host '  Runs unattended: registered as a scheduled task.' -ForegroundColor Green }
        default {
            Write-Host '  NOT registered to run unattended.' -ForegroundColor Yellow
            Write-Host '  DSMT only runs while a PowerShell window is open. Closing that window, or' -ForegroundColor Yellow
            Write-Host '  signing out of Windows, stops the console for everyone with no error shown.' -ForegroundColor Yellow
            Write-Host ''
            Write-Host '  Register it - one command, safe to run at any time:' -ForegroundColor White
            Write-Host '    .\server\Install-DSMT.ps1 -StartWhenDone' -ForegroundColor Cyan
            Write-Host '  A Windows service is the default: it starts at boot, survives sign-out,' -ForegroundColor DarkGray
            Write-Host '  and restarts itself if it fails.' -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Host ('  Then open  http://localhost:' + $Port + '/  and sign in with a domain account.') -ForegroundColor Cyan
    Write-Host '  There is no default account: any valid account in the domain can sign in,' -ForegroundColor DarkGray
    Write-Host '  and what it may change is decided entirely by its delegation in AD.' -ForegroundColor DarkGray

    # Never let someone walk away thinking there is a database when there is
    # not. The console repeats this on the sign-in screen, in the bell and in
    # Settings, and it is said once more here where the decision was made.
    if (-not $sqlReady) {
        Write-Host ''
        Write-Host '  No database is configured, which is the default.' -ForegroundColor Yellow
        Write-Host '  The console is fully usable: everything on screen is read live from the' -ForegroundColor DarkGray
        Write-Host '  directory, and changes are audited to files under data\.' -ForegroundColor DarkGray
        Write-Host '  Add SQL whenever you want from Settings -> Database - no reinstall needed.' -ForegroundColor DarkGray
    }
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

# ---------------------------------------------------------------------------
# Open the console
# ---------------------------------------------------------------------------

$dsmtUrl = 'http://localhost:' + $Port + '/'

# The browser opens on its own. It used to ASK, which was the polite default
# and the wrong one: the operator has just watched thirteen steps go green
# and wants the console, not one more question. It only happens when the port
# actually answered - opening a browser at a dead port teaches the operator
# that the tool is broken - and -NoBrowser turns it off for an unattended run.
if ($script:ConsoleUp -and -not $NoBrowser -and $script:Outstanding.Count -eq 0) {
    try {
        Start-Process $dsmtUrl | Out-Null
        Write-Host ('  Opening ' + $dsmtUrl) -ForegroundColor Cyan
        Write-Host ''
    } catch {
        Write-Host ('  Could not open a browser: ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-Host ('  Open it by hand: ' + $dsmtUrl) -ForegroundColor Cyan
        Write-Host ''
    }
}
