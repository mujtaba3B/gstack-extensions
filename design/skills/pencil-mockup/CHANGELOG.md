# pencil-mockup changelog

## v1.1.0

Folded the canvas conventions into the plugin as a bundled, self-contained reference (`references/wireframes.md`) instead of loading the workspace-level `~/dev/WIREFRAMES.md` at runtime. The skill is now portable: it carries the conventions wherever the `design` plugin is installed. The bundled reference still defers, in order, to a project-level `spec/WIREFRAMES.md` and then a workspace `~/dev/WIREFRAMES.md` when either exists. `shared/core.md`, `SKILL.md`, and the plugin README were rewired to load the bundled reference.

## v1.0.0

Initial Designer Denise skill: create and update Pencil `.pen` mockups via the Pencil MCP, enforcing the no-overlap protocol and the canvas axis conventions.
