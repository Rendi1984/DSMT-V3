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

The version currently in `main` is **1.4.0** (tag `v1.4.0`). Versions 1.5.0
onwards are on `feature/service-identity` and have not been merged.

---

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
