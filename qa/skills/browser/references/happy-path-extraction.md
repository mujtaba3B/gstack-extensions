# Happy path extraction

How QA Quincey converts a feature into a numbered step list with expected outcomes. Three input shapes; same output shape.

The output is always the same:

```
1. <action>. Expected: <outcome>. Mockup ref: <node ID or "none">.
2. ...
```

## Input shape 1: GitHub issue (authored by PM Penny)

```bash
gh issue view <n> --json title,body,labels,assignees
```

Search the body for these headings in order of preference:

### `## QA instructions`

This was written by PM Penny specifically for QA Quincey. Convert each bullet or numbered item to a step. The "expected outcome" is usually embedded ("you should see X"). If it is not, ask the user.

### `## Acceptance criteria`

Each `- [ ]` checkbox is one verification step. The action is implicit; the criterion IS the expected state. Translate "User can submit the form with empty optional fields" into:

```
N. Submit the form with empty optional fields. Expected: submission succeeds, no validation errors.
```

### `## Steps to reproduce` (bug issues)

These are the steps to TRIGGER the bug. After the bug is fixed, those same steps verify the fix. The "expected" is the post-fix correct state, which the issue body usually describes under `## Expected behavior`.

### Free-form body

If none of the above headings exist, the issue is under-specified. Show the issue body to the user and ask them to translate it to steps. Do not invent.

### Extracting the mockup reference

Look in the issue body for:

- A direct file path: `mockup: /path/to/feature.pen`
- An attached file link: `[mockup.pen](attachment://...)`. Download via `gh issue view ... --json body` then unwrap the attachment URL.
- A pencil.dev URL.
- A `screenshots/` or `mockups/` directory referenced inline.

If found, attach the path to every step that has a matching frame.

## Input shape 2: Pencil `.pen` file

The canvas convention (from the `design` plugin's `references/wireframes-cross-tool.md`):

- **Horizontal axis = view sequence**: the flow reads left to right.
- **Vertical axis = variants**: stacked variants of the same view (e.g. empty state, loading, error). The top row is the happy path.
- **`🚧 NEW NEW` marker**: a sticky note flagging a frame as planned but not yet shipped. These ARE valid QA targets.

Steps:

1. `mcp__pencil__open_document(path: <path>)`
2. `mcp__pencil__get_editor_state` to enumerate root-level frames.
3. Filter to frames whose y coordinate is in the top band (the row with the smallest y, plus a tolerance of ~50px for visual alignment slop).
4. Sort that filtered set by x ascending. That order IS the happy path step order.
5. For each frame, generate a step:
   - Action: derive from any sticky-note overlay or button label. If the frame is a screen mockup, the action is typically "Navigate to the screen the mockup represents and verify it matches".
   - Expected: derive from the same sources. If absent, the action is "verify the screen renders matching the mockup".
   - Mockup ref: the frame's node ID. QA Quincey will pass this to `mcp__pencil__get_screenshot` at runtime.
6. `mcp__pencil__snapshot_layout` for any sticky-note text that pins step semantics to a frame.

If the canvas does not follow the left-to-right convention (e.g. all frames stacked vertically with no clear horizontal order), ask the user which frame is step 1, then walk them through the rest.

## Input shape 3: User free-form description

The user describes the flow in prose. Convert to a step list, then show the list back for confirmation.

Rules for conversion:

- Each verb is a candidate step boundary. "Open the app, log in, click Settings, change the email" is four steps.
- If the user says "and then it should X", X is the expected outcome of the previous step.
- If the user is vague ("test the checkout flow"), ask one specific clarifying question per ambiguity. Do not invent steps.
- Cap at ~10 steps for a single run. If the flow is longer, suggest splitting into multiple QA Quincey runs.

## After extraction: always show before testing

Whichever input shape you used, render the extracted plan back to the user before step 5 of the main flow. The user is the final word on "is this the happy path I meant". Do not start testing until they sign off.
