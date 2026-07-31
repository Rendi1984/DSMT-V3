<#
.SYNOPSIS
    DSMT - SQL Server persistence.
.DESCRIPTION
    Creates and uses a real SQL Server database (default name: DSMT) that
    stores:
      dbo.Operators        - who has used the console
      dbo.Sessions         - session history (metadata only, never a password)
      dbo.DirectoryUsers   - a snapshot of the user objects read from AD
      dbo.DirectoryGroups  - a snapshot of the group objects read from AD
      dbo.AuditLog         - every write the console attempted

    WHAT THIS DATABASE IS NOT: it is not the source of truth for the
    directory. The console's user and group grids always read live from
    Active Directory. The snapshot tables are written AFTER a live read, so
    they can go stale between reads and must never be rendered as if they
    were current directory state. Reporting off them is fine; showing them
    in the console instead of a live read is exactly the failure mode
    CLAUDE.md's "No fake/placeholder data" section describes.

    If no -SqlServer is supplied the whole layer is disabled and the audit
    log falls back to the JSONL files. That fallback is announced at startup
    and reported by /api/meta - it never fails silently.
.NOTES
    Author  : IT Team
    Runtime : Windows PowerShell 5.1, System.Data.SqlClient
#>

$script:DsmtSql = @{
    Enabled          = $false
    Server           = ''
    Database         = 'DSMT'
    ConnectionString = ''
    LastError        = ''
}

function Get-DsmtSqlState {
    return $script:DsmtSql
}

function New-DsmtSqlConnectionString {
    param(
        [Parameter(Mandatory = $true)][string] $Server,
        [Parameter(Mandatory = $true)][string] $Database,
        [string] $Username = '',
        [string] $Password = ''
    )

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source']     = $Server
    $builder['Initial Catalog'] = $Database
    $builder['Application Name'] = 'DSMT'
    $builder['Connect Timeout'] = 15

    if ([string]::IsNullOrWhiteSpace($Username)) {
        $builder['Integrated Security'] = $true
    } else {
        $builder['User ID']  = $Username
        $builder['Password'] = $Password
    }

    return $builder.ConnectionString
}

function Invoke-DsmtSqlCommand {
    <#
    .SYNOPSIS
        Runs a parameterised statement. Every value the console sends to SQL
        goes through @parameters - no string concatenation, so a display name
        containing a quote is data, not syntax.
    .PARAMETER Mode
        NonQuery - returns rows affected
        Scalar   - returns the first column of the first row
        Query    - returns an array of PSCustomObject rows
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Sql,
        [hashtable] $Parameters = @{},
        [ValidateSet('NonQuery', 'Scalar', 'Query')][string] $Mode = 'NonQuery',
        [string] $ConnectionString = '',
        [int] $TimeoutSeconds = 30
    )

    $cs = $ConnectionString
    if ([string]::IsNullOrWhiteSpace($cs)) { $cs = $script:DsmtSql.ConnectionString }
    if ([string]::IsNullOrWhiteSpace($cs)) { throw 'SQL is not configured.' }

    $connection = New-Object System.Data.SqlClient.SqlConnection($cs)
    $command    = $null
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText    = $Sql
        $command.CommandTimeout = $TimeoutSeconds

        foreach ($key in $Parameters.Keys) {
            $value = $Parameters[$key]
            if ($null -eq $value) { $value = [System.DBNull]::Value }
            $command.Parameters.AddWithValue('@' + $key, $value) | Out-Null
        }

        switch ($Mode) {
            'Scalar'   { return $command.ExecuteScalar() }
            'NonQuery' { return $command.ExecuteNonQuery() }
            'Query'    {
                $table  = New-Object System.Data.DataTable
                $reader = $command.ExecuteReader()
                $table.Load($reader)
                $reader.Close()

                $rows = @()
                foreach ($row in $table.Rows) {
                    $obj = [ordered]@{}
                    foreach ($col in $table.Columns) {
                        $v = $row[$col.ColumnName]
                        if ($v -is [System.DBNull]) { $v = $null }
                        $obj[$col.ColumnName] = $v
                    }
                    $rows += [pscustomobject]$obj
                }
                return @($rows)
            }
        }
    } finally {
        if ($null -ne $command) { $command.Dispose() }
        $connection.Close()
        $connection.Dispose()
    }
}

function Get-DsmtSqlDatabases {
    <#
    .SYNOPSIS
        Lists the databases on an instance, so an upgrade can point DSMT at
        the database it already has instead of guessing its name.
    .OUTPUTS
        Hashtable with Ok, Error and Databases (array of names).
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Server,
        [string] $Username = '',
        [string] $Password = ''
    )

    try {
        $masterCs = New-DsmtSqlConnectionString -Server $Server -Database 'master' -Username $Username -Password $Password

        $rows = Invoke-DsmtSqlCommand -ConnectionString $masterCs -Mode 'Query' -Sql @'
SELECT name
  FROM sys.databases
 WHERE database_id > 4          -- skip master, tempdb, model, msdb
   AND state = 0                -- online only
 ORDER BY name;
'@
        $names = @()
        foreach ($r in @($rows)) { $names += [string]$r.name }

        return @{ Ok = $true; Error = ''; Databases = @($names) }

    } catch {
        return @{ Ok = $false; Error = $_.Exception.Message; Databases = @() }
    }
}

function Initialize-DsmtSql {
    <#
    .SYNOPSIS
        Connects to SQL Server and prepares the DSMT schema.
    .PARAMETER CreateIfMissing
        $true  - create the database when it does not exist (the installer and
                 the server both want this).
        $false - do not create; report NeedsCreate instead, so a person can be
                 asked first. Creating a database is not something to do as a
                 side effect of a typo in an instance name.
    .OUTPUTS
        Hashtable with Ok, Error, NeedsCreate, DatabaseCreated, TablesCreated
        and TablesFound.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Server,
        [string] $Database = 'DSMT',
        [string] $Username = '',
        [string] $Password = '',
        [bool]   $CreateIfMissing = $true
    )

    $script:DsmtSql.Server   = $Server
    $script:DsmtSql.Database = $Database

    $result = @{
        Ok = $false; Error = ''; NeedsCreate = $false
        DatabaseCreated = $false; TablesCreated = 0; TablesFound = 0
    }

    try {
        # Step 1: connect to master and see whether the database is there.
        $masterCs = New-DsmtSqlConnectionString -Server $Server -Database 'master' -Username $Username -Password $Password

        $exists = Invoke-DsmtSqlCommand -ConnectionString $masterCs -Mode 'Scalar' `
            -Sql 'SELECT database_id FROM sys.databases WHERE name = @db' `
            -Parameters @{ db = $Database }

        if ($null -eq $exists) {
            if (-not $CreateIfMissing) {
                $result.NeedsCreate = $true
                $result.Error = 'The database "' + $Database + '" does not exist on ' + $Server + '.'
                return $result
            }

            # CREATE DATABASE cannot take a parameter for the name, so the
            # name is validated hard and then bracket-quoted.
            if ($Database -notmatch '^[A-Za-z][A-Za-z0-9_]{0,62}$') {
                throw ('Refusing to create a database named "' + $Database + '" - use letters, digits and underscores only.')
            }
            Invoke-DsmtSqlCommand -ConnectionString $masterCs -Mode 'NonQuery' `
                -Sql ('CREATE DATABASE [' + $Database + ']') | Out-Null

            $result.DatabaseCreated = $true
            Write-DsmtLog -Message ('Created SQL database [' + $Database + '] on ' + $Server)
        }

        # Step 2: point at the database and create whatever tables are missing.
        $script:DsmtSql.ConnectionString = New-DsmtSqlConnectionString -Server $Server -Database $Database -Username $Username -Password $Password

        $schema = Install-DsmtSqlSchema
        $result.TablesCreated = $schema.Created
        $result.TablesFound   = $schema.Found

        $script:DsmtSql.Enabled   = $true
        $script:DsmtSql.LastError = ''
        $result.Ok = $true
        return $result

    } catch {
        $script:DsmtSql.Enabled   = $false
        $script:DsmtSql.LastError = $_.Exception.Message
        $result.Error = $_.Exception.Message
        return $result
    }
}

function Install-DsmtSqlSchema {
    <#
    .SYNOPSIS
        Creates every table the console needs, if it is missing. Idempotent.
    #>

    $statements = @()

    $statements += @'
IF OBJECT_ID(N'dbo.Operators', N'U') IS NULL
CREATE TABLE dbo.Operators (
    OperatorId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Operators PRIMARY KEY,
    Account       NVARCHAR(256) NOT NULL CONSTRAINT UQ_Operators_Account UNIQUE,
    SamAccountName NVARCHAR(256) NULL,
    DisplayName   NVARCHAR(256) NULL,
    Upn           NVARCHAR(320) NULL,
    FirstSeenUtc  DATETIME2(0) NOT NULL,
    LastSeenUtc   DATETIME2(0) NOT NULL,
    SignInCount   INT NOT NULL CONSTRAINT DF_Operators_SignInCount DEFAULT(0)
);
'@

    $statements += @'
IF OBJECT_ID(N'dbo.Sessions', N'U') IS NULL
CREATE TABLE dbo.Sessions (
    SessionId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Sessions PRIMARY KEY,
    TokenHash    CHAR(64) NOT NULL,
    OperatorId   INT NOT NULL CONSTRAINT FK_Sessions_Operators REFERENCES dbo.Operators(OperatorId),
    Account      NVARCHAR(256) NOT NULL,
    CreatedUtc   DATETIME2(0) NOT NULL,
    LastSeenUtc  DATETIME2(0) NOT NULL,
    EndedUtc     DATETIME2(0) NULL,
    EndReason    NVARCHAR(64) NULL,
    AppVersion   NVARCHAR(32) NULL
);
'@

    $statements += @'
IF OBJECT_ID(N'dbo.DirectoryUsers', N'U') IS NULL
CREATE TABLE dbo.DirectoryUsers (
    ObjectGuid       UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_DirectoryUsers PRIMARY KEY,
    SamAccountName   NVARCHAR(256) NOT NULL,
    UserPrincipalName NVARCHAR(320) NULL,
    DisplayName      NVARCHAR(256) NULL,
    DistinguishedName NVARCHAR(1024) NULL,
    OuPath           NVARCHAR(1024) NULL,
    Department       NVARCHAR(256) NULL,
    JobTitle         NVARCHAR(256) NULL,
    Manager          NVARCHAR(256) NULL,
    Mail             NVARCHAR(320) NULL,
    Status           NVARCHAR(32) NULL,
    IsEnabled        BIT NULL,
    IsLockedOut      BIT NULL,
    LastLogonUtc     DATETIME2(0) NULL,
    PasswordExpiry   NVARCHAR(64) NULL,
    GroupCount       INT NULL,
    LastSyncUtc      DATETIME2(0) NOT NULL
);
'@

    $statements += @'
IF OBJECT_ID(N'dbo.DirectoryGroups', N'U') IS NULL
CREATE TABLE dbo.DirectoryGroups (
    ObjectGuid       UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_DirectoryGroups PRIMARY KEY,
    SamAccountName   NVARCHAR(256) NOT NULL,
    Name             NVARCHAR(256) NULL,
    DistinguishedName NVARCHAR(1024) NULL,
    OuPath           NVARCHAR(1024) NULL,
    Category         NVARCHAR(32) NULL,
    Scope            NVARCHAR(32) NULL,
    MemberCount      INT NULL,
    LastSyncUtc      DATETIME2(0) NOT NULL
);
'@

    $statements += @'
IF OBJECT_ID(N'dbo.AuditLog', N'U') IS NULL
CREATE TABLE dbo.AuditLog (
    AuditId     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AuditLog PRIMARY KEY,
    TimeUtc     DATETIME2(0) NOT NULL,
    Action      NVARCHAR(128) NOT NULL,
    Target      NVARCHAR(512) NOT NULL,
    Operator    NVARCHAR(256) NOT NULL,
    Controller  NVARCHAR(256) NULL,
    Reason      NVARCHAR(1024) NOT NULL,
    Result      NVARCHAR(32) NOT NULL,
    Category    NVARCHAR(32) NOT NULL,
    Detail      NVARCHAR(MAX) NULL,
    AppVersion  NVARCHAR(32) NULL
);
'@

    $statements += @'
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_AuditLog_TimeUtc' AND object_id = OBJECT_ID(N'dbo.AuditLog'))
CREATE INDEX IX_AuditLog_TimeUtc ON dbo.AuditLog (TimeUtc DESC);
'@

    $statements += @'
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DirectoryUsers_Sam' AND object_id = OBJECT_ID(N'dbo.DirectoryUsers'))
CREATE INDEX IX_DirectoryUsers_Sam ON dbo.DirectoryUsers (SamAccountName);
'@

    # Count what was already there first, so the caller can tell an upgrade
    # ("5 tables already present") from a fresh install ("created 5 tables").
    $wanted = @('Operators', 'Sessions', 'DirectoryUsers', 'DirectoryGroups', 'AuditLog')
    $before = 0
    try {
        $before = [int](Invoke-DsmtSqlCommand -Mode 'Scalar' -Sql @'
SELECT COUNT(*) FROM sys.tables
 WHERE name IN ('Operators','Sessions','DirectoryUsers','DirectoryGroups','AuditLog');
'@)
    } catch {
        $before = 0
    }

    foreach ($sql in $statements) {
        Invoke-DsmtSqlCommand -Sql $sql -Mode 'NonQuery' | Out-Null
    }

    Write-DsmtLog -Message ('SQL schema verified in [' + $script:DsmtSql.Database + '] - ' +
                            $before + ' of ' + $wanted.Count + ' tables already present')

    return @{ Found = $before; Created = ($wanted.Count - $before) }
}

function Get-DsmtTokenHash {
    <#
    .SYNOPSIS
        SHA-256 of the session token. Only the hash is stored, so the
        database never holds anything that could be replayed as a session.
    #>
    param([string] $Token)

    $sha   = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Token))
    $sha.Dispose()
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Register-DsmtOperator {
    <#
    .SYNOPSIS
        Upserts the operator row and records the session. Never stores the
        password - only who signed in and when.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Account,
        [string] $Sam = '',
        [string] $Display = '',
        [string] $Upn = '',
        [string] $Token = ''
    )

    if (-not $script:DsmtSql.Enabled) { return }

    try {
        $cfg = Get-DsmtConfig
        $now = (Get-Date).ToUniversalTime()

        $operatorId = Invoke-DsmtSqlCommand -Mode 'Scalar' -Parameters @{
            account = $Account; sam = $Sam; display = $Display; upn = $Upn; now = $now
        } -Sql @'
MERGE dbo.Operators AS t
USING (SELECT @account AS Account) AS s
   ON t.Account = s.Account
WHEN MATCHED THEN
    UPDATE SET LastSeenUtc = @now, SignInCount = t.SignInCount + 1,
               DisplayName = @display, SamAccountName = @sam, Upn = @upn
WHEN NOT MATCHED THEN
    INSERT (Account, SamAccountName, DisplayName, Upn, FirstSeenUtc, LastSeenUtc, SignInCount)
    VALUES (@account, @sam, @display, @upn, @now, @now, 1);
SELECT OperatorId FROM dbo.Operators WHERE Account = @account;
'@

        if ($Token -and $null -ne $operatorId) {
            Invoke-DsmtSqlCommand -Mode 'NonQuery' -Parameters @{
                hash = (Get-DsmtTokenHash -Token $Token); operatorId = [int]$operatorId
                account = $Account; now = $now; version = $cfg.Version
            } -Sql @'
INSERT INTO dbo.Sessions (TokenHash, OperatorId, Account, CreatedUtc, LastSeenUtc, AppVersion)
VALUES (@hash, @operatorId, @account, @now, @now, @version);
'@ | Out-Null
        }
    } catch {
        Write-DsmtLog -Level 'WARN' -Message ('Could not record the operator in SQL: ' + $_.Exception.Message)
    }
}

function Close-DsmtSqlSession {
    param([string] $Token, [string] $Reason = 'signed out')

    if (-not $script:DsmtSql.Enabled) { return }
    if ([string]::IsNullOrWhiteSpace($Token)) { return }

    try {
        Invoke-DsmtSqlCommand -Mode 'NonQuery' -Parameters @{
            hash = (Get-DsmtTokenHash -Token $Token); now = (Get-Date).ToUniversalTime(); reason = $Reason
        } -Sql @'
UPDATE dbo.Sessions
   SET EndedUtc = @now, LastSeenUtc = @now, EndReason = @reason
 WHERE TokenHash = @hash AND EndedUtc IS NULL;
'@ | Out-Null
    } catch {
        Write-DsmtLog -Level 'WARN' -Message ('Could not close the SQL session row: ' + $_.Exception.Message)
    }
}

function Write-DsmtSqlAudit {
    <#
    .SYNOPSIS
        Inserts one audit record. Returns $true when it landed in SQL.
    #>
    param(
        [Parameter(Mandatory = $true)][datetime] $TimeUtc,
        [Parameter(Mandatory = $true)][string] $Action,
        [Parameter(Mandatory = $true)][string] $Target,
        [Parameter(Mandatory = $true)][string] $Operator,
        [Parameter(Mandatory = $true)][string] $Reason,
        [Parameter(Mandatory = $true)][string] $Result,
        [string] $Category = 'user',
        [string] $Controller = '',
        [string] $Detail = ''
    )

    if (-not $script:DsmtSql.Enabled) { return $false }

    try {
        $cfg = Get-DsmtConfig
        Invoke-DsmtSqlCommand -Mode 'NonQuery' -Parameters @{
            t = $TimeUtc; a = $Action; g = $Target; o = $Operator; c = $Controller
            r = $Reason; res = $Result; cat = $Category; d = $Detail; v = $cfg.Version
        } -Sql @'
INSERT INTO dbo.AuditLog (TimeUtc, Action, Target, Operator, Controller, Reason, Result, Category, Detail, AppVersion)
VALUES (@t, @a, @g, @o, @c, @r, @res, @cat, @d, @v);
'@ | Out-Null
        return $true
    } catch {
        Write-DsmtLog -Level 'WARN' -Message ('Audit insert into SQL failed (the JSONL copy still holds it): ' + $_.Exception.Message)
        return $false
    }
}

function Get-DsmtSqlAudit {
    <#
    .SYNOPSIS
        Reads audit records back out of SQL with the same filters the audit
        view offers: free text, category, and a time window.
    .PARAMETER FromUtc
        Inclusive lower bound, UTC. $null for no lower bound.
    .PARAMETER ToUtc
        Inclusive upper bound, UTC. $null for no upper bound.
    #>
    param(
        [string] $Query = '',
        [string] $Filter = 'All',
        [int] $Limit = 500,
        $FromUtc = $null,
        $ToUtc = $null
    )

    $where  = @()
    $params = @{ limit = $Limit }

    # The time window is applied in SQL, not after the fact in PowerShell -
    # otherwise TOP (@limit) would take the newest 500 rows overall and then
    # filter them down, which silently under-reports an older window.
    if ($null -ne $FromUtc) {
        $where += 'TimeUtc >= @fromUtc'
        $params['fromUtc'] = [datetime]$FromUtc
    }
    if ($null -ne $ToUtc) {
        $where += 'TimeUtc <= @toUtc'
        $params['toUtc'] = [datetime]$ToUtc
    }

    switch ($Filter) {
        'Users'     { $where += 'Category = @cat';        $params['cat'] = 'user' }
        'Groups'    { $where += 'Category = @cat';        $params['cat'] = 'group' }
        'Passwords' { $where += 'Action LIKE @actionLike'; $params['actionLike'] = '%password%' }
        'Deletions' { $where += 'Action LIKE @actionLike'; $params['actionLike'] = '%delet%' }
        default     { }
    }

    if (-not [string]::IsNullOrWhiteSpace($Query)) {
        $where += '(Action LIKE @q OR Target LIKE @q OR Operator LIKE @q OR Controller LIKE @q OR Reason LIKE @q OR Result LIKE @q OR Detail LIKE @q)'
        $params['q'] = '%' + $Query.Trim() + '%'
    }

    $clause = ''
    if ($where.Count -gt 0) { $clause = ' WHERE ' + ($where -join ' AND ') }

    $rows = Invoke-DsmtSqlCommand -Mode 'Query' -Parameters $params -Sql (
        'SELECT TOP (@limit) TimeUtc, Action, Target, Operator, Controller, Reason, Result, Category, Detail ' +
        'FROM dbo.AuditLog' + $clause + ' ORDER BY TimeUtc DESC, AuditId DESC;')

    $total = Invoke-DsmtSqlCommand -Mode 'Scalar' -Parameters $params -Sql (
        'SELECT COUNT_BIG(1) FROM dbo.AuditLog' + $clause + ';')

    $entries = @()
    foreach ($r in @($rows)) {
        $entries += [ordered]@{
            time     = ([datetime]$r.TimeUtc).ToLocalTime().ToString('yyyy-MM-ddTHH:mm:ssK')
            action   = [string]$r.Action
            target   = [string]$r.Target
            operator = [string]$r.Operator
            dc       = [string]$r.Controller
            reason   = [string]$r.Reason
            result   = [string]$r.Result
            category = [string]$r.Category
            detail   = [string]$r.Detail
        }
    }

    $totalValue = 0
    if ($null -ne $total) { $totalValue = [int]$total }

    return @{ entries = @($entries); total = $totalValue }
}

function Sync-DsmtUsersToSql {
    <#
    .SYNOPSIS
        Writes the user rows that were just read from AD into the snapshot
        table. Called after a live read - never instead of one.
    #>
    param([object[]] $Users)

    if (-not $script:DsmtSql.Enabled) { return 0 }
    if ($null -eq $Users -or $Users.Count -eq 0) { return 0 }

    $now   = (Get-Date).ToUniversalTime()
    $count = 0

    foreach ($u in $Users) {
        $guid = $null
        try { $guid = [guid]$u.id } catch { continue }

        $lastLogon = $null
        if ($u.logonRaw) { try { $lastLogon = ([datetime]$u.logonRaw).ToUniversalTime() } catch { $lastLogon = $null } }

        try {
            Invoke-DsmtSqlCommand -Mode 'NonQuery' -Parameters @{
                guid = $guid; sam = $u.sam; upn = $u.upn; display = $u.name; dn = $u.dn
                ou = $u.ou; dept = $u.dept; title = $u.title; manager = $u.manager; mail = $u.mail
                status = $u.status; enabled = [bool]$u.enabled; locked = [bool]$u.locked
                logon = $lastLogon; pwd = $u.pwd; groups = [int]$u.groups; now = $now
            } -Sql @'
MERGE dbo.DirectoryUsers AS t
USING (SELECT @guid AS ObjectGuid) AS s
   ON t.ObjectGuid = s.ObjectGuid
WHEN MATCHED THEN UPDATE SET
    SamAccountName = @sam, UserPrincipalName = @upn, DisplayName = @display,
    DistinguishedName = @dn, OuPath = @ou, Department = @dept, JobTitle = @title,
    Manager = @manager, Mail = @mail, Status = @status, IsEnabled = @enabled,
    IsLockedOut = @locked, LastLogonUtc = @logon, PasswordExpiry = @pwd,
    GroupCount = @groups, LastSyncUtc = @now
WHEN NOT MATCHED THEN INSERT
    (ObjectGuid, SamAccountName, UserPrincipalName, DisplayName, DistinguishedName, OuPath,
     Department, JobTitle, Manager, Mail, Status, IsEnabled, IsLockedOut, LastLogonUtc,
     PasswordExpiry, GroupCount, LastSyncUtc)
    VALUES (@guid, @sam, @upn, @display, @dn, @ou, @dept, @title, @manager, @mail, @status,
            @enabled, @locked, @logon, @pwd, @groups, @now);
'@ | Out-Null
            $count++
        } catch {
            Write-DsmtLog -Level 'WARN' -Message ('User snapshot failed for ' + $u.sam + ': ' + $_.Exception.Message)
        }
    }

    return $count
}

function Sync-DsmtGroupsToSql {
    param([object[]] $Groups)

    if (-not $script:DsmtSql.Enabled) { return 0 }
    if ($null -eq $Groups -or $Groups.Count -eq 0) { return 0 }

    $now   = (Get-Date).ToUniversalTime()
    $count = 0

    foreach ($g in $Groups) {
        $guid = $null
        try { $guid = [guid]$g.id } catch { continue }

        try {
            Invoke-DsmtSqlCommand -Mode 'NonQuery' -Parameters @{
                guid = $guid; sam = $g.sam; name = $g.name; dn = $g.dn; ou = $g.ou
                category = $g.category; scope = $g.scope; members = [int]$g.members; now = $now
            } -Sql @'
MERGE dbo.DirectoryGroups AS t
USING (SELECT @guid AS ObjectGuid) AS s
   ON t.ObjectGuid = s.ObjectGuid
WHEN MATCHED THEN UPDATE SET
    SamAccountName = @sam, Name = @name, DistinguishedName = @dn, OuPath = @ou,
    Category = @category, Scope = @scope, MemberCount = @members, LastSyncUtc = @now
WHEN NOT MATCHED THEN INSERT
    (ObjectGuid, SamAccountName, Name, DistinguishedName, OuPath, Category, Scope, MemberCount, LastSyncUtc)
    VALUES (@guid, @sam, @name, @dn, @ou, @category, @scope, @members, @now);
'@ | Out-Null
            $count++
        } catch {
            Write-DsmtLog -Level 'WARN' -Message ('Group snapshot failed for ' + $g.sam + ': ' + $_.Exception.Message)
        }
    }

    return $count
}
