# PM Penny

A project management specialist that creates well-structured GitHub issues for your coding agents to pick up — and helps you decide which issue to tackle next.

## What it does

PM Penny translates your feature requests, bug reports, and ideas into actionable GitHub issues through a guided discovery conversation. She asks the right questions to nail down scope, priority, and acceptance criteria — then files the issue using the GitHub CLI. She also triages the existing backlog and recommends what to pick up next.

## Skills

- **pm-penny-feature** — scope a new feature or enhancement into a well-formed issue
- **pm-penny-bug** — file a bug with clear repro steps and screenshots
- **pm-penny-next-issue** — triage open issues and recommend the next one to pick up

## How to use

Invoke PM Penny by describing work you want tracked, or by asking what to work on next. Examples:

- "File an issue for adding CSV export to the dashboard" → `pm-penny-feature`
- "The continue button is broken on the confirm screen — ticket this" → `pm-penny-bug`
- "What should I pick up next?" → `pm-penny-next-issue`

## Features

- **Guided discovery** — asks targeted questions one at a time to scope the work
- **Structured issues** — every issue follows a consistent template with summary, acceptance criteria, QA instructions, and context
- **Screenshot handling** — embeds bug screenshots directly in issues via `gh image`
- **UI mockups** — creates pencil.dev mockups for visual changes
- **Auto-labeling** — applies type and priority labels automatically
- **Batch support** — handles multiple issues at once with cross-references
- **Backlog triage** — ranks open issues by priority and staleness, hands off to `/plan-eng-review`

## Requirements

- GitHub CLI (`gh`) authenticated with access to your repo
- Pencil MCP tools (optional, for UI mockups)

## Designed for

Issues are written for a team of Cursor-based coding agents (Feature Frank, BugBash Ben, QA Quincey, Deployer Danny), but work equally well for human engineers.
