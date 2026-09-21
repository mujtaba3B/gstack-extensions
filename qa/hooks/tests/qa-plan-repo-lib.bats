#!/usr/bin/env bats
# Tests for qa-plan-repo-lib.sh (the QA-plan PR gate's cross-cwd repo resolver) and
# for the PR gate hook's out-of-~/dev binding that uses it. The pure parsers are unit
# tested; the resolver and the hook binding need real ~/dev repos + worktrees, so those
# temp repos live under ~/dev (the gates are scoped to that tree) and are removed in
# teardown. Mirrors the ~/dev-scoped-binding tests in eng/hooks/tests/ship-pr-gate.bats.

setup() {
  export GATE_POLICY_TEST=1   # env overrides honored only in test mode
  export GATE_POLICY_FILE="$BATS_TEST_TMPDIR/gate-policy.json"
  export GATE_LOCAL_FILE="$BATS_TEST_TMPDIR/no-such-gate-local.json"
  # Relocate the config root so the gate's audit log is hermetic and assertable.
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/.claude"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  RLIB="$BATS_TEST_DIRNAME/../scripts/qa-plan-repo-lib.sh"
  GPLIB="$BATS_TEST_DIRNAME/../scripts/gate-policy-lib.sh"
  PR_GATE="$BATS_TEST_DIRNAME/../scripts/qa-plan-pr-gate.sh"
  # shellcheck source=/dev/null
  . "$RLIB"
  # shellcheck source=/dev/null
  . "$GPLIB"
  mkdir -p "$HOME/dev"
  # A unique origin so the ~/dev walk binds to THIS repo and nothing else on the host.
  ORIGIN="qpgtest-$$-owner/qpgtest-repo"
  REPO=$(mktemp -d "$HOME/dev/.qpgrepotest.XXXXXX")
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Test User"
  git -C "$REPO" config user.email "t@example.com"
  git -C "$REPO" remote add origin "https://github.com/$ORIGIN.git"
  git -C "$REPO" commit -q --allow-empty -m init
  git -C "$REPO" branch -M main
  git -C "$REPO" checkout -q -b feat/thing
  GITDIR=$(git -C "$REPO" rev-parse --absolute-git-dir)
}

teardown() {
  [ -n "${WT:-}" ] && git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
  rm -rf "$REPO"
}

assert_contains() { case "$1" in *"$2"*) return 0 ;; esac; echo "want substring: $2" >&2; echo "actual: $1" >&2; return 1; }

gp_write_policy() {  # <gate> <config-json>
  jq -nc --arg g "$1" --argjson c "$2" --arg root "$HOME/dev" \
    '{scope:{root:$root, exclude_path_prefixes:[], exclude_nested:false},
      defaults:{($g): $c}, overrides:{}}' > "$GATE_POLICY_FILE"
}
opt_in() { gp_write_policy qa-plan "${1:-{\"base_branches\":[\"main\"]}}"; }
stamp_for() { printf '{"branch":"%s","approved_at":"x","approved_at_epoch":1,"head_at_approval":"y","criteria_digest":"d","approver":"a","approval_source":"AskUserQuestion","approval_nonce":"n","tool":"qa-plan"}' "$1" > "$GITDIR/qa-plan-approved"; }
create_payload() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

# ========================================================================
# Pure: qpg_norm_repo
# ========================================================================

@test "norm_repo: https, scp, host-prefixed and bare forms all fold to owner/name" {
  [ "$(qpg_norm_repo "https://github.com/Owner/Name.git")" = "owner/name" ]
  [ "$(qpg_norm_repo "git@github.com:Owner/Name.git")" = "owner/name" ]
  [ "$(qpg_norm_repo "github.com/owner/name")" = "owner/name" ]
  [ "$(qpg_norm_repo "owner/name")" = "owner/name" ]
  [ "$(qpg_norm_repo "https://github.com/owner/name/")" = "owner/name" ]
}

# ========================================================================
# Pure: qpg_repo_from_flags  (mirrors eng sg_repo_from_flags)
# ========================================================================

@test "repo_from_flags: --repo / --repo= / -R / -RX / GH_REPO, last wins, else 1" {
  [ "$(qpg_repo_from_flags "gh pr create --repo owner/name --base main")" = "owner/name" ]
  [ "$(qpg_repo_from_flags "gh pr create --repo=owner/name")" = "owner/name" ]
  [ "$(qpg_repo_from_flags "gh pr create -R owner/name")" = "owner/name" ]
  [ "$(qpg_repo_from_flags "gh pr create -Rowner/name")" = "owner/name" ]
  [ "$(qpg_repo_from_flags "GH_REPO=owner/name gh pr create --base main")" = "owner/name" ]
  [ "$(qpg_repo_from_flags "gh pr create --repo owner/decoy --repo owner/real")" = "owner/real" ]
  run qpg_repo_from_flags "gh pr create --base main"
  [ "$status" -eq 1 ]
}

# ========================================================================
# Pure: qpg_head_branch_from_cmd
# ========================================================================

@test "head_branch_from_cmd: --head / -H / owner: prefix stripped, else 1" {
  [ "$(qpg_head_branch_from_cmd "gh pr create --head feat/x --base main")" = "feat/x" ]
  [ "$(qpg_head_branch_from_cmd "gh pr create --head=feat/x")" = "feat/x" ]
  [ "$(qpg_head_branch_from_cmd "gh pr create -H feat/x")" = "feat/x" ]
  [ "$(qpg_head_branch_from_cmd "gh pr create --head someone:feat/x")" = "feat/x" ]
  run qpg_head_branch_from_cmd "gh pr create --base main"
  [ "$status" -eq 1 ]
}

# ========================================================================
# Resolver: qpg_dev_worktree_for_repo_branch
# ========================================================================

@test "resolver: governed ~/dev checkout on the branch resolves to its git dir" {
  opt_in
  run qpg_dev_worktree_for_repo_branch "$ORIGIN" "feat/thing"
  [ "$status" -eq 0 ]
  assert_contains "$output" "$REPO"
  assert_contains "$output" "$GITDIR"
}

@test "resolver: a branch no worktree is on does NOT resolve" {
  opt_in
  run qpg_dev_worktree_for_repo_branch "$ORIGIN" "feat/absent"
  [ "$status" -eq 1 ]
}

@test "resolver: an UNgoverned checkout (no policy) does NOT resolve" {
  # No opt_in: gp_gate_config reports out of scope, so the checkout is skipped.
  run qpg_dev_worktree_for_repo_branch "$ORIGIN" "feat/thing"
  [ "$status" -eq 1 ]
}

@test "resolver: a linked worktree on the branch resolves to the worktree's own git dir" {
  opt_in
  WT="$HOME/dev/.qpgwt.$$"
  git -C "$REPO" worktree add -q "$WT" -b feat/linked
  WTGITDIR=$(git -C "$WT" rev-parse --absolute-git-dir)
  run qpg_dev_worktree_for_repo_branch "$ORIGIN" "feat/linked"
  [ "$status" -eq 0 ]
  assert_contains "$output" "$WT"
  assert_contains "$output" "$WTGITDIR"
}

# ========================================================================
# Hook: cross-cwd binding via qa-plan-pr-gate.sh (run from OUTSIDE ~/dev)
# ========================================================================

@test "hook cross-cwd BLOCK: --repo + --head bind to the ~/dev worktree, no stamp -> block" {
  opt_in
  run bash -c "cd '$BATS_TEST_TMPDIR' && printf '%s' '$(create_payload "gh pr create --repo $ORIGIN --head feat/thing --base main")' | bash '$PR_GATE'"
  [ "$status" -eq 0 ]
  assert_contains "$output" '"decision":"block"'
}

@test "hook cross-cwd ALLOW: same bind, a valid stamp in that worktree's git dir -> allow" {
  opt_in; stamp_for "feat/thing"
  run bash -c "cd '$BATS_TEST_TMPDIR' && printf '%s' '$(create_payload "gh pr create --repo $ORIGIN --head feat/thing --base main")' | bash '$PR_GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "hook cross-cwd out-of-scope: --repo but NO --head -> allow, logged" {
  opt_in
  run bash -c "cd '$BATS_TEST_TMPDIR' && printf '%s' '$(create_payload "gh pr create --repo $ORIGIN --base main")' | bash '$PR_GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  assert_contains "$(cat "$CLAUDE_CONFIG_DIR/qa-plan-gate.log" 2>/dev/null || echo)" "OUT-OF-SCOPE(no-bind)"
}

@test "hook cross-cwd out-of-scope: --repo names a repo with no governed ~/dev worktree -> allow" {
  opt_in
  run bash -c "cd '$BATS_TEST_TMPDIR' && printf '%s' '$(create_payload "gh pr create --repo nobody-$$/nowhere --head feat/thing --base main")' | bash '$PR_GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "hook cross-cwd out-of-scope: no --repo from outside ~/dev stays out of scope -> allow" {
  opt_in
  run bash -c "cd '$BATS_TEST_TMPDIR' && printf '%s' '$(create_payload "gh pr create --head feat/thing --base main")' | bash '$PR_GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

# ========================================================================
# Hook: --repo naming the cwd's own repo stays on the CLASSIC path
# ========================================================================

@test "hook classic: --repo naming THIS repo from inside it uses the cwd path (blocks, no stamp)" {
  opt_in
  run bash -c "printf '%s' '$(create_payload "cd $REPO && gh pr create --repo $ORIGIN --base main")' | bash '$PR_GATE'"
  [ "$status" -eq 0 ]
  assert_contains "$output" '"decision":"block"'
}

@test "hook cross-repo guard: --repo naming a DIFFERENT repo from inside a governed checkout does not clear via the cwd stamp" {
  # A valid stamp exists for THIS repo, but the create targets another repo that has no
  # governed ~/dev worktree, so the cwd stamp must not clear it: allow (out of scope),
  # never a false clear off the wrong repo's stamp.
  opt_in; stamp_for "feat/thing"
  run bash -c "printf '%s' '$(create_payload "cd $REPO && gh pr create --repo other-$$/elsewhere --head feat/thing --base main")' | bash '$PR_GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}
