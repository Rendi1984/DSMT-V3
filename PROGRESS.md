# PROGRESS — DSMT-V3

Running notes. A session with zero prior context should be able to read this
file and continue immediately. Update it at the end of every session that
changes the project.

## Current version
`1.7.4` — matches the top entry of `CHANGELOG.md` and
`$script:DsmtVersion` in `server/lib/DsmtCommon.ps1`.

Setup is now automated: `server/Install-DSMT.ps1` (or `Install-DSMT.cmd`)
installs RSAT, prepares folders, creates the SQL database, reserves the port,
opens the firewall, optionally registers a boot task, and saves
`config/dsmt.config.json` — after which `Start-DSMT.ps1` needs no parameters.

Deployment guide for operators: `docs/deployment-guide.html` (open in a
browser). It is the step-by-step install/first-connection document; keep it in
step with any change to startup parameters, prerequisites or the sign-in flow.

## What exists right now
A working console, not a prototype. `server/Start-DSMT.ps1` (Windows
PowerShell 5.1 + `HttpListener`) serves `web/` and a JSON API that reads and
writes **live Active Directory** on `LAB.LOCAL` using the signed-in operator's
own credentials. Optional SQL Server database `DSMT` stores operators,
sessions, a directory snapshot and the audit log. No build step, no external
requests, responsive from 360px up.

The original mock-up now lives in `prototype/` and is reference only — all of
its data is fabricated and every button is inert.

---

## Open tasks

1. **[BLOCKER — first real run, 2026-07-31] The console renders but almost
   nothing works.** Reported from a first install on `LAB.LOCAL`, no SQL.
   **Fix this before anything else. Do not build new features on top of it.**

   ### What works
   - Sign-in, and the session survives.
   - The users grid loads real accounts from `LAB.LOCAL` (7 users, correct OUs,
     correct status). So auth, the API, the AD reads and the attribute mapping
     are all fine.
   - Clicking a row loads the detail pane with real attributes and memberships.
   - **Export** works — and it is the one action that does *not* open a dialog.
   - The bell badge renders a count, so `/api/meta` and `renderNotifications()`
     ran.

   ### What is broken
   - **Every button that opens a dialog does nothing**: About (from the header
     *and* from the menu), New user, Import CSV, Columns, and every button in
     the detail pane — Reset password, Unlock, Disable, Move OU, Add to group,
     Delete. No dialog, no error on screen.
   - **The notifications panel opens off the right edge of the viewport** and
     is unreadable — it extends rightwards from the bell instead of being
     right-aligned under it.
   - Export gives no feedback that anything happened (the toast is not
     appearing — which is consistent with the dialog problem: both are
     overlays).
   - With SQL configured: same behaviour, **and nothing is written to any
     table**.

   ### The pattern, and what it points at
   Everything that fails is an **overlay** — dialog or toast. Everything that
   works is either inline or a file download. Two candidates fit that:

   a) **A JavaScript exception thrown from `openDialog`** (or from the toast
      path), leaving `dispatchAction` dead. Checked statically and ruled out:
      all 40 element ids `wireEvents()` touches exist in `index.html`, and
      `openDialog` itself reads clean. So if it is JS, it is a runtime error
      the console will name in one line.

   b) **`web/app.css` served stale from the browser cache.** This fits the
      bell panel precisely: without the `.bell-wrap { position: relative }`
      rule the panel falls back to its static position and spills off-screen
      to the right, exactly as reported. It would also explain missing
      `[hidden] { display: none !important }` / `z-index` behaviour on the
      dialog backdrop.

   ### Do this first, in order — it should settle it in minutes
   1. **Open DevTools (F12) → Console.** Read the first red error. That alone
      probably identifies it. Screenshot it.
   2. **Network tab, disable cache, hard reload (Ctrl+Shift+R).** Confirm
      `app.js` and `app.css` are served 200 with current content, not 304 from
      cache, and that neither 404s.
   3. In the Console run `typeof openDialog` and then `actionAbout()` directly.
      If About opens that way, the wiring is at fault; if it throws, the error
      text is the answer.
   4. Check `data\dsmt-YYYY-MM-DD.log` on the server for anything logged at
      the moment of a click.

   ### Also to investigate, separately
   - **SQL writes**: with `-SqlServer` set, `dbo.Operators` and `dbo.Sessions`
     should have rows from sign-in alone, and `dbo.DirectoryUsers` from the
     first grid load — none of which needs a working button. If those tables
     are empty too, the failure is server-side and independent of the UI bug:
     check the startup banner for `[ok] SQL Server ...` and the log for
     `Could not record the operator in SQL` / `User snapshot failed`.
   - `dbo.AuditLog` being empty is **expected** while no write action can be
     performed, so it proves nothing on its own.

   ### Note for whoever picks this up
   This is the first time any of this code has been executed. Everything
   through 1.7.4 was verified statically only — that limitation is recorded
   under "Attempted and deliberately NOT pursued" below, and this is exactly
   the class of failure it predicted. Do not assume the rest of the acceptance
   checklist passed; re-run it from the top once the overlays work.

   gMSA testing is **not** worth attempting until this is fixed — agreed with
   the reporter.

2. **Run the rest of the acceptance checklist against LAB.LOCAL** (blocked by
   task 1). Neither `Install-DSMT.ps1` nor
   `Start-DSMT.ps1` has ever been executed: the dev container is Linux with no
   PowerShell and no domain. Treat the first run as a test. On the installer,
   watch specifically:
   - Self-elevation: it rebuilds the original argument list for the elevated
     relaunch — check nothing you typed was dropped.
   - `Get-WindowsCapability -Name 'Rsat.ActiveDirectory.DS-LDS.Tools*'` on a
     client OS, and whether an offline host needs `-FeatureSource`.
   - `Register-ScheduledTask -User <domain account>` without a stored
     password: it may need "Log on as a batch job" or an interactive password
     prompt. The installer warns about this but cannot verify it.
   - **`-InstallAsService`**: the C# host is compiled at install time with
     `Add-Type -OutputAssembly -OutputType ConsoleApplication`. Confirm the
     compile succeeds on the target's .NET Framework, that the service starts
     within the SCM timeout, that killing the child PowerShell triggers a
     recovery restart, and that `Stop-Service` actually takes the child down
     rather than orphaning it.
   - Under service or task there is no console: confirm a deliberate failure
     (e.g. a wrong `-SqlServer`) really does show up in `data\dsmt-*.log`.
   - **gMSA (1.5.0)**: `Test-ADServiceAccount` detection, and whether
     `sc.exe config DSMT obj= "LAB\gmsa$" password= ""` really takes. Also
     `New-ScheduledTaskPrincipal -LogonType Password` with a gMSA.
   - **`-ChangeServiceAccount` (1.5.0)**: the whole five-step sequence, and
     specifically that the console still listens afterwards — the URL
     reservation is the step that breaks quietly.
   - **`hybrid` identity mode (1.5.0)**: that a read really does run as the
     service account (test with an operator who has no read rights), and that
     a write by that same operator still shows *their* name in event 4724 on
     the DC. That second half is the whole point of the design.
   - **Four-day soak.** Leave it running and confirm it still answers. This is
     the only way to catch the class of bug the 72-hour task limit belonged to.
   - **Idle timeout (1.7.0)**: default is 15 minutes, maximum 480. Set it to
     2 minutes in Settings, leave the tab
     alone, and confirm the warning appears at 60 seconds, the countdown runs,
     "Stay signed in" works, and expiry really ends the session server-side
     (a subsequent API call must 401). Confirm a page left open does NOT keep
     itself alive.
   - That `config/dsmt.config.json` is written where the run account can read
     it, and that `Start-DSMT.ps1` then starts with no parameters.

   And on the server itself:
   - `Get-ADDomainController -Discover` returning `HostName` as a collection
     (handled in `Get-DsmtServer`, but verify the DC name in the audit rows
     looks like one host, not two).
   - The `anr` LDAP search on a real directory — confirm searching by
     department/title/UPN behaves as expected and is fast enough.
   - `Set-ADAccountPassword` over the default Negotiate+sealing channel
     (no LDAPS). If it fails with a constraint error, the usual causes are
     password policy or the operator lacking Reset Password delegation.
   - Whether `-ResultSetSize` 500 is the right page size for the lab.
3. **Write a consolidated "required permissions" document.** *(Requested
   2026-07-31; deliberately not started yet — do this when asked.)*

   Today every permission is documented, but scattered across the deployment
   guide and the README. Someone preparing an environment — or answering a
   security review — needs one page listing all of them.

   It should cover, grouped by who grants it:
   - **Active Directory, per operator**: the delegation each console action
     needs (Reset Password + write `pwdLastSet`, write `lockoutTime`, write
     `userAccountControl`, Delete/Create Child for Move OU, write `member`,
     Create Child, Delete). Source: deployment guide 4.5.
   - **Active Directory, for the service account**: what it needs in each
     identity mode — nothing beyond read in `operator` mode, directory read
     in `hybrid`. Plus the gMSA prerequisites (`Add-KdsRootKey`,
     `New-ADServiceAccount`, `PrincipalsAllowedToRetrieveManagedPassword`,
     `Install-ADServiceAccount`).
   - **SQL Server**: `dbcreator` to let DSMT create the database;
     `db_datareader` + `db_datawriter` afterwards; which principal it applies
     to for each account form, including `DOMAIN\HOST$` for LocalSystem.
     Source: deployment guide 5.3 and `sql/schema.sql`.
   - **Local machine**: administrator for the install only; modify on `data\`;
     the URL reservation; the firewall rule; "Log on as a batch job" for a
     scheduled task under a domain account.
   - **What DSMT deliberately does NOT need**: Domain Admin, schema rights,
     write access to its own program folder.

   Format: a section in `docs/deployment-guide.html` (it is already the
   operator-facing document, and a separate file would drift) plus a short
   table in `README.md`. Cross-reference rather than restate, so there is one
   source per fact — the same rule the version number follows.

4. **Serve it over HTTPS before anyone uses it over the network.** The
   `netsh http add sslcert` recipe is in `README.md`; the prefix in
   `Start-DSMT.ps1` also has to change from `http://` to `https://`.
5. **Decide the SQL retention story.** `dbo.AuditLog` grows forever and
   nothing prunes `dbo.Sessions` or the snapshot tables. Pick a retention
   window and add a job.
6. **Vendor Inter, or accept `system-ui`.** The Google Fonts `@import` was
   removed from `styles.css` for the offline constraint, so the console
   currently renders in the system font stack. If Inter is wanted, drop the
   woff2 files into the design-system folder and add an `@font-face` — do not
   re-add a CDN reference.
7. **Consider Kerberos constrained delegation** so operator passwords need not
   be held in memory — see "Attempted and deliberately NOT pursued" below and
   check in before restarting that investigation.
8. **Decide the fate of `prototype/`.** It is kept for reference; delete it
   once nobody needs the original design pass.

---

## Recurring root causes
Durable copy of the section in `CLAUDE.md`. Three shapes to watch for:
1. **A feature is a stub, not a bug** — a UI exists but the core capability was
   never implemented. Record "do not consider this handled until X exists."
2. **Environment/configuration-dependent failure, not code** — a one-time
   external step (permission, dependency, network, credential) was never
   completed. First question on a repeat report is "was the external step
   done?", not "what's wrong with the code."
3. **A design pattern that keeps producing the same category of bug** — record
   the pattern itself, not just each instance.

### Recorded instances
- **[Shape 2] "The server won't start."** Three preflight checks in
  `Start-DSMT.ps1` each name their own fix: RSAT `ActiveDirectory` module
  missing (`Install-WindowsFeature RSAT-AD-PowerShell`), domain unreachable,
  or SQL unreachable. Read the startup banner before touching code.
- **[Shape 2] "Listening on all interfaces fails."** `-ListenAddress any`
  needs an elevated shell or a one-time
  `netsh http add urlacl url=http://+:8080/ user="LAB\svc-dsmt"`.
- **[Shape 2] "Access denied when I reset a password."** Writes run as the
  signed-in operator; AD is enforcing that operator's rights and the audit row
  says `Denied`. The fix is AD delegation, not DSMT code.
- **[Shape 2] "Everyone got logged out."** Restarting the server ends all
  sessions by design — the credentials it needs exist only in process memory.
  A browser refresh (F5) does *not* sign anyone out.
- **[Shape 1] `prototype/` is not the product.** Every action there is `noop`;
  "it doesn't do anything" about those pages is not a DSMT bug.
- **[Shape 3] Snapshot-vs-live.** `dbo.DirectoryUsers` / `dbo.DirectoryGroups`
  are written after a live read and go stale immediately. Rendering the grids
  from them would silently show wrong data with no error — the exact pattern
  the fake-data rule exists to prevent.

---

## Attempted and deliberately NOT pursued
Durable copy of the section in `CLAUDE.md`.

**1. Kerberos constrained delegation instead of credentials in memory.**
Investigated while designing `DsmtSession.ps1`. Cleaner posture, but it needs
SPN and delegation configuration on `LAB.LOCAL` that cannot be designed
blind — it has to be set up and tested against the live domain. Decided
instead: hold the `PSCredential` in process memory for the session lifetime,
document the consequence in `README.md`, never persist it. Revisit when
someone can configure and test delegation in the lab. **Do not rip out the
current design without checking in first.**

**2. Verifying the PowerShell server by running it.**
Dev container is Linux, no PowerShell, no domain. Done instead: ASCII and
brace/paren balance checks on every `.ps1`, `node --check` on `app.js`, and a
line-by-line review that found and fixed five real defects. Runtime
verification against LAB.LOCAL is still outstanding — see Open task 1.

---

## Notes for next session
- **The version lives in exactly one place**: `$script:DsmtVersion` in
  `server/lib/DsmtCommon.ps1`. It reaches the sign-in footer and the About
  dialog through `GET /api/meta`. Never type a version literal anywhere else.
- **The AD attribute mapping lives in exactly one place**:
  `ConvertTo-DsmtUser` / `ConvertTo-DsmtGroup` in `DsmtDirectory.ps1`. AD's
  `sAMAccountName`/`UserPrincipalName`/`LastLogonDate` become `sam`/`upn`/
  `logon` there and nowhere else. Never put raw AD attribute names in `app.js`.
- **PowerShell 5.1 only** — no `??`, no ternary, no `&&`, ASCII-only in
  `.ps1`/`.cmd`. Re-run the ASCII and brace-balance checks after every edit
  (commands are in `CLAUDE.md`).
- **`ConvertTo-Json` collapses single-element arrays.** The front end wraps
  every list in `asArray()` because of this — keep doing that for new lists.
- **Uncaptured output inside a PowerShell function joins its return value.**
  This was a real bug in `Invoke-DsmtBulkAction`; side-effecting calls are
  piped to `| Out-Null`.
- **Sessions**: token in `localStorage`, revalidated on every page load, so F5
  does not prompt for credentials. Idle lifetime 8 hours, configurable with
  `-SessionHours`.
- **Responsive breakpoints** in `app.css`: 1180px (detail pane becomes a
  slide-over), 820px (tabs move into the menu), 640px (tables reflow to
  stacked cards). Check all four widths when adding UI, and never solve a
  narrow viewport by hiding directory data.
- **Zero external requests** is a hard rule — no CDN, no webfont, no bundler.
  `prototype/support.js` still pulls React from unpkg, which is one of the
  reasons the prototype is not shippable.
- **Branching**: `main` is the default branch and holds everything through
  1.2.1. Work on a short-lived feature branch off `main` and merge back via
  pull request; documentation-only fixes may go straight to `main`. The
  original `claude/new-session-6q2ky9` branch was merged into `main` and
  deleted — do not go looking for history there.
- **Nothing has been verified at runtime yet.** Open task 1 is still open and
  is the single most important thing outstanding: neither the installer nor
  the server has ever been executed. Do not treat "it is on `main`" as "it
  works".
