# gstack-extensions — Project Log

Narrative + decision log for the `gstack-extensions` repo. For per-skill technical changes, see each skill's own `CHANGELOG.md` and the repo's git history.

Format: date-headed sections, topic-tagged entries. One line per decision; expand inline if the *why* is non-obvious.

---

## 2026-05-17

### `[skill][pr-watcher]` v3 staleness fixes: sensor init pass, post-batch all-clear, idle_timeout default flip
Symptom: after switching to commit-status polling, the watcher would sit silently for a full 30 minutes after starting (or after CR posted its final clean review) and then ask "keep watching?" with default yes, so the user had to manually stop it. Three independent causes, all fixed in this version. (1) The sensor initialized `last_terminal_status_updated_at = null` and then required `current_updated_at > null` to fire, which is always false; any time CR's terminal status was already in place when the sensor spawned, no transition would ever be detected. Fixed by adding an init pass that runs once before the 15s loop: if the status is already terminal AND no unprocessed CR items exist, return a new outcome `already_settled` immediately. If there are unprocessed items, return them immediately too. Only if the status is pending/absent does the sensor fall through to the 15s loop. (2) After a "round of nitpicks only, no fixes pushed" batch, the dispatcher would spawn another sensor that had nothing to wait for (no new HEAD, CR already terminal). Added Step 4h: if the batch pushed zero commits AND CR's status came back `success` via `status_transition` AND nothing classified as `valid_actionable`/`needs_user_input`, the dispatcher exits cleanly with the "CR's review on HEAD <sha> is clean" message. This is the explicit "loop until CR has nothing for us" exit. (3) Flipped the `idle_timeout` AskUserQuestion default from "keep watching" to "stop", since 30 minutes of silence after start is overwhelmingly "CR is done"; the user can re-invoke /pr-watcher when there is new activity. Schema and CHANGELOG updated in `skills/pr-watcher/`. Not yet committed: left on local working tree for the user to review with `git diff skills/pr-watcher/`.

---

## 2026-05-16

### `[skill][qa-quincey-browser]` New skill: visible Chromium with "QA Quincey | …" tab-title prefix
User wanted to visually distinguish a QA-mode browser window from regular dogfood browsing. The clean fix would be a one-time CDP `Page.addScriptToEvaluateOnNewDocument` injection, but gstack browse's CDP allowlist is deny-default and that method isn't on it. Rather than patch gstack core (which `/gstack-upgrade` would clobber), the skill connects the headed browser the same way `/open-gstack-browser` does, then spawns a tiny background bash loop that re-applies the prefix to the active tab every 2 seconds via `browse js`. PID lands at `~/.gstack/qa-quincey-title.pid` so the next invocation's pre-flight can kill stale loops. One gotcha worth recording: `document.title` getter strips trailing whitespace per HTML spec, so a `startsWith("QA Quincey | ")` check (with trailing space) returns false against the trimmed string and the poller re-prefixes infinitely (`"QA Quincey | QA Quincey | …"`). The shipped script uses a regex that strips any number of leading `QA Quincey |…` runs and re-adds exactly one, making the poll idempotent regardless of starting state. Verified live: prefix persists across `goto` calls (Hesco → Hacker News → admin/login).

---

## 2026-05-14

### `[meta][schema]` Bootstrapped the project schema (CLAUDE.md / LOG.md / INDEX.md)
Repo had none of the three. Adopted the `~/dev/` convention (per `/Users/mujtaba/dev/CLAUDE.md`) and adapted the `unbound/` template to this repo's reality: single-purpose skills repo, no sub-repos, no DESIGN.md, no features folder. `CLAUDE.md` documents the skill layout convention (each `skills/<name>/SKILL.md` is the entry point; `description` is load-bearing; optional `CHANGELOG.md` per skill). `INDEX.md` catalogs the two current skills and the install scripts.

### `[meta][plugins]` Absorbed pm-penny and feature-frank from the deprecated mj-claude repo
The `mj-claude` marketplace repo (`mujtaba3B/mj-claude`) was being archived; its two plugins (PM Penny, Feature Frank) needed a home. Moved them into a new `plugins/` directory parallel to `skills/`. Kept the plugin's internal structure (`shared/*.md` plus `skills/<sub-skill>/SKILL.md`) so the sub-skills' "load `shared/core.md` from the plugin root" instructions keep resolving. Extended `./install` to also symlink `plugins/*/skills/*/` into `~/.claude/skills/`; resolution of `shared/*.md` through the symlink works because the symlink targets a real directory whose parent contains `shared/`. Updated `README.md` and `INDEX.md` to document the plugin layout. Rationale for keeping plugin shape (rather than flattening into `skills/`): three pm-penny sub-skills share `core.md`, `repro-gate.md`, and `scope-gate.md`; duplicating those into each sub-skill folder would be worse than the small install-script extension.

### `[skill][pr-watcher]` Architecture v2: dispatcher + sensor split
Replaced the 9-minute Bash polling loop with a passive sensor subagent that blocks up to 30 minutes in one Agent call and returns a single JSON blob when CodeRabbit posts a settled round of feedback. Main agent now applies fixes, runs tests, commits, pushes, and replies on the PR itself (subagents only sense). Reasons: (1) one Agent call can wait for real signal up to 30 min vs. re-entering Bash every 9 min, (2) main context absorbs one short JSON per cycle instead of minutes of "tick" output, (3) main-owned git + one sensor at a time eliminates concurrent-edit risk. Live validation: PR #49 on Healthcare-Super-Connector/hesco landed via this pattern, two CR rounds, < 5 min total. Skill CHANGELOG entry added at `skills/pr-watcher/CHANGELOG.md`.
