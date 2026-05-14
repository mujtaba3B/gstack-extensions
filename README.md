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

- **`/pr-watcher`** — Foreground watcher that pairs the main agent (dispatcher and fix-applier) with a passive polling subagent (sensor): the sensor blocks silently in one Agent call until CodeRabbit posts a settled round of feedback, then returns a single JSON blob; the main agent classifies, fixes, tests, commits, pushes, and replies on the PR before spawning the next sensor. Invoke manually after `/ship`.
- **`/qa-headless`** — Systematic QA testing of backend features that have no UI (cron jobs, queue workers, webhook handlers, notifiers, CLIs, ETL pipelines).

## How it works

`./install` symlinks every directory under `skills/` into `~/.claude/skills/`. Claude Code scans that directory at session start and discovers any directory containing a `SKILL.md`.

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

1. Create `skills/<name>/SKILL.md` with valid frontmatter (`name`, `description`).
2. Run `./install`.
3. Restart Claude Code.

## Promoting to a Claude Code plugin (future)

The layout (`skills/<name>/SKILL.md`) matches what plugins use. To convert later: add `.claude-plugin/plugin.json` at the repo root. Note that plugin skills invoke as `/<plugin-name>:<skill-name>`, which is a breaking change for anyone already invoking the unprefixed names. Keep `./install` available as an alternative if you publish.
