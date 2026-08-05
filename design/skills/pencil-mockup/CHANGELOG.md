# pencil-mockup changelog

## v1.3.0

Designer Denise now owns the cross-tool wireframe conventions. This release copies the tool-agnostic principles into the design pack at `design/references/wireframes-cross-tool.md`, makes that file authoritative for anything shared across tools, and removes the workspace-level `~/dev/WIREFRAMES.md` from Denise's precedence chain.

**Scope note:** this release does not delete the workspace file. Removing `~/dev/WIREFRAMES.md` itself is a companion `~/dev` PR and is still pending; until that lands, the file remains on disk and is simply no longer consulted by this plugin. Do not read this entry as a claim that it is gone.

The bundled Pencil reference (`references/wireframes.md`) keeps the Pencil operating detail and now defers to the cross-tool file for the shared principles rather than superseding it, so the two cannot silently disagree. Precedence is project `spec/WIREFRAMES.md` -> this Pencil reference (for Pencil operating detail) -> the cross-tool reference (for shared principles). `shared/core.md`, `SKILL.md`, `style-guide/SKILL.md`, and the plugin README were repointed off the workspace path. The `qa` plugin's citations were repointed to the new cross-tool reference too.

## v1.2.0

Style guides become a first-class artifact of every mockup: the create path builds a `Style guide · <Project>` root frame beside the mockup (five-card anatomy in `references/wireframes.md`), and the update path syncs that frame whenever an edit changes styles. The from-scratch flow (questionnaire, research, font options) lives in the new sibling skill `/design:style-guide`. The frame's panel title carries a 1-2 word named direction so the aesthetic is quotable later. `style-guide` borrows from Anthropic's official skills via a soft pointer, never a hard plugin dependency: distilled taste guardrails with an optional read of `frontend-design` when installed (the anti-slop rule scoped to display fonts, so neutral body fonts like Inter stay legitimate), and a named-aesthetic-direction menu fallback when the interview finds no brand or palette anchors.

## v1.1.0

Folded the canvas conventions into the plugin as a bundled, self-contained reference (`references/wireframes.md`) instead of loading the workspace-level `~/dev/WIREFRAMES.md` at runtime. The skill is now portable: it carries the conventions wherever the `design` plugin is installed. The bundled reference still defers, in order, to a project-level `spec/WIREFRAMES.md` and then a workspace `~/dev/WIREFRAMES.md` when either exists. `shared/core.md`, `SKILL.md`, and the plugin README were rewired to load the bundled reference.

## v1.0.0

Initial Designer Denise skill: create and update Pencil `.pen` mockups via the Pencil MCP, enforcing the no-overlap protocol and the canvas axis conventions.
