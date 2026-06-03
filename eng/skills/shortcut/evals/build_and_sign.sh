#!/bin/bash
# build_and_sign.sh: eval for the build+sign stage of mac-shortcut-creator.
#
# Proves the verifiable half of the skill works on this machine: author a
# Run Shell Script bridge plist, sign it with `shortcuts sign`, and assert a
# valid signed .shortcut came out. Import (the "Add Shortcut" click) has no CLI
# and is out of scope here by design.
#
# Exit 0 = all assertions passed. Non-zero = a stage failed (message on stderr).
# No arguments. Writes only to a temp dir, which it cleans up.

set -u

NAME="MacShortcutCreatorEval"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mac-shortcut-eval.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SRC="$WORK/$NAME.shortcut"          # plist contents, named .shortcut (the signing crux)
OUT="$WORK/${NAME}_signed.shortcut" # the signed output
PLIST_ONLY="$WORK/$NAME.plist"      # same content, wrong extension, for the negative check

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- Stage 1: author the bridge plist -------------------------------------
# One Run Shell Script action (stdin/arg tolerant) feeding a Show Result.
cat > "$SRC" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>WFWorkflowActions</key>
    <array>
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
echo "bridge received: $arg"</string>
            </dict>
        </dict>
    </array>
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
    <key>WFWorkflowInputContentItemClasses</key>
    <array>
        <string>WFStringContentItem</string>
        <string>WFURLContentItem</string>
        <string>WFNumberContentItem</string>
        <string>WFFileContentItem</string>
    </array>
    <key>WFWorkflowOutputContentItemClasses</key><array/>
    <key>WFWorkflowTypes</key><array/>
    <key>WFWorkflowName</key><string>MacShortcutCreatorEval</string>
</dict>
</plist>
PLIST

[ -s "$SRC" ] || fail "authored plist is empty"
plutil -lint "$SRC" >/dev/null 2>&1 || fail "authored plist is not well-formed (plutil -lint)"
pass "authored a well-formed bridge plist"

# --- Stage 2: the .shortcut-extension crux --------------------------------
# Signing a .plist must be rejected; signing the identical .shortcut must work.
cp "$SRC" "$PLIST_ONLY"
if shortcuts sign --mode anyone --input "$PLIST_ONLY" --output "$WORK/should_not_exist.shortcut" >/dev/null 2>&1; then
    echo "WARN: signing a .plist unexpectedly succeeded (upstream may have relaxed the extension check)" >&2
else
    pass "signing a .plist input is rejected (the .shortcut-extension crux holds)"
fi

# --- Stage 3: sign the .shortcut ------------------------------------------
# `shortcuts sign` prints harmless `ERROR: Unrecognized attribute string flag`
# ObjC lines to stderr but still exits 0; trust the exit code, not the stderr.
SIGN_ERR="$WORK/sign.stderr"
if ! shortcuts sign --mode anyone --input "$SRC" --output "$OUT" 2>"$SIGN_ERR"; then
    echo "--- sign stderr ---" >&2; cat "$SIGN_ERR" >&2
    fail "shortcuts sign exited non-zero"
fi
pass "shortcuts sign exited 0"

# --- Stage 4: assert a valid signed file ----------------------------------
[ -f "$OUT" ] || fail "signed output not created at $OUT"
SIZE=$(wc -c < "$OUT" | tr -d ' ')
[ "$SIZE" -ge 1000 ] || fail "signed file suspiciously small ($SIZE bytes); expected >= 1000"
pass "signed file exists and is $SIZE bytes"

# A signed .shortcut is NOT a bare plist: `shortcuts sign` wraps the plist in an
# Apple Encrypted Archive (magic bytes "AEA1"), so plutil can't read it directly.
# The AEA1 magic is the real success signature.
MAGIC=$(head -c 4 "$OUT")
[ "$MAGIC" = "AEA1" ] || fail "signed file is not an AEA-wrapped archive (got magic '$MAGIC', expected 'AEA1')"
pass "signed file is a valid AEA-wrapped Shortcut archive"

echo "ALL PASSED: build+sign produces a valid signed .shortcut ($SIZE bytes, AEA1 archive)"
