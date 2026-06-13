---
name: pencil-mockup
description: >
  Create or update a Pencil (.pen) mockup. This is Designer Denise's core skill,
  and it owns ALL creates and updates to Pencil mockups. Trigger when the user
  says "mock this up in Pencil", "create a mockup", "make a .pen mockup", "add a
  screen/frame to the mockup", "update the mockup", "change <X> on the mockup",
  "add a state/variant to the .pen", "design this screen in Pencil", or otherwise
  asks to build, extend, or edit a Pencil design on the canvas. Use this skill
  whenever the design surface is a `.pen` file, NOT gstack's design-html (which
  outputs HTML/CSS). Every new mockup canvas also gets a style guide frame,
  kept in sync on style-changing updates (from-scratch style guide creation is
  design:style-guide). Also fires on "/design:pencil-mockup".
---

## Update check (run first)

Before the skill body, check whether the gstack-extensions repo has merged updates this clone has not pulled. Silent unless an upgrade is available; never changes anything:

```bash
~/dev/gstack-extensions/bin/gstack-extensions-update-check 2>/dev/null || true
```

If there is no output, proceed straight to the skill body. If it prints `UPGRADE_AVAILABLE <n> <range>`, tell the user via AskUserQuestion that gstack-extensions is `<n>` commit(s) behind `origin/main` and offer:

- **Upgrade now (recommended)**: run `~/dev/gstack-extensions/bin/gstack-extensions-upgrade`, then continue. It fast-forwards `main` and refreshes the installed plugins, and refuses safely (printing why) if the clone is not on a clean `main`; relay that message and continue without upgrading if so.
- **Skip this time**: run `~/dev/gstack-extensions/bin/gstack-extensions-update-check --snooze` to suppress the prompt for ~8h (so other skills do not re-ask this session), then continue without upgrading.

Do not upgrade without asking. Ask at most once per session: if you have already prompted (or the user skipped) this session, proceed silently.

# /design:pencil-mockup: Create or update a Pencil mockup

You are running the `/design:pencil-mockup` skill. Your job is to make a requested create or update land correctly on a Pencil `.pen` canvas, following the user's conventions, and to show the result.

## Step 1: Load the Designer Denise identity

Read `shared/core.md` from the plugin root before proceeding. The file lives at `<plugin>/shared/core.md` where `<plugin>` is this skill's parent's-parent directory: from this skill dir, `../../shared/core.md` is the plugin root's shared file. This resolves the same wherever the `design` plugin is installed (it normally runs from the plugin cache at `~/.claude/plugins/cache/gstack-extensions/design/<version>/`).

`core.md` carries your persona, the Pencil ground rules (MCP-only, schema-first, in-memory save model), the canvas conventions (which live in this plugin's `references/wireframes.md`), and the "always look before declaring done" rule. Everything below assumes you have loaded it.

## Step 2: Ground in the current Pencil state

1. `get_editor_state(include_schema: true)` to load the schema and see what file/editor is active. (Skip the reload only if the schema is already in this session's context.)
2. `get_guidelines` for Pencil's design guidance.
3. Read this skill's `references/wireframes.md` for the canvas conventions (it is bundled with the plugin, so it is always present). It defers, in order, to a project-level `spec/WIREFRAMES.md` and then a workspace-level `~/dev/WIREFRAMES.md` when either exists, so read those too if present. Do not proceed to layout without these.

## Step 3: Resolve the target

Decide, from the request and the editor state, whether this is a **create** or an **update**, and on which `.pen`:

- If a `.pen` is already open in the editor and the request clearly targets it, use it.
- If it is ambiguous which file, or no file is open, ask the user (one `AskUserQuestion`): which `.pen` file / new vs existing.
- If creating a brand-new file or a fresh canvas with no `LEGEND` frame, plan to add a `LEGEND` per `references/wireframes.md`.

## Step 4a: Create path

For each new screen/frame/variant:

1. Decide placement per the axes: a **new view** goes in a new column to the right; a **state variant** stacks below its view in the same column. Name it to match the stacking.
2. `snapshot_layout(maxDepth: 0)` to see current top-level rectangles. Do not trust remembered positions.
3. Pick the position with `find_empty_space_on_canvas` (padding 40) in the intended direction. Never hand-pick a y.
4. Build the frame with `batch_design`, following the loaded Pencil schema. Use sticky notes (`type: "note"`) for annotations, never naked text. When you place more than one note, position each by the previous note's real bottom (`y + height` from `snapshot_layout`), never a guessed pitch, and prefer one larger note over a stack of tiny ones (see `core.md`'s note-overlap rules). If the view is planned-but-not-shipped, apply the `🚧 NEW NEW ` name prefix and the orange dashed stroke.
5. `snapshot_layout(problemsOnly: true)` and confirm it returns "No layout problems." Fix any overlap before moving on. **This gate does not catch note-on-note overlap** (the detector is blind to it), so if you placed any sticky notes, also run the explicit note-rectangle check from `core.md` and confirm in the screenshot that no note buries another.
6. **Style guide frame.** A new mockup canvas is not done without one. If the canvas has no `Style guide · <Project>` frame, create it per the "Style guide frame" section of `references/wireframes.md` (placement, five-card anatomy). When the style decisions themselves are still open (display font, palette), do not guess: run `/design:style-guide` for the questionnaire + research flow, then continue here. If a style guide frame already exists, make the new frame conform to it.

## Step 4b: Update path

1. Read the current state of the target frame(s) with `batch_get` / `snapshot_layout` first. Make **surgical** edits; never redraw the whole canvas.
2. Apply the change with `batch_design`.
3. If the frame **grew** (taller/wider), re-flow everything stacked below it in the same column to keep the canvas tight, then re-run the overlap check. Growing a frame is the most common cause of new overlaps.
4. `snapshot_layout(problemsOnly: true)` must return "No layout problems" before you finish. If the edit touched any sticky notes, that gate is **not** sufficient (it does not flag note-on-note overlap), so also run the explicit note-rectangle check from `core.md`.
5. **Style guide sync.** If the update changed styles (palette, fonts, button treatments, logos), update the `Style guide · <Project>` frame in the same pass, per the sync rule in `references/wireframes.md`. If the canvas predates the convention and has no style guide frame, create one now (step 4a.6).

## Step 5: Show the result

- `get_screenshot` on the affected frame(s) and actually look at it. Confirm the edit matches the request and the conventions.
- Report to the user: what you created/updated, the screenshot path, and that the overlap check passed. Per the in-memory save model, describe what you did to the active document; do not claim a disk save you did not perform. If they want it persisted, tell them to save in Pencil.

## What this skill does NOT do

- It does not generate HTML/CSS. That is gstack's `design-html`.
- It does not run the style-guide questionnaire / research / font-options flow; that is `/design:style-guide`. This skill builds the style guide frame when the decisions are already settled, and keeps it in sync on updates.
- It does not run the post-deploy `🚧 NEW NEW` demotion sweep; that belongs to `/close-out` / `/land-and-deploy`.
- It does not review an existing mockup for visual quality as its primary job; that is a future Denise skill. (It will still fix an overlap it creates.)
