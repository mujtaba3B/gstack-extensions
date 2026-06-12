# pencil-mockup changelog

## v1.2.0

Style guides become a first-class artifact of every mockup: the create path builds a `Style guide · <Project>` root frame beside the mockup (five-card anatomy in `references/wireframes.md`), and the update path syncs that frame whenever an edit changes styles. The from-scratch flow (questionnaire, research, font options) lives in the new sibling skill `/design:style-guide`.

## v1.1.0

Folded the canvas conventions into the plugin as a bundled, self-contained reference (`references/wireframes.md`) instead of loading the workspace-level `~/dev/WIREFRAMES.md` at runtime. The skill is now portable: it carries the conventions wherever the `design` plugin is installed. The bundled reference still defers, in order, to a project-level `spec/WIREFRAMES.md` and then a workspace `~/dev/WIREFRAMES.md` when either exists. `shared/core.md`, `SKILL.md`, and the plugin README were rewired to load the bundled reference.

## v1.0.0

Initial Designer Denise skill: create and update Pencil `.pen` mockups via the Pencil MCP, enforcing the no-overlap protocol and the canvas axis conventions.
