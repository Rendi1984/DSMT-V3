# PROGRESS — DSMT-V3

Running notes. A session with zero prior context should be able to read this
file and continue immediately. Update it at the end of every session that
changes the project.

## Current version
`1.2.0` — matches the top entry of `CHANGELOG.md` and
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
1. **Run it against LAB.LOCAL.** Neither `Install-DSMT.ps1` nor
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
2. **Serve it over HTTPS before anyone uses it over the network.** The
   `netsh http add sslcert` recipe is in `README.md`; the prefix in
   `Start-DSMT.ps1` also has to change from `http://` to `https://`.
3. **Decide the SQL retention story.** `dbo.AuditLog` grows forever and
   nothing prunes `dbo.Sessions` or the snapshot tables. Pick a retention
   window and add a job.
4. **Vendor Inter, or accept `system-ui`.** The Google Fonts `@import` was
   removed from `styles.css` for the offline constraint, so the console
   currently renders in the system font stack. If Inter is wanted, drop the
   woff2 files into the design-system folder and add an `@font-face` — do not
   re-add a CDN reference.
5. **Consider Kerberos constrained delegation** so operator passwords need not
   be held in memory — see "Attempted and deliberately NOT pursued" below and
   check in before restarting that investigation.
6. **Decide the fate of `prototype/`.** It is kept for reference; delete it
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
- Work is being developed on branch `claude/new-session-6q2ky9`.
