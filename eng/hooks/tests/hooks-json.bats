#!/usr/bin/env bats
# Wiring-drift guard for the eng plugin's hooks.json: a typo'd path or a renamed
# script makes a hook exit non-zero and the gate silently stops gating, so the
# wiring itself is pinned here. Catches both directions of drift (a wired script
# that is missing, and a gate script added without wiring).

setup() {
  HOOKS_DIR="$BATS_TEST_DIRNAME/.."
  HOOKS_JSON="$HOOKS_DIR/hooks.json"
}

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
    'PostToolUse|Bash|review-skill-stamp.sh' \
    'PostToolUse|Bash|ship-watch-nudge.sh' \
    'PreToolUse|Bash|land-deploy-sentinel.sh' \
    'PreToolUse|Bash|pr-merge-gate.sh' \
    'PreToolUse|Bash|ship-gate-sentinel.sh' \
    'PreToolUse|Bash|ship-pr-gate.sh' \
    'PreToolUse|Skill|land-deploy-sentinel.sh' \
    'PreToolUse|Skill|ship-gate-sentinel.sh' \
    'UserPromptSubmit||land-deploy-sentinel.sh' \
    'UserPromptSubmit||ship-gate-sentinel.sh' \
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
  exempt="merge-clearance.sh merge-clearance-lib.sh apply-merge-clearance-protection.sh ship-pr-gate-lib.sh ship-gate-repo-lib.sh ship-gate-arm-lib.sh ship-completion-lib.sh ship-watch-nudge-lib.sh"
  wired=$(jq -r '.hooks[][].hooks[].command | split("/") | last' "$HOOKS_JSON")
  for f in "$HOOKS_DIR"/scripts/*.sh; do
    base=$(basename "$f")
    case " $exempt " in *" $base "*) continue ;; esac
    grep -qx "$base" <<< "$wired"
  done
}
