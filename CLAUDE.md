# DSMT-V3 — Project Rules for Claude

## What is this project
**DSMT — Directory Service Management Tool.** A web console for Active Directory
operations — users, groups, DNS and policy — across every domain controller in
the domain (the prototype targets `corp.local`, 12 controllers). Operators sign
in with a domain account, browse/filter directory objects, act on them (reset
password, unlock, enable/disable, move OU, group membership, bulk CSV import),
and every write is recorded in an audit log with the operator, the controller
and a mandatory reason string.

**What exists today is a front-end prototype only — there is no backend.** The
repository holds a design-tool export, not a running application:

- **Pages**: `DSMT Login.dc.html` and `DSMT Console.dc.html` — `.dc.html`
  documents: an `<x-dc>` HTML template using `{{ binding }}` placeholders plus a
  `<script type="text/x-dc">` block defining `class Component extends DCLogic`
  with `state` and `renderVals()`.
- **Runtime**: `support.js` — a generated `dc-runtime` bundle (marked *do not
  edit*; it is rebuilt from a `dc-runtime/` source tree that is **not** in this
  repo). It parses the `.dc.html` document and renders it with React.
- **Design system**: `_ds/nocturne-45d14eff-42dd-42cd-8b9f-15e70f1604a8/` —
  the **Nocturne** dark design system. `styles.css` is the single stylesheet and
  token sheet; `readme.md` is its authoritative usage guide; `_ds_bundle.js` is
  currently an empty namespace stub (zero components).
- **Assets**: `uploads/*.png` (hero images), `.thumbnail` (a WebP cover image
  with no file extension — that is the design tool's convention, not a mistake).
- **Data store**: none. See "No fake/placeholder data" below — this is the
  single most important fact about the current state of the project.

Navigation between the two pages is a plain `<a href>`; "Sign in" does not
authenticate anything.

---

## Interface language / branding
- All user-facing text is **English**, and the layout is explicitly `dir="ltr"`
  (set on the login page's root and on both credential inputs). Keep new UI text
  in English and LTR unless that decision is deliberately changed — do not mix
  Hebrew strings into the interface just because a request arrives in Hebrew.
- Follow the **Nocturne** rules in
  `_ds/nocturne-45d14eff-42dd-42cd-8b9f-15e70f1604a8/readme.md`. The ones most
  often violated: take every color, font, spacing, radius and shadow from
  `var(--color-*)` / `var(--font-*)` / `var(--space-*)` / `var(--radius-*)` /
  `var(--shadow-*)` — never hardcode a hex or a font name; primary buttons are an
  accent **outline**, never a filled block; never flood an area with the accent;
  no pure black or pure white; headings stay at weight 500.
- **Offline / self-contained constraint — currently VIOLATED, decide
  deliberately.** An AD management console normally runs on an internal network
  with no internet route, but today the prototype cannot render without one:
  - `support.js` fetches React 18.3.1, ReactDOM 18.3.1 and Babel standalone
    7.29.0 from `unpkg.com` at runtime (`REACT_URL` / `REACT_DOM_URL` /
    `BABEL_URL`, around `support.js:1143`).
  - `_ds/.../styles.css:2` has `@import url('https://fonts.googleapis.com/css2?family=Inter…')`.

  On an air-gapped or firewalled DC network both fail silently-ish: the page
  renders unstyled or blank. Before this ships anywhere real, those three
  scripts and the Inter font must be vendored locally. Do not add any new
  external CDN reference in the meantime.

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
picking the next number — don't trust a stale note elsewhere.

**Current state: no version constant exists anywhere in the code, and no version
is displayed in the UI.** The first time a version is shown on screen, define it
once (a single `const DSMT_VERSION` in a shared file both pages read) and
reference it — do not paste the literal into the login footer and the console
header separately. That is exactly the failure this rule exists to prevent.

---

## Language-specific compatibility rules
The `.dc.html` component scripts run through Babel standalone in the browser, so
modern JS syntax is fine there. Two real constraints:
- **`support.js` is generated — do not edit it.** Its own header says so, and it
  is rebuilt from a `dc-runtime/` source tree that is not part of this
  repository. Any manual fix to it is lost on the next export. If behavior in it
  needs to change, that is a conversation about the runtime, not a patch here.
- **Stay inside the `.dc.html` contract.** Template bindings are `{{ name }}`;
  control flow is `<sc-if value="{{ flag }}">` and
  `<sc-for list="{{ items }}" as="item">`; every value and handler a template
  references must be returned from `renderVals()`. The `hint-placeholder-val` /
  `hint-placeholder-count` attributes are design-tool preview hints only — they
  do not affect runtime behavior, but keep them accurate so the design tool's
  preview stays honest.

---

## How changes are delivered
- Development happens on a feature branch (currently
  `claude/new-session-6q2ky9`) and merges to the default branch via pull
  request. Do not push to another branch without explicit permission.
- **No build step exists.** The pages are opened directly; `support.js` compiles
  the component script in the browser. There is nothing to compile, bundle or
  restart — a change to any file is live on a hard refresh (Ctrl+F5; the CDN
  scripts and `styles.css` cache aggressively).
- **Relative paths are load-bearing.** `DSMT *.dc.html` reference `./support.js`,
  `_ds/nocturne-…/styles.css`, `_ds/nocturne-…/_ds_bundle.js` and
  `uploads/*.png` relatively, and the two pages link to each other by exact
  filename **including the space** (`DSMT Console.dc.html`). Moving or renaming
  any of these breaks the prototype silently. Keep the layout flat at the repo
  root unless all references are updated together.
- **State exactly which file(s) changed and where they go**, every time a fix
  ships — the person deploying should be able to hot-swap individual files
  instead of reasoning it out themselves.

---

## No fake/placeholder data presented as real (MANDATORY — this is the whole app right now)
Any UI or output that can run against both fake data (demo/mock/offline mode)
and a real backend has exactly one failure mode that will recur if not actively
guarded against: a page quietly keeps showing the hardcoded demo data even when
the app is connected to something real, because nothing ever throws an error —
it just shows the wrong (fake) data instead of the right one. This is worse than
a crash: a crash gets reported immediately, this gets reported as "the feature
doesn't work" over and over across unrelated testing rounds because each report
looks like a different bug.

**In DSMT-V3 today, 100% of the directory content is fabricated and there is no
real mode at all.** Everything on screen is invented and looks completely
plausible — real-shaped Hebrew names, `@corp.local` UPNs, OU paths, ticket IDs,
timestamps. Concretely, in `DSMT Console.dc.html`:
- `USERS` (line ~229) — 12 fake accounts with names, samAccountNames, UPNs, OUs,
  departments, titles, last-logon times, password expiry, manager.
- `GROUPS` (line ~244) — 8 fake groups with scopes and member counts.
- `AUDIT` (line ~255) — 15 fake audit entries with operators, controllers and
  ticket numbers.
- Also hardcoded and equally fake: `corp.local · 12 controllers` in the header,
  `Signed in as CORP\mcohen` in the menu, `Managed by: M. Cohen` and
  `Created: 12 Mar 2024` in the group detail pane, the `memberList` membership
  arrays, and `retained 400 days` in the audit footer.
- Every action button is inert: `noop`, and each dialog's confirm button just
  calls `closeDialog` — nothing is written anywhere.

**This is acceptable only while the project is explicitly a design prototype.**
It is dangerous precisely because it is convincing: an audit log showing
`Denied — Missing MFA confirmation` looks like evidence of a working system.
Never describe this UI as functional, and never demo it to someone who might
believe the rows are real directory objects.

Before considering ANY change to a page/feature with both modes complete, audit
it:
1. Is this hardcoded value real UI/config (labels, nav structure, static specs
   of the app's own fixed behavior)? — fine to leave hardcoded. In this repo:
   column definitions (`USER_COLS`, `GROUP_COLS`), tab labels, audit filter
   names, dialog copy.
2. Is it presented as if it reflects a real external system (records, users,
   jobs, logs, anything with real-world names/timestamps/IDs)? — it MUST have a
   real-mode fetch that is actually called and actually used whenever the app is
   in real/live mode, with the demo value only reachable in demo mode. If the
   backend capability doesn't exist yet, build it — don't ship a page that
   silently shows fake data instead. In this repo that is `USERS`, `GROUPS`,
   `AUDIT`, the controller count, the signed-in operator, and the membership
   lists.
3. If a "real mode" fetch function already exists but the value on screen
   doesn't call it (dead code, or the display logic still references the demo
   constant unconditionally) — that is the exact bug pattern to search for.
4. Check field-name/casing consistency between what the backend returns and what
   the frontend reads. This one is a live landmine here: the frontend reads
   lowercase keys (`sam`, `upn`, `ou`, `dept`, `pwd`, `logon`), while AD /
   PowerShell / SQL will hand back `sAMAccountName`, `UserPrincipalName`,
   `DistinguishedName`, `Department`, `LastLogonDate`. A mismatch shows blank or
   `undefined` cells with no error and looks exactly like a "not wired up" bug
   from the outside. Map explicitly at the boundary; don't spread raw
   directory-attribute names through the templates.

---

## Recurring root causes — track these so they aren't re-diagnosed from scratch
When the same category of bug report comes back across multiple testing rounds
even after being "fixed," write down what the ACTUAL root cause is, so a future
fix attempt doesn't re-improve the same symptom without addressing the real
cause. Three shapes:

1. **A feature is a stub, not a bug.** Something LOOKS built (there's a UI for
   it) but a core piece was never implemented. Every "fix" that touches adjacent
   plumbing without building the actual missing piece looks like progress but
   isn't. Write down explicitly: "do not consider this handled until X actually
   exists."
2. **The failure is environment/configuration-dependent, not code.** The code is
   correct and the error is clear — but the action keeps failing until someone
   completes a one-time external step (a permission grant, an installed
   dependency, network reachability, a credential). On a repeat report the first
   question is "was the external step actually completed?", not "what's wrong
   with the code."
3. **A design pattern that keeps producing the same category of bug** (see the
   fake-data section above) — write down the pattern itself, not just each
   instance.

### Known instances
- **[Shape 1] Every write action in the console is a stub.** Sign-in, reset
  password, unlock, enable/disable, move OU, group membership, create, delete,
  bulk CSV import and both Export buttons all resolve to `noop` or
  `closeDialog`. Do **not** consider any of these handled until a real backend
  endpoint exists, is actually called from `renderVals()`, and its result is
  reflected in the UI. Polishing the dialogs is not progress on this.
- **[Shape 2] The prototype will not render on a network without internet
  access** — React, ReactDOM, Babel and the Inter webfont all load from external
  hosts (see the offline constraint above). If someone reports "the page is
  blank/unstyled on the server," check network reachability to `unpkg.com` and
  `fonts.googleapis.com` **before** touching any code.

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
_None recorded yet._

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
