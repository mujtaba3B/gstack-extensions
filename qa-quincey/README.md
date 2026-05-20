# QA Quincey

The manual QA agent concept. A bundle of skills that share an identity, a report format, and a mockup-comparison philosophy.

QA Quincey is the counterpart to PM Penny (issue authoring), Feature Frank (feature implementation), and BugBash Ben (bug fixing). Where `/qa` sweeps an app looking for any bugs, QA Quincey verifies that **one specific defined flow** does **what the spec or mockup said it should do**.

## Skills

| Skill | What it does |
|-------|--------------|
| `qa-quincey-manual-browser-testing` | Defined-flow browser QA against Pencil mockups. AI drives the gstack browse daemon, screenshots each step, narrates deviations from the mockup, walks the user through a per-deviation reconcile loop, files bugs via `/pm-penny-bug`. |
| `qa-quincey-manual-headless-testing` | Defined-flow QA for backend features with no UI: cron jobs, queue workers, webhook handlers, notifiers, CLIs, ETL/data pipelines. Captures side effects (Slack messages, emails, DB writes, log lines), renders them readably, compares to expected output. |

## Why a bundle, not a flat skill

QA Quincey will accrete sibling skills over time (mobile, accessibility, performance regression, etc.). Bundling under `qa-quincey/` lets them share one identity file (`shared/core.md`) so the persona, report format, and reconcile loop stay consistent across the family. The pattern mirrors `pm-penny/` in this same repo.

## Install

From the gstack-extensions root:

```bash
./install
```

The installer symlinks each sub-skill in `qa-quincey/skills/` into `~/.claude/skills/`, so Claude Code discovers them at session start. The bundle's `shared/core.md` is resolved by each skill at runtime via the symlink (sub-skills reference it as `shared/core.md from the bundle root`).

## Conventions

See `shared/core.md` for the full identity. Quick facts:

- Reports land in `~/.gstack/projects/<slug>/qa-quincey/reports/<feature>-<date>.md`.
- Confirmed happy paths are saved as plans in `~/.gstack/projects/<slug>/qa-quincey/plans/<feature>.md` and replayable on future runs.
- Deviations are categorized: LAYOUT, COPY, COLOR, TYPOGRAPHY, MISSING, EXTRA, STATE.
- Verdicts are PASS, DEVIATIONS, or FAIL. Deployer Danny reads this.

## See also

- `~/dev/gstack-extensions/pm-penny/` (sibling agent: writes the issues QA Quincey verifies against).
- `~/dev/WIREFRAMES.md` (Pencil canvas conventions; left-to-right is the flow order QA Quincey reads).
