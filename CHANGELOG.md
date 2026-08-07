# Changelog — DSMT-V3

The **top entry is the authoritative current version**. Read it here before
picking the next version number; do not trust a version noted anywhere else.

Format: `MAJOR.FEATURE.FIX`
- MAJOR — breaking change
- FEATURE — new feature (reset FIX to 0)
- FIX — bug fix only

Every entry states **which files changed and where they go**, so the person
deploying can hot-swap individual files without reasoning it out.

---

## Version history at a glance

One line per release. The full entry for each is below — this table is an
index into it, not a second record, so that there is still exactly one place
where what changed is written down.

| Version | Date | What changed | To deploy |
| --- | --- | --- | --- |
| **1.20.0** | 2026-08-07 | The installer starts the service, **waits until the console answers**, and opens the browser itself. `prototype/` and an unused 4.9 MB image removed | Re-run installer |
| **1.19.1** | 2026-08-07 | The installer now names `Start-Service DSMT` when it registers a service it did not start | Re-run installer |
| **1.19.0** | 2026-08-07 | **Groups tab fixed for real**; the AD health clock reads again; confirmations name the target; profile actions moved above the fold | Restart + refresh |
| **1.18.3** | 2026-08-07 | The service now runs as **LocalSystem** by default - it was asking a Domain Admin to store their password | Re-run installer |
| **1.18.2** | 2026-08-07 | AD health showed one row of blanks per table instead of no rows, and never said why a section was empty | Restart + refresh |
| **1.18.1** | 2026-08-07 | **Fixes the Groups tab**, which 1.15.0 broke; the profile window read the wrong field so every section was empty; a Copy button on the generated password | Restart + refresh |
| **1.18.0** | 2026-08-06 | Clicking a name opens a full profile window - identity, organisation, account and every group membership | Refresh |
| **1.17.0** | 2026-08-06 | **Tools -> AD health**: replication the way `replsum` reads, the five FSMO holders and whether each answers, per-controller ports and clock drift | Restart + refresh |
| **1.16.0** | 2026-08-06 | **DSMT now installs as a Windows service by default**, so it survives a closed window and a sign-out | Re-run installer |
| **1.15.0** | 2026-08-06 | Sensitive-group filter on the Groups tab, matched on SID and extensible; installer stops leaving DSMT in a closable window without saying so | Restart + refresh |
| **1.14.0** | 2026-08-06 | **Move OU never worked** - the identity was passed in a form `Move-ADObject` does not accept; plus System and Failed filters on the audit log | Restart + refresh |
| **1.13.3** | 2026-08-06 | PowerShell files now ship with Windows (CRLF) line endings | Re-copy files |
| **1.13.2** | 2026-08-06 | Installer parameters could be lost in the elevation relaunch; it now shows what it received and what it forwards | Re-run installer |
| **1.13.1** | 2026-07-31 | The two `.cmd` wrappers are removed - both had drifted, and one silently overrode the saved settings | Copy files |
| **1.13.0** | 2026-07-31 | **SQL is now opt-in.** A plain install needs no database, so the console can be demonstrated in one step; `-UseSql` turns it on | Re-run installer |
| **1.12.1** | 2026-07-31 | Installer found one SQL instance and used the first **letter** of its name as the server | Re-run installer |
| **1.12.0** | 2026-07-31 | A **Tools** tab with a rail of tools; the first is a guided gMSA setup, including enabling gMSAs for a forest that never used them | Restart + refresh |
| **1.11.0** | 2026-07-31 | Undo a directory change from its audit entry; a Health section that says what is reachable and how to fix what is not | Restart + refresh |
| **1.10.0** | 2026-07-31 | Refresh button on the Audit log, with a stamp saying how stale the table is | Refresh |
| **1.9.2** | 2026-07-31 | Database section states the live server and database as fields; a 404 on a new route now names the cause | Refresh |
| **1.9.1** | 2026-07-31 | Settings keeps only the section rail; the arrangement switch is gone | Refresh |
| **1.9.0** | 2026-07-31 | Settings rearranged: a section rail with one section at a time, and the operator picks the arrangement | Refresh |
| **1.8.1** | 2026-07-31 | Fixes the idle-timeout 500; pick an existing database; confirm before creating; custom port; Settings laid out in columns | Restart + refresh |
| **1.8.0** | 2026-07-31 | Settings becomes a full tab; shows the verbatim SQL error; builds the service-account command | Refresh |
| **1.7.5** | 2026-07-31 | **Fixes the first-run blocker** - no dialog, toast or notification panel was visible | Refresh |
| **1.7.4** | 2026-07-31 | Guide's contents sidebar collapses by group; 1.7.3's body-section collapsing reverted | Docs only |
| **1.7.3** | 2026-07-31 | Deployment guide sections collapse (superseded by 1.7.4) | Docs only |
| **1.7.2** | 2026-07-31 | Version history indexed at the top of this file | Docs only |
| **1.7.1** | 2026-07-30 | Deployment guide made usable on phones: tables reflow to cards, contents collapse, iOS safe areas | Docs only |
| **1.7.0** | 2026-07-30 | Idle timeout default cut to 15 minutes, capped at 8 hours; bounds enforced on every route | Restart |
| **1.6.0** | 2026-07-30 | Idle timeout with a warning countdown; deployment guide covers every installation form | Restart + refresh |
| **1.5.0** | 2026-07-30 | Service identity: gMSA, dedicated, machine or installing user; `-ChangeServiceAccount`; identity mode; publisher | Restart + refresh |
| **1.4.0** | 2026-07-30 | Run unattended as a Windows service or a hardened scheduled task; `-StartWhenDone` | Restart |
| **1.3.0** | 2026-07-30 | Audit time filtering; Settings screen that creates the database; notifications bell | Restart + refresh |
| **1.2.1** | 2026-07-27 | Deployment guide rewritten in English | Docs only |
| **1.2.0** | 2026-07-27 | Automated installer and saved configuration | Re-run installer |
| **1.1.0** | 2026-07-27 | Step-by-step deployment guide | Docs only |
| **1.0.0** | 2026-07-27 | **First working release** — live AD, SQL persistence, responsive console | Full install |
| 0.1.0 | 2026-07-27 | Design prototype imported (fabricated data, inert buttons) | — |
| 0.0.0 | 2026-07-27 | Project scaffold | — |

**Deploy key**: *Restart* = restart `Start-DSMT.ps1`; *refresh* = hard refresh
in the browser (Ctrl+F5); *Docs only* = no runtime impact.

`main` carries **1.20.0**. The last tag is `v1.4.0`.

---

## 1.20.0 — 2026-08-07

**The installation now finishes the job.** One command, and the console is
open in a browser.

    .\server\Install-DSMT.ps1

### Starting is the default, and "started" now means "answering"

- **`-StartWhenDone` is no longer needed** - it is kept so existing command
  lines keep working, and `-NoStart` is the way to opt out. An installer that
  registers a service and leaves it stopped has not finished; it has left the
  operator to work the last step out of a skip message.
- **The installer waits for the PORT, not for the service status.** "Service
  Running" is not the same as "DSMT is working": the service host starts,
  launches PowerShell, loads six libraries, runs three preflight checks and
  only then opens the listener - several seconds on a cold start, and it can
  fail anywhere in that sequence while the service still reports Running. It
  now polls `127.0.0.1:<port>` for up to 45 seconds and only then says the
  console is up. If nothing answers it says so, names the log, and mentions
  the other common cause - a port already in use.
- **Re-running the installer restarts a running service** rather than
  reporting success against the old files. Copying new files and re-running
  used to leave the previous build serving.

### The browser opens by itself

No question. 1.15.0 asked, which was the polite default and the wrong one:
after thirteen green steps the operator wants the console, not one more
prompt. It opens **only** when the port actually answered and nothing is
outstanding - a browser pointed at a dead port teaches the operator that the
install failed when it did not. `-NoBrowser` for unattended runs.

### Automatic start after a reboot

Unchanged, and worth stating plainly since it was asked: the service is
registered with `StartupType = Automatic` and recovery actions
(restart after 5s, 10s, then every 30s). It comes back on its own after a
restart, and after a crash.

### "Why is there both Install-DSMT and Start-DSMT?"

A fair question, and the answer is that **`Start-DSMT.ps1` is not an
installation step - it is the application.** The service host launches it;
that is what the service *is*. After a service install nobody should ever run
it by hand, and as of this version nothing tells them to.

It stays a separate file for one real reason: the service, the scheduled task
and a debugging session all need to launch the same server, and a server that
can only be started by its installer cannot be debugged or hosted any other
way. What was wrong was not the second file - it was that the installer
stopped short and left the operator to find it.

### Removed: files the running system does not need

- **`prototype/`** - the original mock-up. Fabricated data, inert buttons, and
  it loaded React from a CDN, contradicting the offline rule. Nothing
  referenced it at runtime. Its warnings are removed from `README.md`,
  `CLAUDE.md` and the deployment guide along with it.
- **`uploads/Gemini_Generated_Image_9wfzor...png`** - 4.9 MB, referenced by
  nothing. The sign-in image is the other file, which stays.

The download is now **4.7 MB instead of 8.6 MB**.

`_ds/` is kept whole: only `styles.css` is served, but `readme.md` is the
design system's authoritative usage guide and the three tool files are what
the design tool syncs against. 56 KB, and removing them would break that.

Files: `server/Install-DSMT.ps1`, `server/lib/DsmtCommon.ps1` (version),
`README.md`, `CLAUDE.md`, `PROGRESS.md`, `docs/deployment-guide.html`;
**deleted** `prototype/` and one image.

---

## 1.19.1 — 2026-08-07

**The installer registered a service, did not start it, and never said how.**

Asked from the lab: *does the window still have to stay open?* It does not,
and has not since 1.16.0 - but the installer's own output led straight to
running `Start-DSMT.ps1` by hand anyway.

Step 13 said only:

    [skip] Not requested. Re-run with -StartWhenDone to start it as soon as
           the install finishes.

Two steps earlier it had registered the `DSMT` service successfully. So the
service was sitting there, ready, stopped - and the only instruction on screen
was to run the whole installer again. An operator who wants the console
working in the next thirty seconds runs the start script in a window instead,
which is exactly what the service exists to avoid.

Now, when a service or task was registered but not started, the step names the
one command that starts it:

    [skip] Not started. The service is registered and ready:
               Start-Service DSMT
           Or re-run this installer with -StartWhenDone.

and the closing summary repeats it, with the warning that matters:
**do not run `Start-DSMT.ps1` by hand as well - two instances collide on the
port.**

**A skip message has to say what to do instead, not only what was not done.**

Files: `server/Install-DSMT.ps1`, `server/lib/DsmtCommon.ps1` (version).

---

## 1.19.0 — 2026-08-07

Four findings from the lab.

### Fixed - the Groups tab, for real this time

1.18.2 fixed the `adminCount` cast and I called it done. It was half the
fault. The other half is the **comma operator that 1.18.2's own changelog
warned about**, in the filter function added in 1.15.0:

    Select-DsmtGroupsByFilter ... return ,@($Rows)

The comma protects a single-element list from unrolling - but the route wraps
the call in `@( )`, so the outer array survives and the whole group list
arrives as **one element that is itself an array**. `items` serialised as
`[[ ...20 groups... ]]`, the grid rendered that single element as one blank
row, and the detail pane asked for `/api/groups/undefined`.

All seven of those returns now use `@( )`. **This is the third instance of
the same root cause in this project**, and the first where I had already
written the rule down and then applied it to the wrong file. `CLAUDE.md` now
says it in the form that would have caught this: the comma operator is wrong
when the caller wraps the result.

### Fixed - the AD health clock column

`Exception calling "ParseExact" ... String was not recognized as a valid
DateTime`. `Get-ADRootDSE` returns `currentTime` as a **DateTime object**,
not the LDAP generalized-time string the parse assumed. `[string]` on it
produced a culture-formatted date - `08/07/2026 19:28:10` - and taking the
first 14 characters of that gives `08/07/2026 19:`, which is correctly
refused. Both shapes are now handled, and a value that is neither says so.

### Confirmations name what they act on

"Disable account - 1 object" said nothing about which object - and the detail
pane can be showing a different user than the one ticked in the grid. Every
confirmation now names the target in the title **and** in the body, because a
long name is truncated by the title's width and this is the one place it has
to be unambiguous.

For a bulk action, **every** name is listed rather than "and 12 more": a bulk
change the operator cannot fully read is one they cannot check. The list
scrolls inside its own box.

### The profile window's actions moved above the content

With six group memberships the buttons were past the fold, so the most-used
controls moved further away the more there was to read - exactly backwards.
They are now at the top, and stick there as the panel scrolls.

Files: `server/lib/DsmtDirectory.ps1`, `server/lib/DsmtAdHealth.ps1`,
`server/lib/DsmtCommon.ps1` (version), `web/app.js`, `web/app.css`,
`CLAUDE.md`. **Copy `server/lib/*.ps1` and restart**, then `web/*` and
hard-refresh.

---

## 1.18.3 — 2026-08-07

**The service defaults to LocalSystem. It was asking for a Domain Admin
password and storing it.**

Asked from the lab: *what are the permissions in the installation for?* The
honest answer was that the prompt should not have been there.

**1.16.0's changelog said the service runs as LocalSystem unless
`-ServiceAccount` names something else. That was wrong** - the code kept the
pre-1.16.0 default of "the account running the installer", which for a service
means the service control manager has to **store that account's password on
disk**. On a lab installed by `LAB\Administrator`, the installer warned in
step 7 that running DSMT as a privileged account makes it a target, and then
four steps later asked that same Domain Admin for their password to keep.
The installer was arguing with itself.

The default of "the installing account" was right when the fallback was
running in a window as that person, with nothing stored. **1.16.0 made a
service the default and never revisited it.**

Now, with no `-ServiceAccount`:
- **A service or task runs as LocalSystem.** No password exists, so none is
  stored and none can expire. No prompt.
- **`-NoAutoStart` keeps the old behaviour** - nothing is registered, DSMT
  runs in the operator's own window as them, and nothing is stored either way.
- `-ServiceAccount` is unchanged: a named account still prompts once, a gMSA
  still prompts for nothing.

**This costs nothing in attribution**, which is the only reason it is safe: in
the default `operator` identity mode every directory read and write already
runs as the **signed-in operator**, so the host identity never touches AD and
the domain controller still records the human. It shows in exactly one place -
SQL, where the machine account needs rights - and the installer already says
so when a database is configured.

Files: `server/Install-DSMT.ps1`, `server/lib/DsmtCommon.ps1` (version).
Re-run the installer. It replaces the existing service registration cleanly,
and the password already stored for the old registration is discarded with it.

---

## 1.18.2 — 2026-08-07

**Fixed - every AD health table showed a single row of blanks.**

Replication, FSMO, controllers and failures each rendered one empty row with
`undefined` in the numeric columns. The cause is the mirror image of the
single-element problem already recorded in `CLAUDE.md`, and it is worth adding
to that entry rather than treating it as a new bug:

`return ,@($list)` protects a **one-element** list from being unrolled. On an
**empty** list it does the opposite of what is wanted - it produces an array
containing an empty array, which serialises as `[[]]`, and the front end
faithfully renders that one element as a row where every field is missing.

An empty section must look empty. Three changes:

- The four AD-health readers return `@($list)`. Every call site already wraps
  in `@( )`, which is the guard that actually protects against unrolling.
- The front end filters each list to rows that are real objects carrying the
  key that names them. A section that serialises oddly now renders as empty
  rather than as one row of blanks - blanks read as data.
- **Each section reports its own failure.** Previously one shared `error`
  field was overwritten by whichever check failed last, and a section that
  came back empty said nothing at all. Now every check that throws is named,
  and an FSMO or controller list that is empty *without* an error says so
  explicitly - usually the operator cannot read the forest configuration.

A silently empty card reads as "nothing is wrong here", which is the opposite
of the truth. That is the whole point of this screen.

Files: `server/lib/DsmtAdHealth.ps1`, `server/lib/DsmtCommon.ps1` (version),
`web/app.js`.

---

## 1.18.1 — 2026-08-07

Three faults from the lab, one of them mine from two versions ago.

### Fixed - the Groups tab showed one blank row

**1.15.0 broke it**, and the way it broke is worth writing down.

Adding the privileged-group filter meant reading two more attributes on every
group. The mapping did `[int]$AdGroup.adminCount -eq 1` - and **Active
Directory returns an attribute that is not set as an empty
`ADPropertyValueCollection`, not as `$null`**. Casting that to `[int]` throws.

The cast sat inside the `[ordered]@{ }` literal that builds the whole row, so
the throw did not lose one field: **the entire hashtable assignment failed**,
`ConvertTo-DsmtGroup` returned nothing, and the tab rendered blank rows. The
detail pane then asked for `/api/groups/undefined`, which is the error in the
log - a symptom three steps from the cause.

Both new reads are now wrapped and fall back to a safe default. The pattern to
remember: **a cast inside a hashtable literal takes the whole object with it
when it fails.** Compute values that can throw *before* the literal.

### Fixed - the profile window was empty and Enable did not work

`GET /api/users/<id>` answers `{ ok, item }`. The profile window read the
response object directly instead of `res.item`, so every field was
`undefined`: all four sections said "nothing recorded in the directory", and
the button could not tell whether the account was enabled or disabled.
Pressing an action then said *"select at least one row first"*, because the id
it looked up was undefined too.

Fixed, and the actions now use the **grid row's** id rather than one from the
detail payload - the actions operate on the list, so that is the id that has
to match.

### The generated password can be copied

When a new user is created with no password, DSMT generates one and shows it
once. There was no way to get it out except selecting the text by hand.

There is now a **Copy password** button. It reads the value from the element
on screen rather than from a captured variable, so what lands on the clipboard
is provably what is displayed. The password is still never written to the
audit log, and still shown only once.

Files: `server/lib/DsmtDirectory.ps1`, `server/lib/DsmtCommon.ps1` (version),
`web/app.js`. **Copy `server/lib/*.ps1` and restart**, then `web/app.js` and
hard-refresh.

---

## 1.18.0 — 2026-08-06

**Clicking a name opens a profile window.**

The detail pane on the right is good for glancing while working down a list,
and it has to abbreviate to fit. This is for stopping and looking at one
object properly.

- The name in the grid is now a button. **The rest of the row still selects**,
  so the pane behaves exactly as it did - this adds a way in rather than
  replacing one.
- Four sections: **Identity**, **Organisation** (Directory, for a group),
  **Account**, and every **group membership** - or every member, for a group.
  Two columns at desk width, one on a phone.
- The same actions the pane offers - reset password, unlock, enable/disable,
  move OU, add to group - so there is one set of verbs in the console and they
  behave identically wherever they are pressed.

Three details that are only visible when they are wrong:
- It reads the **same endpoint** the detail pane reads. One fetch, one shape
  of data; a section added here never means a second API.
- A section with nothing in it says **"nothing recorded in the directory for
  these fields"** rather than rendering an empty list. An empty list reads as
  "there is none", when the truth is "nothing was filled in".
- The dialog is widened **only while a profile is open**, so every other
  dialog keeps the measure it was designed at. Pressing an action closes the
  profile first, because two stacked dialogs would fight over one backdrop.

### Recorded, not built

The attribute work asked for alongside this - view a user's attributes, add
one, search for a specific value - is written up as **item 28** in
`PROGRESS.md`, in three parts, and **not started**. The placement asked for is
already the right one: a section of this profile window, closed until asked
for. A user object has well over a hundred populated attributes, so a
permanently expanded list is the definition of crowding the screen.

The note records what has to be settled first, including the part that
deserves a conversation rather than an implementation: writing to an arbitrary
attribute from a web form covers `userAccountControl`, `adminCount` and
`sIDHistory`, some of which are privilege escalation with a friendly UI in
front. That part needs an allow-list and a check-in before anyone starts.

Files: `web/app.js`, `web/app.css`, `server/lib/DsmtCommon.ps1` (version).
Copy `web/*` and hard-refresh; no server change beyond the version.

---

## 1.17.0 — 2026-08-06

**Tools -> AD health.** Settings -> Health asks whether DSMT can reach the
directory. This asks whether the directory itself is well.

### What it reports

**Replication**, one row per controller, **worst first** - the same view as
`repadmin /replsum`: partner count, worst consecutive-failure count, the most
recent successful inbound replication, and the delta since. Over three hours
with no success is a warning; any consecutive failure is a fault.

**FSMO roles** - all five, where each sits, **and whether that holder
answers**. Naming the holder is the easy half and the useless half: a role
pointing at a controller that was decommissioned without transferring it looks
correct in every list, and is the actual fault. Each holder is probed on LDAP.

**Domain controllers** - LDAP 389, LDAPS 636 and Global Catalog 3268, per
controller, plus clock drift. Three deliberate decisions:
- **A closed 636 is information, not a fault.** Plenty of healthy domains do
  not publish LDAPS, and failing on it would train people to ignore the page.
- **3268 is only expected on a controller that is a GC**, read from the
  directory rather than assumed. A GC advertising itself with 3268 closed
  breaks logons for reasons that look nothing like DNS - that one **is** a
  fault.
- **Clock drift comes from the controller's own RootDSE `currentTime`**, an
  ordinary LDAP read that takes `-Credential`. Warns at 2 minutes, fails at 5,
  because Kerberos rejects past 5 and the symptom never mentions time.

**Replication failures** - the list AD keeps itself, shown only when there is
one. Not inferred.

### Three rules the implementation follows

1. **It never shells out to `repadmin`.** Everybody knows `/replsum`, and its
   output is console text: localised, and reformatted between Windows
   versions. Parsing it is a bug waiting for a German server.
   `Get-ADReplicationPartnerMetadata` returns the same numbers as objects and
   takes `-Credential`. The **display** is laid out like replsum, because that
   is the view people know; the data never goes near a parser.
2. **Every check degrades to "could not check, and why."** These calls need
   rights the operator may not have, against controllers that may be down.
   Each controller is wrapped individually: one unreachable DC reports itself
   and leaves the rest of the report intact, and a check that cannot run is
   never reported as green.
3. **It never runs on page load.** Several remote calls per controller. There
   is an explicit **Run the checks** button, the result is kept when you
   switch away and back, and nothing it does changes anything - it is safe to
   repeat.

The overall verdict is the **worst individual result**, never an average.

Files: **new** `server/lib/DsmtAdHealth.ps1`; `server/Start-DSMT.ps1` (loads
it), `server/lib/DsmtHttp.ps1` (`GET /api/tools/adhealth`),
`server/lib/DsmtCommon.ps1` (version), `web/app.js`, `web/app.css`.
**Copy `server/**` including the new file and restart `Start-DSMT.ps1`**, then
copy `web/*` and hard-refresh.

Not runtime-verified: there is no PowerShell here. The parts most worth
watching on the first run are the `currentTime` parse (an LDAP generalized
time, parsed with `ParseExact` on the fixed 14 characters) and
`Get-ADReplicationPartnerMetadata` on a single-controller domain, which
correctly returns nothing and is reported as normal rather than as a fault.

---

## 1.16.0 — 2026-08-06

**A plain install now registers DSMT as a Windows service. The closable
window is gone as a default.**

Raised three times: *"someone can just close my window and the product stops
working."* 1.15.0 answered it with a warning, which was the wrong fix - a
default that needs a warning is a default that is wrong. So the default has
changed.

### What a plain install does now

    .\server\Install-DSMT.ps1 -StartWhenDone

Registers the Windows service **DSMT**, running as **LocalSystem**, starting
at boot, surviving sign-out, restarting itself on failure. No window to close.

- **LocalSystem, deliberately.** No password to store, nothing to expire, and
  nothing to re-enter when a service account is rotated. It costs nothing in
  attribution: in the default `operator` identity mode every directory read
  and write already runs as the **signed-in operator**, so the host identity
  never touches AD. The one place it shows is SQL, where the machine account
  needs rights - and the installer says so when it applies. Pass
  `-ServiceAccount` to use a named account or a gMSA instead.
- **`-InstallScheduledTask`** still registers a task instead.
- **`-NoAutoStart`** is the new opt-out, for a five-minute look at the
  console and nothing else. Its help text says exactly what it costs.
- **`-InstallAsService`** still works and now only states the default
  explicitly. Existing command lines are unaffected.

### The failure path is a fallback, not a shrug

If the service cannot be registered - the C# host will not compile, the
service manager refuses - the installer **falls back to a scheduled task**
rather than quietly leaving DSMT with no way to run. Only if that also fails
is it reported as an outstanding failure, in the words that matter: *DSMT is
not registered to run on its own; until one is, it stops when the window
running it closes.*

The summary now always states how DSMT will run once the installer's window
is gone - service, task, or not at all. That sentence did not exist before,
which is how this went unnoticed for twelve versions.

### Independent of SQL, still

Nothing here changes 1.13.0: **a database is not required.** The service runs,
the console works, every user and group is read live from the directory, and
the audit log is written to files. Add SQL whenever you want from
Settings -> Database, with no reinstall and no restart.

Files: `server/Install-DSMT.ps1`, `server/lib/DsmtCommon.ps1` (version),
`docs/deployment-guide.html`. Copy the installer to the host and re-run it -
it is safe to re-run, and it replaces any previous registration cleanly.

---

## 1.15.0 — 2026-08-06

### Sensitive-group filter on the Groups tab

Filter chips above the group list: **All**, **Privileged**, **AdminSDHolder**,
plus any filter your organisation defines. Every privileged group is also
marked on its own row, so it cannot be scrolled past unnoticed.

**Matched on SID, never on name.** `Domain Admins` can be renamed by any
administrator and is localised out of the box on a non-English installation -
so a filter that looks for the string finds nothing on precisely the domain
where finding it matters most. The RIDs are fixed by Windows and identical in
every domain: 512 Domain Admins, 516 Domain Controllers, 518 Schema Admins,
519 Enterprise Admins, 520 Group Policy Creator Owners, 521 RODCs, 526/527 Key
Admins, plus the built-in aliases at `S-1-5-32-*` (Administrators, Account /
Server / Print / Backup Operators, Replicator).

**`adminCount` is shown, not used to filter.** It marks objects protected by
AdminSDHolder, which is worth seeing - but it **lingers** on an account after
it is removed from a privileged group, so filtering on it would over-report,
and a security filter that over-reports is one that stops being read. It gets
its own chip and stays out of the Privileged decision.

**Custom filters, defined once for everyone.** Settings -> Group filters: a
name and a list of terms, matched against the group name, sAMAccountName,
description or OU. Stored in `config\dsmt.config.json` and served to every
browser - **not** in `localStorage`, because a filter one administrator
defines is one the whole team should see. Built-in filters are deliberately
not editable: they are facts about Active Directory, not configuration.

Two details that only matter when they are wrong:
- The **SQL snapshot is written from the unfiltered read**, so browsing a
  filtered view never truncates what the database believes the directory
  contains.
- A filter deleted while someone had it selected returns **everything**, not
  nothing. An empty screen reads as "there are none", which would be a lie.
- The result line says when a filter is narrowing the view, and out of how
  many groups - a filtered count that looks like a total is how someone
  concludes the domain has three groups.

### The installer stops leaving DSMT in a closable window without saying so

Raised twice: *"someone can just close my window and the product stops
working."* Correct - and `-InstallAsService` has existed since 1.4.0 while the
installer never once mentioned it.

- When DSMT is started as a plain process, the installer now says so in the
  step **and** in the summary: *that window IS the console; close it, or sign
  out of Windows, and DSMT stops for everyone, with no error anywhere* - and
  prints the one command that fixes it.
- The summary always states how DSMT will run once the window is gone:
  registered as a service, registered as a task, or **not registered at all**.

**`-WindowStyle Hidden` is still not offered, and will not be.** It hides the
window without changing anything that matters: the process still belongs to
that sign-in session, so it still dies at sign-out, and now nobody can tell it
is running or read its output when it fails.

### Ask before opening the browser

New `-OpenBrowser` and `-NoBrowser`. On an interactive run the installer asks
(default yes). It **never** asks when there is nobody to answer - a redirected
or non-interactive host skips the question rather than hanging a scripted
deployment forever - and it only offers at all when nothing is outstanding and
DSMT was actually started, because opening a browser at a port nothing is
listening on teaches the operator that the tool is broken.

Files: `server/Install-DSMT.ps1`, `server/lib/DsmtDirectory.ps1`,
`server/lib/DsmtHttp.ps1`, `server/lib/DsmtCommon.ps1` (version),
`web/index.html`, `web/app.css`, `web/app.js`,
`docs/deployment-guide.html`. **Copy `server/**` and restart
`Start-DSMT.ps1`**, then copy `web/*` and hard-refresh.

---

## 1.14.0 — 2026-08-06

### Fixed - Move OU could never have worked

Reported from the lab: moving a user reported
`Cannot find an object with identity: 'dv3' under: 'DC=LAB,DC=LOCAL'`, and
moving the account back by hand changed nothing - because the error was never
about where the object was.

**Not every AD cmdlet accepts the same kind of identity, and the split is not
obvious.** `Get-ADUser`, `Enable-ADAccount`, `Unlock-ADAccount`,
`Set-ADAccountPassword` and `Add-ADGroupMember -Members` all take a
sAMAccountName. The `*-ADObject` cmdlets **do not**: `Move-ADObject -Identity`
accepts a distinguishedName, a GUID or a SID, and nothing else.

DSMT holds a sAMAccountName - `dv3` - and handed it straight to
`Move-ADObject`. The resulting message reads exactly like a missing user and
sends the operator hunting for an account that is sitting in front of them.

- New `Resolve-DsmtObjectDn` turns whatever the console holds into a
  distinguishedName: passes a DN straight through, otherwise searches users,
  groups **and** computers by sAMAccountName, and throws a message naming the
  identity when there is no match or more than one.
- `Move-DsmtObject` resolves before calling `Move-ADObject`.
- `Get-DsmtObjectParent` (which records where a move came *from*, so the move
  can be undone) used the same wrong assumption and is now built on the same
  resolver. It was silently returning nothing, so **Move OU records written
  before this version cannot be undone** even though 1.11.0 said they could.
- `Remove-DsmtObject` already resolved to a DN before calling
  `Remove-ADObject`; checked, unchanged.

**Why the review missed it:** every call in `DsmtDirectory.ps1` looked
identical - `-Identity $Identity` - and only the cmdlet on the other side
differs. It cannot be found by reading for consistency, only by running it.
This is the first defect the lab session produced, and it argues for finishing
that session before building anything else.

### Audit log: two filters that answer the questions people actually ask

`System` and `Failed` join the filter chips, in front of the existing ones.

- **System** - what was done to **DSMT itself** rather than to the directory:
  sign in and out, the idle timeout, the listening port, the identity mode,
  the database, the KDS root key. They all carry the `session` category, which
  is what separates them from directory work.
- **Failed** - everything that did not succeed. Deliberately `Result <>
  'Success'` rather than `Result = 'Failed'`, so it also catches **Denied**
  (an AD permissions problem, not a DSMT one - the most useful thing on the
  screen when someone reports "it will not let me") and the **Partial** result
  a bulk action returns when some targets worked and others did not.

Both are implemented in the SQL reader and the JSONL reader, so the filter
means the same thing whether or not a database is configured.

Files: `server/lib/DsmtDirectory.ps1`, `server/lib/DsmtSql.ps1`,
`server/lib/DsmtAudit.ps1`, `server/lib/DsmtCommon.ps1` (version),
`web/app.js`. **Copy `server/lib/*.ps1` and restart `Start-DSMT.ps1`**, then
copy `web/app.js` and hard-refresh.

---

## 1.13.3 — 2026-08-06

**PowerShell files now ship with CRLF line endings.**

Every `.ps1` in this repository was written in a Linux container and so was
checked out, archived and downloaded with **LF-only** line endings. Windows
PowerShell mostly tolerates that - but "mostly" is not a property to rely on
for the file an operator runs first, and it is one of the few differences
between this repository and an ordinary Windows checkout.

`.gitattributes` now forces `eol=crlf` on `.ps1`, `.psm1`, `.psd1`, `.cmd`,
`.bat` and `.sql`, and keeps `eol=lf` on the web and documentation files,
which are read by browsers that do not care. Archives built with
`git archive` honour the same setting, so a downloaded zip now carries native
Windows files.

**Outcome of the "parameters do not work" report: not a DSMT fault.** The same
files ran correctly inside a VMware Workstation virtual machine, and failed on
the physical endpoint - so the block is endpoint policy on that workstation
(Mark-of-the-Web, AppLocker/WDAC, or an endpoint protection product), not the
script. Recorded as a Shape 2 entry in `CLAUDE.md`: on a repeat report, the
first question is which machine it ran on, not what is wrong with the code.

The file on the reporting machine had already been confirmed byte-identical to
the one shipped (64,580 bytes) and did contain the parameters. So neither
1.13.2 nor this release fixed the reported symptom - both are worth keeping
anyway: 1.13.2's echo is what will make the next such report a one-line
diagnosis, and CRLF removes a real difference between this repository and an
ordinary Windows checkout.

Files: **new** `.gitattributes`; `server/lib/DsmtCommon.ps1` (version).
Re-copy `server\**` to the host - the content is unchanged, only the line
endings.

---

## 1.13.2 — 2026-08-06

**Reported: "the parameters do not work at all."**

Only one code path in the installer can accept a parameter and then act as
though it were never given, and it is the one nobody looks at: **the elevation
relaunch**. Run unelevated, the script does no work itself - it re-launches
itself as administrator in a new window and forwards what you typed. If that
forwarding is wrong, the installer runs to completion and ignores everything,
which is exactly the reported symptom.

Two changes, one a fix and one so this is never a guess again:

**The relaunch now builds a single command-line string.** It was passing an
**array** to `Start-Process -ArgumentList` with `-Verb RunAs`. That hands the
list to ShellExecute, which re-quotes the elements itself, and the result is
not reliably what was intended - a value can arrive mangled, or the command
line can end early and drop every parameter after it. Building the string
here means what is sent is what was meant. Any double quote inside a value is
escaped first, for the same reason: one unescaped quote ends the command line
and silently discards the rest.

**The installer now prints what it received, and what it forwards.**
- The banner gains a `Parameters :` line listing every bound parameter, or
  `none given - every default applies, including no database`.
- Before relaunching it prints `Forwarding: powershell.exe ...`, the exact
  command line the elevated window will run.

That turns the report into a one-line diagnosis. Either the parameters are
listed in the elevated window's banner and the fault is elsewhere, or they are
not and the forwarding is at fault. Those are different faults with different
fixes, and until now there was no way to tell them apart from the outside.

**Worth knowing while diagnosing:** `-SkipSql` is the default since 1.13.0, so
passing it correctly changes nothing visible - that is not a broken parameter.
The one that turns SQL **on** is `-UseSql`.

**This is not confirmed as the reported fault.** It cannot be executed here -
there is no PowerShell in the development container - so it is the one real
defect found by reading the code on the only path that produces that symptom.
If the elevated banner now lists the parameters correctly and the behaviour is
still wrong, the cause is elsewhere and the banner will say so.

Files: `server/Install-DSMT.ps1`, `server/lib/DsmtCommon.ps1` (version).
Copy the installer to the host and re-run it.

---

## 1.13.1 — 2026-07-31

**`Install-DSMT.cmd` and `Start-DSMT.cmd` are removed.**

The question was fair: the documentation says to install with the `.ps1`
scripts, so why were there `.cmd` files as well? They were double-click
convenience wrappers, and by this version both were **actively wrong**:

- **`Install-DSMT.cmd` had drifted.** It carried its own copy of the whole
  parameter set as `set DSMT_*` variables — a second source of truth for
  something that already has one. It still spoke of `DSMT_SKIPSQL` and of
  leaving `DSMT_SQLSERVER` empty to auto-detect, neither of which is how
  1.13.0 behaves. It would have installed something other than what it said.
- **`Start-DSMT.cmd` was worse than stale: it silently overrode the saved
  configuration.** It always passed `-Domain`, `-Port` and `-ListenAddress`
  explicitly, and an explicit parameter beats `config\dsmt.config.json`. So
  double-clicking it could quietly contradict what the installer had just
  set up, on the port or even the domain, with nothing on screen to say so.

Neither bought anything real. `Install-DSMT.ps1` **already asks for elevation
itself**, so a plain PowerShell window is enough, and after the installer has
run `Start-DSMT.ps1` needs no parameters at all. Deleting them removes a
duplicate parameter list that could disagree with the real one — the same
single-source-of-truth rule this project applies to the version number.

The folder structure is now exactly what the documentation describes:

    C:\DSMT\
    +- server\        Install-DSMT.ps1, Start-DSMT.ps1, lib\
    +- web\           index.html, app.css, app.js
    +- _ds\           the Nocturne design system
    +- uploads\       images
    +- sql\           schema.sql, the schema standalone
    +- docs\          deployment-guide.html
    +- config\        created by the installer
    +- data\          created at startup: logs, file audit

Also corrected while in there: `DsmtGmsa.ps1` was missing from the file
listings in `README.md` and `CLAUDE.md`, and the guide still said `lib\` held
six files.

Files: **deleted** `Install-DSMT.cmd`, `Start-DSMT.cmd`;
`server/lib/DsmtCommon.ps1` (version), `README.md`, `CLAUDE.md`,
`PROGRESS.md`, `docs/deployment-guide.html`. Nothing to restart — but delete
the two `.cmd` files from any host they were copied to, so nobody
double-clicks the stale one.

---

## 1.13.0 — 2026-07-31

**SQL Server is now opt-in. A plain `.\Install-DSMT.ps1` installs no database
and that is a complete, working installation.**

The option to skip SQL already existed — as `-SkipSql`, a switch you could
only find by reading the script. That is not an option, it is a secret. And it
was the wrong way round: **SQL is the only step of the installation that
depends on a machine other than this one**, so making it the default turned a
ten-minute evaluation into a SQL support call. The last install failed on
exactly that step and nothing else.

What changed:

- **No SQL switch at all = no database**, reported as `[skip] Not configured -
  this is the default` rather than as a failure.
- **`-UseSql`** turns it on and finds a local instance, as before.
  **`-SqlServer <instance>` and `-SqlExpressSetup <path>` imply it**, so an
  existing command line that named an instance keeps working unchanged.
- **`-SkipSql` still works** and now only states the intent. Existing scripts
  and the deployment guide keep working. If both are given, `-SkipSql` wins.
- The step still reports a local instance it noticed, even while skipping —
  "there was already a database here" is exactly what someone re-running the
  installer needs to hear.

**Nothing is hidden by this.** Everything the console *displays* is read live
from the directory either way: users, groups, membership, OUs, controllers,
the signed-in operator. A database adds **history that survives a restart** —
stored operators, sessions, a directory snapshot, and an audit log that can be
queried rather than grepped. It does not add correctness. So the honest
default is off, said out loud in four places: the installer step, the closing
summary, the notification bell and Settings -> Database. And it can be turned
on at any time from the console with no reinstall.

Also updated so nothing contradicts the new default: `README.md`, and in
`docs/deployment-guide.html` the storage-options table, the parameter
reference (`-UseSql` added, `-SkipSql` marked as the default), and every
example that passed `-SkipSql` to get the short path.

Files: `server/Install-DSMT.ps1`, `server/lib/DsmtCommon.ps1` (version),
`README.md`, `docs/deployment-guide.html`, `CLAUDE.md`. Copy the installer to
the host and re-run it — it is safe to re-run.

---

## 1.12.1 — 2026-07-31

**Fixed - the installer announced `Found a local SQL instance: l` and then
failed to connect to a server called "l".**

`Get-LocalSqlInstances` ends with `return @($names)`. With exactly one SQL
instance installed, PowerShell **unrolls the single-element array on return**,
so the caller got the plain string `localhost` rather than a one-element
array. Both of the next two lines then lied convincingly:

- `$local.Count` on a string is **1**, so the "did we find anything" test
  passed.
- `$local[0]` on a string is its **first character**, so the instance name
  became `l`.

Which is why the error named a server nobody had ever configured. In a
console font `l` and `1` are near-identical, so the report read as
`instance: 1` - the message was right and unreadable at the same time.

Fixed in three places, because one is not enough for this class of bug:

1. The call site wraps the call: `$local = @(Get-LocalSqlInstances)`. This is
   the fix that matters, and the comment says the parentheses are
   load-bearing.
2. The function returns `,@($names)` - the comma operator stops the unroll at
   the source, for any future caller.
3. A new guard **refuses any instance name one character long** and says so,
   rather than passing it to SQL and letting the operator read a
   "server was not found" message that names nothing real.

**This is the same root cause as two bugs already in `CLAUDE.md`**: the
`HostName` returned as a collection by `-Discover`, and `ConvertTo-Json`
collapsing a one-element array into a bare object. Single-element collections
are the recurring defect in this codebase. The rule is now written down in
`CLAUDE.md` rather than rediscovered each time: **any function returning a
list must be called inside `@( )`, and should return `,@( )`.**

Files: `server/Install-DSMT.ps1`, `server/lib/DsmtCommon.ps1` (version),
`CLAUDE.md`, `PROGRESS.md`. Copy the installer to the host and **re-run it**
- it is safe to re-run, and every step re-checks the current state.

---

## 1.12.0 — 2026-07-31

**A Tools tab, and the first tool: gMSA.**

### The tab

`Tools` sits between `Audit log` and `Settings`, laid out exactly like
Settings — a rail of tools on the left, one open at a time. The split is
deliberate: **Settings is "how this server is configured", Tools is "things I
do to the directory."** Mixing them would make both harder to read. The rail
is data (`TOOLS` in `app.js`), so the next tool is one entry plus a render
function.

### gMSA — five steps, and an honest split between them

| # | Step | Who does it |
| --- | --- | --- |
| 1 | KDS root key (once per forest) | DSMT, *in-process* — see below |
| 2 | Group of permitted computers | DSMT, as **you** |
| 3 | Computers in that group | DSMT, as **you** |
| 4 | The gMSA itself | DSMT, as **you** |
| 5 | Install it on the host | **You**, elevated — cannot run here |

**Requirements are stated before any button**, not discovered by failure:
domain functional level 2012+, a KDS root key, the ten-hour convergence wait,
the specific rights each step needs, and Windows Server 2012+ on any machine
that will use the account.

**Enabling gMSAs for an organisation that never used them** is step 1, and it
is guarded by **two confirmations that say different things** — one that this
changes the *forest* and that nothing works for ten hours afterwards, one that
the operator is authorised to make a forest-level change. Two different
statements rather than "are you sure" twice, so ticking both is a second
thought and not a reflex. **Both are re-checked on the server**, not only in
the browser, and a reason is mandatory. A forest that already has a key is
refused with an explanation rather than given a second one.

**An attribution gap, recorded rather than hidden.** `Add-KdsRootKey` accepts
neither `-Credential` nor `-Server`: it acts on the forest of the machine it
runs on, as whoever runs it. So this one action runs as the account the DSMT
*server* runs as, never as the operator. The screen says so plainly, the audit
record names the operator as initiator and the service account as executor,
and the equivalent command is always shown for running on a DC instead. Where
the `Kds` module is absent locally, the button is disabled and only the
command is offered.

**The ten-hour wait is treated as a first-class state**, not an error. The key
is read from the forest configuration partition (`msKds-ProvRootKey`), its
effective time is compared against now, and a key that exists but has not
converged reports *Waiting*, with the hours remaining and an explicit "this is
not a fault". Creating a gMSA before then is refused with that same
explanation, instead of AD's `Key does not exist`.

**A lab shortcut, labelled as one.** Backdating the effective time makes the
key usable immediately; the checkbox says *lab only* and explains why, and the
audit record says the time was backdated.

**Computers are resolved before anything changes.** `DSMT01`, `DSMT01$` and
`dsmt01.lab.local` are all accepted; every name is looked up first, and if any
one fails to resolve **nothing is changed** and the message names it. A typo
that silently adds nothing is exactly how a correct-looking gMSA ends up
refusing to install on the one host that was missed. The screen also says what
no error message ever will: **a computer does not see a new group membership
until it reboots.**

**Everything is read live.** No step remembers what was clicked. State comes
from the directory on every render, because a wizard showing a green tick
because a button was pressed last week is the fake-data failure in `CLAUDE.md`
wearing a different hat — and here it would send someone away believing a gMSA
works when it does not.

### Also

The clipboard helper was duplicated (Settings had its own with a different
fallback). There is now one `copyText()` for the whole console. Note the
non-obvious part: `navigator.clipboard` needs a secure context, which
`http://host:8080` is not, so the textarea fallback is the path that actually
runs on most installations — not legacy cruft.

Files: **new** `server/lib/DsmtGmsa.ps1`; `server/Start-DSMT.ps1` (loads it),
`server/lib/DsmtHttp.ps1` (five `/api/tools/gmsa/*` routes),
`server/lib/DsmtCommon.ps1` (version), `web/index.html`, `web/app.css`,
`web/app.js`. **Copy `server/lib/*.ps1` including the new file, and restart
`Start-DSMT.ps1`**, then copy `web/*` and hard-refresh.

---

## 1.11.0 — 2026-07-31

Two features: **undo**, and a **health check**.

### Undo, from the audit entry

Every audit row that can be reversed now carries an **Undo** button; every row
that cannot carries a dash whose tooltip says why.

Reversible, using nothing but the record itself:

| Original | Undo |
| --- | --- |
| Disable user | Enable user |
| Enable user | Disable user |
| Add to group | Remove from that group |
| Remove from group | Add back to that group |
| Move OU | Move back to the source OU |

Refused **on purpose**, each with its reason shown:

- **Reset password / Unlock account** — DSMT never knew the previous password,
  and a lockout comes from failed sign-ins, not from an administrator. There
  is no previous state to restore.
- **Create / Delete, and CSV import** — a recreated object gets a **new SID**,
  so every ACL, membership and profile that referenced the old one is still
  broken. An "undo" that produces a same-named stranger is a lie. Use the AD
  Recycle Bin.
- **Anything that failed** — a Failed or Denied record changed nothing.

Three properties that matter more than the feature:

1. **The original entry is never touched.** The undo is a new audit record
   (`Undo: Disable user`) with its own operator, its own timestamp and its own
   **mandatory reason**. The log is append-only and stays that way.
2. **It runs as the signed-in operator**, exactly like the button that would
   make the same change by hand — so it can never do anything that operator is
   not already permitted to do, and the DC records their name against it.
3. **The server decides, not the browser.** `Get-DsmtUndoPlan` recomputes the
   plan and refuses anything not on its own list. The copy in `app.js` only
   decides whether to paint a button.

**Move OU became undoable, which needed a change to what is recorded.** The
audit detail said only `into <OU>`; the source was never captured, and after
the move it is gone. `Invoke-DsmtBulkAction` gained `-DetailBuilder`, a
scriptblock evaluated per target *before* the operation, and the move now
records `from <A> into <B>`. A failure in the builder can never block the
action. **Moves recorded before this version cannot be undone**, and the
console says so rather than guessing at a container.

### Health check

**Settings -> Health**, first in the rail. One request, run live on demand:

- **ActiveDirectory module** — is RSAT actually loaded.
- **Domain** — which controller answered, and how many exist.
- **Directory read** — a real search as the signed-in operator. Reaching the
  domain and being *allowed* to read it are different things.
- **SQL Server** — the instance, the database and the audit row count; or the
  verbatim error; or a warning that none is configured.
- **Data folder** — actually written to and deleted again. The JSONL audit
  fallback lives there, and an unwritable folder loses records silently.
- **Last successful write** — the newest non-session Success in the log.
- **Uptime** — how long this process has been up. See the 72-hour scheduled
  task default in `CLAUDE.md` for why that is not a theoretical question.
- **Open sessions** — how many, and the idle window.

Every check that is not green carries a **Fix** line with the actual command
or the actual menu path. A red light with no instruction moves the problem
rather than helping with it — and most "the server won't start" reports in
this project were a known external step nobody had done yet. The overall
verdict is the **worst** individual result: a page that averages its checks
into a comfortable green is worse than no page.

Colour is never the only signal — every check also carries a word (OK /
Attention / Failing).

Files: `server/lib/DsmtHttp.ps1` (undo plan, undo route, health, the detail
builder), `server/lib/DsmtDirectory.ps1` (`Get-DsmtObjectParent`),
`server/lib/DsmtSession.ps1` (`Get-DsmtSessionSummary`),
`server/lib/DsmtCommon.ps1` (version, `StartedUtc`), `web/index.html`,
`web/app.css`, `web/app.js`. **Copy `server/lib/*.ps1` and restart
`Start-DSMT.ps1`**, then copy `web/*` and hard-refresh.

---

## 1.10.0 — 2026-07-31

**Refresh on the Audit log.**

The audit log is the one table in the console written by *everyone*. Every
other grid shows what this operator asked for; this one goes out of date the
moment a second operator acts, and until now the only way to see their entry
was to change a filter and change it back, or reload the page — which on a
tab that costs a round trip to AD is a poor way to ask a small question.

- **Refresh** sits in the Audit log toolbar, before the search box, and
  reloads with the range, filter and search term already in force.
- Beside it, **Updated HH:MM:SS** — how stale what you are reading is. It is
  clock time, not "5 minutes ago": a relative label needs a timer to stay
  honest, and a stale one on an audit screen is worse than none at all.
- The button is its own progress indicator (*Refreshing...*, disabled while
  in flight). There is no spinner anywhere else in this console, and a button
  that does nothing visible when pressed reads as a broken button — which is
  exactly the report that came back about Export in 1.7.5.
- Narrow screens put the search box on its own line and let Refresh and
  Export share the next one; the stamp stays, because staleness matters most
  where you cannot see the whole table at once.

Files: `web/index.html`, `web/app.css`, `web/app.js`,
`server/lib/DsmtCommon.ps1` (version). Copy `web/*` and hard-refresh. No
server change — `GET /api/audit` already took every parameter this needs.

---

## 1.9.2 — 2026-07-31

**Says what it is connected to, and explains a 404 on a new route.**

- The **Database** section opens with a connection panel: a Connected /
  Not connected marker and four fields — SQL Server instance, Database,
  where the audit log goes, and whether operators, sessions and the snapshot
  are stored. It was a sentence before; on a screen with two name-shaped
  inputs, what is *live* has to be readable without comparing it to what is
  typed in the boxes underneath.
- The rail entry for Database now carries `server / database` as its hint,
  so the current target is visible without opening the section.
- `No API route for POST /api/settings/sql/databases` now adds what it
  means: the web files were copied but the server was not restarted, so a new
  front end is talking to an old back end. The raw 404 read like a broken
  feature. **This is not a code fix — the route has existed since 1.8.1 —
  it is a fix for the message.**

Files: `web/app.js`, `web/app.css`, `server/lib/DsmtCommon.ps1` (version).
Copy `web/*` and hard-refresh. Note that `server/lib/*.ps1` from 1.8.1 must
be on the host and the server restarted before *List existing databases*,
the custom port or the idle timeout will work at all.

---

## 1.9.1 — 2026-07-31

**The arrangement switch is removed. One section at a time is the layout.**

1.9.0 offered three arrangements because there seemed to be no single right
one. There was: the rail. *Single column* and *Columns* were both variations
on scrolling past five sections you did not come for, and a setting whose
only real answer is "the default" is not a setting, it is a decision that was
not made. Made now.

- The segmented control in the Settings header is gone, and with it the
  `.seg` / `.seg-btn` styles and the `dsmt.settings.layout` key.
- The rail is always there; which section was open is still remembered per
  browser in `dsmt.settings.section`.
- Cards are still hidden rather than removed, so handlers survive a switch,
  and below 900px the rail is still a scrolling row of chips.

Files: `web/index.html`, `web/app.css`, `web/app.js`,
`server/lib/DsmtCommon.ps1` (version). Copy `web/*` and hard-refresh.

---

## 1.9.0 — 2026-07-31

**Settings is rearranged, and the arrangement is the operator's choice.**

1.8.1 put the settings cards into a two- or three-column grid. That fixed the
narrow-strip problem but produced a new one: six cards of unequal height in a
grid have ragged bottoms, no reading order, and a form whose fields sit in a
different column from the button that submits them. Density is not the same
thing as order.

What it is now:

- **A section rail.** The six sections — System, Network, Database, Identity,
  Service account, Sessions — are listed down the left with a one-line hint
  each, and one section is shown at a time. The current one is marked with an
  accent edge, not a filled block.
- **Three arrangements, chosen in the header.** *One section* (the default,
  the rail), *Single column* (everything, top to bottom, at a readable
  measure), *Columns* (two from 1100px, three from 1700px — 1.8.1's layout,
  kept for anyone who prefers it). The choice and the open section are
  remembered per browser in `localStorage`.
- **Cards are hidden, never removed.** Switching sections toggles `hidden` on
  elements that stay in the DOM, so every handler wired by `wireSettings()`
  stays attached — no re-wiring, and no dead buttons after a switch.
- **On a phone** the rail becomes a horizontally scrolling row of section
  chips above the card, so it never takes half the screen. Below 900px the
  hints are dropped and the accent edge moves from the left to the bottom.

There is no single correct arrangement for a screen that is used on a 360px
phone and a 34" monitor, which is why this is a setting and not a decision.

Files: `web/index.html`, `web/app.css`, `web/app.js`,
`server/lib/DsmtCommon.ps1` (version). Copy `web/*` and hard-refresh
(Ctrl+F5); restart the server only so the About dialog reports 1.9.0.

---

## 1.8.1 — 2026-07-31
Fixes the idle-timeout error, and finishes the Settings screen.

**Fixed - saving an idle timeout returned 500.**
`Cannot convert value " -> " to type "System.Int32"`. The audit line built its
target as `$previous + ' -> ' + $minutes`, and `$previous` is an **int** - so
PowerShell tried to parse the string `' -> '` as a number. Cast to `[string]`
first. The two other `' -> '` audit targets are string-plus-string and were
never affected; checked.

**Choose an existing database** (`DsmtSql.ps1`, `DsmtHttp.ps1`, `web/*`):
- **List existing databases** on the instance and pick one, for upgrading an
  installation that already has a DSMT database under any name. DSMT then adds
  only the tables that are missing and leaves the data alone.
- `POST /api/settings/sql/databases` lists the online user databases.

**Confirmation before a database is created**:
- `Initialize-DsmtSql` takes `-CreateIfMissing`. From the console it is
  **false**, so a missing database comes back as `needsCreate` and the screen
  asks first - a typo in an instance name should not silently leave a stray
  database on a production server. The installer and the server still create
  on sight, which is what they are for.
- The result now says which of three things happened: created the database,
  used an existing one and added N missing tables, or used an existing one
  that was already complete. That distinction is the whole point when
  upgrading.

**Custom port** - a Network section sets the listening port, saved to
`config\dsmt.config.json`. It states plainly that a listener cannot move port
while running, so it applies on the next start, and prints the matching
`netsh http add urlacl` and firewall commands, since a new port needs both.

**Layout** - the Settings screen was a narrow strip down the left of a wide
monitor. It is now a grid: one column under 1000px, two above, three above
1600px, capped at 1500px so no card stretches past a readable measure.

**Also** - the menu no longer appends the controller count to the domain name.

Deploy: `web\*` — hard refresh. `server\**` — restart.

## 1.8.0 — 2026-07-31
Settings becomes a screen, and it is now the place to diagnose SQL.

**Settings is a tab, not a dialog** (`web/*`):
- It sits alongside Users, Groups and Audit log, and renders inline. Nothing
  in it depends on an overlay being able to display - which matters, because
  1.7.5 was an incident where no overlay displayed and the settings screen was
  therefore unreachable exactly when it was needed.
- Five sections: **System** (version, publisher, domain, controller, listen
  address, result cap, data folder), **Database**, **Identity**, **Service
  account**, **Sessions**.
- Every action reports **inline, next to the control that produced it**, not
  in a toast.

**Database section** — the fastest way to find out why SQL is not recording
anything. Enter the instance, press Connect, and the **exact error SQL Server
returned is shown verbatim** rather than being reduced to "it failed". On
success the database and tables are created and the setting persisted.

**Service account section** — pick gMSA, a dedicated account or LocalSystem,
type the name, and DSMT builds the exact `-ChangeServiceAccount` command, with
a Copy button and a per-type hint (a gMSA gets its trailing `$` added for you).

It builds the command rather than running it, and says why: changing the
account rewrites the service or scheduled task, the URL reservation, the data
folder permissions and the SQL login, which need administrator rights on the
host that this process deliberately does not have. A button that pretended
otherwise would fail halfway and leave the installation in a worse state than
it started.

**Also**: the Settings entry moved out of the menu into the tab strip; the
identity-mode warning and the idle-timeout controls moved into the new screen;
the deployment guide updated to match.

Deploy: `web\*` — hard refresh (Ctrl+F5). No server restart needed.

## 1.7.5 — 2026-07-31
**Fixes the first-run blocker: no overlay in the console was visible.**

Reported from the first real install on `LAB.LOCAL`: dialogs never appeared,
so About, New user, Import CSV, Columns and every detail-pane action - Reset
password, Unlock, Disable, Move OU, Add to group, Delete - all did nothing.
Toasts never appeared, so Export gave no feedback. The notifications panel
opened off the right edge of the screen.

**It was not JavaScript.** The browser console was clean and every request
returned 200 - including `/api/ous`, which is fetched only from inside the
Move OU / New user / New group / Import handlers. So the listeners fired, the
actions ran, the fetches succeeded and the markup was built. What failed was
making it visible.

**Cause**: all three overlays positioned themselves with logical inset
properties, and on the browser in use those were ignored - leaving each
element at its static position:

| Overlay | Was | Result |
| --- | --- | --- |
| Dialog | `inset: 0` (from the design system) | Collapsed to content size at the foot of the page, clipped by `body { overflow: hidden }` |
| Toasts | `inset-block-end` + `inset-inline-end` | Landed below the fold, clipped the same way |
| Bell panel | `inset-inline-end: 0` | Spilled to the right, off-screen |

One cause, all three symptoms, and no error anywhere - which is why it read as
"nothing works".

**Fix** (`web/app.css`, rewritten):
- Every overlay now uses physical offsets - `top` / `right` / `bottom` /
  `left`. `.dialog-backdrop` is restated in full over the design system's
  version, since that is where `inset: 0` came from.
- `color-mix()` replaced with `rgba()` throughout, including a redefinition of
  `--color-divider`, which the design system builds with `color-mix()` - where
  unsupported the variable is invalid and every border drawn from it silently
  disappears.
- `min()` replaced with `width` + `max-width`; `.dialog` gets an explicit
  width because the design system sizes it with `min()`.
- `100dvh` moved into an `@supports` block as progressive enhancement; the
  base layout uses `vh`.
- Logical padding/margin replaced with physical. The console is LTR-only by
  decision, so they bought nothing and cost a class of failure that produces
  no error message.
- The rules for what may and may not be used are written at the top of the
  file, with this incident as the reason.
- `docs/deployment-guide.html` given the same treatment.

Deploy: **`web\app.css` and `docs\deployment-guide.html`. Hard refresh
(Ctrl+F5) - the old stylesheet will otherwise be served from cache.** No
server restart needed.

## 1.7.4 — 2026-07-31
`docs/deployment-guide.html` - the contents sidebar collapses instead of the
document.

- **1.7.3 collapsed the wrong thing.** It made the body sections collapsible;
  what was wanted was the contents list on the left. The body is back to a
  normally flowing document, and the sidebar is now what folds.
- Each contents entry that has sub-sections gets its own disclosure control,
  and **all of them start collapsed** - the sidebar opens as twelve top-level
  entries instead of thirty.
- **The chevron toggles, the link navigates.** They are separate targets, so
  one click never does two things - the usual complaint with this pattern.
- The group containing the section you are reading **opens itself** and is
  marked in the accent colour, so a collapsed sidebar still shows where you
  are. Driven by the URL fragment, so it works from a contents click, a
  cross-reference, or a pasted link.
- Printing expands the whole contents list first.
- Keyboard and screen readers: `aria-expanded` and `aria-controls` on every
  toggle, and a visible focus ring.

Deploy: replace `docs\deployment-guide.html`. Documentation only.

## 1.7.3 — 2026-07-31
`docs/deployment-guide.html` - every section now collapses.

- All 17 top-level sections are native `<details>`, and **only the first is
  open**. The guide opens as a one-screen index of itself rather than 88KB of
  prose, on a desktop as much as on a phone.
- **Expand all / Collapse all** at the top.
- Following a link into a collapsed section opens it - otherwise the anchor
  would land on a closed heading and the guide would look broken. Works from
  the contents list, from a cross-reference, and from a pasted URL with a
  fragment.
- On a phone, tapping a contents entry closes the contents behind you.
- Printing opens everything first and restores your state afterwards, via
  `beforeprint`/`afterprint` plus a `matchMedia('print')` listener for Safari,
  with a print stylesheet as a fallback. A printed guide of bare headings
  would be worse than no printing at all.
- Collapsing and expanding still work with **scripting disabled** - that is
  native `<details>` behaviour. The script only adds the three things that
  would otherwise be annoying.

Deploy: replace `docs\deployment-guide.html`. Documentation only.

## 1.7.2 — 2026-07-31
- `CHANGELOG.md` — added a **"Version history at a glance"** table: one row
  per release with the date, a one-line summary and what deploying it takes.
  It is an index into the entries below it, not a second record — a separate
  version-history file would have been a second source of truth to keep in
  step, which is the failure mode the versioning rule exists to prevent.
- `CLAUDE.md` — records that a release adds both the row and the entry, and
  that the row must never carry a detail the entry does not.

Deploy: documentation only, no runtime impact.

## 1.7.1 — 2026-07-30
`docs/deployment-guide.html` made usable on a phone — Safari on iOS, and any
Chromium browser on Android or iOS.

- **Tables reflow into stacked cards below 640px.** Every data cell carries
  its column name in `data-label`, added to all 17 multi-column tables, so a
  narrow screen loses no information. Hiding columns would have been easier
  and would have hidden exactly the prerequisites people miss.
- **The contents list collapses on a phone**, so the document starts at the
  top of the screen instead of below a full-page index. Four lines of inline
  script, no requests; with scripting off it simply stays open.
- **iOS specifics**: `-webkit-text-size-adjust: 100%` stops Safari inflating
  text on rotation to landscape; `env(safe-area-inset-*)` keeps content clear
  of the notch and the home indicator; `-webkit-overflow-scrolling: touch` on
  scrollable blocks.
- **Nothing scrolls the page sideways.** Code blocks scroll inside themselves
  and keep their lines unwrapped so commands stay copy-pasteable; inline code
  wraps instead of widening the page.
- Deliberately **not** `overflow-x: hidden` on `body`, which is the usual
  quick fix and breaks `position: sticky` for the desktop sidebar in both
  Safari and Chromium. The real cause is a grid item refusing to shrink below
  its content, so `min-width: 0` fixes it without side effects.
- Larger tap targets in the contents under `@media (pointer: coarse)`, and a
  second type scale at 640px.

Deploy: replace `docs\deployment-guide.html`. Documentation only, no runtime
impact.

## 1.7.0 — 2026-07-30
Idle timeout defaults tightened.

- **Default is now 15 minutes** (was 480). An idle console showing directory
  objects and holding an operator's credentials should not sit unattended for
  a working day.
- **Maximum is 480 minutes (8 hours)**, down from 10080. A session that can
  outlive a working day is not an idle control, it is a formality.
- The default, minimum and maximum are **three constants in
  `DsmtCommon.ps1`**, enforced on every route that can set the value — the
  `-SessionMinutes` parameter, `config\dsmt.config.json`, and
  `POST /api/settings/session` — and served to the browser through
  `/api/meta` and `/api/settings` as `sessionBounds`, so the Settings form
  validates against exactly the numbers the server enforces instead of
  keeping its own copy.
- Out-of-range values from a parameter or a config file are **clamped, not
  rejected**: a stale config must not stop the server from starting. The
  runtime API still rejects them with a 400, because there a human is
  watching and silently changing their number would be worse.
- `-SessionHours` no longer carries a default of its own, so it cannot
  quietly override the new default when omitted.
- Settings presets relabelled: 15 minutes is marked as the default, 8 hours
  as the maximum.

**Upgrading**: an existing `config\dsmt.config.json` keeps whatever it
already has — an explicit setting still wins. Only fresh installs, and
installations that never set a value, pick up 15 minutes. Anything above 480
in an old file is clamped to 480 on the next start.

Deploy: `web\*` — hard refresh. `server\**` — restart.

## 1.6.0 — 2026-07-30
Idle timeout, and a deployment guide that covers every installation form.

**Deployment guide** (`docs/deployment-guide.html`):
- New section **"Every installation form, at a glance"** — the four
  independent choices an installation is made of (how it stays running, which
  account, where records are stored, which identity acts), each as a table of
  the concrete forms with the switch that selects it and what it needs. They
  combine freely, and five worked examples show the common combinations.
- New **1.4 "What each choice additionally requires"** — a matrix of every
  optional choice against its one-time prerequisite and who provides it.
  These are exactly the steps that, when skipped, resurface later as failures
  that look like bugs: the KDS root key and its 10-hour propagation, the
  `dbcreator` right, FOD media for an offline client, the batch-logon right.
- Subsection numbering repaired: the incremental additions had produced
  4.1a/4.1b/4.1c and 8.3a. Now 4.1–4.6 and 8.1–8.7, with stable anchors, and
  every cross-reference updated to match.
- Table of contents rebuilt to include the subsections that had accumulated
  without ever being listed.
- States explicitly that none of the choices is a one-way door: account,
  database, identity mode, idle timeout and hosting form can all be changed
  afterwards.

Verified: no broken internal links, no external references, no Hebrew left.

**Server** (`DsmtCommon.ps1`, `DsmtSession.ps1`, `DsmtHttp.ps1`,
`Start-DSMT.ps1`):
- The timeout is now held in **minutes, in one field** (`SessionMinutes`,
  default 480). `-SessionHours` still works and is converted at startup rather
  than stored alongside — two fields meaning the same thing is how they end up
  disagreeing.
- `-SessionMinutes` on `Start-DSMT.ps1`, saved in `config\dsmt.config.json`.
- `POST /api/settings/session` changes it at runtime, audited, persisted, and
  **applied to sessions that are already open** — the check is made against
  the current value on every request, not captured when the session started.
  Accepted range 1 minute to 7 days; anything else is a 400.
- `/api/meta` and `GET /api/session` return the value so the browser can run
  its own countdown.
- The startup banner states the timeout.

**Front end** (`web/app.js`):
- A real idle watch. **Only genuine interaction counts** — mousedown, keydown,
  touch, wheel, focus. Background work deliberately does not reset the clock,
  or a console left open on a dashboard would keep its session alive forever
  and the timeout would mean nothing.
- One minute before expiry a dialog appears with a live countdown, "Stay
  signed in" and "Sign out now". Any real activity dismisses it and tells the
  server, so both clocks agree.
- On expiry the session is ended server-side too, and the sign-in screen says
  why rather than just appearing.
- The server remains the enforcement — nothing the browser does extends a
  session. The timer only exists so an operator is warned instead of
  discovering it as a failed action mid-task.

**Settings** — the timeout is editable, with presets from 5 minutes to 8
hours. Changing it restarts the local countdown immediately.

Deploy: `web\*` — hard refresh. `server\**` — restart.

## 1.5.0 — 2026-07-30
Flexible service identity: gMSA, dedicated account, machine account or the
installing user — changeable at any time. Plus an identity mode that lets
directory reads run as the service account while writes stay on the operator.

**Identity mode** (`server/lib/DsmtDirectory.ps1`, `DsmtCommon.ps1`,
`DsmtHttp.ps1`, `Start-DSMT.ps1`, `web/*`):
- `Get-DsmtAdParams` now takes `-Intent 'read'|'write'` and is **the single
  place** that decides which identity performs an operation. All 16 call
  sites declare their intent.
- `operator` (default) — reads and writes both run as the signed-in operator.
  Byte-for-byte the 1.4.x behaviour; an existing installation notices nothing.
- `hybrid` — reads run as the account the server runs under, writes still run
  as the operator. **Writes deliberately stay on the operator in both modes**,
  because that is what makes the DC's own security log name the human who
  made the change. Nothing can forge that afterwards.
- "Runs as the service account" is implemented as *not passing* `-Credential`
  — the process already runs as that account. That is precisely why a gMSA or
  machine account works: there is no password to hand over.
- `-Intent` defaults to `write`, so a call site that forgets to declare itself
  keeps operator credentials rather than silently gaining service-account
  rights.
- Settable with `-IdentityMode`, in `config\dsmt.config.json`, or from
  **Settings** at runtime (`POST /api/settings/identity`, audited).
- The hybrid consequence — every operator can see everything the service
  account can see — is stated in the Settings dialog next to the control, in
  the startup banner, and as a notification. Not buried in documentation.

**Service accounts** (`server/Install-DSMT.ps1`):
- `-ServiceAccount` now accepts four forms, classified automatically:
  the installing user (default), a dedicated account, a **gMSA** (detected by
  the trailing `$`, no password requested), or **LocalSystem**.
- Pre-flight per kind: a gMSA is verified with `Test-ADServiceAccount` before
  anything is registered against it; an ordinary account is checked for
  `PasswordNeverExpires` and for membership of Domain/Enterprise/Schema
  Admins, both of which produce a loud warning rather than a silent surprise.
- gMSA registration uses `sc.exe config obj= "DOM\name$" password= ""` after
  `New-Service`, because `New-Service` cannot express a passwordless managed
  account. Scheduled tasks use `New-ScheduledTaskPrincipal`.
- The default remains the installing user: it is the only choice that cannot
  fail, since the installer has just proved that account reaches AD and SQL.
  It requires one password prompt — Windows cannot log on as an account at
  boot without storing its password.

**`-ChangeServiceAccount`** — move an installation to a different account
without reinstalling. Updates all five things that depend on the identity as
one operation: the service or scheduled task, **the URL reservation** (the one
that otherwise breaks listening much later, with a misleading error), the
`data\` permissions, the SQL login (printed as a script, since the installer
may not hold rights on the instance), and the saved settings. The target
account is verified and its password collected before anything is touched, so
a failure leaves the installation as it was.

**Publisher** — `$script:DsmtPublisher` in `DsmtCommon.ps1`, one constant like
the version, surfaced through `/api/meta` into the sign-in footer and the
About dialog. Set to **Rendi Group**.

**Notifications** — two new, both derived from real state: running under a
personal account (with the exact `-ChangeServiceAccount` command), and hybrid
mode being active.

Deploy: `web\*` — hard refresh. `server\**` — restart. Re-run the installer
only if you want to change the account.

## 1.4.0 — 2026-07-30
Run DSMT unattended: as a real Windows service, or as a hardened scheduled
task, and start it straight from the installer.

**New** — `server/Install-DSMT.ps1`:
- `-InstallAsService` registers DSMT as a Windows service, so it answers
  `Get-Service` / `Start-Service` / `Restart-Service` and the service
  manager's recovery settings. PowerShell cannot be a service directly — the
  SCM kills any process that does not answer its protocol — so the installer
  compiles a small C# host (`server\DsmtService.exe`) with the `csc.exe` that
  ships with the .NET Framework and runs `Start-DSMT.ps1` as its child.
  **Nothing is downloaded.** If the console dies, the host exits non-zero so
  the SCM restarts it instead of leaving a service that claims to be running
  with nothing behind it. Recovery is configured to 5s / 10s / every 30s.
  With `-ServiceAccount` the installer prompts for the password (the SCM has
  to store it); without it the service runs as LocalSystem and reaches AD and
  SQL as the computer account, which the installer says out loud.
- `-StartWhenDone` starts DSMT as soon as the install finishes — the service,
  the task, or a background window, whichever was set up — and verifies it
  actually came up rather than assuming it did.
- Re-registering is clean: an existing service is stopped and deleted first.

**Changed**:
- The scheduled task is now configured for a process that must stay up:
  **no execution time limit** (the default stopped it after 72 hours),
  restart on failure (3 attempts a minute apart), start when available, and
  no dependency on mains power. Previously it had Windows' defaults.
- `server/Start-DSMT.ps1` — every preflight failure is now written to
  `data\dsmt-*.log` as well as the console. Under a service or task there is
  no console, and a start that failed silently was undiagnosable.
- `Install-DSMT.cmd` — `DSMT_SERVICE`, `DSMT_AUTOSTART` and `DSMT_STARTNOW`
  settings at the top.
- `docs/deployment-guide.html` — step 11 rewritten: how to choose between the
  two, why the compiled host exists, what the installer configures that a
  hand-made task usually misses, and where to look when a headless start
  fails.

Deploy: `server\Install-DSMT.ps1`, `server\Start-DSMT.ps1`, `Install-DSMT.cmd`.
Re-run the installer with the switch you want; restart `Start-DSMT.ps1`.

## 1.3.0 — 2026-07-30
Audit time filtering, a Settings screen that can create the database, and a
notifications bell.

**Audit log - filter by date** (`web/*`, `server/lib/DsmtAudit.ps1`,
`server/lib/DsmtSql.ps1`, `server/lib/DsmtHttp.ps1`):
- New range chips above the audit table: Last 24 hours, Last 48 hours, Last 7
  days, Last 30 days, All time, and Custom range with two date/time pickers.
- `GET /api/audit` accepts `from` and `to` (ISO 8601, both optional and
  independent). A value that is present but unparseable is a 400, not a
  silently ignored filter.
- **The window is applied inside the SQL query**, not after the rows come
  back — otherwise `TOP (@limit)` would take the newest 500 rows overall and
  then filter them down, silently under-reporting an older window.
- The JSONL fallback path widens its file scan to reach the requested start
  date, so a custom window older than six months is not reported as empty
  when it simply was not searched.
- The line under the table now names the window it counted, and says whether
  the records came from SQL Server or from files.

**Settings** (`web/*`, `server/lib/DsmtHttp.ps1`, `server/lib/DsmtCommon.ps1`):
- New **Settings** entry in the menu. Shows what the server is actually
  running with (version, domain, DC, listen address, session lifetime, result
  cap, data folder) and the current storage state.
- From there an operator can point DSMT at a SQL Server and **create the DSMT
  database and its tables without restarting**. `POST /api/settings/sql` runs
  the same schema code the server uses, saves the setting to
  `config/dsmt.config.json` so it survives a restart, audits the change, and
  backfills the current operator and session into the new database.
- `GET /api/settings` returns the running configuration.
- `Save-DsmtSavedSettings` merges over the existing config file rather than
  overwriting it.

**Notifications** (`web/*`):
- The avatar circle in the header is replaced by a notifications bell with a
  count badge and a panel.
- Every notification is derived from real server state — there are no seeded
  or sample notifications. Currently raised: no SQL database configured (with
  a **Create database** button that opens Settings), SQL reporting an error,
  and the directory search hitting its result cap.

**Changed**:
- The header now shows the auto-detected domain name only; the controller
  count moved to the menu and **About**, where there is room for it.

Deploy: `web\*` — hard refresh (Ctrl+F5). `server\**` — restart
`Start-DSMT.ps1`.

## 1.2.1 — 2026-07-27
- `docs/deployment-guide.html` — rewritten in English. The guide was written in
  Hebrew and RTL; it is now `lang="en" dir="ltr"` throughout, matching the rest
  of the project's documentation and the console's own interface language. No
  content was dropped: all 11 steps, the installer fast path, the acceptance
  checklist, the troubleshooting table and all five appendices carry over, and
  every anchor keeps its previous id so existing links still work. Still a
  single self-contained file with zero external requests.

Deploy: replace `docs\deployment-guide.html`. Documentation only, no runtime
impact.

## 1.2.0 — 2026-07-27
Automated installer. Preparing a machine is now one command instead of a
checklist.

**New** — deploy to `server\` and the repo root:
- `server/Install-DSMT.ps1` — installs every prerequisite and prepares the
  host. Self-elevates; checks PowerShell version, domain membership and
  machine role; installs the RSAT ActiveDirectory module (`Install-WindowsFeature`
  on Server, `Add-WindowsCapability` on client Windows, `-FeatureSource` for
  offline hosts); verifies the domain answers; creates `data\` and `config\`
  and grants the run account modify rights; finds a local SQL instance or
  installs SQL Express unattended from supplied media (`-SqlExpressSetup` —
  nothing is downloaded), then creates the database and tables by calling the
  server's own schema code so the two cannot drift; reserves the HTTP URL;
  opens the firewall port; optionally registers a boot-time scheduled task
  (`-InstallScheduledTask`); writes `config\dsmt.config.json`; and prints a
  summary listing anything still outstanding with its fix. Safe to re-run.
- `Install-DSMT.cmd` — one-click launcher with settings at the top.

**Changed**:
- `server/lib/DsmtCommon.ps1` — added `Get-DsmtSavedSettings`, which reads
  `config\dsmt.config.json`. A malformed file is reported, not silently
  ignored.
- `server/Start-DSMT.ps1` — applies the saved settings for any parameter not
  passed explicitly, so it can now be started with no parameters at all. An
  explicit parameter always wins. The banner says when settings came from the
  file.
- `docs/deployment-guide.html` — new fast-path section for the installer: how
  to run it, what each of its 12 steps does mapped to the
  manual step it replaces, the saved config file, expected output, and the
  three things it deliberately does not automate (offline RSAT source, SQL
  Express download, AD delegation) with what to do instead. Manual steps 2, 5,
  6 and 11 now note that the installer covers them; appendix A documents the
  installer's parameters.
- `README.md` — new "Installing it" section.

Deploy: copy `server\Install-DSMT.ps1` and `Install-DSMT.cmd`, then run the
installer. Existing installations keep working unchanged — the saved-settings
file is optional.

## 1.1.0 — 2026-07-27
Deployment documentation.

- Added `docs/deployment-guide.html` — step-by-step install and rollout guide
  (Hebrew, RTL, self-contained single file, no external requests, prints
  cleanly). Covers: why there is no installer and what "install" means here;
  prerequisites; RSAT setup; file layout; the run-account vs operator identity
  distinction and the AD delegation each action needs; SQL preparation with
  both the auto-create and DBA-creates-it paths; port reservation and
  firewall; reading the startup preflight banner; **how the first connection
  works** (there is no default account and no first-user wizard — any valid
  domain account signs in, AD decides what it may change); an acceptance
  checklist for the first run; HTTPS; running as a scheduled task;
  troubleshooting table; CSV format and parameter reference.
- Updated `README.md` — links to the guide.

Deploy: copy `docs\` alongside the rest of the tree. Documentation only, no
runtime impact.

## 1.0.0 — 2026-07-27
First working release. DSMT stops being a mock-up: the console now reads and
writes live Active Directory on `LAB.LOCAL`, persists to SQL Server, and is
responsive from 360px up. MAJOR bump because nothing of the prototype's
runtime survives — the `.dc.html` pages are no longer the application.

**Server (new)** — deploy to `server\`, then restart `Start-DSMT.ps1`:
- `server/Start-DSMT.ps1` — entry point. Preflight checks (AD module, domain
  reachability, SQL, front end), `HttpListener` loop, `-Domain` (default
  `LAB.LOCAL`), `-Port`, `-ListenAddress`, `-SessionHours`, `-PageSize`,
  `-SqlServer`, `-SqlDatabase`, `-SqlUsername`, `-SqlPassword`.
- `server/lib/DsmtCommon.ps1` — **`$script:DsmtVersion`, the single source of
  truth for the version**, plus paths, logging, DN/time formatting, LDAP
  escaping and password generation.
- `server/lib/DsmtDirectory.ps1` — all AD access and the one attribute
  mapping (`ConvertTo-DsmtUser` / `ConvertTo-DsmtGroup`).
- `server/lib/DsmtSession.ps1` — credential validation, session tokens, idle
  expiry.
- `server/lib/DsmtAudit.ps1` — audit records: SQL primary, JSONL always.
- `server/lib/DsmtSql.ps1` — SQL connection, database + schema creation,
  operator/session records, directory snapshots.
- `server/lib/DsmtHttp.ps1` — static file serving, the JSON API, bulk-action
  semantics with per-target results.

**Front end (new)** — deploy to `web\`, then hard refresh (Ctrl+F5):
- `web/index.html`, `web/app.css`, `web/app.js` — sign-in, users, groups,
  audit, detail pane, dialogs. Vanilla JS, no framework, no build step, zero
  external requests. Responsive at 1180 / 820 / 640px.

**Database (new)** — created automatically on first start:
- `sql/schema.sql` — `dbo.Operators`, `dbo.Sessions`, `dbo.DirectoryUsers`,
  `dbo.DirectoryGroups`, `dbo.AuditLog`.

**Features**: live directory search, configurable columns, reset password
(typed or generated), unlock, enable/disable, move OU, add/remove group
membership, create user, create group, delete, bulk CSV import with per-row
results, CSV export of results and of group members, audit log with filters,
search and export. A reason is mandatory on every write. Version shown on the
sign-in screen and in the new **About** dialog, both read from `/api/meta`.

**Changed**:
- `_ds/nocturne-.../styles.css` — removed the Google Fonts `@import`; the
  font tokens fall back to `system-ui`. DSMT now makes no external requests.
- `CLAUDE.md`, `PROGRESS.md`, `README.md` (new) — rewritten for the real
  application.

**Moved** — all references updated, nothing else points at them:
- `DSMT Console.dc.html`, `DSMT Login.dc.html`, `support.js`, `.thumbnail`
  → `prototype/`, with a README stating that all of its data is fabricated
  and every button inert.

Deploy: copy the tree, install RSAT `ActiveDirectory` on the host, run
`server\Start-DSMT.ps1` (or edit and double-click `Start-DSMT.cmd`).
Not yet executed against a live domain — see `PROGRESS.md`, Open task 1.

## 0.1.0 — 2026-07-27
Import of the DSMT design prototype. Front-end only — no backend, no build step,
every action inert and all directory data fabricated.

- Added `DSMT Login.dc.html` — sign-in page (repo root).
- Added `DSMT Console.dc.html` — the console: users/groups directory with
  search, column picker, bulk selection, detail pane, audit log view and
  confirm dialogs (repo root).
- Added `support.js` — generated `dc-runtime` bundle that renders the `.dc.html`
  pages. **Do not edit; it is regenerated from a `dc-runtime/` source tree that
  is not in this repository** (repo root).
- Added `_ds/nocturne-45d14eff-42dd-42cd-8b9f-15e70f1604a8/` — the Nocturne dark
  design system: `styles.css` (the only stylesheet + token sheet), `readme.md`
  (authoritative usage guide), `_ds_manifest.json`,
  `_adherence.oxlintrc.json`, `_ds_bundle.js` (empty namespace stub).
- Added `uploads/Gemini_Generated_Image_*.png` — hero imagery used by the login
  page (`uploads/`).
- Added `.thumbnail` — WebP cover image, no file extension by design-tool
  convention (repo root).
- Updated `CLAUDE.md` and `PROGRESS.md` with the project's real facts, replacing
  the 0.0.0 scaffold placeholders (repo root).

Deploy: copy the tree as-is and open `DSMT Login.dc.html` in a browser. Relative
paths and the space in the filenames are load-bearing. Requires internet access
at runtime — React/ReactDOM/Babel load from `unpkg.com` and the Inter font from
Google Fonts.

## 0.0.0 — 2026-07-27
Project scaffold. No application code yet.

- Added `CLAUDE.md`, `CHANGELOG.md`, `PROGRESS.md` (repo root).

Deploy: none — documentation only, no runtime impact.
