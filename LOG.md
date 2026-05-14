# gstack-extensions — Project Log

Narrative + decision log for the `gstack-extensions` repo. For per-skill technical changes, see each skill's own `CHANGELOG.md` and the repo's git history.

Format: date-headed sections, topic-tagged entries. One line per decision; expand inline if the *why* is non-obvious.

---

## 2026-05-14

### `[meta][schema]` Bootstrapped the project schema (CLAUDE.md / LOG.md / INDEX.md)
Repo had none of the three. Adopted the `~/dev/` convention (per `/Users/mujtaba/dev/CLAUDE.md`) and adapted the `unbound/` template to this repo's reality: single-purpose skills repo, no sub-repos, no DESIGN.md, no features folder. `CLAUDE.md` documents the skill layout convention (each `skills/<name>/SKILL.md` is the entry point; `description` is load-bearing; optional `CHANGELOG.md` per skill). `INDEX.md` catalogs the two current skills and the install scripts.

### `[skill][pr-watcher]` Architecture v2: dispatcher + sensor split
Replaced the 9-minute Bash polling loop with a passive sensor subagent that blocks up to 30 minutes in one Agent call and returns a single JSON blob when CodeRabbit posts a settled round of feedback. Main agent now applies fixes, runs tests, commits, pushes, and replies on the PR itself (subagents only sense). Reasons: (1) one Agent call can wait for real signal up to 30 min vs. re-entering Bash every 9 min, (2) main context absorbs one short JSON per cycle instead of minutes of "tick" output, (3) main-owned git + one sensor at a time eliminates concurrent-edit risk. Live validation: PR #49 on Healthcare-Super-Connector/hesco landed via this pattern, two CR rounds, < 5 min total. Skill CHANGELOG entry added at `skills/pr-watcher/CHANGELOG.md`.
