#!/usr/bin/env bats
# Integration tests for the pr-merge-gate.sh PreToolUse hook. Drives the real hook
# with sample tool-call payloads and asserts allow (silent, exit 0) vs block
# (decision JSON on stdout). Temp repos must live under ~/dev because the gate is
# scoped to that tree; they are removed in teardown.

setup() {
  # Hermetic: pin the gate-policy lookup at a path that cannot exist, so these
  # tests exercise the MARKER-FALLBACK contract (a machine with no gate policy)
  # deterministically, instead of inheriting whatever ~/dev/gate-policy.json this
  # machine happens to carry. Inheritance-by-default is covered end-to-end in
  # gate-inheritance.bats.
  export GATE_POLICY_TEST=1   # env overrides are honored only in test mode
  export GATE_POLICY_FILE="$BATS_TEST_TMPDIR/no-such-gate-policy.json"
  export GATE_LOCAL_FILE="$BATS_TEST_TMPDIR/no-such-gate-local.json"
  GATE="$BATS_TEST_DIRNAME/../scripts/pr-merge-gate.sh"
  mkdir -p "$HOME/dev"   # hermetic on clean runners: the gate scopes to ~/dev
  REPO=$(mktemp -d "$HOME/dev/.mctest.XXXXXX")
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Test User"
  git -C "$REPO" config user.email "t@example.com"
  git -C "$REPO" commit -q --allow-empty -m init
  HEAD=$(git -C "$REPO" rev-parse HEAD)
  GITDIR=$(git -C "$REPO" rev-parse --absolute-git-dir)
  NOW=$(date +%s)
}

teardown() { rm -rf "$REPO" "${REPO2:-/nonexistent}"; }

# emit a PreToolUse payload for a Bash command
payload() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

# Arming is now a POLICY write, not a marker file. Markers were dropped entirely on
# 2026-09-02: a machine-local, git-ignored file that arms enforcement is what
# produced the worktree hole. `opt_in` keeps its meaning (this repo is governed);
# only the mechanism changed, so every test below reads the same.
# With no policy written, nothing is governed, which preserves the "allow" cases.
gp_write_policy() {  # <gate> <config-json>
  mkdir -p "$(dirname "$GATE_POLICY_FILE")"
  jq -nc --arg g "$1" --argjson c "$2" --arg root "$HOME/dev" \
    '{scope:{root:$root, exclude_path_prefixes:[], exclude_nested:false},
      defaults:{($g): $c}, overrides:{}}' > "$GATE_POLICY_FILE"
}
opt_in()  { gp_write_policy merge-clearance '{"base_branches":["main"]}'; }
stamp()   { printf '{"head":"%s","checked_at_epoch":%s,"ttl_seconds":600,"tool":"land-and-deploy"}' "$1" "$2" > "$GITDIR/merge-clearance-head"; }
# ld_sentinel <head> <epoch>: the /land-and-deploy sentinel. repo/pr left as the
# test repo has no remote (gate resolves target_repo="" -> repo match skipped) and
# no PR (target_pr="" -> pr match skipped); head_sha is the binding under test.
ld_sentinel() { printf '{"set_at_epoch":%s,"ttl_seconds":1800,"repo":"owner/name","head_sha":"%s","pr_number":"","source":"skill"}' "$2" "$1" > "$GITDIR/land-deploy-clearance"; }

@test "allow: non-merge command is ignored" {
  run bash -c "printf '%s' '$(payload "git status")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "allow: merge in a non-dev repo (out of scope)" {
  run bash -c "printf '%s' '$(payload "cd /tmp && gh pr merge 5")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "allow: ~/dev repo not covered by any gate policy" {
  run bash -c "printf '%s' '$(payload "cd $REPO && gh pr merge")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "block: opted-in repo with no clearance stamp" {
  opt_in
  run bash -c "printf '%s' '$(payload "cd $REPO && gh pr merge")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "allow: opted-in repo with a valid stamp AND matching land-deploy sentinel" {
  opt_in; stamp "$HEAD" "$NOW"; ld_sentinel "$HEAD" "$NOW"
  run bash -c "printf '%s' '$(payload "cd $REPO && gh pr merge")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "block: valid stamp but NO sentinel (bare merge / manual clear is not a path)" {
  opt_in; stamp "$HEAD" "$NOW"
  run bash -c "printf '%s' '$(payload "cd $REPO && gh pr merge")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
  echo "$output" | grep -q 'land-and-deploy'
}

@test "block: valid stamp + expired sentinel" {
  opt_in; stamp "$HEAD" "$NOW"; ld_sentinel "$HEAD" "$((NOW-2000))"
  run bash -c "printf '%s' '$(payload "cd $REPO && gh pr merge")' | bash '$GATE'"
  echo "$output" | grep -q '"decision":"block"'
}

@test "block: valid stamp + head-mismatched sentinel (sentinel for an older commit)" {
  opt_in; stamp "$HEAD" "$NOW"; ld_sentinel "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$NOW"
  run bash -c "printf '%s' '$(payload "cd $REPO && gh pr merge")' | bash '$GATE'"
  echo "$output" | grep -q '"decision":"block"'
}

@test "block: opted-in repo with an expired stamp" {
  opt_in; stamp "$HEAD" "$((NOW-700))"
  run bash -c "printf '%s' '$(payload "cd $REPO && gh pr merge")' | bash '$GATE'"
  echo "$output" | grep -q '"decision":"block"'
}

@test "block: opted-in repo with a stale-head stamp (wrong sha)" {
  opt_in; stamp "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$NOW"
  run bash -c "printf '%s' '$(payload "cd $REPO && gh pr merge")' | bash '$GATE'"
  echo "$output" | grep -q '"decision":"block"'
}

@test "allow: trigger phrase inside a quoted string is not command position" {
  opt_in
  run bash -c "printf '%s' '$(payload "cd $REPO; echo do gh pr merge soon")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "block: env-var prefix before gh is still caught (no stamp)" {
  opt_in
  run bash -c "printf '%s' '$(payload "cd $REPO && FOO=1 gh pr merge")' | bash '$GATE'"
  echo "$output" | grep -q '"decision":"block"'
}

@test "block: absolute path to gh is still caught (no stamp)" {
  opt_in
  run bash -c "printf '%s' '$(payload "cd $REPO && /opt/homebrew/bin/gh pr merge")' | bash '$GATE'"
  echo "$output" | grep -q '"decision":"block"'
}

@test "block: an EMPTY env-var prefix before gh is still caught (no stamp)" {
  # Regression. The command-position prefix required a non-empty assignment
  # value ([^[:space:]]+), so `FOO= gh pr merge` matched neither the bare form
  # (no shell separator before gh) nor the env-prefixed one, and sailed through.
  # Found while building deploy-gate.sh, which copied this same prefix; the
  # quantifier is now `*` in every gate that carries it.
  opt_in
  run bash -c "printf '%s' '$(payload "cd $REPO && FOO= gh pr merge")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "merge gate: sibling lib resolution ignores a bogus CLAUDE_PLUGIN_ROOT (env-independence)" {
  opt_in
  run bash -c "cd '$REPO' && CLAUDE_PLUGIN_ROOT=/nonexistent/other-plugin printf '%s' '$(payload "gh pr merge 1 --squash")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision":"block"'* ]]
}
