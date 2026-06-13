# PLAYBOOK.md - how gstack-extensions runs its plays

The canonical, human-readable record of the repeatable things we do in this repo. Tracked in git on purpose: a durable process narrative and a build backlog, not agent scratch.

A **play** is a discrete repeatable thing we do. It is born as prose; it graduates into a skill once it recurs and proves out, at which point its entry keeps the *judgment* and points at the skill for the *mechanics*. The prose plays are the backlog of what to systematize next. `/close-out` harvests new plays at session end.

## Play format

```text
### Play: <name>
- **What / when:** one line
- **Status:** `skill: <name>`  |  `prose (candidate skill)`  |  `external: <tool>`
- **Notes:** the non-obvious judgment + gotchas worth not re-deriving
```

---

## Shipping

### Play: Ship a gstack-extensions change through the gate stack

- **What / when:** any tracked change to this repo (`main` carries soft branch protection: required check `local-review/merge-clearance`).
- **Status:** `skill chain: qa:qa-plan -> ship -> eng:cr -> land-and-deploy`
- **Notes:** the repo is opted into the QA-plan, ship-PR, and merge-clearance gates (machine-local markers; registry in `~/dev/gated-repos.json`). No root `VERSION` or test suite: per-plugin `plugin.json` versions are the release unit (bump major when a plugin gains/loses enforcement surface), and tests are the bats suites under `<plugin>/hooks/tests/`, run as INDIVIDUAL files (never a full-suite invocation on this machine). `/eng:cr` mints the merge-clearance stamp; CodeRabbit threads must be resolved before clearance.

## Packaging

### Play: Ship a gate inside a persona plugin (plugin-native hooks)

- **What / when:** adding or migrating an enforcement hook that belongs to a persona's workflow (QA gates -> qa plugin, PR-lifecycle gates -> eng plugin).
- **Status:** `prose (proven once, PR #32; candidate skill if a third persona gains hooks)`
- **Notes:** the hook ships as `<plugin>/hooks/scripts/<gate>.sh` wired by `<plugin>/hooks/hooks.json` with quoted `"${CLAUDE_PLUGIN_ROOT}"` commands; bats suites sit in `<plugin>/hooks/tests/` resolving scripts via `BATS_TEST_DIRNAME/../scripts/`. Path rule (Codex-confirmed): `CLAUDE_PLUGIN_ROOT` locates ENTRYPOINTS (hooks.json layer only); inside scripts, sibling libs resolve via `BASH_SOURCE` so the executing copy binds its own dependencies (the scripts are dual-use: skills, the shim, bats). Cross-plugin or shim lookups pick the HIGHEST cached version via `sort -V`, never mtime. A fixed-path consumer outside the plugin (e.g. `/land-and-deploy`) gets a shim written by `bin/install`, not a hardcoded cache path. Add a `hooks-json.bats` golden-tuple guard so wiring drift is caught. Swap sequencing: install + verify the plugin hooks fire (fresh `claude -p`) BEFORE removing any old wiring; gates must never be absent or double-fire mid-swap.

### Play: Borrow from official Anthropic skills via a soft pointer, not a hard dependency

- **What / when:** enriching one of our skills with guidance that an official Anthropic skill (claude-plugins-official marketplace, anthropics/skills repo) already articulates well (taste vocabulary, a direction menu, a structural pattern).
- **Status:** `prose (proven once, PR #37; candidate skill if a third borrow lands)`
- **Notes:** Claude Code plugins DO support a native `plugin.json` `dependencies` field that auto-installs a declared plugin, so a hard dependency is technically available. Do not reach for it when the thing you want is PROSE the agent reads (a `SKILL.md` of principles), not a callable API: a codex `/second-opinion` (confidence 4/5) argued that auto-installing a whole plugin to read one document is package-level coupling for document-level inspiration, and it hurts portability + reproducibility (output drifts with the installed upstream version, breaks on a clean machine). Instead reuse the repo's defer-when-present idiom (the same shape as `wireframes.md` deferring to a workspace override): ship a distilled local baseline that is complete on its own, plus an OPTIONAL runtime read of the official skill when a `find ~/.claude/plugins -path '*<skill>*/SKILL.md'` hit exists. Scope any borrowed rule to where it actually applies (frontend-design bans Inter outright; we scoped the anti-slop rule to DISPLAY fonts so a neutral body font stays legitimate, and said so in-file). Survey the official set first (`gh api repos/anthropics/skills/contents/skills`); second-opinion the coupling call before committing.

## Design

### Play: A style guide is a first-class artifact of every mockup

- **What / when:** any Pencil mockup work. `design:pencil-mockup` builds a `Style guide · <Project>` frame beside a new canvas and syncs it on style-changing edits; `design:style-guide` creates one from scratch (questionnaire -> research -> font option panels -> five-card frame).
- **Status:** `skill: design:pencil-mockup + design:style-guide` (PR #37)
- **Notes:** the five-card anatomy (display type, body type, color, buttons, logos) lives in ONE home, `pencil-mockup/references/wireframes.md`; everything else points there. The frame's panel title carries a 1-2 word named direction so the aesthetic is quotable later. Reference implementation: the Hackers & Healers frame in `hh-landing.pen`. `.pen` bootstrap gotcha: `batch_design` with a nonexistent `filePath` silently falls back to the ACTIVE editor, so a from-scratch file is copy-template -> open -> verify-active -> clear -> build.

### Play: Graduate an approved style guide into a per-project brand file

- **What / when:** after a style guide is approved on the Pencil canvas and the project needs the SAME visual language on non-Pencil surfaces (HTML prototypes, decks, emails, generated docs).
- **Status:** `prose (candidate skill)`
- **Notes:** the canvas style guide is the source of truth for the decisions; this play promotes it into a durable, machine-applicable per-project brand file so non-Pencil tools inherit the palette, type, and logos without re-deriving them. Reference shape: Anthropic's official `brand-guidelines` skill (colors + typography + smart application rules, applied to any artifact). Not built yet: the open questions are where the brand file lives (project repo `spec/brand/` vs a skill), and whether it graduates into a `design:*` skill or stays a per-project doc the existing skills read. Graduate to a skill once a second project needs it.
