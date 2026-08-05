# Cross-tool wireframe conventions

Designer Denise's tool-agnostic canvas principles. They apply to every wireframe file regardless of tool (Pencil `.pen`, Figma, tldraw, Balsamiq, Excalidraw). This is the canonical home for the cross-tool conventions: the tool-specific operating contract (exact MCP calls, stroke values, overlap-check tooling) lives with each tool's skill, not here.

**Precedence (most specific wins).** Defer to a more specific convention file for anything it covers, and fall back to this doc for everything it does not:

1. A project-level `spec/WIREFRAMES.md` in the repo you are working in (most specific).
2. This file (Denise's cross-tool baseline).

**Pencil operating contract.** For Pencil `.pen` work, the sibling reference `../skills/pencil-mockup/references/wireframes.md` is a self-contained superset: it carries every principle below plus the Pencil operating detail (the `mcp__pencil__*` calls, the orange-stroke JSON, the sticky-note overlap protocol, the style guide frame anatomy). Read that one for Pencil; read this one for any other tool.

---

## Canvas layout axes

- **Horizontal axis (left to right) = new view in the flow.** Each step the user navigates to is its own column to the right of the previous step. Example: `1. Who` -> `1b. Who confirm` -> `1c. Who - new` -> `3a. Preview`.
- **Vertical axis (top to bottom) = state variant of the same view.** Different states, populated vs empty, hover vs default, sibling branches of the same step, all stack below the original frame in the same column. Example: `1. Who` at the top of column 1, `1d. Who - after adding 2 observers` below it.

When adding a new frame, decide first: is this a new view the user navigates to, or a state variant of an existing view? Then place it accordingly. Never place a new view below another (reads as state variant), never place a state variant to the right (reads as next step in flow).

Naming should match the stacking. If `S1b. Build - bio empty` is a state variant of `S1. Build`, drop the `b` and name it `S1. Build - bio empty` so the column-level prefix matches what's actually stacked.

---

## Overlap is a hard error (no frame may sit on top of another)

**This is the most common mistake when adding or resizing frames, and it must stop.** Two frames may never share canvas space. One pixel of overlap is never allowed. Bounding-box edges may touch only when neither frame renders a visible stroke; if either one does, leave a gap, because the strokes would visually merge into each other.

The principle: **check before you write, and re-check after.** Snapshot the current layout before inserting, copying, moving, or resizing a frame; pick the new position with a real empty-space check rather than eyeballing the previous frame's height; and run the tool's overlap detector after, confirming it passes before you call the edit done. When you grow a frame, everything stacked below it in the same column probably now overlaps, so re-check.

**Why this rule is strict:** overlap looks like progress in the screenshot of the new frame on its own, but corrupts the canvas as a whole. The frame below disappears under the new one, exports come out wrong, and reviewers think the underlying frame was deleted. This has shipped to the user repeatedly.

The tool-specific protocol (which calls to run, and the caveat that some detectors are blind to sticky-note-on-sticky-note overlap) lives with the tool's skill: for Pencil, see the sibling reference linked at the top.

**If a project-level `spec/WIREFRAMES.md` relaxes this rule, defer to it. Otherwise no exceptions.**

---

## Tight canvas: no big gaps

Frames in the same column or row should sit close to each other (allow ~40px padding for readability, no more). Empty stretches break visual continuity and make the flow look incomplete.

When a frame's height grows (e.g. a preview gets taller after adding fields), re-flow every frame stacked below it in the same column. Don't leave them at their old coordinates.

---

## Annotations live in sticky notes, not naked text

Floating annotation text (copy-scaling rules, behavior notes, implementation pointers) on the canvas should be a sticky note, not free-floating text. Notes have a distinct visual treatment and read as "metadata about the design," whereas naked text reads as "content inside a frame that lost its frame."

Frame labels (the frame `name`) handle "what is this frame called" already, so naked text is rarely the right answer.

---

## Planned-but-not-shipped views: `🚧 NEW NEW` marker

A wireframe file is a mix of what's already in production and what's planned. Keep them visually distinct at a glance:

- **Production views** (shipped): normal frame, no marker.
- **Planned views** (designed but not yet built): prefix the frame's `name` with `🚧 NEW NEW`, followed by a space (literal "NEW NEW", capitalized, with the construction emoji), plus a tool-specific "unshipped" treatment (for Pencil, an orange dashed stroke; see the sibling reference). When the view ships to production, remove both the prefix and the treatment.

This makes screenshots, exports, and the canvas itself obvious about which parts of the spec are aspirational. Variants of an unshipped feature (state variations of the same planned view) all get marked.

If a project-level convention overrides the color or prefix, defer to it.

### Post-deploy demotion sweep

Any time work ships to production (`/land-and-deploy`, manual `git push` + deploy, Heroku release, Vercel promote, etc.):

1. Identify which `🚧 NEW NEW`-prefixed frames correspond to what just shipped (check the diff, the LOG entry, the commit messages).
2. For each one that's now in production: remove the `🚧 NEW NEW` prefix (and its trailing space) and the tool's unshipped treatment. The frame reverts to a normal production wireframe.
3. If a frame is partially shipped (only some states/variants live), leave the marker on the unshipped variants and demote only the ones that are real.
4. After demotion, note it in `LOG.md` under the relevant `[<feature>][spec]` tag so the wireframe state stays auditable.

This runs as part of the deploy workflow, not standalone. With `/land-and-deploy` the sweep fires after canary passes; with a manual deploy, surface the sweep prompt after the deploy is confirmed live. `/close-out` also carries this sweep. Denise applies the markers; the deploy flow removes them.

---

## LEGEND frame on the canvas

Every wireframe file should have a `LEGEND` frame (or sticky note) somewhere on the canvas explaining:
- The axis convention (horizontal = view, vertical = variant).
- The `🚧 NEW NEW` marker meaning.
- Project-specific markers (if any).

This lets any human or agent opening the file understand the conventions without leaving the canvas. Place it top-left or in an unused corner so it doesn't fight for attention with the actual flow.
