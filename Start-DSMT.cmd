@echo off
REM ==========================================================================
REM  DSMT - Directory Service Management Tool
REM  Convenience launcher. Edit the settings below, then double-click.
REM
REM  Requirements on this machine:
REM    - domain-joined to the domain named in DSMT_DOMAIN
REM    - RSAT ActiveDirectory PowerShell module
REM        Install-WindowsFeature RSAT-AD-PowerShell            (Server)
REM        Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
REM    - reachable SQL Server instance if DSMT_SQLSERVER is set
REM ==========================================================================

set DSMT_DOMAIN=LAB.LOCAL
set DSMT_PORT=8080
set DSMT_LISTEN=localhost
REM Leave DSMT_SQLSERVER empty to run without SQL (audit falls back to files).
set DSMT_SQLSERVER=
set DSMT_SQLDATABASE=DSMT

setlocal
set PS=powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server\Start-DSMT.ps1"

if "%DSMT_SQLSERVER%"=="" (
    %PS% -Domain %DSMT_DOMAIN% -Port %DSMT_PORT% -ListenAddress %DSMT_LISTEN%
) else (
    %PS% -Domain %DSMT_DOMAIN% -Port %DSMT_PORT% -ListenAddress %DSMT_LISTEN% -SqlServer %DSMT_SQLSERVER% -SqlDatabase %DSMT_SQLDATABASE%
)

endlocal
pause
