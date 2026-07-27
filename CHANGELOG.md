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
