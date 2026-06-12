# Pencil canvas conventions

The canvas layout contract Designer Denise follows for every `.pen` create or update. This is the plugin's own copy, so the skill is self-contained: it carries these conventions wherever the `design` plugin is installed, with no dependency on any workspace-level file.

**Precedence (most specific wins).** If a more specific convention file exists, defer to it for anything it covers, and fall back to this doc for everything it does not:

1. A project-level `spec/WIREFRAMES.md` in the repo you are working in (most specific).
2. A workspace-level `~/dev/WIREFRAMES.md`, if one exists (the user's cross-tool conventions).
3. This file (the always-present baseline).

The principles below are tool-agnostic; the operating detail (the `mcp__pencil__*` calls, the stroke JSON) is Pencil-specific and is what makes this the design plugin's home for the contract.

---

## Canvas layout axes

- **Horizontal axis (left to right) = a new view in the flow.** Each step the user navigates to is its own column to the right of the previous step. Example: `1. Who` -> `1b. Who confirm` -> `1c. Who - new` -> `3a. Preview`.
- **Vertical axis (top to bottom) = a state variant of the same view.** Different states (populated vs empty, hover vs default, sibling branches of the same step) stack below the original frame in the same column. Example: `1. Who` at the top of column 1, `1d. Who - after adding 2 observers` below it.

When adding a frame, decide first: is this a new view the user navigates to, or a state variant of an existing view? Then place it accordingly. Never place a new view below another (reads as a state variant); never place a state variant to the right (reads as the next step in the flow).

Naming should match the stacking. If `S1b. Build - bio empty` is a state variant of `S1. Build`, drop the `b` and name it `S1. Build - bio empty` so the column-level prefix matches what is actually stacked.

---

## Overlap is a hard error (no frame may sit on top of another)

**This is the most common mistake when adding or resizing frames, and it must stop.** Two frames may never share canvas space. Edges touching is fine; one pixel of overlap is not. Touching counts as overlap when the frames have visible strokes, since the strokes will visually merge.

**Mandatory protocol when inserting, copying, moving, or resizing any frame:**

1. **Before** the write, get the current top-level layout with `snapshot_layout(maxDepth: 0)`. Note the rectangles of every existing frame near where you are working. Do not trust your prior memory of positions: frames grow when content is added, and the y you used last session is probably stale.
2. **Pick the position with a real check, not a guess.** Call `find_empty_space_on_canvas` with `padding: 40` in the direction you want the new frame. Never hand-pick a y by "looking at" the previous frame's y and adding what feels like enough; previous frames' heights are content-driven and you cannot eyeball them.
3. **After** the write, run `snapshot_layout(problemsOnly: true)`. It must return "No layout problems." If it surfaces an overlap, fix immediately before reporting the task done. Do not ship a wireframe edit whose overlap-check you have not seen pass.
4. When you grow a frame (add rows, expand a section), re-run the overlap check, because everything stacked below it in the same column probably now overlaps.

**Why this rule is strict:** overlap looks like progress in the screenshot of the new frame on its own, but corrupts the canvas as a whole. The frame below disappears under the new one, exports come out wrong, and reviewers think the underlying frame was deleted. This has shipped to the user repeatedly. The protocol above is the fix: do not write before checking, do not finish before re-checking.

### Sticky notes overlap silently (the detector is blind to them)

`snapshot_layout(problemsOnly: true)` only flags frame and clipping problems. It does **not** report two sticky notes (`type: "note"`) sitting on top of each other: it returns "No layout problems" while notes are fully stacked and unreadable. So the standard frame-overlap gate is not enough whenever you place a note. This has shipped overlapping, illegible note stacks to the user (notes placed at a ~100px pitch while each note was ~220px tall, so every note buried the one above it).

Whenever you add or move one or more notes, do this in addition to the frame-overlap protocol:

1. **Never stack notes at a guessed pitch.** A note's rendered height is content-driven and is commonly 200px+. Do not place note N+1 at "note N's y plus a round number". Read note N's real rectangle from `snapshot_layout` and place note N+1 at its actual bottom (`y + height`) plus ~24px padding, or pick the slot with `find_empty_space_on_canvas` (padding 40).
2. **Prefer fewer, larger notes.** One note holding a short paragraph beats five tiny notes fragmenting one thought into a fragile stack. Consolidate related annotation lines into a single note.
3. **Verify note rectangles explicitly.** After placing notes, `snapshot_layout` the parent they live in (the frame, or the canvas) and read the real `{x, y, width, height}` of every note. Confirm no two note rectangles intersect: two rects overlap iff their x-ranges overlap AND their y-ranges overlap. `problemsOnly: true` will not do this check for you.
4. **Read the screenshot for legibility, not just position.** In `get_screenshot`, confirm each note's full text is visible and no note's header sits over another note's body.

---

## Tight canvas: no big gaps

Frames in the same column or row should sit close to each other (allow ~40px padding for readability, no more). Empty stretches break visual continuity and make the flow look incomplete.

When a frame's height grows (e.g. a preview gets taller after adding fields), re-flow every frame stacked below it in the same column. Do not leave them at their old y coordinates. Use `find_empty_space_on_canvas` to land at the next-available y, never a guessed number that creates slack.

---

## Annotations live in sticky notes, not naked text

Floating annotation text (copy-scaling rules, behavior notes, implementation pointers) on the canvas should be a sticky note (`type: "note"`), not a free-floating `type: "text"` label. Notes have a distinct visual treatment and read as "metadata about the design," whereas naked text reads as "content inside a frame that lost its frame."

Frame labels (the `name` property) already handle "what is this frame called," so naked text is rarely the right answer.

---

## Planned-but-not-shipped views: the `🚧 NEW NEW` marker

A wireframe file is a mix of what is already in production and what is planned. Keep them visually distinct at a glance:

- **Production views** (shipped): normal frame, no marker.
- **Planned views** (designed but not yet built):
  - Prefix the frame's `name` with `🚧 NEW NEW ` (literal "NEW NEW", capitalized, with the construction emoji).
  - Also add an orange dashed stroke: `stroke: { align: "outside", fill: "#f59e0b", thickness: 4, dashPattern: [8, 6] }`.
  - When the view ships to production, remove both the prefix and the stroke.

This makes screenshots, exports, and the canvas itself obvious about which parts of the spec are aspirational. Variants of an unshipped feature (state variations of the same planned view) all get marked.

### Post-deploy demotion sweep

The demotion sweep (removing the `🚧 NEW NEW ` prefix and orange stroke once a view ships) is **not** part of this skill. It runs from `/close-out` and `/land-and-deploy` after a deploy is confirmed live: those flows identify which marked frames correspond to what just shipped, demote the real ones, leave the marker on any still-unshipped variants, and note the demotion in `LOG.md`. Denise applies markers; the deploy flow removes them.

---

## Style guide frame (every mockup canvas carries one)

Every mockup canvas gets a companion style guide: a root-level frame named `Style guide · <Project>`, sitting in its own column past the last view column (it is reference material, not a view in the flow, so it never participates in the horizontal/vertical axes). It is a sibling of the screen frames, never nested inside one.

**Anatomy (the five-card shape).** One vertical frame (light gray fill such as `#F5F5F5`, ~760px wide, `padding: 32`, `gap: 24`) with a small mono panel title, then five rounded cards (`cornerRadius: 12`, `width: fill_container`), top to bottom:

1. **Type · Display**: card on the product's primary surface color, rendering the REAL headline copy in the chosen display font, plus a one-line role description (which weights, which elements).
2. **Type · Body + Labels**: card with the body font sample and the label/mono font sample at their real sizes, plus a one-line spec (sizes, where each is used).
3. **Color**: card with a swatch row; each swatch is a chip + hex + a short role caption ("dark sections", "actions on dark", etc.).
4. **Buttons**: card on the surface the buttons actually live on, with primary (filled), secondary (stroked), and chip samples in their real treatments.
5. **Logos**: card with the brand mark, the wordmark, any partner logos, and a note pointing at the SVG source path on disk so future sessions can re-derive the vectors.

Adapt card surfaces and content to the project (a light-themed product flips the dark cards), but keep the five sections and the order. Reference implementation: the frame `Style guide · Hackers & Healers` in `~/dev/apps/hackers-and-healers/spec/wireframes/hh-landing.pen` (inspect via the Pencil MCP only; `.pen` files are encrypted).

**Sync rule.** The style guide is load-bearing, not decorative: any mockup edit that changes styles (palette, fonts, button treatments, logos) also updates the style guide frame in the same pass. A style guide that disagrees with the mockup beside it is worse than none.

**Division of labor.** Creating a style guide from scratch (the questionnaire, the research, the font option panels) is `/design:style-guide`'s job. `pencil-mockup` creates the frame inline when the style decisions are already settled, and keeps it in sync on every update.

---

## LEGEND frame on the canvas

Every wireframe file should have a `LEGEND` frame (or sticky note) somewhere on the canvas explaining:

- The axis convention (horizontal = view, vertical = variant).
- The `🚧 NEW NEW` + orange dashed stroke meaning.
- Project-specific markers (if any).

This lets any human or agent opening the file understand the conventions without leaving the canvas. Place it top-left or in an unused corner so it does not fight for attention with the actual flow. If you are starting a fresh canvas with no `LEGEND`, add one.
