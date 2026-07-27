# PROGRESS — DSMT-V3

Running notes. A session with zero prior context should be able to read this
file and continue immediately. Update it at the end of every session that
changes the project.

## Current version
`0.1.0` — matches the top entry of `CHANGELOG.md`.

## What exists right now
A front-end **design prototype only**, no backend, no build step. Two pages
(`DSMT Login.dc.html`, `DSMT Console.dc.html`) rendered client-side by the
generated `support.js` runtime, styled by the Nocturne design system in
`_ds/nocturne-45d14eff-42dd-42cd-8b9f-15e70f1604a8/`. Open the login page in a
browser; nothing to install or compile. See `CLAUDE.md` for the full picture.

---

## Open tasks
1. **Nothing in the console actually does anything.** Every action — sign-in,
   reset password, unlock, enable/disable, move OU, group membership, create,
   delete, CSV import, both Export buttons — is `noop` or `closeDialog`. A real
   backend must exist and be called before any of these counts as done.
2. **Replace the fabricated data with real fetches.** `USERS`, `GROUPS`,
   `AUDIT`, the `corp.local · 12 controllers` header, `Signed in as CORP\mcohen`,
   the membership lists, `Managed by / Created` in the group pane, and
   `retained 400 days`. Until then, do not demo this as a working tool — the
   fake rows are convincing enough to be mistaken for real directory objects.
   When wiring the backend, map attribute names at the boundary: the frontend
   reads `sam`/`upn`/`ou`/`dept`/`pwd`/`logon`, AD returns `sAMAccountName`/
   `UserPrincipalName`/`DistinguishedName`/`Department`/`LastLogonDate`.
   A casing mismatch renders blank cells with no error.
3. **Vendor the external dependencies locally.** React 18.3.1, ReactDOM 18.3.1
   and Babel standalone 7.29.0 (from `unpkg.com`, `support.js:~1143`) and the
   Inter webfont (`_ds/.../styles.css:2`, Google Fonts). An AD console usually
   runs where none of those hosts are reachable. Note that `support.js` is
   generated and must not be hand-edited — this needs the `dc-runtime/` source
   tree, which is not in this repo.
4. **Decide the real architecture.** There is no backend, no auth, no data
   store, and no decision recorded about what they will be (PowerShell/AD
   module behind an API? .NET service? something else?). Record the decision in
   `CLAUDE.md` under "What is this project" once it's made.
5. **Define the version single source of truth** the first time a version string
   is shown in the UI: one `const DSMT_VERSION` both pages read, never a pasted
   literal in two places.
6. **Decide whether `.dc.html` is the delivery format or just the design stage.**
   These files are a design-tool export. If the product ships as a real app, the
   templates get ported; if the export stays authoritative, note that any change
   made by hand here may be overwritten by the next export from the design tool.

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
- **[Shape 1] Every console write action is a stub** (see Open task 1). Polishing
  the dialogs is not progress on this.
- **[Shape 2] Blank/unstyled page on a network without internet access** —
  React/ReactDOM/Babel come from `unpkg.com` and Inter from
  `fonts.googleapis.com`. Check reachability to those hosts before touching code.

---

## Attempted and deliberately NOT pursued
Durable copy of the section in `CLAUDE.md`. For each entry record: what was
investigated, exactly where it stopped and the real blocker, what was decided
instead, and under what condition to revisit. A future session must check in
with the project owner before restarting any of these from zero.

### Entries
_None yet._

---

## Notes for next session
- **`support.js` is generated — do not edit it.** Its own first line says so; it
  is rebuilt from a `dc-runtime/` tree that is not in this repository.
- **`.dc.html` format**: an `<x-dc>` template with `{{ binding }}` placeholders,
  `<sc-if value="{{ flag }}">` and `<sc-for list="{{ items }}" as="item">` for
  control flow, plus a `<script type="text/x-dc">` block with
  `class Component extends DCLogic` exposing `state` and `renderVals()`. Every
  value or handler a template references must be returned from `renderVals()`.
  `hint-placeholder-val` / `hint-placeholder-count` are design-tool preview
  hints only — no runtime effect, but keep them accurate.
- **Relative paths and the filename space are load-bearing.** The pages link to
  each other as `DSMT Console.dc.html` / `DSMT Login.dc.html` (with the space)
  and reference `./support.js`, `_ds/nocturne-…/`, `uploads/` relatively.
  Renaming or moving anything breaks the prototype silently.
- **`.thumbnail`** is a WebP image with no file extension — the design tool's
  convention, not a broken file.
- **`_ds/.../_ds_bundle.js`** is an empty namespace stub (zero components); all
  styling comes from `styles.css`. Read `_ds/.../readme.md` before any UI work —
  it is the authoritative Nocturne guide (tokens only, outlined primary buttons,
  no accent floods, no pure black/white, headings at weight 500).
- **Hard refresh (Ctrl+F5)** after edits — there is no build step, but the CDN
  scripts and `styles.css` cache aggressively.
- The prototype's UI is English and `dir="ltr"` by deliberate choice; requests
  arriving in Hebrew are not a reason to put Hebrew strings into the interface.
