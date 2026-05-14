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

Plugins (`plugins/`) . skill bundles that share common context files:

- **PM Penny** (`plugins/pm-penny/`): `/pm-penny-feature`, `/pm-penny-bug`, `/pm-penny-next-issue`. Product manager who turns ideas, bug reports, and "what should I work on next?" into well-structured GitHub issues. Shares identity and label conventions across the three sub-skills via `pm-penny/shared/core.md`.
- **Feature Frank** (`plugins/feature-frank/`): `/feature-frank-pr-feedback`. Engineer who works through PR review comments, patches the code, and captures durable lessons.

## How it works

`./install` symlinks every directory under `skills/` AND every plugin sub-skill under `plugins/*/skills/` into `~/.claude/skills/`. Claude Code scans that directory at session start and discovers any directory containing a `SKILL.md`. Plugin sub-skills resolve their shared files (e.g. `shared/core.md`) relative to the plugin root, which works through the symlink.

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

For a plugin (a bundle of sub-skills that share `shared/*.md` context):

1. Create `plugins/<plugin>/skills/<sub-skill>/SKILL.md` for each sub-skill.
2. Put shared context in `plugins/<plugin>/shared/`; sub-skills reference it as "from the plugin root".
3. Run `./install`. Each sub-skill is symlinked into `~/.claude/skills/` directly (no plugin-name prefix on the invocation).
