# gstack-extensions

Personal skills layered on top of [gstack](https://github.com/garrytan/gstack), discovered by Claude Code alongside gstack's own skills.

## Install

```
git clone <this-repo> ~/dev/gstack-extensions
cd ~/dev/gstack-extensions
./bin/install
```

Then restart your Claude Code session. Skills become invokable as `/pr-watcher`, `/qa-quincey-manual-browser-testing`, etc.

## What's included

Standalone skills (`skills/`):

- **`/pr-watcher`** . Foreground watcher that pairs the main agent (dispatcher and fix-applier) with a passive polling subagent (sensor): the sensor blocks silently in one Agent call until CodeRabbit posts a settled round of feedback, then returns a single JSON blob; the main agent classifies, fixes, tests, commits, pushes, and replies on the PR before spawning the next sensor. Invoke manually after `/ship`.
- **`/coderabbit-config`** . Generates a tailored `.coderabbit.yaml` for the current repo. Detects languages, monorepo shape, generated/vendored dirs, and lifts conventions from CLAUDE.md/AGENTS.md into `path_filters`, `path_instructions`, and `tools`. Wraps the `coderabbit` CLI for optional live validation.
- **`/first-principles-thinking`** . Goal-first reframe coaching skill. Interrupts in-flight optimization-inside-an-inherited-frame with a seven-step walk: goal, success signal, hard constraints, assumed constraints, current path, constraint-class attacks, pressure-test. Light mode by default; escalates to Deep (Socratic, one-question-per-turn) on pushback or missing context. Modeled on the SpaceX rocket-floor and Neuralink no-surgeons reframes.
- **`/feature-spike`** . Pre-plan risk-discovery skill. Drives a four-phase loop to cheaply prove or disprove the riskiest unknown of a feature before committing to plan and build: lock a one-line outcome ("I will know X if Y"), prepare isolation (worktree or branch) and open `SPIKE.md` as a live ledger with a `THROWAWAY SPIKE` marker, write the leanest possible falsifier (karpathy-guidelines explicitly OFF), escalate to `/second-opinion` then user when blocked, complete the verdict (PROVEN / DISPROVEN / INCONCLUSIVE) in `SPIKE.md`. Sits before `/plan-eng-review`. Burn-after-reading: the branch and code are throwaway; only the SPIKE.md knowledge is meant to survive.
- **`/mac-shortcut-creator`** . Creates a signed macOS/iOS Shortcut from a spec so you don't hand-build it in Shortcuts.app: author the workflow as a plist, sign it into a `.shortcut` with `shortcuts sign`, open it for the one mandatory "Add Shortcut" click, then verify it runs with `shortcuts run`. Sweet spot is a Run Shell Script bridge that lets the menu bar, a hotkey, or Siri invoke a CLI you already wrote. Bundles a 360+ action / 700+ AppIntent plist reference (vendored from `cranecj/shortcuts-generator`, MIT; see the skill's `NOTICE.md`) and a `build_and_sign.sh` eval. macOS only.

Bundles (top-level dirs with their own `skills/` and `shared/`), skill groups that share common context files:

- **PM Penny** (`pm-penny/`): `/pm-penny-feature`, `/pm-penny-bug`, `/pm-penny-next-issue`. Product manager who turns ideas, bug reports, and "what should I work on next?" into well-structured GitHub issues. Shares identity, label conventions, scope/repro gates, and fast-mode logic across the three sub-skills via `pm-penny/shared/*.md`.
- **Feature Frank** (`feature-frank/`): `/feature-frank-pr-feedback`. Engineer who works through PR review comments, patches the code, and captures durable lessons.
- **QA Quincey** (`qa-quincey/`): `/qa-quincey-manual-browser-testing`, `/qa-quincey-manual-headless-testing`. Manual QA specialist who verifies one defined flow against the spec or mockup. Browser sub-skill drives the gstack browse daemon autonomously and AI-compares screenshots against Pencil mockups; headless sub-skill (successor to the prior `/qa-headless`) verifies backend features by capturing side effects. Shares persona, deviation vocabulary, plan/report storage, and reconcile loop via `qa-quincey/shared/core.md`.

## How it works

`./bin/install` symlinks every directory under `skills/` AND every sub-skill under `<bundle>/skills/` into `~/.claude/skills/`. Claude Code scans that directory at session start and discovers any directory containing a `SKILL.md`. Bundle sub-skills resolve their shared files (e.g. `shared/core.md`) relative to the bundle root, which works through the symlink.

This repo lives outside `~/.claude/skills/gstack/`, so `gstack-upgrade` never touches it. gstack and these extensions coexist as peers in the flat `~/.claude/skills/` namespace.

## Updating

```
cd ~/dev/gstack-extensions
git pull
./bin/install   # idempotent; refreshes links and cleans stale ones
```

## Uninstall

```
./bin/uninstall
```

Removes only symlinks that point into this repo. Leaves gstack and any other skills alone.

## Adding a new extension

For a standalone skill:

1. Create `skills/<name>/SKILL.md` with valid frontmatter (`name`, `description`).
2. Run `./bin/install`.
3. Restart Claude Code.

For a bundle (a group of sub-skills that share `shared/*.md` context):

1. Create `<bundle>/skills/<sub-skill>/SKILL.md` for each sub-skill at the repo top level (sibling to `skills/`).
2. Put shared context in `<bundle>/shared/`; sub-skills reference it as "from the bundle root".
3. Run `./bin/install`. Each sub-skill is symlinked into `~/.claude/skills/` directly (no bundle-name prefix on the invocation).
