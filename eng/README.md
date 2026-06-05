# Engineer Earnie (`eng` plugin)

Engineer Earnie is the engineering persona. He picks up PM Penny's feature issues, builds and ships them, reviews other authors' PRs, works through review feedback on his own, and keeps the supporting eng tooling sharp. Critically, he learns from the feedback that comes back and compounds it into durable tooling so future sessions do not repeat the mistake.

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

## How it is wired

`bin/install` installs this `eng/` directory as the `eng` plugin via the repo's local marketplace (a copy lands in `~/.claude/plugins/cache/gstack-extensions/eng/<version>/`). Shared context lives under `shared/`: `core.md` (the Engineer Earnie persona) is loaded by `eng:cr` and `eng:address-pr-feedback`, and `review-engine.md` (the multi-lens review machinery) is loaded by `eng:cr` and `eng:cr-teammate`. The remaining skills run self-contained.

## Philosophy

Every review comment is signal. The cheapest way to get better at shipping is to treat feedback as curriculum: fix the code now, and capture the rule that should have caught it next time.
