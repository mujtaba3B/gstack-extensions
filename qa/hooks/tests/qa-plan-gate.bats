#!/usr/bin/env bats
# Tests for the QA-plan approval gates: the pure decision logic
# (qa-plan-gate-lib.sh), the build gate hook (qa-plan-build-gate.sh), the PR gate
# hook (qa-plan-pr-gate.sh), and the stamp writer (qa-plan-stamp.sh). Temp repos
# live under ~/dev because the gates are scoped to that tree; removed in teardown.

setup() {
  LIB="$BATS_TEST_DIRNAME/../scripts/qa-plan-gate-lib.sh"
  BUILD_GATE="$BATS_TEST_DIRNAME/../scripts/qa-plan-build-gate.sh"
  PR_GATE="$BATS_TEST_DIRNAME/../scripts/qa-plan-pr-gate.sh"
  STAMP="$BATS_TEST_DIRNAME/../scripts/qa-plan-stamp.sh"
  # shellcheck source=/dev/null
  . "$LIB"
  REPO=$(mktemp -d "$HOME/dev/.qpgtest.XXXXXX")
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Test User"
  git -C "$REPO" config user.email "t@example.com"
  git -C "$REPO" commit -q --allow-empty -m init
  git -C "$REPO" branch -M main   # normalize default branch name (some envs default to master)
  git -C "$REPO" checkout -q -b feat/thing
  GITDIR=$(git -C "$REPO" rev-parse --absolute-git-dir)
}

teardown() { rm -rf "$REPO"; }

# ---- helpers ----------------------------------------------------------------

opt_in()    { printf '%s' "${1:-{\"base_branches\":[\"main\"]}}" > "$REPO/.qa-plan-gate.json"; }
stamp_for() { printf '{"branch":"%s","approved_at":"x","approved_at_epoch":1,"head_at_approval":"y","criteria_digest":"d","approver":"a","tool":"qa-plan"}' "$1" > "$GITDIR/qa-plan-approved"; }
edit_payload() { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"},"cwd":"%s"}' "$1" "$REPO"; }
create_payload() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

# ========================================================================
# Pure: qpg_stamp_valid <stamp> <branch>
# ========================================================================

@test "stamp_valid: matching branch -> valid" {
  run qpg_stamp_valid '{"branch":"feat/x"}' "feat/x"
  [ "$output" = "valid" ]; [ "$status" -eq 0 ]
}

@test "stamp_valid: empty stamp -> no-stamp" {
  run qpg_stamp_valid "" "feat/x"
  [ "$output" = "no-stamp" ]; [ "$status" -eq 1 ]
}

@test "stamp_valid: corrupt json -> malformed" {
  run qpg_stamp_valid '{not json' "feat/x"
  [ "$output" = "malformed" ]; [ "$status" -eq 1 ]
}

@test "stamp_valid: stamp for a different branch -> wrong-branch" {
  run qpg_stamp_valid '{"branch":"feat/other"}' "feat/x"
  [ "$output" = "wrong-branch" ]; [ "$status" -eq 1 ]
}

# ========================================================================
# Pure: qpg_is_spike <branch>
# ========================================================================

@test "is_spike: spike/ prefix is a spike" {
  run qpg_is_spike "spike/poke-at-it"
  [ "$output" = "spike" ]; [ "$status" -eq 0 ]
}

@test "is_spike: feature branch is not a spike" {
  run qpg_is_spike "feat/thing"
  [ "$output" = "no" ]; [ "$status" -eq 1 ]
}

@test "is_spike: 'spike' as a substring does not bypass (only the prefix)" {
  run qpg_is_spike "fix-spike-handling"
  [ "$output" = "no" ]; [ "$status" -eq 1 ]
}

# ========================================================================
# Pure: qpg_path_needs_plan <path>
# ========================================================================

@test "path: a .py source file needs a plan" {
  run qpg_path_needs_plan "src/app/main.py"
  [ "$output" = "source" ]; [ "$status" -eq 0 ]
}

@test "path: markdown is carved out" {
  run qpg_path_needs_plan "docs/guide.md"
  [ "$output" = "carveout" ]; [ "$status" -eq 1 ]
}

@test "path: json config is carved out" {
  run qpg_path_needs_plan "config/settings.json"
  [ "$output" = "carveout" ]; [ "$status" -eq 1 ]
}

@test "path: a file under tests/ is carved out" {
  run qpg_path_needs_plan "tests/test_main.py"
  [ "$output" = "carveout" ]; [ "$status" -eq 1 ]
}

@test "path: a *_test.go basename is carved out even outside a tests dir" {
  run qpg_path_needs_plan "pkg/handler_test.go"
  [ "$output" = "carveout" ]; [ "$status" -eq 1 ]
}

@test "path: the gate's own marker is carved out" {
  run qpg_path_needs_plan ".qa-plan-gate.json"
  [ "$output" = "carveout" ]; [ "$status" -eq 1 ]
}

@test "path: a .ts file is source" {
  run qpg_path_needs_plan "lib/index.ts"
  [ "$output" = "source" ]; [ "$status" -eq 0 ]
}

# ========================================================================
# Pure: qpg_marker_gates / qpg_gate_enabled / qpg_base_in_scope
# ========================================================================

@test "marker_gates: silent marker enables all three" {
  run qpg_marker_gates '{"base_branches":["main"]}'
  [ "$output" = "build pr deploy" ]
}

@test "marker_gates: explicit subset is honored" {
  run qpg_marker_gates '{"gates":["deploy"]}'
  [ "$output" = "deploy" ]
}

@test "gate_enabled: deploy enabled when only deploy listed" {
  run qpg_gate_enabled '{"gates":["deploy"]}' deploy
  [ "$status" -eq 0 ]
}

@test "gate_enabled: build NOT enabled when only deploy listed" {
  run qpg_gate_enabled '{"gates":["deploy"]}' build
  [ "$status" -ne 0 ]
}

@test "base_in_scope: main in default scope" {
  run qpg_base_in_scope '{}' "main"
  [ "$output" = "in" ]; [ "$status" -eq 0 ]
}

@test "base_in_scope: a feature branch is out of the default base scope" {
  run qpg_base_in_scope '{}' "feat/thing"
  [ "$output" = "out" ]; [ "$status" -ne 0 ]
}

# ========================================================================
# Build gate hook: qa-plan-build-gate.sh
# ========================================================================

@test "build gate allow: ~/dev repo without the marker" {
  run bash -c "printf '%s' '$(edit_payload "$REPO/src/main.py")' | bash '$BUILD_GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "build gate block: opted-in, feature branch, source file, no stamp" {
  opt_in
  run bash -c "printf '%s' '$(edit_payload "$REPO/src/main.py")' | bash '$BUILD_GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "build gate allow: opted-in but editing a markdown carve-out" {
  opt_in
  run bash -c "printf '%s' '$(edit_payload "$REPO/README.md")' | bash '$BUILD_GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "build gate allow: opted-in with a valid stamp for the branch" {
  opt_in; stamp_for "feat/thing"
  run bash -c "printf '%s' '$(edit_payload "$REPO/src/main.py")' | bash '$BUILD_GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "build gate block: opted-in with a stamp for a DIFFERENT branch" {
  opt_in; stamp_for "feat/other"
  run bash -c "printf '%s' '$(edit_payload "$REPO/src/main.py")' | bash '$BUILD_GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "build gate allow: spike/ branch bypasses even without a stamp" {
  opt_in
  git -C "$REPO" checkout -q -b spike/poke
  run bash -c "printf '%s' '$(edit_payload "$REPO/src/main.py")' | bash '$BUILD_GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "build gate allow: on the base branch (main) there is no feature work to gate" {
  opt_in
  git -C "$REPO" checkout -q main
  run bash -c "printf '%s' '$(edit_payload "$REPO/src/main.py")' | bash '$BUILD_GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

# ========================================================================
# PR gate hook: qa-plan-pr-gate.sh
# ========================================================================

@test "pr gate allow: non-create command is ignored" {
  opt_in
  run bash -c "printf '%s' '$(create_payload "cd $REPO && git status")' | bash '$PR_GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "pr gate block: opted-in repo, feature branch, no stamp" {
  opt_in
  run bash -c "printf '%s' '$(create_payload "cd $REPO && gh pr create --base main")' | bash '$PR_GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "pr gate allow: opted-in repo with a valid stamp" {
  opt_in; stamp_for "feat/thing"
  run bash -c "printf '%s' '$(create_payload "cd $REPO && gh pr create --base main")' | bash '$PR_GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "pr gate allow: create targeting an out-of-scope base" {
  opt_in
  run bash -c "printf '%s' '$(create_payload "cd $REPO && gh pr create --base release")' | bash '$PR_GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "pr gate block: spike branch is NOT exempt at PR time" {
  opt_in
  git -C "$REPO" checkout -q -b spike/poke
  run bash -c "printf '%s' '$(create_payload "cd $REPO && gh pr create --base main")' | bash '$PR_GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

# ========================================================================
# Stamp writer: qa-plan-stamp.sh
# ========================================================================

@test "stamp writer: write then status round-trips the branch" {
  run bash -c "cd '$REPO' && bash '$STAMP' write --approver tester --digest abc123"
  [ "$status" -eq 0 ]
  [ -f "$GITDIR/qa-plan-approved" ]
  run bash -c "cd '$REPO' && bash '$STAMP' status"
  echo "$output" | grep -q '"branch":"feat/thing"'
  echo "$output" | grep -q "matches current branch"
}

@test "stamp writer: the gate accepts a stamp the writer produced" {
  opt_in
  bash -c "cd '$REPO' && bash '$STAMP' write >/dev/null"
  run bash -c "printf '%s' '$(edit_payload "$REPO/src/main.py")' | bash '$BUILD_GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "stamp writer: clear removes the stamp and the gate blocks again" {
  opt_in
  bash -c "cd '$REPO' && bash '$STAMP' write >/dev/null"
  bash -c "cd '$REPO' && bash '$STAMP' clear >/dev/null"
  run bash -c "printf '%s' '$(edit_payload "$REPO/src/main.py")' | bash '$BUILD_GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "build gate: sibling lib resolution ignores a bogus CLAUDE_PLUGIN_ROOT (env-independence)" {
  opt_in
  run bash -c "CLAUDE_PLUGIN_ROOT=/nonexistent/other-plugin printf '%s' '$(edit_payload "$REPO/src/main.py")' | bash '$BUILD_GATE'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision":"block"'* ]]
}
