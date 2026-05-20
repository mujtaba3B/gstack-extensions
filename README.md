# gstack-extensions

Personal skills layered on top of [gstack](https://github.com/garrytan/gstack), discovered by Claude Code alongside gstack's own skills.

## Install

```
git clone <this-repo> ~/dev/gstack-extensions
cd ~/dev/gstack-extensions
./install
```

Then restart your Claude Code session. Skills become invokable as `/pr-watcher`, `/qa-headless`, etc.

## What's included

Standalone skills (`skills/`):

- **`/pr-watcher`** . Foreground watcher that pairs the main agent (dispatcher and fix-applier) with a passive polling subagent (sensor): the sensor blocks silently in one Agent call until CodeRabbit posts a settled round of feedback, then returns a single JSON blob; the main agent classifies, fixes, tests, commits, pushes, and replies on the PR before spawning the next sensor. Invoke manually after `/ship`.
- **`/qa-headless`** . Systematic QA testing of backend features that have no UI (cron jobs, queue workers, webhook handlers, notifiers, CLIs, ETL pipelines).
- **`/qa-quincey-browser`** . Visible Chromium with "QA Quincey | <page title>" prefix on every tab, kept in place across navigations by a small background poll loop. Same connect flow as `/open-gstack-browser`; the prefix makes the QA window visually distinct from regular dogfood browsing.
- **`/coderabbit-config`** . Generates a tailored `.coderabbit.yaml` for the current repo. Detects languages, monorepo shape, generated/vendored dirs, and lifts conventions from CLAUDE.md/AGENTS.md into `path_filters`, `path_instructions`, and `tools`. Wraps the `coderabbit` CLI for optional live validation.

Bundles (top-level dirs with their own `skills/` and `shared/`), skill groups that share common context files:

- **PM Penny** (`pm-penny/`): `/pm-penny-feature`, `/pm-penny-bug`, `/pm-penny-next-issue`. Product manager who turns ideas, bug reports, and "what should I work on next?" into well-structured GitHub issues. Shares identity, label conventions, scope/repro gates, and fast-mode logic across the three sub-skills via `pm-penny/shared/*.md`.
- **Feature Frank** (`feature-frank/`): `/feature-frank-pr-feedback`. Engineer who works through PR review comments, patches the code, and captures durable lessons.

## How it works

`./install` symlinks every directory under `skills/` AND every sub-skill under `<bundle>/skills/` into `~/.claude/skills/`. Claude Code scans that directory at session start and discovers any directory containing a `SKILL.md`. Bundle sub-skills resolve their shared files (e.g. `shared/core.md`) relative to the bundle root, which works through the symlink.

This repo lives outside `~/.claude/skills/gstack/`, so `gstack-upgrade` never touches it. gstack and these extensions coexist as peers in the flat `~/.claude/skills/` namespace.

## Updating

```
cd ~/dev/gstack-extensions
git pull
./install   # idempotent; refreshes links and cleans stale ones
```

## Uninstall

```
./uninstall
```

Removes only symlinks that point into this repo. Leaves gstack and any other skills alone.

## Adding a new extension

For a standalone skill:

1. Create `skills/<name>/SKILL.md` with valid frontmatter (`name`, `description`).
2. Run `./install`.
3. Restart Claude Code.

For a bundle (a group of sub-skills that share `shared/*.md` context):

1. Create `<bundle>/skills/<sub-skill>/SKILL.md` for each sub-skill at the repo top level (sibling to `skills/`).
2. Put shared context in `<bundle>/shared/`; sub-skills reference it as "from the bundle root".
3. Run `./install`. Each sub-skill is symlinked into `~/.claude/skills/` directly (no bundle-name prefix on the invocation).
