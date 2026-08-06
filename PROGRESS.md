# PROGRESS — DSMT-V3

Running notes. A session with zero prior context should be able to read this
file and continue immediately. Update it at the end of every session that
changes the project.

## Current version
`1.12.0` — matches the top entry of `CHANGELOG.md` and
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

1. **[FIXED IN 1.7.5 - NEEDS CONFIRMING ON THE LAB MACHINE] No overlay in the
   console was visible.** Reported 2026-07-31 from the first real install.

   ### What was wrong
   Dialogs, toasts and the notifications panel never appeared, so About, New
   user, Import CSV, Columns and every detail-pane action did nothing, and
   Export gave no feedback. Everything else worked: sign-in, the grid, the
   detail pane, and the file download itself.

   ### How it was identified
   The browser console was **clean** and every request returned 200 -
   including `/api/ous`, which is fetched *only* from inside the Move OU /
   New user / New group / Import handlers. That proved the listeners fired,
   the actions ran and the fetches succeeded; the failure was purely in making
   the result visible. Which pointed at CSS, not JavaScript.

   All three overlays positioned themselves with **logical inset properties**
   (`inset: 0`, `inset-inline-end`, `inset-block-end`). On a browser that
   ignores those, each element falls back to its static position - the dialog
   and toasts land below a container with `overflow: hidden`, and the bell
   panel spills off the right edge. One cause, all three symptoms, no error.

   ### The fix (1.7.5)
   `web/app.css` rewritten with physical offsets, `rgba()` instead of
   `color-mix()`, `width`+`max-width` instead of `min()`, and `dvh` demoted to
   an `@supports` block. `.dialog-backdrop` is restated over the design
   system's version, which is where `inset: 0` came from. The rules are
   written at the top of the file with this incident as the reason.

   ### Confirm on the lab machine
   Deploy `web\app.css`, **hard refresh (Ctrl+F5)**, then:
   - About opens - from the header and from the menu.
   - New user, Import CSV and Columns open.
   - Every detail-pane button opens its dialog.
   - Export shows a toast in the bottom-right corner.
   - The bell panel opens *under* the bell and is fully readable.

   **If any of that still fails**, the diagnosis was wrong and the next step is
   to inspect the live element: right-click where the dialog should be ->
   Inspect, find `#dialogBackdrop`, and read its computed `display`,
   `position`, `top/left/width/height` and `z-index`. That says immediately
   whether it is positioned off-screen, sized to zero, or covered.

   ### Still open from the same report - NOT fixed by 1.7.5
   - **With SQL configured, nothing is written to any table.** `dbo.Operators`
     and `dbo.Sessions` should get rows from sign-in alone, and
     `dbo.DirectoryUsers` from the first grid load - none of which needs a
     working button, so this is independent of the overlay bug. Check the
     startup banner for `[ok] SQL Server ...`, then `data\dsmt-*.log` for
     `Could not record the operator in SQL` or `User snapshot failed`, which
     is where both paths report a failure rather than throwing.
   - `dbo.AuditLog` being empty was expected while no write could succeed.
     Recheck it once the buttons work.

   ### Note
   This was the first execution of any of this code. Do not assume the rest of
   the acceptance checklist passed - re-run it from the top.

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
9. **Verify the gMSA tool against LAB.LOCAL (1.12.0).** None of it has been
   executed. Specifically:
   - `Get-DsmtKdsStatus` builds the forest DN from `(Get-ADDomain).Forest` and
     reads `CN=Master Root Keys,...`. Confirm the search base resolves in this
     forest, and that a forest with **no** key returns Exists=false rather
     than throwing on a missing container.
   - The two confirmations are re-checked server-side; confirm a request with
     one of them false is refused with 400.
   - `Add-KdsRootKey` runs in-process. Confirm the audit record names both the
     initiator and the executing account.
   - Computer resolution accepts NAME, NAME$ and FQDN; the all-or-nothing
     behaviour on an unresolvable name has not been exercised.
   - `New-ADServiceAccount -PrincipalsAllowedToRetrieveManagedPassword` is
     passed the group NAME, not its DN. Confirm AD accepts that here.
10. **Verify 1.11.0 against LAB.LOCAL.** Undo and the health page have never
   been executed — there is no PowerShell in the dev container. Specifically
   worth watching on the first run:
   - `Get-DsmtObjectParent` resolves an identity that is a sAMAccountName and
     one that is a DN; the fallback branch has not been exercised.
   - Undo of **Move OU** only works for moves recorded by 1.11.0 or later.
     Older records legitimately show the dash — that is not a bug.
   - The health **Data folder** check writes and deletes a probe file. Confirm
     it leaves nothing behind if the delete fails.
   - `Get-DsmtHealth` calls `Get-DsmtUsers -Limit 1` as the operator; on a very
     large domain confirm this returns promptly.

---

## Proposed features — NOT approved, do not build

Put here on 2026-07-31 at the operator's request ("just propose, do not work
on them"). Nothing below is a commitment and none of it has been designed.
**A future session must not start any of these without being asked**; when one
is picked, move it into "Open tasks" first.

Ordered by value for the effort, highest first.

1. **Saved searches / filter presets.** The Users grid already filters by OU,
   department and text. Saving a combination under a name ("Disabled in Sales",
   "No logon in 90 days") turns a repeated five-click task into one. Local to
   the browser is enough to start; SQL later would share them across operators.
2. ~~Undo the last action~~ — **built in 1.11.0.**
3. **Bulk import from CSV.** Named in the project description and still not
   built. Requires a dry-run pass that reports what *would* happen before
   anything is written; an import that half-succeeds with no preview is the
   worst possible shape for this feature.
4. **Password expiry and stale-account report.** "Expires in N days",
   "no logon in 90 days", "password never expires" — read straight from
   attributes DSMT already fetches. Mostly a query and a view.
5. **Scheduled directory snapshot.** `dbo.DirectoryUsers` / `DirectoryGroups`
   are only written when someone browses. A timed sync would make them
   genuinely useful for reporting. **Must obey the fake-data rule**: anything
   rendered from a snapshot has to be labelled as one, with its `LastSyncUtc`.
6. **Audit retention and archive.** The table grows forever. Needs a retention
   setting, an archive table, and a deliberate decision about who may purge —
   an audit log that any operator can delete is not an audit log.
7. **A read-only role.** DSMT has no permission model by design; AD enforces
   everything. A UI-level read-only mode is *not* security, but it is useful
   for a service desk that should look and not touch. Would need to be
   labelled honestly as a guard rail, not a control.
8. ~~Health check page~~ — **built in 1.11.0** as Settings -> Health.
9. **Live session list with the ability to sign someone out.** DSMT already
   tracks sessions in `dbo.Sessions`. Useful with several operators, and
   necessary the day someone leaves mid-shift.
10. **Column chooser on the Audit table**, matching the one the Users grid
    already has. Small, consistent, cheap.
11. **Keyboard shortcuts** — `/` to search, `Esc` to close the detail pane,
    `r` to refresh. Cheap, and the kind of thing a daily operator notices.
12. **A dark/light theme switch.** Nocturne is a dark system; a light variant
    is a real piece of design work on the token sheet, not a CSS toggle. Listed
    last deliberately — the cost is much higher than it looks.

13. **LAPS — read and audit the local administrator password.** Raised
    2026-07-31: "logs for the admin password via LAPS. We will open this later
    if it becomes relevant." **Not designed, not scheduled.**
    Sketch only, so a future session does not start from nothing:
    - Windows LAPS (Server 2019+ / 11 with the April 2023 update) stores the
      password in `msLAPS-EncryptedPassword` / `msLAPS-Password`; legacy
      Microsoft LAPS uses `ms-Mcs-AdmPwd`. **A future session must establish
      which of the two this domain runs before designing anything** — they are
      different attributes with different ACL models, and encrypted LAPS
      cannot be read by a plain attribute fetch.
    - Reading is already gated by AD: only principals granted
      `CONTROL_ACCESS` on the attribute see it. That fits DSMT's model exactly
      — it acts as the operator, so AD decides.
    - **The audit requirement is the actual feature.** Every read must be an
      audit record with a mandatory reason, exactly like a password reset,
      because a LAPS read is functionally handing someone local admin. It is
      the one place where the read matters as much as any write.
    - Open questions to settle first: is the password ever displayed on
      screen or only copied; is it masked by default; is there a retention
      rule for the audit entries; and does an expiry-time write
      (`msLAPS-PasswordExpirationTime`, forcing a rotation) belong here too.

14. **Health checks for the Active Directory services themselves.** Raised
    2026-07-31, alongside LAPS. **Not to be built yet.**
    Settings -> Health today answers "can DSMT reach AD". This would answer
    "is AD healthy", which is a different and much larger question. Sketch:
    - **Replication** — `Get-ADReplicationPartnerMetadata -Scope Server` per
      DC: last attempt, last success, consecutive failures. The single most
      useful signal, and the one that goes unnoticed longest.
    - **Per-controller reachability** — LDAP 389, LDAPS 636, Global Catalog
      3268, and DNS resolution of each DC. DSMT already lists every DC.
    - **The five FSMO role holders** — named, and reachable.
    - **Time skew** between DCs. Kerberos fails past five minutes, and the
      symptom looks like nothing to do with time.
    - **SYSVOL / DFSR state**, and whether every DC advertises itself.
    - **Secure channel** from the DSMT host (`Test-ComputerSecureChannel`).
    Design constraints already known, so they are not rediscovered:
    - These are **slow** — several remote calls per DC. It must not run on
      opening the page the way the current checks do; it needs its own
      explicit "Run AD checks" button and probably a per-DC progress list.
    - Some checks need rights the signed-in operator may not have. Each must
      degrade to "could not check, and why", never to a false green.
    - This is diagnostic reporting, not monitoring. If it grows scheduling and
      alerting it has become a different product; say no at that point.

---

## Under consideration — asked about, not decided

**Replacing the HttpListener host with IIS.** Asked 2026-07-31; the answer was
given in conversation and **no change was made, deliberately**. The trade-off
in one line: IIS buys process lifetime management, real HTTPS certificate
handling and Windows authentication, at the cost of the credential-in-memory
design that produces per-operator attribution today — an app-pool recycle
silently signs everyone out, and that is the same class of failure as the
72-hour scheduled-task default already recorded below. **Do not begin this
migration without an explicit decision**; if it is revisited, the first
question is what happens to the sessions on a recycle, not how to host the
files.

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
- **[Shape 3] Modern CSS that degrades to nothing, with no error.** Every
  overlay in the console was invisible on the first real run — no JS error,
  all requests 200 — because logical inset properties were ignored and each
  element fell back to its static position behind an `overflow: hidden`.
  Fixed in 1.7.5. **The pattern: unsupported CSS is discarded silently, so a
  layout that depends on it quietly becomes something else.** Prefer the older
  property for anything that must be visible; the rules are at the top of
  `web/app.css`. No check in this repo can catch it — there is no browser here.
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
