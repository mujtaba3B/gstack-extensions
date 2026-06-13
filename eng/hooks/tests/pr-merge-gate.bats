#!/usr/bin/env bats
# Integration tests for the pr-merge-gate.sh PreToolUse hook. Drives the real hook
# with sample tool-call payloads and asserts allow (silent, exit 0) vs block
# (decision JSON on stdout). Temp repos must live under ~/dev because the gate is
# scoped to that tree; they are removed in teardown.

setup() {
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
opt_in()  { echo '{"base_branches":["main"]}' > "$REPO/.merge-clearance.json"; }
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

@test "allow: ~/dev repo without the opt-in marker" {
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

@test "merge gate: sibling lib resolution ignores a bogus CLAUDE_PLUGIN_ROOT (env-independence)" {
  opt_in
  run bash -c "cd '$REPO' && CLAUDE_PLUGIN_ROOT=/nonexistent/other-plugin printf '%s' '$(payload "gh pr merge 1 --squash")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision":"block"'* ]]
}
