# Style guide recipes

Operational detail for `/design:style-guide`. The five-card frame anatomy itself lives in the sibling reference `../../pencil-mockup/references/wireframes.md` ("Style guide frame" section); these are the recipes for getting there.

## Reference-site palette extraction (gstack /browse)

When the user names a reference site, pull its live palette instead of guessing brand colors:

1. `/browse` -> `goto <url>`.
2. `js` over the computed styles of the elements that carry brand color, tallying frequencies:

```js
const tally = {};
for (const el of document.querySelectorAll("a, button, h1, h2, nav, header, footer")) {
  const s = getComputedStyle(el);
  for (const p of ["color", "background-color", "border-color"]) {
    const v = s.getPropertyValue(p);
    if (v && !v.includes("0, 0, 0, 0")) tally[v] = (tally[v] || 0) + 1;
  }
}
JSON.stringify(Object.entries(tally).sort((a, b) => b[1] - a[1]).slice(0, 12));
```

3. Convert the top recurring `rgb()` values to hex and assign roles (primary accent, surface, text). Worked example: this against doximity.com yielded `#00538A` (brand blue), `#000000`, `#FFFFFF`, `#F5F5F5`, `#BBBBBB`.

Ignore one-off decorative colors; frequency is the signal. Present the extracted palette to the user as candidates, not facts: the site may be mid-redesign or off-brand.

## Bootstrap recipe: project has no .pen yet

The Pencil MCP **cannot create a `.pen` file from scratch**, and `batch_design` with a `filePath` that does not exist on disk does not error: it **silently falls back to the active editor document**. Skipping this recipe is how an unrelated project's open mockup gets polluted.

1. Copy a small existing `.pen` as a template, e.g.:
   ```bash
   cp /Users/mujtaba/dev/businesses/unbound/spec/brand/app-store/app-store.pen <project>/spec/wireframes/<name>.pen
   ```
   (~12KB; any small `.pen` works. Create the destination directory first.)
2. `open <path>` via Bash so the copy becomes the **active** Pencil editor document.
3. `get_editor_state` and VERIFY the active file is the new path. Do not write anything until it is.
4. Delete the template's leftover nodes (`batch_design` with `Delete(...)` per top-level node id from the editor state).
5. Build on the now-empty canvas.

## Font option panel (taste decisions on the canvas)

The user picks fonts by looking at real renderings, never from font names in chat.

- One root-level panel frame (`Font options · <Project>`), placed with `find_empty_space_on_canvas` (padding 40), holding 4-5 stacked cards.
- Each card renders the project's REAL copy: the actual headline, subline, and a section title, in one candidate font, at display sizes, on the real background color the product will use. No lorem ipsum, no "The quick brown fox".
- Label each card `OPTION A` .. `OPTION E` (small mono label) with a one-line vibe description ("geometric, technical", "humanist, warm").
- Candidate selection: all Google Fonts are available in Pencil. Honor the interview's direction and the no-stereotypically-AI-fonts rule from the skill's interview step (step 3 of `SKILL.md`).
- Ask for the pick with `AskUserQuestion` (one option per letter, plus the vibe line). After the pick, delete the panel unless the user wants to keep the record.

The same panel pattern works for any contested taste call (two palette directions, button shapes): render the real thing side by side, label the options, let the user point.
