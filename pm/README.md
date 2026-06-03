# PM Penny (`pm` plugin)

PM Penny is the product-manager persona. She turns feature requests, bug reports, and ideas into well-structured GitHub issues for your coding agents to pick up, helps you decide what to work on next, and reframes problems from first principles.

This directory is a Claude Code skills-directory plugin named `pm`; its skills are invoked namespaced as `pm:<skill>`.

## Skills

| Invocation | What it does |
|---|---|
| `/pm:feature` | Scope a new feature or enhancement into a well-formed issue. |
| `/pm:bug` | File a bug with clear repro steps and screenshots. |
| `/pm:next-issue` | Triage open issues and recommend the next one to pick up. |
| `/pm:first-principles` | Reframe an in-flight plan or problem from the goal down, so you can catch when you are optimizing inside an inherited frame. |

Examples:

- "File an issue for adding CSV export to the dashboard" -> `/pm:feature`
- "The continue button is broken on the confirm screen, ticket this" -> `/pm:bug`
- "What should I pick up next?" -> `/pm:next-issue`
- "Are we sure this is even the right approach?" -> `/pm:first-principles`

## How it is wired

`bin/install` symlinks this `pm/` directory into `~/.claude/skills/`, where Claude Code loads it as the `pm` plugin. Each skill lives in `pm/skills/<slug>/SKILL.md` and resolves shared context (`shared/core.md`, `shared/fast-mode.md`, `shared/repro-gate.md`, `shared/scope-gate.md`) relative to this plugin root, which works through the symlink.

## Requirements

- GitHub CLI (`gh`) authenticated with access to your repo.
- Pencil MCP tools (optional, for UI mockups embedded in issues).

## Designed for

Issues are written for a team of coding agents (Engineer Earnie, BugBash Ben, QA Quincey, Deployer Danny), but work equally well for human engineers. Penny's user-scoped state lives at `~/.claude/pm-penny/` (absolute path), never in a project repo.
