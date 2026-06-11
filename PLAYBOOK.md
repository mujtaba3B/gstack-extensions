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
