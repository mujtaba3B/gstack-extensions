# Engineer Ernie (`eng` plugin)

Engineer Ernie is the engineering persona. He picks up PM Penny's feature issues, builds and ships them, reviews other authors' PRs, works through review feedback on his own, and keeps the supporting eng tooling sharp. Critically, he learns from the feedback that comes back and compounds it into durable tooling so future sessions do not repeat the mistake.

This directory is a Claude Code plugin named `eng` (installed from this repo's local marketplace); its skills are invoked namespaced as `eng:<skill>`.

## Skills

| Invocation | What it does |
|---|---|
| `/eng:cr` | Master code review and the single local review path the `~/dev` merge gate keys on. Reviews any code (your own or someone else's), risk-tiers the depth, runs the shared review engine, and mints the merge-clearance stamp. Routes to the specialists below rather than duplicating them. |
| `/eng:cr-teammate` | Review a PR authored by someone else (a human teammate or an autonomous agent), run it through the shared review engine, verify the sharp findings, and post exactly one author-tagged comment. Does not mint the gate stamp. |
| `/eng:address-pr-feedback` | Manually work through review comments on a PR you authored: diagnose what each comment wants and how the mistake got through, then patch, push back, or skip, and capture a durable lesson. |
| `/eng:pr-watcher` | Autonomous watcher that pairs a dispatcher with a polling sensor to handle CodeRabbit feedback on a PR: classify, fix, test, commit, push, reply, repeat. The auto sibling of `address-pr-feedback`. |
| `/eng:spike` | Cheaply prove or disprove a feature's riskiest unknown before committing to plan and build. Throwaway code on a `spike/<slug>` branch, verdict in `SPIKE.md`. |
| `/eng:coderabbit-config` | Generate or update a tailored `.coderabbit.yaml` for the current repo. |
| `/eng:shortcut` | Create a signed macOS/iOS Shortcut from a spec, especially a Run Shell Script bridge for a CLI. macOS only. |

## Hooks (Ernie's enforcement arm)

The plugin ships its PR-lifecycle gates in `hooks/hooks.json`; installing the plugin activates them, uninstalling deactivates them. They are opt-in per repo (`.ship-gate.json` / `.merge-clearance.json` markers at the repo root) and scoped to git repos under `~/dev`; everything else is untouched. All gates fail open on missing dependencies. Path convention: `hooks.json` commands locate entrypoints via `${CLAUDE_PLUGIN_ROOT}`; inside the scripts, sibling libs resolve via `BASH_SOURCE` so the executing copy always binds its own dependencies (the scripts are dual-use: skills, the shim, and the bats suites invoke them without the hook env).

| Hook | Event | What it enforces |
|---|---|---|
| `ship-pr-gate.sh` | PreToolUse Bash | Blocks a bare `gh pr create` in an opted-in repo unless a fresh `/ship` sentinel proves the create is part of a real `/ship` run. |
| `ship-gate-sentinel.sh` | PreToolUse Skill + UserPromptSubmit | Mints the `/ship`-is-running sentinel the ship gate reads. Never blocks. |
| `pr-merge-gate.sh` | PreToolUse Bash | Blocks `gh pr merge` in an opted-in repo unless BOTH a valid HEAD-matched merge-clearance stamp AND a fresh, target-matched `/land-and-deploy` sentinel exist. The stamp can come from a bare `merge-clearance clear`; the sentinel can only come from actually invoking `/land-and-deploy`, so requiring both makes `/land-and-deploy` the single sanctioned CLI merge path (default-on fleet-wide). The local accident-guard half; the GitHub required check is the hard backstop. |
| `land-deploy-sentinel.sh` | PreToolUse Skill + UserPromptSubmit | Mints the `/land-and-deploy`-is-running sentinel the merge gate reads. Target-bound to repo + HEAD sha (+ PR number when resolvable), stored per-worktree in `<gitdir>/land-deploy-clearance`. Never blocks. |
| `review-skill-stamp.sh` | PostToolUse Bash | Records the reviewed HEAD when a review skill logs completion; a sub-signal merge-clearance reads. |
| `merge-clearance.sh` | (utility) | The pre-merge gauntlet: `check` renders the CodeRabbit + CI + review + QA checklist; `clear` writes the stamp and posts the `local-review/merge-clearance` GitHub status. Called by `/land-and-deploy`. External callers use the stable shim `~/.claude/scripts/merge-clearance.sh` (written by `bin/install`), which execs the newest installed plugin copy. CI and CodeRabbit are hard; `--skip-review` / `--skip-qa` waive the two human-judgment dimensions. When CodeRabbit is RATE-LIMITED on a head (its commit status missing, stuck pending, failed with a rate-limit description, or SUCCEEDED with one - CR publishes green without reading the code), a current `/eng:cr` review backstops it automatically. A GENUINE CodeRabbit failure takes the explicit `--override-cr-failure`, which also requires that current review, so the gate never loses both reviewers at once. Every waiver is recorded in the checklist, the `--json` verdict, the stamp evidence and the posted status description. |
| `apply-merge-clearance-protection.sh` | (utility) | Applies the GitHub branch ruleset (require CI + the clearance status check, `enforce_admins` on) that binds the web Merge button too. |

Pure decision logic lives in `merge-clearance-lib.sh` / `ship-pr-gate-lib.sh`, unit-tested by the bats suites in `hooks/tests/` (run them as individual files). The re-appliable gstack patch that wires `/land-and-deploy` into the gauntlet is `docs/land-and-deploy-merge-clearance.md`.

## How it is wired

`bin/install` installs this `eng/` directory as the `eng` plugin via the repo's local marketplace (a copy lands in `~/.claude/plugins/cache/gstack-extensions/eng/<version>/`). Shared context lives under `shared/`: `core.md` (the Engineer Ernie persona) is loaded by `eng:cr` and `eng:address-pr-feedback`, and `review-engine.md` (the multi-lens review machinery) is loaded by `eng:cr` and `eng:cr-teammate`. The remaining skills run self-contained.

## Philosophy

Every review comment is signal. The cheapest way to get better at shipping is to treat feedback as curriculum: fix the code now, and capture the rule that should have caught it next time.
