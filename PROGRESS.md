# PROGRESS — DSMT-V3

Running notes. A session with zero prior context should be able to read this
file and continue immediately. Update it at the end of every session that
changes the project.

## Current version
`1.13.2` — matches the top entry of `CHANGELOG.md` and
`$script:DsmtVersion` in `server/lib/DsmtCommon.ps1`.

Setup is now automated: `server/Install-DSMT.ps1`
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
7. ~~A read-only role~~ — **superseded by 24**, which covers it properly.
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
    - **Replication** — asked for again on 2026-07-31 as "`repadmin /replsum`".
      Give the operator that summary, but **do not shell out to `repadmin` and
      parse its output**: it is console text, it is localised, and its layout
      has changed between Windows versions - parsing it is a bug waiting for a
      German server. The same numbers come back as objects from
      `Get-ADReplicationPartnerMetadata -Scope Server` (last attempt, last
      success, consecutive failures) and `Get-ADReplicationFailure`, both of
      which take `-Credential`. Present it as `replsum` does - one row per DC,
      largest delta first - because that is the view people know.
      This is the single most useful signal here, and the one that goes
      unnoticed longest.
    - **Per-controller reachability** — LDAP 389, LDAPS 636, Global Catalog
      3268, and DNS resolution of each DC. DSMT already lists every DC.
    - **The five FSMO role holders** — asked for again on 2026-07-31: show
      where each role sits. Three come from `Get-ADDomain` (PDCEmulator,
      RIDMaster, InfrastructureMaster) and two from `Get-ADForest`
      (SchemaMaster, DomainNamingMaster) - no extra tooling needed, and both
      cmdlets are already used in this codebase. Name the holder **and whether
      it currently answers**: a role pointing at a decommissioned DC looks
      perfectly healthy in a list and is the actual fault.
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

### Remote server management (15-18) — raised 2026-07-31, NOT to be built yet

Four related requests: connect to servers with a PowerShell session and run
commands remotely; kill processes; stop / start / restart services; schedule
tasks. Recorded together because they are one feature with four faces, and
because they share one decision that has to be made **before** any of them is
written.

**These change what DSMT is.** Every existing feature reads or writes the
*directory*. This is remote administration of *machines* — a different product
axis, a different failure surface, and by far the largest security change in
the project's history: "run this command over there" is arbitrary remote code
execution by definition. That is not an argument against building it. It is an
argument for deciding deliberately, once, rather than discovering it halfway
through feature 17.

15. **Remote PowerShell session and command execution.**
    - `New-PSSession` / `Invoke-Command -Credential $session.Credential`, so it
      runs as the operator exactly like every directory write — WinRM and the
      target machine's own ACLs decide what is allowed, and DSMT keeps having
      no permission model of its own. Do not break that.
    - **The second-hop problem is the known blocker**: a command that runs on
      server A and then reaches server B or a file share fails, because the
      operator's credential does not delegate past the first hop. CredSSP or
      resource-based constrained delegation solves it and neither can be
      designed blind — same shape as the delegation entry already recorded
      under "attempted and deliberately NOT pursued".
    - Environment prerequisites, which will otherwise be reported as bugs:
      WinRM enabled and listening, the firewall open, and Kerberos (not
      NTLM) so the machine name resolves properly. A health check per target
      before offering a console is the honest way to handle it.
    - **Audit the full command text, verbatim, with a mandatory reason.**
      Anything less makes the audit log worthless for the one feature where it
      matters most. Consider whether an allow-list of commands should be the
      default posture, with free-form as an explicit opt-in.
16. **Kill processes.** Read with `Get-Process` / `Get-CimInstance
    Win32_Process` (owner and command line are worth showing), stop with
    `Stop-Process`. Needs a confirmation naming the process and the machine,
    and should warn — not silently refuse — on system-critical processes.
17. **Services: stop, start, restart.** The most useful of the four and the
    least dangerous. `Get-Service` for state and start type, with the
    dependency list shown before a stop, because stopping a service with
    dependents is how an afternoon disappears. Restart is the common case and
    deserves to be one button.
18. **Scheduled tasks.** List, run now, enable/disable, and possibly create.
    Note the trap already recorded in this file: a task created without
    `-ExecutionTimeLimit ([TimeSpan]::Zero)` is killed after 72 hours by
    default. Anything DSMT creates must set it, and anything DSMT *shows*
    should surface it, because the same default has already cost this project
    once.

**Where these belong — the placement question, thought through.**

Not in `Tools`. Tools is "guided jobs against the directory", and the gMSA
wizard sets the shape: a sequence of steps with an end state. These four are
not wizards; they are a live view of a machine with actions on it — which is
exactly the shape of `Users` and `Groups`.

So: **a new top-level `Servers` tab, built like the directory tabs.** A
searchable list of computer accounts read live from AD (DSMT already reads
computers — `Get-DsmtComputerAccount` exists), a detail pane per machine, and
the four features as sections within that pane: Services, Processes, Scheduled
tasks, Run command. That gives every one of them an obvious home, reuses the
list/detail/bulk-action machinery already built, and keeps the mental model
simple:

| Tab | Means |
| --- | --- |
| Users / Groups | Directory objects |
| **Servers** | **Machines, and what is running on them** |
| Tools | Guided jobs with an end state |
| Audit log | What was done |
| Settings | How this server is configured |

Two consequences to accept before starting: the detail pane will need its own
section rail (four sections is too many to stack), and **"Run command" should
be the last of the four built, not the first** — the other three are bounded
operations with clear audit records, and they will prove the remote-session
plumbing before the unbounded one is exposed.

### Reports, DNS/DHCP, and sensitive-group filters (19-22) — raised 2026-07-31, NOT to be built yet

19. **Reports out of Active Directory.** Named queries with an export, run
    against the live directory. The four that earn their place immediately:
    stale accounts (no logon in N days), password state (expiring, expired,
    never expires), privileged group membership (see 22 — the same SID list
    feeds both), and accounts created or disabled in a window.
    - The engine is already there: `Get-DsmtUsers` reads every attribute these
      need, and the CSV export exists. A report is a saved query plus a column
      set, not new plumbing.
    - **Reports must be dated on the page and in the export.** A directory
      report with no "as at" stamp gets circulated for months as if it were
      current — the same failure the fake-data rule guards against, in a form
      that survives being emailed.
    - Decide early whether a report may run from the SQL snapshot. If yes it
      must be labelled a snapshot with its `LastSyncUtc`, never presented as
      live. If no, say so and always read live.
20. **DHCP.** Read scopes, leases, reservations; convert a lease to a
    reservation. Notes before anyone starts:
    - The `DhcpServer` module is a separate RSAT feature
      (`RSAT-DHCP`) and is **not** installed by `Install-DSMT.ps1` today. It is
      also not present on a machine that is not a DHCP server, so it must be a
      checked prerequisite with a named fix, like the AD module.
    - Authorised DHCP servers are listed in AD (`Get-DhcpServerInDC`), which is
      the honest way to discover them rather than asking the operator to type
      names.
    - Leases are volatile: anything shown must be timestamped and refreshable,
      and reservations are the only part worth writing.
21. **DNS.** Read zones and records; create and delete A / CNAME / PTR. The
    `DnsServer` module is again a separate RSAT feature.
    - AD-integrated zones replicate, so a change made against one DC is not
      instantly visible at another. Whatever is shown must name **which server
      answered**, exactly as the directory views already do.
    - Deleting a record is the destructive case here and needs the same
      treatment as deleting a user: confirmation, mandatory reason, audit.
    - PTR records are the classic trap - created in a different zone, easy to
      orphan. Either handle the pair together or say plainly that it does not.
22. **Sensitive-group filter on the Groups screen**, with editable filters.
    The smallest of these four and probably the most useful day to day.
    - **Match on SID, never on name.** `Domain Admins` can be renamed, and is
      localised on a non-English install; the RIDs are fixed. Domain Admins
      512, Domain Controllers 516, Schema Admins 518, Enterprise Admins 519,
      Group Policy Creator Owners 520, plus the built-in aliases in the
      `S-1-5-32-*` range (Administrators 544, Account Operators 548, Server
      Operators 549, Backup Operators 551, Print Operators 550). A filter that
      matches the string "Domain Admins" is a filter that silently returns
      nothing on the day it matters most.
    - `adminCount = 1` is a useful second signal - it marks objects protected
      by AdminSDHolder - but it is **not** a substitute: it lingers on accounts
      removed from a privileged group, so it over-reports. Show it, do not
      filter solely on it.
    - Shape it like the audit filter chips that already exist, so it is one
      familiar control rather than a new idea.
    - **Where custom filters are stored matters now that SQL is optional.**
      Built-in filters belong in code (they are static facts about AD, not
      configuration). Custom ones belong in `config\dsmt.config.json`, so they
      are shared by everyone using that server and survive with no database.
      `localStorage` would make them per-browser, which is wrong for something
      one administrator defines for the team.

### Certificate services (23) — raised 2026-07-31, NOT to be built yet

Four related asks: issue certificates against the CA servers, check CRL
validity, create certificate requests, and read a CSR or PEM file and show the
operator what is in it.

**Two design rules to settle before any code, because they are hard to
retrofit:**

- **DSMT must never hold a private key.** If it generates a request, the key
  belongs on the machine the certificate is for. The moment a private key
  passes through this server, the whole "credentials only ever live in process
  memory" posture in `README.md` is a different conversation. Read requests,
  submit them, show what came back - do not generate keypairs server-side.
- **Enrolment rights are AD template permissions**, so the existing model
  holds perfectly: run as the operator, and the CA decides what they may
  enrol. Do not build a permission model here either.

23a. **Discover the CAs.** They are published in the forest configuration
     partition under `CN=Enrollment Services,CN=Public Key Services,
     CN=Services,CN=Configuration,<forest DN>`. DSMT already reads that
     partition for the KDS root key (`Get-DsmtKdsStatus`), so the same
     approach works and nothing has to be typed by hand. Show each CA, its
     DNS name, and the templates it publishes.
23b. **Issue / request.** `Get-Certificate` (the built-in `PKI` module,
     Windows 8 / 2012 and later) enrols against a template and takes
     `-Credential`. `certreq.exe` covers submitting an existing CSR.
     **Do not plan on PSPKI** - it is a community module from the PowerShell
     Gallery, and this project must keep working on an isolated network with
     no package install. Every dependency here has to ship with Windows.
23c. **CRL validity.** Read the CDP URLs from the CA or from a certificate,
     fetch each CRL, and report `ThisUpdate` / `NextUpdate` with the time
     remaining - an expired CRL fails validation everywhere at once and is a
     classic silent outage, so this is the highest-value item of the four.
     **The awkward part, stated in advance:** .NET Framework 4.x has no CRL
     parser, so on PowerShell 5.1 there is no clean managed way to read one.
     `certutil -dump` works but means parsing console text - exactly what the
     `repadmin` note above says to avoid. Accept it here if there is no
     alternative, but **isolate it in one function** with the raw output kept
     on failure, rather than spreading `certutil` parsing through the codebase.
23d. **Read a CSR or PEM and display it.** Two very different jobs:
     - A **certificate** (`.cer`, `.pem`, base64 or DER) loads natively with
       `X509Certificate2` - subject, issuer, validity, SANs, key usage,
       thumbprint. Easy, and worth doing first.
     - A **CSR** (PKCS#10) has no parser in .NET Framework at all. Same
       `certutil -dump` compromise as the CRL. Plan for it; do not discover it
       halfway through.
     Show expiry as a plain "expires in N days" alongside the date - the
     number is what anyone actually looks for.
23e. **Build a request from a template plus parameters, and have the CA sign
     it.** Asked for 2026-07-31 as the main point of the PKI work, so treat
     23a-d as the groundwork for this rather than as the goal.

     **The form must be generated FROM the template, not fixed.** Templates
     are published in AD at `CN=Certificate Templates,CN=Public Key Services,
     CN=Services,CN=Configuration,<forest DN>` and are readable with
     `-Credential`, so DSMT can know before asking anything:
     - `msPKI-Certificate-Name-Flag` - whether the subject is **built from AD**
       or **supplied in the request**. This single flag decides whether the
       operator should be asked for a subject at all. Ask when the template
       builds it from AD and the CA rejects the request; do not ask when the
       template requires it and the certificate comes back naming the wrong
       thing.
     - `pKIExtendedKeyUsage` - the EKUs, which is what the certificate is
       actually *for*, and the most useful thing to show when picking.
     - `msPKI-Minimal-Key-Size`, `msPKI-Enrollment-Flag` (autoenrolment,
       publish to AD), and whether approval is required - a request that goes
       to **pending** rather than issued is a normal outcome and the UI has to
       have a state for it, not treat it as failure.
     - The template ACL decides who may enrol. Show templates the operator can
       actually use, and say plainly when one is listed but not permitted.

     **Where the key is generated decides the whole flow** - this is the
     rule from the top of 23 applied concretely:
     - Certificate **for the DSMT host itself**: direct enrolment with
       `Get-Certificate -Template <name> -Credential` is fine, because the key
       is generated where it belongs.
     - Certificate **for any other machine**: DSMT must NOT generate the key.
       Build the request definition (the `certreq` INF: subject, SANs, key
       length, provider, exportable flag) from the template and the operator's
       parameters, and either hand over the `certreq -new` / `-submit`
       commands to run on the target, or accept a CSR the operator already
       has (23d) and submit that. Same shape as the gMSA tool's step 4 -
       generate the command where the console genuinely cannot act.

     Traps to design for, all of which produce unhelpful CA errors:
     - **SANs.** Most modern uses require a SAN, and a SAN in the request is
       only honoured if the template allows it, or if the CA has
       `EDITF_ATTRIBUTESUBJECTALTNAME2` set - which is a CA-wide setting with
       real security implications and must not be suggested casually. Report
       which of the two applies rather than letting the request fail.
     - **Provider**: KSP versus legacy CSP, and whether the key is marked
       exportable. Wrong choice, and the certificate issues but cannot be used
       by the service it was meant for.
     - Audit the whole thing: template, subject, SANs, CA, and the serial and
       thumbprint that came back. A certificate nobody can trace to a request
       is the PKI equivalent of an unaudited write.

### Roles from AD groups, and a dashboard (24-25) — raised 2026-07-31, NOT to be built yet

24. **Application roles driven by AD group membership.** Members of one group
    are administrators of DSMT; members of another get read-only.

    **Read this before designing it, because it touches a decision recorded in
    `CLAUDE.md`:** DSMT deliberately has no permission model of its own - every
    directory write runs as the signed-in operator, so AD is the authority.
    That decision is not overturned by this feature, and the distinction is the
    whole design:

    - **For directory operations, a role can only ever SUBTRACT.** Putting
      someone in the "DSMT Admins" group cannot give them rights AD has not
      granted - the write still runs as them and still fails. So "admin on the
      system" means *nothing is hidden from them in this console*, not *they
      can do more*. A read-only role is real and useful, but it constrains
      **DSMT**, not the person: the same operator can still open ADUC or a
      PowerShell prompt and do whatever AD permits. **It must be described
      that way in the UI**, or it will be mistaken for a control that it is
      not, and someone will rely on it.
    - **For DSMT's OWN settings, a role has real teeth**, because nothing in
      AD governs them. Who may change the idle timeout, point the console at a
      different database, change the identity mode, create the forest KDS root
      key, or (see 6) purge the audit log - these are application decisions
      with no AD equivalent, and today any operator who can sign in can make
      all of them. **This is the part that genuinely closes a gap**, and on its
      own it may be the better first version.

    Implementation notes:
    - **Map SIDs, not group names** - same lesson as 22. Names are renameable
      and localised.
    - Resolve at sign-in and cache on the session. Use the token groups so
      nested membership is included; a check against `memberOf` alone misses
      a user who is an admin through a nested group, which is how most real
      directories are arranged.
    - **Enforce on the server, on every route.** Hiding a button is a
      convenience, not an enforcement: the API is reachable directly. A role
      that exists only in `app.js` is decoration.
    - Store the mapping in `config\dsmt.config.json` so it works with no
      database, and **fail open to the current behaviour** when no mapping is
      configured - an upgrade must not lock everyone out of their own console.
    - Decide explicitly what happens when the mapping names a group that no
      longer exists, and when an operator matches both roles. Say it in the UI.

25. **A dashboard summarising the current state**, per area.
    Candidate tiles, all from data DSMT already reads: user and group counts,
    accounts disabled or locked out, passwords expiring in the next N days,
    stale accounts, recent audit activity, and the Health verdict that already
    exists (1.11.0).

    Three rules, because a dashboard is the single easiest place to reintroduce
    the failure this project has a whole section about:
    - **Every tile is live, or it is labelled with the time it was taken.**
      A number on a dashboard is read as "now" by default. If a tile ever
      comes from the SQL snapshot it must show its `LastSyncUtc`.
    - **A tile that cannot be computed says so.** It shows the error, not a
      zero. "0 locked-out accounts" and "the query failed" look identical and
      mean opposite things.
    - **Cost is the design constraint.** Counting every user in a large domain
      on every page load is not free. Either use indexed counts, or load tiles
      individually and let each report its own state, rather than blocking the
      screen on the slowest one.

    Placement: this is the natural landing screen after sign-in - the console
    currently opens straight into the Users grid, which answers no question.
    Whether it becomes a tab or replaces the default landing view is worth
    deciding at the time.

### Running unattended, and the end of the installer (26-27) — raised 2026-07-31

26. **"It runs in a window and somebody can close it."** Correct, and it
    matters - but the fix already exists and the installer is not steering
    people to it. **This is a discoverability problem, not a missing feature.**

    `-InstallAsService` (1.4.0) registers a real Windows service: no window at
    all, starts at boot, survives sign-out, and the service manager restarts
    it if it dies. `-InstallScheduledTask` is the lighter alternative - runs
    whether or not anyone is signed in, with
    `-ExecutionTimeLimit ([TimeSpan]::Zero)` so the 72-hour default cannot
    kill it. The visible window only happens with neither: the installer's
    `default` start branch launches a plain PowerShell process, which is the
    right behaviour for a first run and the wrong one to leave in place.

    **`-WindowStyle Hidden` is NOT the answer and must not be offered as one.**
    It hides the window without changing anything that matters: the process
    still belongs to that sign-in session, so it still dies at sign-out, and
    now nobody can tell it is running or read its output when it fails. It
    trades a visible problem for an invisible one.

    What to actually build:
    - When DSMT is started as a bare process, **say so and say what to do**:
      "running in this window - close it and the console stops. Re-run with
      `-InstallAsService` to run it properly." One line, at the end of the
      install.
    - Consider making a service or task the **default** when the installer is
      run interactively, with the bare process as the explicit fallback. Same
      reasoning as making SQL opt-in in 1.13.0: the default should be the
      thing that works unattended.
    - Whatever is added, honour the acceptance test already recorded under
      "recurring root causes": leave it running for four days and confirm it
      still answers. Nothing shorter catches the platform-default class.

27. **Ask at the end of the installation whether to open the browser.**
    Today the summary prints the URL and stops. Small, and it is the last
    thing between a finished install and seeing the console work.
    - Prompt, do not just launch - an installer that opens a browser without
      asking is rude on a server console. Default to yes on an interactive
      run.
    - **Must not prompt when there is nobody to answer.** A service install,
      a scheduled task, or any unattended run has to skip the question rather
      than block forever. Gate it on an interactive host, and add a switch
      (`-OpenBrowser` / `-NoBrowser`) so an unattended caller can state its
      intent.
    - Only offer it when the install actually succeeded and DSMT was started -
      opening a browser at a console that is not listening teaches the
      operator that the tool is broken.
    - It is a small change; build it with the next installer work rather than
      on its own.

### Where all of this goes — the tab count is the real constraint

Today: Users, Groups, Audit log, Tools, Settings. The open proposals would add
Servers (15-18), Reports (19), DNS/DHCP (20-21) and certificates (23) - nine
or ten tabs, and
the header already moves tabs into the hamburger at 820px. Sprawl is the
actual risk, not any individual feature.

The grouping that holds up:

| Tab | Contains |
| --- | --- |
| Users, Groups | Directory objects. 22 is a filter here, not a new tab |
| Servers | Machines: services, processes, tasks, remote command (15-18) |
| Infrastructure | A rail: DNS, DHCP, Certificates (20-21, 23). None deserves a top-level tab alone, and all three are separate Windows roles read through separate modules |
| Reports | A rail of report types (19) |
| Tools | Guided jobs with an end state |
| Audit log | What was **done** - distinct from Reports, which is what **is** |
| Settings | How this server is configured - roles (24) are a section here |

Seven tabs, each with a one-sentence meaning, plus the dashboard (25) as the
landing screen rather than an eighth. **Reports and Audit log must not
be merged** even though both produce tables: one answers "what is true now",
the other "what changed and who did it". Collapsing them would make both
harder to explain.

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
- **[Shape 3] A collection of one is not a collection.** Durable copy of the
  entry now in `CLAUDE.md`. Three instances so far: `ConvertTo-Json`
  collapsing a single-element array, `-Discover` returning `HostName` as a
  collection, and 1.12.1's installer reading the first *character* of
  `localhost` as a SQL instance name. Rules: return `,@($list)`, call inside
  `@( )`, `asArray()` on the client, and validate values that must have a
  shape.
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
