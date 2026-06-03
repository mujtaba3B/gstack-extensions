# eng:shortcut

A Claude Code skill that creates a macOS/iOS Shortcut programmatically from a spec, so an agent can
wire up a Shortcut without you hand-building it in Shortcuts.app. Its sweet spot is a **Run Shell
Script bridge**: a thin Shortcut that lets the menu bar, a hotkey, Siri, or a `shortcuts://` URL
invoke a CLI you already wrote.

## What it does

| Stage | Automated? | How |
|-------|-----------|-----|
| Author the workflow as a plist | yes | Agent writes plist XML from the action reference |
| Sign into a `.shortcut` file | yes | `shortcuts sign --mode anyone` |
| Open for import | yes | `open <file>` |
| Click "Add Shortcut" | **no** | Mandatory manual step (no CLI exists to import) |
| Verify it runs | yes | `shortcuts list` + `shortcuts run` |

The macOS `shortcuts` CLI can `run`/`list`/`view`/`sign` but cannot create or import, so the final
click is the one thing the agent hands back to you.

## Layout

| Path | Purpose |
|------|---------|
| `SKILL.md` | Entry point: workflow, the `.shortcut`-extension crux, quick reference, key rules |
| `references/RUN_SHELL_SCRIPT.md` | The Run Shell Script bridge recipe (read for any CLI bridge) |
| `references/` | Plist format, 360+ actions, 700+ AppIntents, variables, control flow, filters, examples |
| `evals/build_and_sign.sh` | Verifies the build+sign stage works on your machine |
| `NOTICE.md` | Provenance and attribution (vendored upstream + local additions) |

## Verify it works

```bash
./evals/build_and_sign.sh
```

Builds a known-good bridge plist, signs it, and asserts a valid signed `.shortcut` (an `AEA1`
archive, ~20 KB) came out. It does not import (that needs the manual click).

## Attribution

The plist reference material and core signing technique are vendored from
[`cranecj/shortcuts-generator`](https://github.com/cranecj/shortcuts-generator) (MIT), which builds
on Drew Carr's `generate-shortcuts-skill`. See `NOTICE.md` for details and the list of local
additions. Licensed MIT (`LICENSE`).
