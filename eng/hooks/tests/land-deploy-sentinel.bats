#!/usr/bin/env bats
# Tests for land-deploy-sentinel.sh: the writer that mints the
# <gitdir>/land-deploy-clearance sentinel when /land-and-deploy is invoked. Drives
# the real hook with synthetic Skill / UserPromptSubmit payloads and asserts the
# sentinel file is (or is not) written, and that it is target-bound (head_sha).
# Temp repos live under ~/dev because the hook scopes to that tree.

setup() {
  WRITER="$BATS_TEST_DIRNAME/../scripts/land-deploy-sentinel.sh"
  mkdir -p "$HOME/dev"
  REPO=$(mktemp -d "$HOME/dev/.ldtest.XXXXXX")
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Test User"
  git -C "$REPO" config user.email "t@example.com"
  git -C "$REPO" remote add origin "https://github.com/owner/name.git"
  git -C "$REPO" commit -q --allow-empty -m init
  HEAD=$(git -C "$REPO" rev-parse HEAD)
  GITDIR=$(git -C "$REPO" rev-parse --absolute-git-dir)
  SENTINEL="$GITDIR/land-deploy-clearance"
}

teardown() { rm -rf "$REPO"; }

skill_payload()  { printf '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"%s"},"cwd":"%s"}' "$1" "$REPO"; }
prompt_payload() { printf '{"hook_event_name":"UserPromptSubmit","prompt":"%s","cwd":"%s"}' "$1" "$REPO"; }

@test "writes a sentinel on a Skill invocation of land-and-deploy" {
  printf '%s' "$(skill_payload "land-and-deploy")" | bash "$WRITER"
  [ -f "$SENTINEL" ]
  [ "$(jq -r .head_sha "$SENTINEL")" = "$HEAD" ]
  [ "$(jq -r .repo "$SENTINEL")" = "owner/name" ]
  [ "$(jq -r .source "$SENTINEL")" = "skill" ]
}

@test "writes a sentinel on a namespaced skill id (eng:land-and-deploy)" {
  printf '%s' "$(skill_payload "eng:land-and-deploy")" | bash "$WRITER"
  [ -f "$SENTINEL" ]
  [ "$(jq -r .head_sha "$SENTINEL")" = "$HEAD" ]
}

@test "writes a sentinel on a prompt starting with /land-and-deploy" {
  printf '%s' "$(prompt_payload "/land-and-deploy")" | bash "$WRITER"
  [ -f "$SENTINEL" ]
  [ "$(jq -r .source "$SENTINEL")" = "prompt" ]
}

@test "captures the PR number from the prompt args (#123)" {
  printf '%s' "$(prompt_payload "/land-and-deploy #123 https://x.test")" | bash "$WRITER"
  [ -f "$SENTINEL" ]
  [ "$(jq -r .pr_number "$SENTINEL")" = "123" ]
}

@test "does NOT write for a different skill" {
  printf '%s' "$(skill_payload "ship")" | bash "$WRITER"
  [ ! -f "$SENTINEL" ]
}

@test "does NOT write when the prompt only mentions the command mid-sentence" {
  printf '%s' "$(prompt_payload "should I use /land-and-deploy here?")" | bash "$WRITER"
  [ ! -f "$SENTINEL" ]
}

@test "does NOT write for /land-and-deployer (whole-token match)" {
  printf '%s' "$(prompt_payload "/land-and-deployer")" | bash "$WRITER"
  [ ! -f "$SENTINEL" ]
}

@test "does NOT write for a repo outside ~/dev" {
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/ldout.XXXXXX")
  git -C "$OUT" init -q
  git -C "$OUT" commit -q --allow-empty -m init
  payload=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"land-and-deploy"},"cwd":"%s"}' "$OUT")
  printf '%s' "$payload" | bash "$WRITER"
  outgit=$(git -C "$OUT" rev-parse --absolute-git-dir)
  [ ! -f "$outgit/land-deploy-clearance" ]
  rm -rf "$OUT"
}

@test "sentinel always exits 0 and never emits stdout (it is the gate's input, not a gate)" {
  run bash -c "printf '%s' '$(skill_payload "land-and-deploy")' | bash '$WRITER'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
