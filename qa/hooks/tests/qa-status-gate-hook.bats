#!/usr/bin/env bats
# End-to-end tests for the qa-status-gate.sh Stop hook itself (not the pure
# lib): pipe a real Stop payload at a fixture repo and assert on stdout.
# Locks in the 2026-06-10 noise-control behavior: a dirty tree alone does not
# arm the gate, only commits ahead of the base branch do, and the block reason
# is the short pointer form (not the old 2,500-char posture menu).

setup() {
  GATE="$BATS_TEST_DIRNAME/../scripts/qa-status-gate.sh"
  FIX="$BATS_TEST_TMPDIR/fixture"
  git init -q -b main "$FIX"
  git -C "$FIX" config user.email t@t
  git -C "$FIX" config user.name t
  echo seed > "$FIX/seed.txt"
  git -C "$FIX" add seed.txt
  git -C "$FIX" commit -q -m base
  git -C "$FIX" checkout -q -b feat/x
}

payload() { # $1 = last assistant message, $2 = stop_hook_active (default false)
  jq -nc --arg m "$1" --arg c "$FIX" --argjson a "${2:-false}" \
    '{last_assistant_message:$m, cwd:$c, stop_hook_active:$a}'
}

run_gate() { # $1 = message, $2 = stop_hook_active
  payload "$1" "${2:-false}" | bash "$GATE"
}

commit_ahead() {
  echo work > "$FIX/file.txt"
  git -C "$FIX" add file.txt
  git -C "$FIX" commit -q -m work
}

# Wire a bare origin holding the base branch, so the primary
# origin/${BASE}..HEAD arming path (not the local-branch fallback) runs.
add_origin() { # $1 = base branch name, $2 = "set-head" | "no-head"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  git init -q --bare "$ORIGIN"
  git -C "$FIX" remote add origin "$ORIGIN"
  git -C "$FIX" push -q origin "$1"
  if [ "$2" = "set-head" ]; then
    git -C "$FIX" remote set-head origin "$1"
  fi
}

assert_short_block() { # validates $output as the short-pointer block form
  [ "$(echo "$output" | jq -r '.decision')" = "block" ]
  reason=$(echo "$output" | jq -r '.reason')
  # Short by design: a handful of lines, well under the old 2,500-char menu.
  [ "$(printf '%s\n' "$reason" | wc -l | tr -d ' ')" -le 4 ]
  [ "${#reason}" -lt 600 ]
  for kw in dev_verified deploy_branch_for_manual_qa prod_verified blocked \
            skip_requested no_tracked_change qa-status-postures.md; do
    printf '%s' "$reason" | grep -q "$kw"
  done
}

@test "hook allows silently: modified tracked file alone, no commits ahead" {
  echo dirty >> "$FIX/seed.txt"   # the motivating case: a modified tracked file
  run run_gate 'All done, ready to merge.'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook allows silently: untracked file alone, no commits ahead" {
  echo dirty > "$FIX/new-file.txt"
  run run_gate 'All done, ready to merge.'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook blocks: commits ahead (no remote, local-base fallback), short reason" {
  commit_ahead
  run run_gate 'All done, ready to merge.'
  [ "$status" -eq 0 ]
  assert_short_block
}

@test "hook blocks: commits ahead of origin base (primary origin/HEAD path)" {
  add_origin main set-head
  commit_ahead
  run run_gate 'All done, ready to merge.'
  [ "$status" -eq 0 ]
  assert_short_block
}

@test "hook allows: branch fully synced with origin base, dirty tree only" {
  add_origin main set-head
  echo dirty >> "$FIX/seed.txt"
  run run_gate 'All done, ready to merge.'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook blocks: master-default repo with origin but NO origin/HEAD" {
  # Plain `git remote add` never sets origin/HEAD; with rev-list the sole
  # arming signal, the BASE probe must still find origin/master here.
  git -C "$FIX" branch -m feat/x feat/y 2>/dev/null || true
  git -C "$FIX" checkout -q main
  git -C "$FIX" branch -m main master
  add_origin master no-head
  git -C "$FIX" checkout -q -b feat/z
  commit_ahead
  run run_gate 'All done, ready to merge.'
  [ "$status" -eq 0 ]
  assert_short_block
}

@test "hook allows: commits ahead but QA_STATUS posture stated" {
  commit_ahead
  run run_gate 'Done. QA_STATUS: dev_verified EVIDENCE: ran the flow'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook allows: stop_hook_active continuation never re-blocks (loop guard)" {
  commit_ahead
  run run_gate 'All done, ready to merge.' true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
