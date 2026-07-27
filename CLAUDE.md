# DSMT-V3 — Project Rules for Claude

> Status: scaffold. The repository is currently empty — every section marked
> `[TO FILL]` must be replaced with real, specific facts (actual file names,
> actual service names, actual commands) as soon as the code exists. Do not
> leave a placeholder in place once the real answer is known; a vague rule here
> is worse than no rule, because it gets trusted.

## What is this project
[TO FILL — one paragraph: what DSMT-V3 does, who uses it, the core components/
services and how they talk to each other. Name the actual file/service names,
not generic placeholders — specificity here is what makes the rest of this file
useful.]

Shape to fill in:
- **Frontend**: `[entry file]` — [framework], served by [how].
- **Backend/API**: `[entry file]` — [framework/language], running as [how].
- **Data store**: [what].

---

## Interface language / branding
- [TO FILL — the one required language for all user-facing text, if there is
  such a rule.]
- [TO FILL — any "must be self-contained / offline / no external CDN"
  constraint. This class of rule is easy to violate accidentally (e.g. a
  webfont `<link>`) and hard to notice until a real deployment fails to reach
  the internet.]

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

Single source of truth location: [TO FILL — the exact file and constant name.]

---

## Language-specific compatibility rules
[TO FILL only if real — e.g. "must run on PowerShell 5.1, no `??` / ternary /
`&&`", "must support Node 14", "no ES2022 syntax". Name the actual forbidden or
required constructs, not "be careful with compatibility." Delete this section if
the runtime is not constrained.]

---

## How changes are delivered
- Development happens on a feature branch; it is merged to the default branch
  via pull request. [TO FILL — confirm or correct; note if direct commits are
  allowed.]
- [TO FILL — any restart/redeploy step required after certain files change, and
  exactly which files trigger which step. E.g. "changing the API entry file
  requires restarting service X"; "changing the frontend bundle needs a hard
  refresh, no restart needed." Being explicit here saves a support cycle.]
- **State exactly which file(s) changed and where they go**, every time a fix
  ships — the person deploying should be able to hot-swap individual files
  instead of reasoning it out themselves.

---

## No fake/placeholder data presented as real (MANDATORY)
Applies to any UI or output that can run against both fake data
(demo/mock/offline mode) and a real backend/database/external system. That
combination has exactly one failure mode that will recur if not actively guarded
against: a page or feature quietly keeps showing the hardcoded demo data even
when the app is connected to something real, because nothing ever throws an
error — it just shows the wrong (fake) data instead of the right one. This is
worse than a crash: a crash gets reported immediately, this gets reported as
"the feature doesn't work" over and over across unrelated testing rounds because
each report looks like a different bug.

Before considering ANY change to a page/feature with both modes complete, audit
it:
1. Is this hardcoded value real UI/config (labels, nav structure, static specs
   of the app's own fixed behavior)? — fine to leave hardcoded.
2. Is it presented as if it reflects a real external system (a list of records,
   users, jobs, logs, anything with real-world names/timestamps/IDs)? — it MUST
   have a real-mode fetch that is actually called and actually used whenever the
   app is in real/live mode, with the demo value only reachable in demo/mock
   mode. If the backend capability doesn't exist yet, build it — don't ship a
   page that silently shows fake data instead.
3. If a "real mode" fetch function already exists in the code but the value
   shown on screen doesn't call it (dead code, or the display logic still
   references the demo constant unconditionally) — that is the exact bug pattern
   to search for.
4. Check field-name/casing consistency between what the backend returns and what
   the frontend reads — a backend that returns raw database-row casing (e.g.
   PascalCase columns) into a frontend that expects a different casing (e.g.
   lowercase keys) will silently show blank/undefined values with no visible
   error, and looks exactly like a "not wired up" bug from the outside.

---

## Recurring root causes — track these so they aren't re-diagnosed from scratch
When the same category of bug report comes back across multiple testing rounds
even after being "fixed," write down explicitly what the ACTUAL root cause is,
so a future fix attempt (by a future session or a future person) doesn't
re-improve the same symptom without addressing the real cause. Three shapes this
takes in practice:

1. **A feature is a stub, not a bug.** Something LOOKS built (there's a UI for
   it) but a core piece was never actually implemented (e.g. list-only where
   create/update was never wired, or a hardcoded reference-data table that was
   never connected to the real source). Every "fix" that touches the adjacent
   plumbing without building the actual missing piece will look like progress
   but isn't. Write down explicitly: "do not consider this handled until X
   actually exists," where X is the concrete missing capability.
2. **The failure is environment/configuration-dependent, not code.** The code is
   correct and the error message is now clear and specific — but the underlying
   action will keep failing until someone completes a one-time external step (a
   permission grant, an installed dependency, network reachability, a
   credential). If this gets reported again, the first question should be "was
   the external step actually completed?", not "what's wrong with the code."
3. **A design pattern that keeps producing the same category of bug** (see the
   fake-data-in-live-mode section above) — write down the pattern itself, not
   just each instance, so it can be checked proactively instead of being
   rediscovered per-page.

### Known instances
_None recorded yet._

---

## Attempted and deliberately NOT pursued
When an approach is investigated and consciously set aside — not because it
failed technically, but because of a real constraint (a knowledge/verification
limit that couldn't be resolved without a live test environment, an explicit
decision to keep the simpler existing approach, a scope/complexity tradeoff) —
record:
- What was investigated and the specific approaches considered.
- Exactly where the investigation stopped and why (the real blocker, not a vague
  "didn't work").
- What was decided instead, and under what condition it should be revisited.
- An explicit instruction for a future session: don't restart this investigation
  from zero — check in with the person first about whether to resume where it
  left off or try a different angle.

This is different from "recurring root causes" above: that section is for things
still expected to be fixed eventually; this section is for things explicitly not
being pursued right now, by decision.

### Entries
_None recorded yet._

---

## Session/progress memory
`PROGRESS.md` is the running notes file. A session with zero prior context must
be able to read it and immediately continue. It carries: current version, open
tasks, the durable copy of "recurring root causes," the durable copy of
"attempted and deliberately not pursued," and notes for the next session.

Update `PROGRESS.md` at the end of every session that changes the project — move
finished items out of "Open tasks," add anything newly discovered, and don't
skip this step even for a small fix; the whole point is that it's cheap now and
expensive to reconstruct later.
