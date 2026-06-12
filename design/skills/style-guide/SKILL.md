---
name: style-guide
description: >
  Create a project style guide on the Pencil canvas. Designer Denise interviews
  the user (a few questions, strictly one at a time), does light research
  (reference-site palette extraction, existing brand assets in the repo), puts
  taste decisions on the canvas as labeled option panels rendering the real
  copy, and generates the standard five-card style guide frame (display type,
  body type + labels, color, buttons, logos). Trigger when the user says
  "create a style guide", "make a brand guide", "style guide for this project",
  "design system for the mockup", "pick fonts for this project", "pick a
  palette / colors", "what should our typography be", or otherwise wants to
  establish or formalize a project's visual language on a .pen canvas. Also
  fires on "/design:style-guide". For HTML/CSS design-system output use
  gstack's design-consultation instead; for building the mockup screens
  themselves use design:pencil-mockup.
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

# /design:style-guide: Create a project style guide

You are running the `/design:style-guide` skill. Your job is to land a `Style guide · <Project>` frame on the project's Pencil canvas: interview first, research second, put taste decisions on the canvas, then generate.

## Step 1: Load the Designer Denise identity

Read `shared/core.md` from the plugin root before proceeding. The file lives at `<plugin>/shared/core.md`: from this skill dir, `../../shared/core.md`. This resolves the same wherever the `design` plugin is installed (it normally runs from the plugin cache at `~/.claude/plugins/cache/gstack-extensions/design/<version>/`).

`core.md` carries your persona, the Pencil ground rules (MCP-only, schema-first, in-memory save model), and the "always look before declaring done" rule. Everything below assumes you have loaded it.

## Step 2: Ground in conventions and Pencil state

1. `get_editor_state(include_schema: true)` to load the schema and see what file is active. (Skip the reload only if the schema is already in this session's context.)
2. `get_guidelines` for Pencil's design guidance.
3. Read the sibling skill's canvas reference at `../pencil-mockup/references/wireframes.md`, especially its **"Style guide frame"** section: it defines the five-card anatomy, placement, and sync rule this skill produces. It defers to a project-level `spec/WIREFRAMES.md` and a workspace `~/dev/WIREFRAMES.md` when those exist, so read those too if present.

## Step 3: Interview (one question at a time, never a batch)

Ask a FEW questions before designing anything. Hard rule: one question per turn, never a numbered list of questions. Use `AskUserQuestion` for anything that fits 2-4 discrete options. Skip any question the request or the repo already answers; 2-4 questions is the normal total. The candidates, in priority order:

1. **Brand adjacency.** Is there a reference brand or site to anchor to (their own product, a company they admire, a parent brand)? A named site feeds the palette research in step 4.
2. **Palette anchors.** Existing colors that are fixed: a logo's colors, an established brand color, a required partner color. Anchors constrain; everything else is yours to propose.
3. **Font taste.** Standing preference: the user hates stereotypically-AI font picks. Fraunces and Space Grotesk are the canonical offenders; never propose them, and treat "this font is suddenly on every AI-generated landing page" as a disqualifier. Ask for direction (serif vs sans, sharp vs warm, any loved/hated fonts) rather than naming candidates yet; candidates come as an on-canvas panel in step 6.
4. **Audience and tone.** Who is this for and how should it feel (clinical, playful, premium, brutalist)?

## Step 4: Light research before proposing

Do the research that grounds the proposal; do not design from vibes alone.

- **Reference-site palette.** If the user named a site, extract its live palette with gstack `/browse` (computed-style frequency tally). Recipe in `references/recipes.md`.
- **Repo brand assets.** Look for existing assets in the project repo: `assets/`, `spec/brand/`, SVG logos, favicons, an existing `.pen` with brand frames. A logo's vector colors are palette anchors.
- **Drive Brand Kit.** The user's businesses may have a Brand Kit folder on Google Drive; if the project maps to one of his businesses, search Drive for it before inventing assets.

Summarize what the research found (extracted hexes with their roles, asset paths) in one short report before generating.

## Step 5: Resolve the target .pen file

The style guide frame lives on the project's mockup canvas (one `.pen` per project, style guide beside the screens).

- If the project already has a `.pen`, open it (`open <path>` via Bash) and confirm via `get_editor_state` that it is the active editor.
- If the project has no `.pen` yet, follow the **bootstrap recipe** in `references/recipes.md` exactly; it exists because skipping it pollutes whatever unrelated file is open (the footgun is documented there). Never call `batch_design` until `get_editor_state` shows the intended file as active.

## Step 6: Put taste decisions on the canvas (font option panels)

Where taste matters, the user picks from real renderings, not from font names in chat. The display font always gets this treatment; use it for any other contested call (palette direction, button shape) when the interview surfaced doubt.

Build an options panel per the **font panel recipe** in `references/recipes.md`: 4-5 cards, each rendering the project's REAL copy (headline, subline, a section title) in one candidate, on the real background color, labeled `OPTION A` through `OPTION E` with a one-line vibe description. Then ask the user to look at the canvas and pick a letter (`AskUserQuestion`, one option per letter). After the pick, delete the panel (offer to keep it if the user wants the record) and carry the winner into the style guide frame.

## Step 7: Generate the style guide frame

Build the `Style guide · <Project>` frame per the "Style guide frame" section of `../pencil-mockup/references/wireframes.md`: root-level frame in its own column, five cards top to bottom (Type · Display, Type · Body + Labels, Color, Buttons, Logos), card surfaces adapted to the project. That section is the single home for the anatomy; follow it, do not improvise the shape.

All canvas writes obey the overlap protocol from the reference: `snapshot_layout(maxDepth: 0)` before, `find_empty_space_on_canvas` (padding 40) to place, `snapshot_layout(problemsOnly: true)` must return "No layout problems" after, plus the explicit note-rectangle check for any sticky notes (the detector is blind to note-on-note overlap).

## Step 8: Show the result and hand off

- `get_screenshot` the style guide frame and actually look at it: every card legible, swatch hexes correct, the real copy rendered in the chosen fonts.
- Report: the decisions made (fonts, palette with roles, button treatments), the screenshot path, and that the overlap check passed. Per the in-memory save model, do not claim a disk save; tell the user to save in Pencil if they want it persisted.
- If a mockup is next, hand off to `/design:pencil-mockup`: the style guide frame is now the styling contract every screen it builds must follow, and its update path keeps the frame in sync from here on.

## What this skill does NOT do

- It does not build mockup screens; that is `design:pencil-mockup`.
- It does not generate HTML/CSS design systems; that is gstack's `design-consultation` / `design-html`.
- It does not invent a palette when research can find one: a named reference site or an existing logo always gets mined first.
