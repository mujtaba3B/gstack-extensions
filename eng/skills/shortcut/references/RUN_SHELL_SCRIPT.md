# Run Shell Script bridge

The most common reason to generate a Shortcut programmatically is to **bridge a CLI or script you
already built into Shortcuts.app**, so it can be triggered from the menu bar, a global hotkey, Siri,
the Shortcuts widget, or a `shortcuts://run-shortcut?name=...&input=...` URL (which a web page or
userscript can open). The Shortcut is a thin wrapper: one Run Shell Script action that calls your
binary and passes the Shortcut's input through.

## The `runshellscript` action

Identifier: `is.workflow.actions.runshellscript`. Parameters:

| Param | Type | Meaning |
|-------|------|---------|
| `Shell` | string | Shell path, e.g. `/bin/zsh` or `/bin/bash`. |
| `Script` | string | The script body (can embed variable references like any text param). |
| `InputType` | string | How the Shortcut's input reaches the script: `asArguments` (becomes `$1`, `$2`, ...) or `toStdin` (piped to stdin). |
| `Input` | variable | The input to feed in (usually the Shortcut Input variable). Omit for a no-input script. |

Action that runs a CLI, passing the Shortcut input as an argument. The **`Input` param must
reference the Shortcut Input (`ExtensionInput`) variable** or no input reaches the script:

```xml
<dict>
    <key>WFWorkflowActionIdentifier</key>
    <string>is.workflow.actions.runshellscript</string>
    <key>WFWorkflowActionParameters</key>
    <dict>
        <key>UUID</key>
        <string>1A2B3C4D-5E6F-7081-9A2B-3C4D5E6F7081</string>
        <key>Shell</key>
        <string>/bin/zsh</string>
        <key>InputType</key>
        <string>asArguments</string>
        <key>Input</key>
        <dict>
            <key>Value</key>
            <dict><key>Type</key><string>ExtensionInput</string></dict>
            <key>WFSerializationType</key><string>WFTextTokenAttachment</string>
        </dict>
        <key>Script</key>
        <string>arg="${1:-$(cat)}"
/opt/homebrew/bin/my-cli run "$arg" 2>&amp;1 | tail -20</string>
    </dict>
</dict>
```

Escape `&` as `&amp;`, `<` as `&lt;`, `>` as `&gt;` inside the `<string>` script body.

### The Shortcut must also declare it accepts input

Wiring `Input` to `ExtensionInput` is only half of it. The **root** plist key
`WFWorkflowInputContentItemClasses` must be non-empty, or the Shortcut declares it takes no input and
nothing arrives (verified: an empty `<array/>` there means the script's input is always empty, even
with the `Input` wiring above). List the classes the bridge should accept:

```xml
<key>WFWorkflowInputContentItemClasses</key>
<array>
    <string>WFStringContentItem</string>
    <string>WFURLContentItem</string>
    <string>WFNumberContentItem</string>
    <string>WFFileContentItem</string>
</array>
```

For a text bridge, `WFStringContentItem` alone is enough; the set above is a safe general default.

## Make the script tolerant: `arg="${1:-$(cat)}"`

Whether the Shortcut delivers input as an **argument** (`$1`) or on **stdin** depends on `InputType`
and on how the user wired "Pass Input". Rather than depend on getting that exactly right, make the
script accept either:

```sh
arg="${1:-$(cat)}"
```

This takes `$1` if present, else reads stdin. The same signed Shortcut then works whether input
arrives as an argument or a pipe, which removes the most common "it imported but does nothing" class
of bug. Build every bridge script this way unless you have a specific reason not to.

## Stripped PATH: use absolute paths

A script launched from a Run Shell Script action runs with a **stripped environment**: Homebrew,
nvm, pyenv, and `~/.local/bin` are not on `PATH`. Two robust options:

- Invoke binaries by absolute path: `/opt/homebrew/bin/python3`, `~/dev/app/.venv/bin/python`, etc.
- Or set `PATH` at the top of the script: `export PATH="/opt/homebrew/bin:$PATH"`.

If the CLI needs a working directory (to read `.env`, resolve relative paths, find a venv), `cd` there
first: `cd ~/dev/app && .venv/bin/python -m app.cli "$arg"`.

## Surface the output

A Run Shell Script action's result is not shown to the user by default. To make the result visible,
follow it with a Show Result (`is.workflow.actions.showresult`) or Show Notification action whose
input is the shell script's output. Piping the script through `| tail -20` keeps notifications short.

## Verifying a bridge

Build + sign with `evals/build_and_sign.sh` (or the workflow in `SKILL.md`), open the signed file,
have the user click "Add Shortcut", then:

```bash
echo "sample-input" | shortcuts run "<ExactName>" --input-path - --output-path -
```

`--input-path -` reads the Shortcut's input from stdin; `--output-path -` writes its output to
stdout. A bare pipe without `--input-path -` does NOT feed the Shortcut (the input is dropped), which
looks identical to a wiring bug, so always pass `--input-path -` when verifying input flow.

## Real-world reference

A working, manually-built equivalent lives in `~/dev/apps/email-hero/userscript/README.md`: the
`EmailHeroRunPipeline` Shortcut is a Run Shell Script bridge (Shell `zsh`, input passed as an
argument) whose script is:

```sh
cd ~/dev/email-hero && .venv/bin/python -m email_hero.cli run "$1" --dry-run 2>&1 | tail -20
```

A Gmail userscript opens `shortcuts://run-shortcut?name=EmailHeroRunPipeline&input=expensify-forward`,
which hands the automation name to the Shortcut as input. That is the pattern this skill automates:
generate and sign that wrapper instead of having the user assemble it by hand.
