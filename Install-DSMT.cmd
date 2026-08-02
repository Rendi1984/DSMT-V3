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

REM Account that will run the console. Four forms are accepted:
REM   (empty)             the account running this installer - the default,
REM                       and the only one that cannot fail. You are asked
REM                       for its password once.
REM   LAB\svc-dsmt        a dedicated account. Asks for the password.
REM   LAB\gmsa-dsmt$      a gMSA - the trailing $ is how it is detected.
REM                       No password is asked for.
REM   LocalSystem         the machine account. No password.
REM It can be changed later without reinstalling:
REM   .\server\Install-DSMT.ps1 -ChangeServiceAccount "LAB\gmsa-dsmt$"
set DSMT_ACCOUNT=

REM Which account performs directory operations.
REM   operator (default)  reads and writes both run as the signed-in operator
REM   hybrid              reads run as the service account, writes stay on the
REM                       operator. In hybrid, every operator can see
REM                       everything the service account can see.
set DSMT_IDENTITYMODE=operator

REM SQL instance to use. Leave empty to auto-detect a local instance.
REM Set DSMT_SKIPSQL=1 to install without any database at all.
set DSMT_SQLSERVER=
set DSMT_SQLDATABASE=DSMT
set DSMT_SKIPSQL=

REM How DSMT should start automatically. Set exactly one of these to 1:
REM   DSMT_SERVICE=1   a real Windows service (Get-Service DSMT), recommended
REM                    if you want service semantics and recovery
REM   DSMT_AUTOSTART=1 a scheduled task at boot - no extra moving parts
set DSMT_SERVICE=
set DSMT_AUTOSTART=

REM Start DSMT as soon as the installation finishes. Set to 1 to enable.
set DSMT_STARTNOW=1

setlocal enabledelayedexpansion

set ARGS=-Domain %DSMT_DOMAIN% -Port %DSMT_PORT% -ListenAddress %DSMT_LISTEN% -SqlDatabase %DSMT_SQLDATABASE%
if not "%DSMT_ACCOUNT%"==""      set ARGS=!ARGS! -ServiceAccount "%DSMT_ACCOUNT%"
if not "%DSMT_IDENTITYMODE%"=="" set ARGS=!ARGS! -IdentityMode %DSMT_IDENTITYMODE%
if not "%DSMT_SQLSERVER%"=="" set ARGS=!ARGS! -SqlServer "%DSMT_SQLSERVER%"
if not "%DSMT_SKIPSQL%"==""   set ARGS=!ARGS! -SkipSql
if not "%DSMT_AUTOSTART%"=="" set ARGS=!ARGS! -InstallScheduledTask
if not "%DSMT_SERVICE%"==""   set ARGS=!ARGS! -InstallAsService
if not "%DSMT_STARTNOW%"==""  set ARGS=!ARGS! -StartWhenDone

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server\Install-DSMT.ps1" !ARGS!

endlocal
pause
