---
name: stop-slop
description: Remove AI writing patterns from prose. Use when drafting, editing, or reviewing text to eliminate predictable AI tells. Run it on every marketing:copywriting draft. Also fires on "/marketing:stop-slop".
metadata:
  trigger: Writing prose, editing drafts, reviewing content for AI patterns
  author: Hardik Pandya (https://hvpandya.com)
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

# Stop Slop

Eliminate predictable AI writing patterns from prose.

## Core Rules

1. **Cut filler phrases.** Remove throat-clearing openers, emphasis crutches, and all adverbs. See [references/phrases.md](references/phrases.md).

2. **Break formulaic structures.** Avoid binary contrasts, negative listings, dramatic fragmentation, rhetorical setups, false agency. See [references/structures.md](references/structures.md).

3. **Use active voice.** Every sentence needs a human subject doing something. No passive constructions. No inanimate objects performing human actions ("the complaint becomes a fix").

4. **Be specific.** No vague declaratives ("The reasons are structural"). Name the specific thing. No lazy extremes ("every," "always," "never") doing vague work.

5. **Put the reader in the room.** No narrator-from-a-distance voice. "You" beats "People." Specifics beat abstractions.

6. **Vary rhythm.** Mix sentence lengths. Two items beat three. End paragraphs differently. No em dashes.

7. **Trust readers.** State facts directly. Skip softening, justification, hand-holding.

8. **Cut quotables.** If it sounds like a pull-quote, rewrite it.

## Quick Checks

Before delivering prose:

- Any adverbs? Kill them.
- Any passive voice? Find the actor, make them the subject.
- Inanimate thing doing a human verb ("the decision emerges")? Name the person.
- Sentence starts with a Wh- word? Restructure it.
- Any "here's what/this/that" throat-clearing? Cut to the point.
- Any "not X, it's Y" contrasts? State Y directly.
- Three consecutive sentences match length? Break one.
- Paragraph ends with punchy one-liner? Vary it.
- Em-dash anywhere? Remove it.
- Vague declarative ("The implications are significant")? Name the specific implication.
- Narrator-from-a-distance ("Nobody designed this")? Put the reader in the scene.
- Meta-joiners ("The rest of this essay...")? Delete. Let the essay move.

## Scoring

Rate 1-10 on each dimension:

| Dimension | Question |
|-----------|----------|
| Directness | Statements or announcements? |
| Rhythm | Varied or metronomic? |
| Trust | Respects reader intelligence? |
| Authenticity | Sounds human? |
| Density | Anything cuttable? |

Below 35/50: revise.

## Examples

See [references/examples.md](references/examples.md) for before/after transformations.

## License

MIT
