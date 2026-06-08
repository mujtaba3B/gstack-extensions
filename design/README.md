# Designer Denise (`design` plugin)

Designer Denise is the design persona. She is the Pencil-native designer: while gstack's `design-*` skills work in HTML/CSS, Denise creates and updates real mockups on the Pencil (`.pen`) canvas via the Pencil MCP.

This directory is a Claude Code plugin named `design` (installed from this repo's local marketplace); its skills are invoked namespaced as `design:<skill>`.

## Skills

| Invocation | What it does |
|---|---|
| `/design:pencil-mockup` | Create or update a Pencil mockup. Owns all creates and updates to `.pen` files: lays out new screens/variants per the canvas axes, makes surgical edits to existing frames, enforces the no-overlap protocol, and screenshots the result. |

Denise is a basket; more skills (review, variant exploration, and so on) will land here over time as sibling `design:*` skills.

## How it is wired

`bin/install` installs this `design/` directory as the `design` plugin via the repo's local marketplace (a copy lands in `~/.claude/plugins/cache/gstack-extensions/design/<version>/`). The skill lives in `design/skills/pencil-mockup/SKILL.md` and resolves `shared/core.md` relative to its plugin root (parent's-parent of the skill dir).

## Conventions

- `shared/core.md` carries the Denise persona plus the Pencil ground rules (MCP-only, schema-first via `get_editor_state(include_schema: true)`, the in-memory save model).
- Canvas layout follows the plugin's bundled `skills/pencil-mockup/references/wireframes.md` (self-contained, so the plugin is portable). It defers, in order, to a project-level `spec/WIREFRAMES.md` and then a workspace-level `~/dev/WIREFRAMES.md` when either exists. Horizontal is a new view, vertical is a state variant, overlap is a hard error, annotations are sticky notes, planned views carry the `🚧 NEW NEW` marker.

## Requirements

- Pencil MCP tools (`mcp__pencil__*`) connected.
