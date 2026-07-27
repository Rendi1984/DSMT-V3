/* =========================================================================
   DSMT - Directory Service Management Tool
   SQL Server schema.

   The server creates this automatically on first start (see
   server\lib\DsmtSql.ps1, Install-DsmtSqlSchema). This file is the same
   schema as a standalone script, for a DBA who would rather create the
   database by hand, review it before it is applied, or diff it against an
   existing instance.

   Run against the DSMT database:
       sqlcmd -S SQL01 -d DSMT -i schema.sql
   or create the database first:
       CREATE DATABASE [DSMT];

   WHAT THIS DATABASE IS FOR
   -------------------------
   Operators, sessions, the audit log, and a snapshot of the directory
   objects the console has read.

   WHAT IT IS NOT
   --------------
   It is not the source of truth for the directory. DirectoryUsers and
   DirectoryGroups are written AFTER a live Active Directory read and go
   stale the moment AD changes. The console always renders users and groups
   from a live read - never from these tables. Use them for reporting and
   history, not to answer "what does the directory look like right now".

   No password is stored anywhere in this schema. Sessions hold a SHA-256
   hash of the session token only, so nothing here can be replayed.
   ========================================================================= */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------- Operators
   One row per domain account that has ever signed in to the console. */
IF OBJECT_ID(N'dbo.Operators', N'U') IS NULL
CREATE TABLE dbo.Operators (
    OperatorId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Operators PRIMARY KEY,
    Account        NVARCHAR(256) NOT NULL CONSTRAINT UQ_Operators_Account UNIQUE,  -- LAB\jdoe
    SamAccountName NVARCHAR(256) NULL,
    DisplayName    NVARCHAR(256) NULL,
    Upn            NVARCHAR(320) NULL,
    FirstSeenUtc   DATETIME2(0) NOT NULL,
    LastSeenUtc    DATETIME2(0) NOT NULL,
    SignInCount    INT NOT NULL CONSTRAINT DF_Operators_SignInCount DEFAULT(0)
);
GO

/* ----------------------------------------------------------------- Sessions
   Session history. TokenHash is SHA-256 of the bearer token - the token
   itself and the operator's password are never written here. */
IF OBJECT_ID(N'dbo.Sessions', N'U') IS NULL
CREATE TABLE dbo.Sessions (
    SessionId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Sessions PRIMARY KEY,
    TokenHash   CHAR(64) NOT NULL,
    OperatorId  INT NOT NULL CONSTRAINT FK_Sessions_Operators REFERENCES dbo.Operators(OperatorId),
    Account     NVARCHAR(256) NOT NULL,
    CreatedUtc  DATETIME2(0) NOT NULL,
    LastSeenUtc DATETIME2(0) NOT NULL,
    EndedUtc    DATETIME2(0) NULL,
    EndReason   NVARCHAR(64) NULL,       -- 'signed out' | 'idle timeout'
    AppVersion  NVARCHAR(32) NULL
);
GO

/* ----------------------------------------------------------- DirectoryUsers
   Snapshot of user objects as last read from AD. LastSyncUtc is how stale
   the row is - always check it before reporting off this table. */
IF OBJECT_ID(N'dbo.DirectoryUsers', N'U') IS NULL
CREATE TABLE dbo.DirectoryUsers (
    ObjectGuid        UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_DirectoryUsers PRIMARY KEY,
    SamAccountName    NVARCHAR(256) NOT NULL,
    UserPrincipalName NVARCHAR(320) NULL,
    DisplayName       NVARCHAR(256) NULL,
    DistinguishedName NVARCHAR(1024) NULL,
    OuPath            NVARCHAR(1024) NULL,
    Department        NVARCHAR(256) NULL,
    JobTitle          NVARCHAR(256) NULL,
    Manager           NVARCHAR(256) NULL,
    Mail              NVARCHAR(320) NULL,
    Status            NVARCHAR(32) NULL,   -- Enabled | Disabled | Locked out
    IsEnabled         BIT NULL,
    IsLockedOut       BIT NULL,
    LastLogonUtc      DATETIME2(0) NULL,
    PasswordExpiry    NVARCHAR(64) NULL,
    GroupCount        INT NULL,
    LastSyncUtc       DATETIME2(0) NOT NULL
);
GO

/* ---------------------------------------------------------- DirectoryGroups */
IF OBJECT_ID(N'dbo.DirectoryGroups', N'U') IS NULL
CREATE TABLE dbo.DirectoryGroups (
    ObjectGuid        UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_DirectoryGroups PRIMARY KEY,
    SamAccountName    NVARCHAR(256) NOT NULL,
    Name              NVARCHAR(256) NULL,
    DistinguishedName NVARCHAR(1024) NULL,
    OuPath            NVARCHAR(1024) NULL,
    Category          NVARCHAR(32) NULL,   -- Security | Distribution
    Scope             NVARCHAR(32) NULL,   -- Global | Universal | Domain local
    MemberCount       INT NULL,
    LastSyncUtc       DATETIME2(0) NOT NULL
);
GO

/* ----------------------------------------------------------------- AuditLog
   Every write the console attempted, successful or not. Append-only by
   convention: DSMT never updates or deletes a row here. */
IF OBJECT_ID(N'dbo.AuditLog', N'U') IS NULL
CREATE TABLE dbo.AuditLog (
    AuditId    BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AuditLog PRIMARY KEY,
    TimeUtc    DATETIME2(0) NOT NULL,
    Action     NVARCHAR(128) NOT NULL,      -- 'Reset password', 'Move OU', ...
    Target     NVARCHAR(512) NOT NULL,
    Operator   NVARCHAR(256) NOT NULL,
    Controller NVARCHAR(256) NULL,          -- the DC that served the change
    Reason     NVARCHAR(1024) NOT NULL,     -- mandatory, entered by the operator
    Result     NVARCHAR(32) NOT NULL,       -- Success | Partial | Failed | Denied
    Category   NVARCHAR(32) NOT NULL,       -- user | group | session
    Detail     NVARCHAR(MAX) NULL,
    AppVersion NVARCHAR(32) NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_AuditLog_TimeUtc' AND object_id = OBJECT_ID(N'dbo.AuditLog'))
CREATE INDEX IX_AuditLog_TimeUtc ON dbo.AuditLog (TimeUtc DESC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DirectoryUsers_Sam' AND object_id = OBJECT_ID(N'dbo.DirectoryUsers'))
CREATE INDEX IX_DirectoryUsers_Sam ON dbo.DirectoryUsers (SamAccountName);
GO

/* ------------------------------------------------------------- Permissions
   Grant the account that runs Start-DSMT.ps1 (a service account, or the
   operators' own accounts if you run it interactively) the rights it needs.
   Adjust the principal name, then uncomment:

   CREATE USER [LAB\svc-dsmt] FOR LOGIN [LAB\svc-dsmt];
   ALTER ROLE db_datareader ADD MEMBER [LAB\svc-dsmt];
   ALTER ROLE db_datawriter ADD MEMBER [LAB\svc-dsmt];

   Creating the database on first start additionally needs dbcreator on the
   instance; grant it once, or pre-create the database and skip it.
   ------------------------------------------------------------------------ */
