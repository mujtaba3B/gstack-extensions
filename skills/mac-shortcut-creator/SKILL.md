---
name: mac-shortcut-creator
description: >-
  Create a macOS/iOS Shortcut programmatically from a spec, without the user hand-building it in
  Shortcuts.app. Authors the workflow as a plist, signs it into a .shortcut file, opens it for the
  one mandatory "Add Shortcut" click, then verifies it runs. Use this whenever you need to wire up
  a Shortcut for the user, especially a "Run Shell Script" bridge that lets a Shortcut, the menu
  bar, a hotkey, or Siri invoke a CLI or script. Trigger on "create a shortcut", "make a Shortcuts
  workflow", "add a Shortcut that runs my script", "bridge this CLI to Shortcuts", "wire X into
  Shortcuts.app", or any request to generate/build/install an Apple Shortcut from code.
---

# mac-shortcut-creator

Build a signed `.shortcut` file from a spec so the user does not have to assemble actions by hand
in Shortcuts.app. The macOS `shortcuts` CLI can `run`/`list`/`view`/`sign` but **cannot** create or
import, so the final "Add Shortcut" click is a mandatory user step. Everything up to that click is
automatable, and so is verification afterward.

The most common use is a **Run Shell Script bridge**: a one-action Shortcut that pipes its input to
a CLI or script you already built, so it can be triggered from the menu bar, a hotkey, Siri, or the
Shortcuts widget. For that case read `references/RUN_SHELL_SCRIPT.md` after this file.

## Workflow

1. **Build** the plist XML (actions, UUIDs, variable references, metadata) and write it to a working
   file whose name ends in **`.shortcut`** (see the crux below). The working/input filename does not
   matter, e.g. `build.shortcut`.
2. **Sign** it, writing the output to a file named **exactly the final Shortcut name** plus
   `.shortcut`:
   ```bash
   shortcuts sign --mode anyone --input "build.shortcut" --output "<ExactName>.shortcut"
   ```
   The imported Shortcut takes its name from the **output filename**, not from the `WFWorkflowName`
   key inside the plist (verified: signing to `Foo_signed.shortcut` imports as "Foo_signed"). So name
   the output file what you want the Shortcut called: no `_signed` suffix.
   `--mode anyone` produces a file importable on any machine. Exit code 0 plus a signed file of
   roughly 15-25 KB (starting with `AEA1`) means success. You will see harmless lines on stderr that
   begin with `ERROR: Unrecognized attribute string flag ...`: despite the `ERROR:` prefix, signing
   still exits 0 and the file is valid. Ignore them; trust the exit code and the `AEA1` check.
3. **Open** the signed file to hand off to the user:
   ```bash
   open "<ExactName>.shortcut"
   ```
4. **STOP and wait.** Shortcuts.app shows an "Add Shortcut" sheet. Only the user can click it; there
   is no CLI for import. Tell the user exactly what to click, then wait for them to confirm before
   continuing. Do not claim the Shortcut is installed until they confirm.
5. **Verify** once they confirm. `shortcuts list` can lag a few seconds after import, so poll it:
   ```bash
   shortcuts list | grep -F "<ExactName>"                                        # confirms it imported
   echo "<sample input>" | shortcuts run "<ExactName>" --input-path - --output-path -   # confirms it runs
   ```
   Note `--input-path -`: `shortcuts run` reads input from `--input-path` (`-` = stdin), NOT from a
   bare pipe. Without it the Shortcut runs with no input. Report the actual `shortcuts run` output.
   Never hardcode a "verified" string (see the project rule on unverified success claims).

### The crux: the file MUST end in `.shortcut`

`shortcuts sign` rejects a `.plist` input with "isn't in the correct format". The file you sign must
have a **`.shortcut`** extension even though its contents are a plist. This is the single most common
blocker; get it right first.

You can write the plist as XML and sign it directly: signing handles the binary conversion. Writing a
binary plist also works (`plutil -convert binary1 <file>.shortcut`), but it is optional, not required.

### Same-name re-import makes "Name 2"

If a Shortcut with the same name already exists, importing again creates a second one named
"<Name> 2" rather than overwriting. Before re-importing during iteration, check
`shortcuts list | grep -F "<Name>"`; if it already exists, tell the user to delete the old one in
Shortcuts.app first (right-click -> Delete) so the name stays clean.

## Quick reference

### Plist structure

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>WFWorkflowActions</key>
    <array><!-- actions --></array>
    <key>WFWorkflowClientVersion</key><string>2700.0.4</string>
    <key>WFWorkflowMinimumClientVersion</key><integer>900</integer>
    <key>WFWorkflowMinimumClientVersionString</key><string>900</string>
    <key>WFWorkflowIcon</key>
    <dict>
        <key>WFWorkflowIconGlyphNumber</key><integer>59511</integer>
        <key>WFWorkflowIconStartColor</key><integer>4282601983</integer>
    </dict>
    <key>WFWorkflowHasOutputFallback</key><false/>
    <key>WFWorkflowImportQuestions</key><array/>
    <key>WFWorkflowInputContentItemClasses</key><array/>
    <key>WFWorkflowOutputContentItemClasses</key><array/>
    <key>WFWorkflowTypes</key><array/>
    <key>WFWorkflowName</key><string>My Shortcut</string>
</dict>
</plist>
```

### Action structure

```xml
<dict>
    <key>WFWorkflowActionIdentifier</key>
    <string>is.workflow.actions.showresult</string>
    <key>WFWorkflowActionParameters</key>
    <dict>
        <key>UUID</key>
        <string>A1B2C3D4-E5F6-7890-ABCD-EF1234567890</string>
        <!-- action-specific params -->
    </dict>
</dict>
```

### Variable references

Source action needs a `UUID`. Consumer references it via `OutputUUID` in `attachmentsByRange`.
Placeholder char: `￼` (U+FFFC). Range format: `{position, 1}`.

```xml
<key>Text</key>
<dict>
    <key>Value</key>
    <dict>
        <key>attachmentsByRange</key>
        <dict>
            <key>{0, 1}</key>
            <dict>
                <key>OutputName</key><string>Text</string>
                <key>OutputUUID</key><string>SOURCE-UUID</string>
                <key>Type</key><string>ActionOutput</string>
            </dict>
        </dict>
        <key>string</key><string>￼</string>
    </dict>
    <key>WFSerializationType</key><string>WFTextTokenString</string>
</dict>
```

Single variable (no surrounding text): use `WFTextTokenAttachment` instead of `WFTextTokenString`.

### Control flow

- `GroupingIdentifier`: a UUID linking start/middle/end of a block.
- `WFControlFlowMode`: `<integer>0</integer>` = start, `1` = middle (else/case), `2` = end.
  **Must be `<integer>`, not `<string>`.**
- Repeat: `is.workflow.actions.repeat.count` / `repeat.each`.
- Conditional: `is.workflow.actions.conditional`.
- Menu: `is.workflow.actions.choosefrommenu`.

### Common actions

| Action | Identifier (prefix `is.workflow.actions.`) | Key params |
|--------|-----------|------------|
| Text | `gettext` | `WFTextActionText` |
| Show Result | `showresult` | `Text` |
| Ask Input | `ask` | `WFAskActionPrompt`, `WFInputType` |
| AI/LLM | `askllm` | `WFLLMPrompt`, `WFLLMModel`, `WFGenerativeResultType` |
| URL | `url` | `WFURLActionURL` |
| HTTP Request | `downloadurl` | `WFURL`, `WFHTTPMethod`, `WFHTTPBodyType` |
| Open App | `openapp` | `WFAppIdentifier` |
| Alert | `alert` | `WFAlertActionTitle`, `WFAlertActionMessage` |
| Run Shell Script | `runshellscript` | `Shell`, `Script`, `Input`, `InputType` (see `references/RUN_SHELL_SCRIPT.md`) |
| Find Photos | `filter.photos` | `WFContentItemFilter` |
| Current Weather | `weather.currentconditions` | (none) |

### Key rules

1. UUIDs must be **uppercase**.
2. `WFControlFlowMode` is an **integer**.
3. Range keys are `{position, length}`; length is always 1.
4. `￼` (U+FFFC) marks each variable insertion point.
5. Every control-flow start needs a matching end with the same `GroupingIdentifier`.
6. Screenshots filter: use the `Is a Screenshot` boolean, NOT `Media Type = Screenshot`.
7. Delete photos param is `photos` (lowercase), not `WFInput`.

## Platform notes (verified macOS 26 / Darwin 25.x, 2026-06-02)

- The `shortcuts` CLI has only `run` / `list` / `view` / `sign`. No create, no import. The "Add
  Shortcut" click is unavoidable.
- Scripts run from a Run Shell Script action get a **stripped `PATH`**: invoke binaries by absolute
  path (e.g. `/opt/homebrew/bin/...`), or set `PATH` at the top of the script.
- The `.shortcut` extension on the signing input is mandatory (the crux above).
- The **signed** output is an Apple Encrypted Archive (magic bytes `AEA1`), not a plain plist, so
  `plutil` cannot read it back. The unsigned input you author is a plist; the signed output is a
  wrapped container. A signed file of ~15-25 KB starting with `AEA1` is the success signature.
- For a Shortcut that **receives external input** (any bridge that acts on the input you pass it),
  the empty `<key>WFWorkflowInputContentItemClasses</key><array/>` in the template above is not
  enough: it must list accepted classes (e.g. `WFStringContentItem`), and the action that consumes
  the input must reference the Shortcut Input (`ExtensionInput`) variable. Verified: a bridge with an
  empty input-classes array runs but its input never arrives. See `references/RUN_SHELL_SCRIPT.md`.

## Detailed references

Read these from `references/` only when you need detail beyond this file:

- `references/RUN_SHELL_SCRIPT.md`: the Run Shell Script bridge recipe (read this for any CLI bridge).
- `references/PLIST_FORMAT.md`: full plist structure and root keys.
- `references/ACTIONS.md`: all documented `is.workflow.actions.*` identifiers (360+).
- `references/APPINTENTS.md`: AppIntent actions organized by app (700+).
- `references/MESSAGES.md`: Messages/iMessage actions.
- `references/PARAMETER_TYPES.md`: parameter value types and serialization.
- `references/VARIABLES.md`: the UUID-based variable reference system.
- `references/CONTROL_FLOW.md`: repeat, conditional, and menu patterns.
- `references/FILTERS.md`: content filters for Find/Filter actions.
- `references/EXAMPLES.md`: complete worked examples.

## Building and verifying offline

`evals/build_and_sign.sh` builds a known-good Run Shell Script bridge plist, signs it, and asserts a
valid signed `.shortcut` came out (exit 0, non-trivial size, `AEA1` magic-byte check). It also
`plutil -lint`s the *unsigned* input (the signed output is an `AEA1` archive `plutil` cannot read).
Run it to confirm the build+sign half works on this machine before you hand a generated Shortcut to
the user. It does not import (no CLI exists for that); it isolates everything you can verify without
the click.
