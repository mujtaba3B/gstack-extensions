# Designer Denise (`design` plugin)

Designer Denise is the design persona. She is the Pencil-native designer: while gstack's `design-*` skills work in HTML/CSS, Denise creates and updates real mockups on the Pencil (`.pen`) canvas via the Pencil MCP.

This directory is a Claude Code skills-directory plugin named `design`; its skills are invoked namespaced as `design:<skill>`.

## Skills

| Invocation | What it does |
|---|---|
| `/design:pencil-mockup` | Create or update a Pencil mockup. Owns all creates and updates to `.pen` files: lays out new screens/variants per the canvas axes, makes surgical edits to existing frames, enforces the no-overlap protocol, and screenshots the result. |

Denise is a basket; more skills (review, variant exploration, and so on) will land here over time as sibling `design:*` skills.

## How it is wired

`bin/install` symlinks this `design/` directory into `~/.claude/skills/`, where Claude Code loads it as the `design` plugin. The skill lives in `design/skills/pencil-mockup/SKILL.md` and resolves `shared/core.md` relative to this plugin root (parent's-parent of the skill dir), which works through the symlink.

## Conventions

- `shared/core.md` carries the Denise persona plus the Pencil ground rules (MCP-only, schema-first via `get_editor_state(include_schema: true)`, the in-memory save model).
- Canvas layout follows `~/dev/WIREFRAMES.md` (a project-level `spec/WIREFRAMES.md` overrides it): horizontal is a new view, vertical is a state variant, overlap is a hard error, annotations are sticky notes, planned views carry the `🚧 NEW NEW` marker.

## Requirements

- Pencil MCP tools (`mcp__pencil__*`) connected.
