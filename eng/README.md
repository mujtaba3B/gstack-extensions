# Engineer Earnie (`eng` plugin)

Engineer Earnie is the engineering persona. He picks up PM Penny's feature issues, builds and ships them, reviews other authors' PRs, works through review feedback on his own, and keeps the supporting eng tooling sharp. Critically, he learns from the feedback that comes back and compounds it into durable tooling so future sessions do not repeat the mistake.

This directory is a Claude Code plugin named `eng` (installed from this repo's local marketplace); its skills are invoked namespaced as `eng:<skill>`.

## Skills

| Invocation | What it does |
|---|---|
| `/eng:pr-feedback` | Work through review comments on a PR you authored: diagnose what each comment wants and how the mistake got through, then patch, push back, or skip, and capture a durable lesson. |
| `/eng:review-pr` | Review someone else's PR (typically an autonomous-agent PR), run it through the toolkit review lenses, verify the sharp findings, and post exactly one author-tagged comment. |
| `/eng:pr-watcher` | Foreground watcher that pairs a dispatcher with a polling sensor to handle CodeRabbit feedback on a PR: classify, fix, test, commit, push, reply, repeat. |
| `/eng:spike` | Cheaply prove or disprove a feature's riskiest unknown before committing to plan and build. Throwaway code on a `spike/<slug>` branch, verdict in `SPIKE.md`. |
| `/eng:coderabbit-config` | Generate or update a tailored `.coderabbit.yaml` for the current repo. |
| `/eng:shortcut` | Create a signed macOS/iOS Shortcut from a spec, especially a Run Shell Script bridge for a CLI. macOS only. |

## How it is wired

`bin/install` installs this `eng/` directory as the `eng` plugin via the repo's local marketplace (a copy lands in `~/.claude/plugins/cache/gstack-extensions/eng/<version>/`). `eng:pr-feedback` carries the Engineer Earnie persona and loads `shared/core.md`; the other five skills were folded in from standalone skills and run self-contained (they do not load `shared/core.md`).

## Philosophy

Every review comment is signal. The cheapest way to get better at shipping is to treat feedback as curriculum: fix the code now, and capture the rule that should have caught it next time.
