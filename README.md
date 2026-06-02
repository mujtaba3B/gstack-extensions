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

Bundles (top-level dirs with their own `skills/` and `shared/`), skill groups that share common context files:

- **PM Penny** (`pm-penny/`): `/pm-penny-feature`, `/pm-penny-bug`, `/pm-penny-next-issue`. Product manager who turns ideas, bug reports, and "what should I work on next?" into well-structured GitHub issues. Shares identity, label conventions, scope/repro gates, and fast-mode logic across the three sub-skills via `pm-penny/shared/*.md`.
- **Feature Frank** (`feature-frank/`): `/feature-frank-pr-feedback`. Engineer who works through PR review comments, patches the code, and captures durable lessons.
- **QA Quincey** (`qa-quincey/`): `/qa-quincey-manual-browser-testing`, `/qa-quincey-manual-headless-testing`. Manual QA specialist who verifies one defined flow against the spec or mockup. Browser sub-skill drives the gstack browse daemon autonomously and AI-compares screenshots against Pencil mockups; headless sub-skill (successor to the prior `/qa-headless`) verifies backend features by capturing side effects. Shares persona, deviation vocabulary, plan/report storage, and reconcile loop via `qa-quincey/shared/core.md`.

## How it works

`./bin/install` symlinks every directory under `skills/` AND every sub-skill under `<bundle>/skills/` into `~/.claude/skills/`. Claude Code scans that directory at session start and discovers any directory containing a `SKILL.md`. Bundle sub-skills resolve their shared files (e.g. `shared/core.md`) relative to the bundle root, which works through the symlink.

This repo lives outside `~/.claude/skills/gstack/`, so `gstack-upgrade` never touches it. gstack and these extensions coexist as peers in the flat `~/.claude/skills/` namespace.

## Updating

Each skill checks on invocation whether this clone's `main` is behind `origin/main` (a TTL-gated `git fetch`, so it does not hammer the remote) and, if so, offers to upgrade. Accepting runs:

```
~/dev/gstack-extensions/bin/gstack-extensions-upgrade
```

which fast-forwards `main` and re-installs the symlinks. It refuses safely (and tells you why) if the clone is not on a clean `main`, so it never disrupts in-progress feature-branch work. To upgrade by hand at any time:

```
cd ~/dev/gstack-extensions
git pull --ff-only   # must be on a clean main
./bin/install        # idempotent; refreshes links and cleans stale ones
```

`bin/gstack-extensions-update-check` is the read-only check behind the prompt; it prints `UPGRADE_AVAILABLE <n> <range>` when behind and nothing otherwise.

## Uninstall

```
./bin/uninstall
```

Removes only symlinks that point into this repo. Leaves gstack and any other skills alone.

## Adding a new extension

For a standalone skill:

1. Create `skills/<name>/SKILL.md` with valid frontmatter (`name`, `description`).
2. Add the standard "Update check (run first)" preamble right after the frontmatter (copy it from any existing skill, e.g. `skills/pr-watcher/SKILL.md`) so the skill prompts on a stale clone like the others.
3. Run `./bin/install`.
4. Restart Claude Code.

For a bundle (a group of sub-skills that share `shared/*.md` context):

1. Create `<bundle>/skills/<sub-skill>/SKILL.md` for each sub-skill at the repo top level (sibling to `skills/`).
2. Put shared context in `<bundle>/shared/`; sub-skills reference it as "from the bundle root".
3. Run `./bin/install`. Each sub-skill is symlinked into `~/.claude/skills/` directly (no bundle-name prefix on the invocation).
