---
name: pre-release-audit
description: The checks to run before releasing a DSMT version - version single-source-of-truth, CHANGELOG entry and glance row, documentation against actual behaviour, PROGRESS.md, and the static checks that are possible in this container. Use before bumping $script:DsmtVersion, before committing a release, or when asked whether the project is ready to ship.
---

# Pre-release audit

Run this before a release commit, in order. It is cheap now and expensive to
reconstruct later - which is the whole reason it exists: a review in 2026-11
found two months of accumulated drift between the documentation and the code,
and none of it was hard to find once someone looked.

This skill ends in edits. Make them as you go; do not just report.

It deliberately does **not** cover the zip filename, release branch naming or
the download link - that is `handing-over-a-build`, and duplicating the rule in
two places is how the two copies start disagreeing.

## 1. Pick the number from the authoritative source

Read the **top entry of `CHANGELOG.md`**. That is the current version. Do not
trust a note in `PROGRESS.md`, a branch name or a memory of the last release.

Then pick the next number by `MAJOR.FEATURE.FIX`:

- MAJOR - breaking change
- FEATURE - new feature, and **FIX resets to 0**
- FIX - bug fix only

A release that is purely repository tooling or documentation is not a version
bump at all. Say so and stop rather than inventing a number for it.

## 2. One version constant

`$script:DsmtVersion` in `server/lib/DsmtCommon.ps1` is the only place the
number is written. It is copied into `$script:DsmtConfig.Version` at startup and
reaches every display spot from there - the sign-in footer and About via
`GET /api/meta` and `applyVersion()`, the startup and installer banners via the
constant, and the log lines, audit records, `dbo.AuditLog.AppVersion` and
`dbo.Sessions.AppVersion` via `$cfg.Version`.

Edit the constant. Then prove nothing else carries a literal:

A bare search for `N.N.N` returns around 140 hits across the tree, nearly all
of them legitimate - version history in prose, a required SQL or RSAT version, a
`PROGRESS.md` note. Search for the numbers that matter instead: the version
being released and the one before it.

```
# OLD = the version being replaced, NEW = the one being released
grep -rn --exclude-dir=.git -E "(OLD|NEW)" \
  server web _ds sql docs *.md | grep -vE "CHANGELOG\.md|PROGRESS\.md"
```

Read every hit. Two kinds are fine: `$script:DsmtVersion` itself, and prose in a
comment that is describing history ("ungated until 1.29.1"). Everything else is
a defect - **the version number presented as the app's own version**: a banner,
a comment header, a `<title>`, a `$cfg` default, a commit-time string, a SQL
insert.

Run it for OLD as well as NEW. A literal that is already stale is the failure
this rule exists to prevent, and it will not match the number you are about to
write.

Any such hit is a bug to remove, not a spot to keep in sync. In a real project
this rule was skipped for six display spots and two of them silently carried a
stale number for the entire lifetime of a feature branch before anyone noticed,
because each spot needed its own manual edit and one was always missed.

The publisher name `$script:DsmtPublisher` ("Rendi Group") follows the same
rule and lives beside it.

## 3. The CHANGELOG entry and its glance row

Add **both**:

- the entry itself, under the new version
- the row in the "Version history at a glance" table

The table is an index into the entries below it. **Never let the row carry a
detail that is not in the entry** - check this explicitly, in both directions,
because a row is edited far more casually than an entry.

The entry says what changed and, for a fix, what the actual root cause was -
not the symptom. If this release fixes something that has been "fixed" before,
that is a signal the earlier fix addressed a symptom; say so in the entry.

## 4. Documentation against actual behaviour

This is the step that catches drift, and it is the one that gets skipped. For
each file, check the specific things that have gone stale before:

- **`README.md`** - the two roots (code vs state), that the registry is the
  settings store since 1.22.0, the security model section, the preflight checks
  and their fixes, and anything describing `dsmt.config.json`, which no longer
  exists.
- **`docs/deployment-guide.html`** - installed layout, registry keys, the HTTPS
  certificate flow, the service registration. This file was written in Hebrew
  once and had to be rewritten; it is English.
- **`docs/required-permissions.md`** - every console action mapped to the AD
  right it needs. A release that adds an action adds a row here.
- **`CLAUDE.md`** - if this release changes a rule, a root or a recurring
  pattern, it changes here too.
- **`sql/schema.sql`** - standalone copy of the schema. If this release changed
  a table, it changed here as well, and `Install-DsmtSqlSchema` creates it.

Everything is in **English**, including the documentation, whatever language the
request arrived in.

## 5. PROGRESS.md

A session with zero prior context has to be able to read this and continue
immediately. Update it:

- move finished items out of **Open tasks**
- add anything newly discovered, including tasks the user asked to defer
- record a new failure pattern in **Recurring root causes** if this release
  found one - the *pattern*, not just the instance, and which of the three
  shapes it is (a stub rather than a bug, environment-dependent rather than
  code, or a design pattern that keeps producing the same category of bug)
- add to **Attempted and deliberately NOT pursued** if something was
  investigated and set aside: what was investigated, exactly where it stopped
  and the real blocker, what was decided instead, and an explicit note that a
  future session must check in before restarting it from zero
- refresh **Notes for next session**

Do not skip this for a small fix. The point is that it is cheap now.

## 6. The static checks that are possible here

The container is Linux with no PowerShell, no Windows, no domain and no
browser, so this is the whole of what can be verified mechanically:

```
# ASCII only, every .ps1 and .cmd
for f in $(git ls-files '*.ps1' '*.cmd'); do
  python3 -c "import sys;c=open(sys.argv[1],encoding='utf-8').read();s=sorted(set(ch for ch in c if ord(ch)>127));print(sys.argv[1],s) if s else None" "$f"
done

# JavaScript parses
node --check web/app.js

# Brace and paren balance, every .ps1
```

**Known false positive: the balance check reports `Install-DSMT.ps1` as -2
parens.** Lines 836 and 1866 contain `') '` inside string literals. The file is
fine. Do not "fix" it, and do not spend a round rediscovering it.

Then run the two reviewer agents on the diff - `ps51-reviewer` for `server/**`,
`web-reviewer` for `web/**` and `_ds/**`. They are read-only; you apply what
they find.

## 7. State what to deploy

There is no build step - deployment is copying files - so the release note has
to say exactly which files changed and where they go, so the person deploying
can hot-swap individual files instead of reasoning it out:

- `web/*`, `_ds/*` changed - hard refresh in the browser (Ctrl+F5)
- `server/**` changed - restart `Start-DSMT.ps1`, **which ends all sessions by
  design** (the operator credentials it needs to call AD only ever exist in
  process memory). Say that explicitly; it is not an incident.
- `sql/schema.sql` changed - restart; missing tables are created automatically

## 8. What this audit cannot tell you

Say this out loud rather than implying the release is verified:

**Runtime verification against `LAB.LOCAL` is still outstanding.**
`Start-DSMT.ps1` has never been executed - not in this release, not in any.
Treat a first run as a test, not a deployment, and hand over the specific things
to watch in the lab, not a general "please test".

Anything whose failure mode is visual, anything that depends on a browser
supporting a CSS feature, anything that touches AD, SQL, the registry under
`HKLM`, `http.sys` or elevation is untested by definition. The lab checklist in
`PROGRESS.md` is where those live.
