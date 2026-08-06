# DSMT-V3 — Project Rules for Claude

## What is this project
**DSMT — Directory Service Management Tool.** A web console for Active
Directory operations — users, groups, membership, bulk import — across every
domain controller in the domain. The lab domain is **`LAB.LOCAL`**. Operators
sign in with their own domain account, browse and filter live directory
objects, act on them, and every write is recorded in an audit log with the
operator, the controller and a mandatory reason string.

- **Installer**: `server/Install-DSMT.ps1` — installs
  RSAT, prepares `data/` and `config/`, creates the SQL database via the
  server's own schema code, reserves the URL, opens the firewall, optionally
  registers a boot task, and writes `config/dsmt.config.json`. Idempotent.
  It deliberately does **not** download RSAT sources or SQL media, and does
  **not** touch AD delegation — see `README.md` for why.
- **Server**: `server/Start-DSMT.ps1` — Windows PowerShell 5.1 running a
  `System.Net.HttpListener`. Serves the front end and a JSON API. Split into
  `server/lib/`:
  - `DsmtCommon.ps1` — **the version constant**, paths, logging, formatting
  - `DsmtDirectory.ps1` — every AD read/write; the one attribute mapping
  - `DsmtSession.ps1` — sign-in, tokens, idle expiry
  - `DsmtAudit.ps1` — audit records (SQL primary, JSONL always)
  - `DsmtSql.ps1` — SQL Server connection, schema creation, snapshots
  - `DsmtGmsa.ps1` — the gMSA tool: KDS root key, group, account
  - `DsmtHttp.ps1` — static files, API routing, bulk-action semantics
- **Front end**: `web/index.html`, `web/app.css`, `web/app.js` — vanilla
  ES5-compatible JS, no framework, no build step, no external requests.
- **Design system**: `_ds/nocturne-45d14eff-42dd-42cd-8b9f-15e70f1604a8/` —
  **Nocturne**. `styles.css` is the single stylesheet and token sheet;
  `readme.md` is its authoritative usage guide.
- **Data store**: SQL Server, database `DSMT` — `dbo.Operators`,
  `dbo.Sessions`, `dbo.DirectoryUsers`, `dbo.DirectoryGroups`, `dbo.AuditLog`.
  Created automatically on first start; `sql/schema.sql` is the same schema
  standalone. Optional: without `-SqlServer` the audit log falls back to JSONL
  under `data/`, and that fallback is announced at startup and in **About**.
- **Directory access**: the RSAT `ActiveDirectory` module, called with the
  signed-in operator's own credentials.
- **`prototype/`**: the original design-tool mock-up. Everything in it is
  fabricated and every button is inert. It is reference material only — see
  `prototype/README.md`. Do not use it to check whether a feature works.

---

## Interface language / branding
- All user-facing text is **English**, and the layout is `dir="ltr"`. Keep new
  UI text in English and LTR unless that decision is deliberately changed — do
  not mix Hebrew strings into the interface just because a request arrives in
  Hebrew.
- **This applies to the documentation too**, not only to the console:
  `README.md`, `CLAUDE.md`, `PROGRESS.md`, `CHANGELOG.md` and
  `docs/deployment-guide.html` are all English. The deployment guide was
  written in Hebrew once and had to be rewritten — write new docs in English
  the first time, whatever language the request arrives in.
- Follow the **Nocturne** rules in
  `_ds/nocturne-45d14eff-42dd-42cd-8b9f-15e70f1604a8/readme.md`. The ones most
  often violated: take every color, font, spacing, radius and shadow from
  `var(--color-*)` / `var(--font-*)` / `var(--space-*)` / `var(--radius-*)` /
  `var(--shadow-*)` — never hardcode a hex or a font name; primary buttons are
  an accent **outline**, never a filled block; never flood an area with the
  accent; no pure black or pure white; headings stay at weight 500.
- **Offline / self-contained is now a satisfied constraint — keep it that
  way.** The running application makes zero external requests: no CDN, no
  webfont, no package install, no build step. The Google Fonts `@import` was
  removed from `styles.css` (the font tokens fall back to `system-ui`).
  **Do not add any external reference** — DSMT runs on isolated networks where
  it would simply fail. If Inter is wanted, vendor the woff2 files into the
  design-system folder and add an `@font-face`.
  Note that `prototype/support.js` still loads React/Babel from `unpkg.com`;
  that is one more reason the prototype is not shippable.
- **Responsive is a requirement, not a nice-to-have.** The console must work
  from a 360px phone to an ultrawide monitor. The breakpoints in `app.css` are
  1180px (detail pane becomes a slide-over), 820px (header tabs move into the
  menu) and 640px (tables reflow to stacked cards). When adding UI, check all
  four sizes — and never solve a narrow viewport by hiding directory data.

---

## Handing over a build
Whenever a download link is given for this project, **name it `DSMT <version>`
first** — "DSMT 1.13.0", then the link. A bare GitHub URL does not say which
version is behind it, and branch zips move: the same URL served 1.8.1 and
1.12.0 a day apart. State the version, then the link, then which files go
where.

**The downloaded file must carry the version too.** GitHub names an archive
after the ref, so `refs/heads/main.zip` always arrives as `DSMT-V3-main.zip` —
three of those in a downloads folder are indistinguishable. So every release
gets a **branch named exactly the version number** (`1.13.0`, no `v`, no
prefix), cut from `main` at the release commit, and that is the link handed
over:

    https://github.com/Rendi1984/DSMT-V3/archive/refs/heads/1.13.0.zip
    -> DSMT-V3-1.13.0.zip

Do not name the branch `DSMT-1.13.0` — the repo name is already in the
filename and it comes out as `DSMT-V3-DSMT-1.13.0.zip`. A `v` prefix is also
pointless: **GitHub strips a leading `v` from the ref when naming an archive**,
so branch `v1.13.1` still downloads as `DSMT-V3-1.13.1.zip`.

**The archive name cannot be controlled beyond that.** GitHub always builds it
as `<repo>-<ref>.zip`, and this repo is `DSMT-V3`, so the `-V3` is unavoidable.
Two consequences worth knowing before promising a filename:

- Some browsers ignore `Content-Disposition` and save the URL's last segment
  instead, which is why `.../1.13.1.zip` can land on disk as `1.13.1.zip`.
- The only way to a freely chosen name is a **release asset**
  (`/releases/download/v1.13.1/DSMT-v1.13.1.zip`), which needs a tag and an
  upload — neither possible from the dev container.

When an exact filename is asked for, **build it locally and send the file**:
`git archive --format=zip --prefix=DSMT-v1.13.1/ -o DSMT-v1.13.1.zip HEAD`.
That is the only method here that produces the requested name, and the prefix
keeps the extracted folder named for the version too.

A git **tag** would be the proper mechanism and produces the same filename,
but **tags cannot be pushed from the dev container** — the git proxy answers
403 (`send-pack: unexpected disconnect`). Same for deleting a remote branch.
Both have to be done by hand in the GitHub UI, so tag and release creation is
a request to the operator, never a step to attempt silently.

---

## Versioning policy (MANDATORY)
Format: `MAJOR.FEATURE.FIX`.
- MAJOR: breaking change
- FEATURE: new feature (reset FIX to 0)
- FIX: bug fix only

**Single source of truth for the version number.** If a version string is
displayed in more than one place in the UI/output, it MUST be read from exactly
one constant/field and referenced everywhere else — never hardcode the same
literal in a second spot "just this once." This is not a style preference: in a
real project this rule was skipped for six display spots, two of them silently
carried a stale version number for the entire lifetime of a feature branch
before anyone noticed, because each spot needed its own manual edit and one was
always missed. A single source of truth makes that failure mode structurally
impossible instead of relying on discipline to catch it every time.

Check `CHANGELOG.md` (top entry) for the authoritative current version before
picking the next number — don't trust a stale note elsewhere. Its "Version
history at a glance" table is an index into the entries below it; when you add
a release, add the row **and** the entry, and never let the row carry a detail
that is not in the entry.

**The one constant is `$script:DsmtVersion` in
`server/lib/DsmtCommon.ps1`.** It is copied into `$script:DsmtConfig.Version`
at startup and reaches every display spot from there:

The publisher name (`$script:DsmtPublisher`, "Rendi Group") follows the exact
same rule and lives beside it — one constant, surfaced through `/api/meta`.

| Where it is shown | How it gets there |
| --- | --- |
| Sign-in screen footer badge | `GET /api/meta` → `applyVersion()` |
| **About** dialog | `GET /api/meta` / `GET /api/session` → `applyVersion()` |
| Server startup banner, installer banner, `config/dsmt.config.json` | `$script:DsmtVersion` / `$cfg.Version` |
| Log lines, audit records, `dbo.AuditLog.AppVersion`, `dbo.Sessions.AppVersion` | `$cfg.Version` |

To release a version: edit `$script:DsmtVersion`, add a `CHANGELOG.md` entry.
Nothing else. **Never** type a version literal into `index.html`, `app.js`,
a `<title>`, a comment header or a commit-time string — if you find one, that
is a bug to remove, not a spot to keep in sync.

---

## Language-specific compatibility rules
The server must run on **Windows PowerShell 5.1** — no `pwsh` on a lab DC.
- No `??`, no ternary `?:`, no `&&`/`||` pipeline chains, no `??=`.
- No `[System.Text.Json]` — use `ConvertTo-Json` / `ConvertFrom-Json`.
- **ASCII only in `.ps1` and `.cmd` files** — no smart quotes, em-dashes or
  arrows. Verify after every edit:
  `python3 -c "c=open('f.ps1',encoding='utf-8').read(); print(set(ch for ch in c if ord(ch)>127))"`
- Here-strings: the closing `'@` / `"@` must be the first two characters on
  its own line. Several SQL statements in `DsmtSql.ps1` are here-strings.
- `ConvertTo-Json` collapses a one-element array into a bare object. The front
  end funnels every list through `asArray()` for exactly this reason — keep
  using it for any new list-shaped response.
- Output leakage: inside a function, any uncaptured output joins the return
  value. Pipe side-effecting calls to `| Out-Null` (see
  `Invoke-DsmtBulkAction`, where this was a real bug).
- The front end is deliberately ES5-compatible vanilla JS with no build step.
  Do not introduce a framework, a bundler or a transpiler.

---

## How changes are delivered
- **`main` is the default branch.** Development happens on a short-lived
  feature branch off `main`, and merges back via pull request. Small
  documentation-only fixes may go straight to `main`. Do not push to another
  branch without explicit permission.
  (History note: the repository started empty, so the first release was built
  on `claude/new-session-6q2ky9`; `main` was created from it at 1.2.1 and that
  branch was deleted. There is no separate pre-`main` history to look for.)
- **No build step.** Deployment is copying files.
  - `web/*`, `_ds/*` changed → hard refresh in the browser (Ctrl+F5).
  - `server/**` changed → restart `Start-DSMT.ps1`. Restarting ends all
    sessions by design (see Security model in `README.md`).
  - `sql/schema.sql` changed → restart; missing tables are created
    automatically by `Install-DsmtSqlSchema`.
- **Relative paths are load-bearing.** `Start-DSMT.ps1` resolves the repo root
  as its own parent directory and serves `web/`, `_ds/` and `uploads/` from
  there. Moving `server/` or renaming `web/` breaks the server's paths.
- **State exactly which file(s) changed and where they go**, every time a fix
  ships — the person deploying should be able to hot-swap individual files
  instead of reasoning it out themselves.

---

## No fake/placeholder data presented as real (MANDATORY)
Any UI or output that can run against both fake data (demo/mock/offline mode)
and a real backend has exactly one failure mode that will recur if not actively
guarded against: a page quietly keeps showing the hardcoded demo data even when
the app is connected to something real, because nothing ever throws an error —
it just shows the wrong (fake) data instead of the right one. This is worse than
a crash: a crash gets reported immediately, this gets reported as "the feature
doesn't work" over and over across unrelated testing rounds because each report
looks like a different bug.

**Current state: the running application has no demo mode and no sample data.**
Users, groups, memberships, OUs, the domain name, the controller list and the
signed-in operator are all read live from `LAB.LOCAL` through
`server/lib/DsmtDirectory.ps1`. When AD cannot be reached, the API returns the
error and the UI paints an error box in place of the table. There is no
fallback array anywhere in `web/app.js`.

Two places still need active guarding:

1. **`prototype/`** — 100% fabricated and completely convincing. Never demo it,
   never treat it as evidence a feature works. It has its own README saying so.
2. **The SQL snapshot tables** (`dbo.DirectoryUsers`, `dbo.DirectoryGroups`) —
   written *after* a live AD read, so they go stale the moment the directory
   changes. They exist for reporting and history. **Rendering the console's
   grids from them instead of from a live read would be exactly this bug.** If
   a future change adds a "load from cache" path, it must be visibly labelled
   as a snapshot with its `LastSyncUtc`, never presented as current state.

Before considering ANY change to a page/feature with both modes complete,
audit it:
1. Is this hardcoded value real UI/config (labels, nav structure, static specs
   of the app's own fixed behavior)? — fine to leave hardcoded. In this repo:
   `USER_COLS` / `GROUP_COLS`, tab labels, `AUDIT_FILTERS`, dialog copy.
2. Is it presented as if it reflects a real external system? — it MUST have a
   real-mode fetch that is actually called and actually used, with the demo
   value only reachable in demo mode. If the backend capability doesn't exist
   yet, build it — don't ship a page that silently shows fake data instead.
3. If a "real mode" fetch exists but the value on screen doesn't call it (dead
   code, or display logic still referencing a demo constant) — that is the
   exact bug pattern to search for.
4. Check field-name/casing consistency between what the backend returns and
   what the frontend reads. **This is handled in exactly one place: the
   `ConvertTo-DsmtUser` / `ConvertTo-DsmtGroup` functions in
   `DsmtDirectory.ps1`.** AD hands back `sAMAccountName`, `UserPrincipalName`,
   `DistinguishedName`, `Department`, `LastLogonDate`; the UI reads `sam`,
   `upn`, `dn`, `dept`, `logon`. **Do not spread raw AD attribute names into
   `app.js`, and do not add a second mapping site** — a mismatch renders blank
   cells with no error and looks exactly like a "not wired up" bug.

---

## Recurring root causes — track these so they aren't re-diagnosed from scratch
When the same category of bug report comes back across multiple testing rounds
even after being "fixed," write down what the ACTUAL root cause is, so a future
fix attempt doesn't re-improve the same symptom without addressing the real
cause. Three shapes:

1. **A feature is a stub, not a bug.** Something LOOKS built but a core piece
   was never implemented. Write down explicitly: "do not consider this handled
   until X actually exists."
2. **The failure is environment/configuration-dependent, not code.** The code
   is correct and the error is clear — but the action keeps failing until
   someone completes a one-time external step. On a repeat report the first
   question is "was the external step actually completed?", not "what's wrong
   with the code."
3. **A design pattern that keeps producing the same category of bug** (see the
   fake-data section) — write down the pattern itself, not just each instance.

### Known instances
- **[Shape 3] A collection of one is not a collection.** Three separate bugs,
  one cause. `ConvertTo-Json` collapses a one-element array into a bare
  object; `-Discover` returned `HostName` as a collection; and in 1.12.1 the
  installer, on a machine with exactly one SQL instance, announced
  `Found a local SQL instance: l` and then failed to reach a server called
  `l` — because `return @($names)` **unrolls on return**, `.Count` on the
  resulting string is 1 (so the guard passed), and `[0]` on a string is its
  first *character*. Note how well it hid: the count test succeeded, the
  message was printed correctly, and in a console font `l` and `1` are
  indistinguishable, so the report read as `instance: 1`.
  **The pattern, not the instance: PowerShell and `ConvertTo-Json` both treat
  a one-element collection as a scalar, and every scalar in PowerShell answers
  `.Count` with 1 and `[0]` with itself — so the usual defensive checks pass
  while the value is wrong.** The rules, which apply to new code without
  discussion:
    - a function returning a list ends with `return ,@($list)`;
    - **every call site wraps it: `$x = @(Get-Something)`** — this is the one
      that actually protects you, because you do not control every callee;
    - the front end funnels every list-shaped response through `asArray()`;
    - where a value must look like something (a server name, a DN, an
      account), validate it before use rather than passing nonsense onward.
- **[Shape 3] Modern CSS that degrades to nothing, with no error.** The first
  real run of the console found every dialog, toast and popover invisible —
  About, every action button, every result message. There was no JavaScript
  error and every request returned 200; the handlers ran and the markup was
  built. The cause was that all three overlays positioned themselves with
  logical inset properties (`inset: 0`, `inset-inline-end`, `inset-block-end`)
  which the browser ignored, dropping each element at its static position
  behind an `overflow: hidden`. Fixed in 1.7.5 by using physical offsets.
  **The pattern, not the instance: a CSS feature that is unsupported does not
  fail loudly, it is discarded — and a layout that depends on it silently
  becomes something else.** So in anything the console needs to be *visible*,
  prefer the older property: `top/right/bottom/left` over `inset*`, `rgba()`
  over `color-mix()`, `width`+`max-width` over `min()`, `vh` with `dvh` only
  inside `@supports`. The rules and the reason are written at the top of
  `web/app.css`. Note this cannot be caught by any check in this repo — the
  dev container has no browser — so it is a code-review rule, not a test.
- **[Shape 3] A platform default silently kills a long-running process.**
  Task Scheduler stops a task after 72 hours by default, which would have
  taken the console down every three days with no error — found by reading
  the code, not by running it, and fixed in 1.4.0 with
  `-ExecutionTimeLimit ([TimeSpan]::Zero)`. **The pattern, not the instance:
  whenever a new way of running DSMT is added (service, task, container,
  reverse proxy), enumerate the platform's default limits on a long-lived
  process before calling it done** — idle timeouts, recycling, execution
  caps, power policy. The acceptance test for any hosting change is to leave
  it running for four days and confirm it still answers; nothing shorter
  catches this class.
- **[Shape 2] "The server won't start."** The three preflight checks in
  `Start-DSMT.ps1` each name their own fix: the RSAT `ActiveDirectory` module
  is missing (`Install-WindowsFeature RSAT-AD-PowerShell`), the domain is
  unreachable, or SQL is unreachable. Read the banner before touching code.
- **[Shape 2] "Listening on all interfaces fails."** `-ListenAddress any`
  needs an elevated shell or a one-time
  `netsh http add urlacl url=http://+:8080/ user="LAB\svc-dsmt"`. Not a code
  problem.
- **[Shape 2] "It says access denied when I reset a password."** Directory
  writes run as the signed-in operator, so AD is enforcing that operator's
  rights. The audit record says `Denied`. The fix is a delegation change in
  AD, not in DSMT — DSMT deliberately has no permission model of its own.
- **[Shape 2] "Everyone got logged out."** Restarting the server ends all
  sessions: the operator credentials it needs to call AD only ever exist in
  process memory and are never persisted. A browser refresh (F5) does *not*
  sign anyone out — that path is covered by the token in `localStorage`.
- **[Shape 1] `prototype/` is not the product.** Every action there is `noop`.
  A report of "it doesn't do anything" that turns out to be about those pages
  is not a bug in DSMT.

---

## Attempted and deliberately NOT pursued
When an approach is investigated and consciously set aside — not because it
failed technically, but because of a real constraint (a verification limit that
needs a live environment, a decision to keep the simpler approach, a
scope/complexity tradeoff) — record: what was investigated, exactly where it
stopped and the real blocker, what was decided instead and when to revisit, and
an explicit instruction that a future session must check in before restarting
the investigation from zero.

### Entries

**1. Running the server as a service account with Kerberos delegation instead
of holding operator credentials in memory.**
Investigated while designing `DsmtSession.ps1`. Constrained delegation would
let DSMT act as the operator without keeping their password, which is the
cleaner security posture. Stopped because it needs SPN registration and
delegation configuration on `LAB.LOCAL` that cannot be designed blind — it has
to be set up and tested against the live domain. Decided instead: hold the
`PSCredential` in process memory for the session lifetime, document the
consequence in `README.md` ("Security model"), and never persist it. Revisit
when someone can configure and test delegation in the lab. **A future session
must not rip out the credential-in-memory design without checking in first.**

**2. Verifying the PowerShell server by running it.**
The development container is Linux with no PowerShell, no Windows and no
domain, so `Start-DSMT.ps1` has never been executed. What was done instead:
ASCII and brace/paren balance checks on every `.ps1`, `node --check` on
`app.js`, and a line-by-line review that found and fixed five real defects
(undefined `Get-DsmtOperatorIdentity`, `HostName` returned as a collection by
`-Discover`, an invalid wildcard on a DN-syntax LDAP attribute, an inverted
dummy-leaf DN in `Get-DsmtOus`, and output leaking from the bulk-action
scriptblock into its return value). **Runtime verification against LAB.LOCAL
is still outstanding — treat the first run as a test, not as a deployment**,
and see "Notes for next session" in `PROGRESS.md` for the specific things to
watch.

---

## Session/progress memory
`PROGRESS.md` is the running notes file. A session with zero prior context must
be able to read it and continue immediately: current version, open tasks, the
durable copy of "recurring root causes," the durable copy of "attempted and
deliberately not pursued," and notes for the next session.

Update `PROGRESS.md` at the end of every session that changes the project — move
finished items out of "Open tasks," add anything newly discovered, and don't
skip this step even for a small fix; the whole point is that it's cheap now and
expensive to reconstruct later.
