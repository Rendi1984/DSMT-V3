# PROGRESS — DSMT-V3

Running notes. A session with zero prior context should be able to read this
file and continue immediately. Update it at the end of every session that
changes the project.

## Current version
`0.0.0` — matches the top entry of `CHANGELOG.md`.

---

## Open tasks
1. **Fill in `CLAUDE.md`.** Every `[TO FILL]` marker must be replaced with real
   specifics once the code exists. In priority order:
   - "What is this project" — actual components and actual entry-file names.
   - Versioning single source of truth — the exact file and constant name that
     holds the version string.
   - "How changes are delivered" — the real branch/PR workflow, and exactly
     which file changes require which restart/redeploy step.
   - Interface language / offline-self-contained constraint, if either applies.
   - Language-specific compatibility rules — or delete that section if the
     runtime is not constrained.
2. **Add the first application code.** The repository currently has no commits
   beyond these documentation files.
3. **Decide whether DSMT-V3 has a demo/mock mode alongside a real/live mode.**
   If it does, the "No fake/placeholder data presented as real" section of
   `CLAUDE.md` is load-bearing and every dual-mode page needs the audit. If it
   does not, note that here explicitly so future sessions don't go looking.

---

## Recurring root causes
Durable copy of the section in `CLAUDE.md`. Three shapes to watch for:
1. **A feature is a stub, not a bug** — a UI exists but the core capability was
   never implemented. Record "do not consider this handled until X exists."
2. **Environment/configuration-dependent failure, not code** — the code is
   correct; a one-time external step (permission, dependency, network,
   credential) was never completed. First question on a repeat report is "was
   the external step done?", not "what's wrong with the code."
3. **A design pattern that keeps producing the same category of bug** — record
   the pattern itself, not just each instance.

### Recorded instances
_None yet._

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
- The repository was empty (zero commits) as of 2026-07-27; these three
  documentation files are the first content.
- `CLAUDE.md` is a scaffold, not a description of a real system. Treat any
  `[TO FILL]` section as unknown — do not infer project facts from it.
- Work is being developed on branch `claude/new-session-6q2ky9`.
