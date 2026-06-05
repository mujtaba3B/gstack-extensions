# QA Quincey (`qa` plugin)

QA Quincey is the manual-QA persona. Where gstack's `/qa` sweeps an app looking for any bugs, QA Quincey verifies that **one specific defined flow** does **what the spec or mockup said it should do**, then walks you through every deviation.

This directory is a Claude Code plugin named `qa` (installed from this repo's local marketplace); its skills are invoked namespaced as `qa:<skill>`. The `qa:` prefix coexists with gstack's own loose `/qa` skill: `/qa` and `/qa:browser` are distinct invocations, so there is no collision.

## Skills

| Invocation | What it does |
|---|---|
| `/qa:browser` | Defined-flow LIVE-browser QA. Drives the real running app through the user's persistent agent-browser session (`abrowser`, headed) at click/pixel level, walks the spec (spec/eng docs + Pencil frames) and reports per-assertion Spec compliance, seeds and tears down TAGGED data via the repo's `.gstack/qa-quincey/recipe.yml`, observes at the real surface with an adversarial probe, and ends by stating the `QA_STATUS` posture that feeds the build-time Stop hook and the PR qa-gate CI. |
| `/qa:headless` | Defined-flow QA for backend features with no UI: cron jobs, queue workers, webhook handlers, notifiers, CLIs, ETL/data pipelines. Captures side effects (Slack messages, emails, DB writes, log lines), renders them readably, compares to expected output. |

QA Quincey will accrete sibling skills over time (mobile, accessibility, performance regression, and so on). They share one identity file (`shared/core.md`) so the persona, report format, and reconcile loop stay consistent across the family.

## How it is wired

`bin/install` installs this `qa/` directory as the `qa` plugin via the repo's local marketplace (a copy lands in `~/.claude/plugins/cache/gstack-extensions/qa/<version>/`). Each skill lives in `qa/skills/<slug>/SKILL.md` and resolves `shared/core.md` relative to its plugin root (parent's-parent of the skill dir). Because the plugin lives in the plugin cache rather than `~/.claude/skills/`, there is no filesystem collision with gstack's loose `/qa` skill.

## Conventions

See `shared/core.md` for the full identity. Quick facts:

- Reports land in `~/.gstack/projects/<slug>/qa-quincey/reports/<feature>-<date>.md` (the `qa-quincey` artifact path is persona-keyed runtime state and is intentionally unchanged by the plugin rename).
- Confirmed happy paths are saved as plans in `~/.gstack/projects/<slug>/qa-quincey/plans/<feature>.md` and replayable on future runs.
- Deviations are categorized: LAYOUT, COPY, COLOR, TYPOGRAPHY, MISSING, EXTRA, STATE.
- Verdicts are PASS, DEVIATIONS, or FAIL.

## See also

- `~/dev/gstack-extensions/pm/` (PM Penny: writes the issues QA Quincey verifies against, and receives `/pm:bug` handoffs).
- `~/dev/WIREFRAMES.md` (Pencil canvas conventions; left-to-right is the flow order QA Quincey reads).
