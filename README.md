# DSMT - Directory Service Management Tool

A web console for Active Directory operations - users, groups, membership,
bulk import - across every domain controller in the domain. Operators sign in
with their own domain account, and every write is recorded in an audit log
with the operator, the controller and a mandatory reason.

Everything on screen is read live from Active Directory. There is no demo
mode and no sample data anywhere in the running application: if the directory
cannot be reached, the console shows the error it got - it never falls back to
invented rows.

---

> **Deploying it for the first time?** Open
> [`docs/deployment-guide.html`](docs/deployment-guide.html) in a browser -
> a step-by-step install and first-connection guide, including what "install"
> means here (there is no installer), the AD delegation each action needs, and
> an acceptance checklist for the first run.

## Requirements

On the machine that runs the server:

| Requirement | How to satisfy it |
| --- | --- |
| Windows PowerShell 5.1 | Built into Windows Server 2016+ / Windows 10+ |
| Domain-joined to the domain you manage | e.g. `LAB.LOCAL` |
| RSAT ActiveDirectory module | `Install-WindowsFeature RSAT-AD-PowerShell` (Server)<br>`Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0` (Win 10/11) |
| SQL Server (optional but recommended) | Any reachable instance; DSMT creates the database itself |

Nothing is downloaded at runtime. No CDN, no webfont, no npm install, no
build step - the console works on an isolated lab network.

In the browser: any current Chrome, Edge or Firefox. The UI is responsive from
a 360px phone to an ultrawide monitor.

---

## Installing it

`Install-DSMT.ps1` does the prerequisite work for you. It is safe to re-run —
every step checks the current state first.

```powershell
# The full lab setup: prepare everything, run as a service, start now
.\server\Install-DSMT.ps1 -Domain LAB.LOCAL -SqlServer SQL01 `
                          -ServiceAccount "LAB\svc-dsmt" -InstallAsService -StartWhenDone

# Same, but as a boot-time scheduled task instead of a service
.\server\Install-DSMT.ps1 -Domain LAB.LOCAL -SqlServer SQL01 `
                          -ServiceAccount "LAB\svc-dsmt" -InstallScheduledTask -StartWhenDone

# Minimal, and the quickest way to see it working: no database
.\server\Install-DSMT.ps1

# With a database, finding a local SQL instance automatically
.\server\Install-DSMT.ps1 -UseSql
```

`Install-DSMT.ps1` asks for elevation itself, so a normal PowerShell window is
enough.

It installs the RSAT ActiveDirectory module (`Install-WindowsFeature` on
Server, `Add-WindowsCapability` on client Windows), creates `data\` and
`config\` and grants the run account write access, finds or prepares SQL and
creates the database and its tables, reserves the HTTP URL, opens the firewall
port, optionally registers a boot-time scheduled task, and writes
`config\dsmt.config.json` so the console can then be started with no
parameters. Each step prints `[ok]` / `[skip]` / `[FAIL]`, and the summary
lists anything still outstanding with the fix for it.

### Which account DSMT runs as

`-ServiceAccount` accepts four forms and classifies them automatically:

| Form | Password | Needs preparing |
| --- | --- | --- |
| *omitted* — the installing user (default) | asked once | nothing |
| `LAB\svc-dsmt` | asked once | create the account |
| `LAB\gmsa-dsmt$` — a gMSA, detected by the `$` | **none** | KDS root key + `Install-ADServiceAccount` |
| `LocalSystem` | **none** | grant `LAB\HOSTNAME$` on SQL |

The installing user is the default because it is the only choice that cannot
fail — it exists, and the installer has just proved it reaches AD and SQL.
Windows still needs its password once, to log on at boot.

Change it at any time, without reinstalling:

```powershell
.\server\Install-DSMT.ps1 -ChangeServiceAccount "LAB\gmsa-dsmt$"
```

That updates all five things that depend on the identity — the service or
task, **the URL reservation**, the `data\` permissions, the SQL login (printed
as a script) and the saved settings — after verifying the target account, so a
failure changes nothing.

### Identity mode

| Mode | Reads | Writes |
| --- | --- | --- |
| `operator` (default) | signed-in operator | signed-in operator |
| `hybrid` | the service account | **signed-in operator** |

`hybrid` lets operators browse the directory without broad read rights of
their own. It does mean every operator can see everything the service account
can see — stated in Settings next to the control, not buried here.

**Writes stay on the operator in both modes.** That is what makes the domain
controller's own security log name the person who made each change, and no
tool can fake that after the fact.

### Three things the installer deliberately does not do

| Not automated | Why | What to do |
| --- | --- | --- |
| Download RSAT on an offline Windows 10/11 client | `Add-WindowsCapability` fetches from Windows Update | Pass `-FeatureSource <FOD media or \sources\sxs>` |
| Download SQL Server Express | DSMT hosts usually have no internet route, and a silent download would contradict that | Pass `-SqlExpressSetup <path to setup>` for an unattended install, or omit every SQL switch - no database is the default |
| Delegate AD rights to operators | A security decision that depends on your OU structure | Delegate per OU — see the deployment guide, step 4 |

### Running it unattended

Two supported options, both set up by the installer:

| | Scheduled task | Windows service |
| --- | --- | --- |
| Switch | `-InstallScheduledTask` | `-InstallAsService` |
| Managed with | `Get-ScheduledTask "DSMT Console"` | `Get-Service DSMT` |
| Restarts on failure | 3 attempts, 1 min apart | 5s, 10s, then every 30s |
| Extra moving parts | none | a compiled host executable |

**The scheduled task is the recommendation** unless you specifically need
service semantics — it uses nothing but what Windows already ships.

PowerShell cannot be a Windows service directly: the service control manager
terminates any process that does not answer its protocol, so pointing
`New-Service` at `powershell.exe` looks right and does not work. For
`-InstallAsService` the installer compiles a small C# host
(`server\DsmtService.exe`) with the `csc.exe` that ships with the .NET
Framework — nothing is downloaded — and that host runs `Start-DSMT.ps1` as a
child process, exiting non-zero if the console dies so the SCM restarts it.

Under either option there is no console to read, so **every startup failure is
written to `data\dsmt-*.log`** — check there first.

## Running it

After the installer has run, no parameters are needed — settings come from
`config\dsmt.config.json`, and an explicit parameter overrides the file:

```powershell
.\server\Start-DSMT.ps1
```

To run it without installing first, or to override the saved settings:

```powershell
# Simplest: localhost only, audit to files
.\server\Start-DSMT.ps1

# The usual lab setup: reachable from other machines, records in SQL
.\server\Start-DSMT.ps1 -Domain LAB.LOCAL -ListenAddress any -Port 8080 `
                        -SqlServer SQL01 -SqlDatabase DSMT
```

After the installer has run, `Start-DSMT.ps1` needs no parameters at all — it
reads `config\dsmt.config.json`.

Then open `http://localhost:8080/` and sign in with a domain account.

`-ListenAddress any` needs an elevated shell, or a one-time reservation so it
can run unprivileged:

```
netsh http add urlacl url=http://+:8080/ user="LAB\svc-dsmt"
```

The server refuses to start if the AD module is missing or the domain is
unreachable, and tells you which one it was. That is deliberate: those two
failures are environment problems, and a console that starts anyway would
just fail later in a way that looks like a code bug.

---

## What each part is

| Path | What it is |
| --- | --- |
| `server/Install-DSMT.ps1` | Installs prerequisites and prepares the machine |
| `server/Start-DSMT.ps1` | Entry point: preflight checks, HTTP listener, request loop |
| `server/lib/DsmtCommon.ps1` | **The version constant**, paths, logging, formatting helpers |
| `server/lib/DsmtDirectory.ps1` | Every AD read and write, and the one attribute mapping |
| `server/lib/DsmtSession.ps1` | Sign-in, session tokens, idle expiry |
| `server/lib/DsmtAudit.ps1` | Audit records (SQL primary, JSONL always) |
| `server/lib/DsmtSql.ps1` | SQL Server connection, schema creation, snapshots |
| `server/lib/DsmtGmsa.ps1` | The gMSA tool: KDS root key, permitted-computers group, the account |
| `server/lib/DsmtHttp.ps1` | Static files, the JSON API, bulk-action semantics |
| `web/index.html`, `web/app.css`, `web/app.js` | The front end |
| `_ds/nocturne-.../` | The Nocturne design system (tokens + component CSS) |
| `sql/schema.sql` | The database schema as a standalone script |
| `config/dsmt.config.json` | Settings the installer saved; read at startup |
| `docs/deployment-guide.html` | Step-by-step install and first-connection guide |
| `prototype/` | The original mock-up. **All of its data is fake** - see its README |

---

## Features

Users and groups

- Live search across the directory (AD ambiguous name resolution, plus UPN,
  department and title), not a filter over a preloaded page
- Configurable columns, remembered per tab in the browser
- Detail pane with the account's real attributes and real group memberships
- Reset password (typed or generated), unlock, enable, disable
- Move OU, add to group, remove from group
- Create user, create group, delete
- Bulk CSV import with a per-row result list
- CSV export of the current result set, and of a group's members

Audit

- Every write attempt, successful or not, with operator, controller, reason
  and result (Success / Partial / Failed / Denied)
- Time-range filter: last 24 hours, last 48 hours, last 7 or 30 days, all
  time, or a custom range. Applied inside the SQL query, so the count is the
  true number in that window
- Category filter chips, free-text search, CSV export

Sessions

- Idle timeout, **default 15 minutes, maximum 8 hours**, configurable in
  Settings and applied to sessions already open. The browser warns a minute
  before with a countdown; only genuine interaction resets the clock

Settings and notifications

- **Settings** in the menu shows the running configuration and can point DSMT
  at a SQL Server, creating the database and its tables without a restart
- A notifications bell raises real conditions only — no SQL database
  configured, SQL reporting an error, a search hitting its result cap

Everywhere

- A reason is required before any write; the confirm button rejects a blank one
- Bulk operations report per-target results - a partial result is shown as a
  partial result, never rounded up to "done"
- The version is shown on the sign-in screen and in **About**, both read from
  one constant on the server

---

## Security model

- Operators sign in with their own domain account. Credentials are validated
  against the domain and then used for every directory call that session
  makes, so **AD enforces what each operator may do** and the change is
  attributed to their account on the domain controller. DSMT has no
  permission model of its own to get out of step with the directory's.
- That requires holding the operator's password in the server process for the
  session lifetime (default 8 hours idle). Consequences to accept before
  deploying: run it on a restricted host, and put it behind HTTPS.
- The password is never written to SQL, to the audit log or to the log file.
  `dbo.Sessions` stores a SHA-256 hash of the session token only.
- The browser keeps the session token in `localStorage`, so a refresh (F5)
  does not ask for credentials again - the token is revalidated against the
  server on every load and rejected once the session has expired. Restarting
  the server does end all sessions, because the credentials it needs only
  ever existed in memory.
- Search input is escaped before it reaches an LDAP filter, and every SQL
  statement is parameterised.

### Serving it over HTTPS

`HttpListener` will serve HTTPS once a certificate is bound to the port:

```
netsh http add sslcert ipport=0.0.0.0:8443 certhash=<thumbprint> appid={00000000-0000-0000-0000-000000000000}
```

Then start with `-Port 8443` and change the prefix in `Start-DSMT.ps1` from
`http://` to `https://`. Do this before anyone uses it over the network.

---

## The SQL database

Give `-SqlServer` and DSMT creates the database (default name `DSMT`) and its
tables on first start, then keeps them up to date. `sql/schema.sql` is the
same schema if you would rather create it by hand.

| Table | What it holds |
| --- | --- |
| `dbo.Operators` | One row per account that has used the console |
| `dbo.Sessions` | Session history: token hash, start, end, why it ended |
| `dbo.DirectoryUsers` | Snapshot of user objects, written after each live read |
| `dbo.DirectoryGroups` | Snapshot of group objects |
| `dbo.AuditLog` | Every write attempted, with reason and result |

**The snapshot tables are not the source of truth.** They are written *after*
a live AD read and go stale the moment the directory changes. The console
always renders users and groups from a live read. Use the snapshots for
reporting and history - never to answer "what does the directory look like
right now".

Without `-SqlServer`, the audit log still works: it is written as JSONL under
`data\audit-YYYY-MM.jsonl`. The startup banner says so, and **About** in the
console says so too, so nobody assumes a database is recording things that are
only in a local file.

---

## Deploying a change

There is no build step. Copy the changed file into place and restart the
PowerShell process; front-end files (`web/*`, `_ds/*`) need only a hard
refresh (Ctrl+F5) in the browser.

| Changed | Action |
| --- | --- |
| `web/*`, `_ds/*` | Hard refresh in the browser |
| `server/**` | Restart `Start-DSMT.ps1` |
| `sql/schema.sql` | Restart; missing tables are created automatically |
