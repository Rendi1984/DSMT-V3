@echo off
REM ==========================================================================
REM  DSMT - Directory Service Management Tool
REM  One-click installer. Right-click this file and "Run as administrator",
REM  or just double-click it - the script asks for elevation itself.
REM
REM  It installs the RSAT ActiveDirectory module, prepares the data folder,
REM  creates the SQL database, reserves the HTTP port, opens the firewall,
REM  and saves the settings so Start-DSMT.cmd needs no parameters afterwards.
REM
REM  Edit the settings below before the first run.
REM ==========================================================================

set DSMT_DOMAIN=LAB.LOCAL
set DSMT_PORT=8080
set DSMT_LISTEN=any

REM Account that will run the console. Leave empty to use the account
REM running this installer.
set DSMT_ACCOUNT=

REM SQL instance to use. Leave empty to auto-detect a local instance.
REM Set DSMT_SKIPSQL=1 to install without any database at all.
set DSMT_SQLSERVER=
set DSMT_SQLDATABASE=DSMT
set DSMT_SKIPSQL=

REM Register a scheduled task that starts DSMT at boot. Set to 1 to enable.
set DSMT_AUTOSTART=

setlocal enabledelayedexpansion

set ARGS=-Domain %DSMT_DOMAIN% -Port %DSMT_PORT% -ListenAddress %DSMT_LISTEN% -SqlDatabase %DSMT_SQLDATABASE%
if not "%DSMT_ACCOUNT%"==""   set ARGS=!ARGS! -ServiceAccount "%DSMT_ACCOUNT%"
if not "%DSMT_SQLSERVER%"=="" set ARGS=!ARGS! -SqlServer "%DSMT_SQLSERVER%"
if not "%DSMT_SKIPSQL%"==""   set ARGS=!ARGS! -SkipSql
if not "%DSMT_AUTOSTART%"=="" set ARGS=!ARGS! -InstallScheduledTask

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server\Install-DSMT.ps1" !ARGS!

endlocal
pause
