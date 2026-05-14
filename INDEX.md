# gstack-extensions — Project Index

Content catalog. Companion to `LOG.md` (chronological/narrative). This file is the "where do I find X?" lookup; LOG.md is the "what happened and why?" history.

Per `CLAUDE.md`: keep this updated when artifacts are created, renamed, or deprecated. Do NOT catalog every file inside every skill (use `ls` for that). Only list things a future session would benefit from finding without hunting.

---

## Meta / project schema

| Path | What it is |
|---|---|
| `CLAUDE.md` | Project schema. Auto-loaded by Claude Code in any session under this tree. Defines LOG / INDEX / skill conventions. |
| `LOG.md` | Chronological decision log. Updated when a meaningful decision, blocker, or convention change happens. |
| `INDEX.md` | This file. |
| `README.md` | Public-facing install + usage doc. Tagline list of skills lives here. |

## Install scripts

| Path | What it is |
|---|---|
| `install` | Symlinks every directory under `skills/` into `~/.claude/skills/`. Idempotent: refreshes links and cleans stale ones. |
| `uninstall` | Removes only symlinks that point into this repo. Leaves gstack and other skills alone. |

## Skills

| Path | What it does |
|---|---|
| `skills/pr-watcher/` | `/pr-watcher` — Foreground watcher for CodeRabbit feedback on a GitHub PR. Dispatcher (main agent) + sensor (polling subagent). Main applies fixes, runs tests, commits, pushes, replies. v2 architecture (see skill's CHANGELOG.md). |
| `skills/qa-headless/` | `/qa-headless` — Systematic QA for backend features with no UI (cron jobs, queue workers, webhook handlers, notifiers, CLIs, ETL pipelines). |

## External references

| Where | What it is |
|---|---|
| `https://github.com/garrytan/gstack` | Upstream gstack repo. These extensions layer on top of it; they do not modify it. `gstack-upgrade` never touches this repo. |
| `~/.claude/skills/` | Flat namespace Claude Code scans at session start. `./install` symlinks into here; gstack and these extensions coexist as peers. |
| `~/.cache/pr-watcher/<owner>__<repo>__<pr>/` | Per-PR state directory used by `/pr-watcher`. Persists across sessions for resumability. |
