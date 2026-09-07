#!/usr/bin/env bats
# Wiring-drift guard for the qa plugin's hooks.json: a typo'd path or a renamed
# script makes a hook exit non-zero and the gate silently stops gating, so the
# wiring itself is pinned here. Catches both directions of drift (a wired script
# that is missing, and a gate script added without wiring).

setup() {
  HOOKS_DIR="$BATS_TEST_DIRNAME/.."
  HOOKS_JSON="$HOOKS_DIR/hooks.json"
}

# Every (event, matcher, script-basename) tuple, sorted, pipe-delimited.
tuples() {
  jq -r '
    .hooks | to_entries[] as $e
    | $e.value[] as $entry
    | $entry.hooks[]
    | [$e.key, ($entry.matcher // ""), (.command | split("/") | last)]
    | join("|")
  ' "$HOOKS_JSON" | sort
}

@test "the Bash build gate is wired to BOTH PostToolUse and PostToolUseFailure" {
  # PostToolUse fires only for a SUCCESSFUL tool call, verified on CLI 2.1.261.
  # Without the failure event, `sed -i src/app.py && npm test` with a failing test
  # writes source and the gate never runs. This pins both registrations so the
  # bypass cannot come back by someone deleting the one that looks redundant.
  for ev in PostToolUse PostToolUseFailure; do
    run jq -e --arg e "$ev" '
      .hooks[$e] | map(select(.matcher == "Bash")
      | .hooks[] | select(.command | endswith("qa-plan-bash-build-gate.sh"))) | length == 1
    ' "$HOOKS_JSON"
    [ "$status" -eq 0 ]
  done
}

@test "the Bash build gate declares a timeout (it shells out on every Bash call)" {
  run jq -e '[.hooks.PostToolUse[], .hooks.PostToolUseFailure[]]
             | map(select(.matcher == "Bash") | .hooks[]
             | select(.command | endswith("qa-plan-bash-build-gate.sh")))
             | length > 0 and all(.timeout != null)' "$HOOKS_JSON"
  [ "$status" -eq 0 ]
}

@test "hooks.json is valid JSON with a top-level hooks object" {
  run jq -e '.hooks | type == "object"' "$HOOKS_JSON"
  [ "$status" -eq 0 ]
}

@test "wiring matches the golden tuple set exactly" {
  expected=$(printf '%s\n' \
    'PostToolUse|AskUserQuestion|qa-plan-approval-token.sh' \
    'PostToolUse|Bash|qa-plan-bash-build-gate.sh' \
    'PostToolUseFailure|Bash|qa-plan-bash-build-gate.sh' \
    'PreToolUse|AskUserQuestion|qa-plan-present-gate.sh' \
    'PreToolUse|Bash|qa-plan-pr-gate.sh' \
    'PreToolUse|Edit|MultiEdit|Write|qa-plan-build-gate.sh' \
    'Stop||qa-status-gate.sh' \
    'UserPromptSubmit||qa-plan-prompt-override.sh' \
    | sort)
  run tuples
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "every wired command uses the quoted CLAUDE_PLUGIN_ROOT prefix" {
  run jq -r '.hooks[][].hooks[].command' "$HOOKS_JSON"
  [ "$status" -eq 0 ]
  while IFS= read -r cmd; do
    # case/esac, not `[[ ]]`: a failing `[[ ]]` above another line is a silent
    # no-op under bats-core 1.13 (errexit does not fire for the keyword there).
    case "$cmd" in "\"\${CLAUDE_PLUGIN_ROOT}\""/hooks/scripts/*) ;; *) false ;; esac
  done <<< "$output"
}

@test "every wired script exists in hooks/scripts and is executable" {
  run jq -r '.hooks[][].hooks[].command | split("/") | last' "$HOOKS_JSON"
  [ "$status" -eq 0 ]
  while IFS= read -r script; do
    [ -x "$HOOKS_DIR/scripts/$script" ]
  done <<< "$output"
}

@test "every event-shaped gate script in hooks/scripts is wired (no orphans)" {
  # Utilities and sourced libs are exempt: they are not event hooks. Libs are
  # matched by the *-lib.sh SUFFIX rather than listed by name, so adding one
  # does not require editing this test (gate-policy-lib.sh broke it that way).
  # Only non-lib utilities still need naming.
  exempt="qa-plan-stamp.sh"
  wired=$(jq -r '.hooks[][].hooks[].command | split("/") | last' "$HOOKS_JSON")
  for f in "$HOOKS_DIR"/scripts/*.sh; do
    base=$(basename "$f")
    case "$base" in *-lib.sh) continue ;; esac
    case " $exempt " in *" $base "*) continue ;; esac
    grep -qx "$base" <<< "$wired"
  done
}
