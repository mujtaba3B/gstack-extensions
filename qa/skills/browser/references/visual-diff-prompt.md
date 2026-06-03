# Visual diff prompt (mockup vs live)

This is the canonical prompt QA Quincey uses to compare a Pencil mockup screenshot against a live browser screenshot. Load it when step 7e of the flagship skill runs.

The prompt assumes you are a vision-capable model with both images available. Read both images, then narrate deviations using the category vocabulary defined in `shared/core.md`.

---

## Prompt

You are doing a designer-grade visual diff between two screenshots of the same UI moment:

- **Image A (mockup)**: the designer's intent. This is the ground truth.
- **Image B (live)**: what the user actually sees. The thing being verified.

Your output is a list of deviations. A deviation is anything in B that does not match A, with two exceptions:

- **Data differences are not deviations.** If the mockup shows "John Doe" and live shows "Mujtaba Badat", that is content, not a defect. Ignore.
- **Dynamic content is not a deviation.** Timestamps, IDs, "X minutes ago", random tokens. Ignore.

For each real deviation, output exactly this structure:

```
- **<CATEGORY>**: <element name>. <property>: <live value> (live) vs <mockup value> (mockup). <one-sentence impact>.
```

Categories (use these exact labels):

- **LAYOUT**: position, alignment, spacing, sizing
- **COPY**: text content differs
- **COLOR**: color value differs
- **TYPOGRAPHY**: font family, size, weight, line-height
- **MISSING**: element in mockup, absent from live
- **EXTRA**: element in live, absent from mockup
- **STATE**: same element, different state (loading, error, disabled, selected)

### Rules

- **Be specific.** Name the element by its visible label or role. "The CTA button". "The email input". "The header avatar". Never "the thing" or "the area".
- **Give both values.** Color: hex if you can infer it, otherwise descriptive ("light blue" vs "darker blue"). Sizing: pixel estimates ("~24px" vs "~16px"). Position: "shifted ~8px down" not "moved".
- **One line per deviation.** Multi-line analysis goes in your reasoning, not the output.
- **Order deviations by visual prominence.** The most visible deviation first. Subtle ones last.
- **Empty list is a valid answer.** If the two images match, say "No deviations." Do not invent.

### Anti-rules

- Do not flag antialiasing fuzz at sub-pixel boundaries.
- Do not flag the browser chrome (URL bar, scrollbars, dev tools).
- Do not flag scroll position unless the mockup explicitly shows a different scroll state.
- Do not editorialize about whether the mockup or the live version is "better". You are reporting gaps, not opinions.

### Output template

```
DEVIATIONS:
- **<CATEGORY>**: <description per rules above>
- **<CATEGORY>**: <description>
...

OR

DEVIATIONS: none
```

That is the entire output of the visual diff call. The skill body parses this into the report's per-step deviation list.
