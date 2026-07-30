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
