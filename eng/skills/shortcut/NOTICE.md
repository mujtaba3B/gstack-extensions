# Provenance and attribution

The plist-format reference material in `references/` (`ACTIONS.md`, `APPINTENTS.md`,
`CONTROL_FLOW.md`, `EXAMPLES.md`, `FILTERS.md`, `MESSAGES.md`, `PARAMETER_TYPES.md`,
`PLIST_FORMAT.md`, `VARIABLES.md`) and the core plist/signing technique were vendored
from an upstream open-source skill:

- **Source:** [`cranecj/shortcuts-generator`](https://github.com/cranecj/shortcuts-generator)
- **Commit:** `e89b026ad31df53395ec148b6cf493b6eebdbe2b`
- **License:** MIT (see `LICENSE`, preserved verbatim from upstream)
- **Vendored on:** 2026-06-02

`cranecj/shortcuts-generator` credits **Drew Carr (@drewocarr)**'s original
`generate-shortcuts-skill` for the foundational plist format documentation, variable
reference system, control flow patterns, filter docs, parameter types, and working
examples. That lineage is preserved here.

Upstream has no ongoing maintenance (single-commit repo, snapshot of the macOS
Shortcuts ToolKit SQLite database), so this is a vendored copy rather than a tracked
fork. To refresh the action reference when Apple ships new Shortcuts actions, re-extract
from the local ToolKit database rather than pulling upstream.

## Local additions (not from upstream)

The following are original to this skill and are not derived from the upstream source:

- `SKILL.md` workflow: the full `build -> sign -> open -> wait-for-"Add Shortcut" -> verify`
  loop, including the mandatory user-click handoff and `shortcuts run` verification.
- `references/RUN_SHELL_SCRIPT.md`: the Run Shell Script bridge recipe.
- Same-name re-import detection ("Name 2") guidance.
- macOS 26 / Darwin 25.x verification notes (the `.shortcut`-extension signing crux,
  binary-plist-optional note, harmless ObjC sign warnings, success heuristics).
- `evals/`: the build+sign verification harness.
