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

@test "hooks.json is valid JSON with a top-level hooks object" {
  run jq -e '.hooks | type == "object"' "$HOOKS_JSON"
  [ "$status" -eq 0 ]
}

@test "wiring matches the golden tuple set exactly" {
  expected=$(printf '%s\n' \
    'PreToolUse|AskUserQuestion|qa-plan-present-gate.sh' \
    'PreToolUse|Bash|qa-plan-pr-gate.sh' \
    'PreToolUse|Edit|MultiEdit|Write|qa-plan-build-gate.sh' \
    'Stop||qa-status-gate.sh' \
    | sort)
  run tuples
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "every wired command uses the quoted CLAUDE_PLUGIN_ROOT prefix" {
  run jq -r '.hooks[][].hooks[].command' "$HOOKS_JSON"
  [ "$status" -eq 0 ]
  while IFS= read -r cmd; do
    [[ "$cmd" == "\"\${CLAUDE_PLUGIN_ROOT}\""/hooks/scripts/* ]]
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
  # Utilities and sourced libs are exempt: they are not event hooks.
  exempt="qa-plan-stamp.sh qa-plan-gate-lib.sh qa-status-gate-lib.sh"
  wired=$(jq -r '.hooks[][].hooks[].command | split("/") | last' "$HOOKS_JSON")
  for f in "$HOOKS_DIR"/scripts/*.sh; do
    base=$(basename "$f")
    case " $exempt " in *" $base "*) continue ;; esac
    grep -qx "$base" <<< "$wired"
  done
}
