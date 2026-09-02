#!/usr/bin/env bats
# Tests for the QA-plan APPROVAL TOKEN (gstack-extensions#71): the pure decision
# logic (qa-plan-token-lib.sh), the minting hook (qa-plan-approval-token.sh), and
# the stamp writer's refusal to write without one.
#
# The property under test, stated once: a stamp claiming a human approved the QA
# plan can exist ONLY because a human answered the "QA plan" AskUserQuestion with
# "Approve". There is deliberately no bypass to test around, so these tests mint
# tokens the same way production does, by feeding the hook a real payload shape.

setup() {
  TLIB="$BATS_TEST_DIRNAME/../scripts/qa-plan-token-lib.sh"
  GLIB="$BATS_TEST_DIRNAME/../scripts/qa-plan-gate-lib.sh"
  MINT="$BATS_TEST_DIRNAME/../scripts/qa-plan-approval-token.sh"
  STAMP="$BATS_TEST_DIRNAME/../scripts/qa-plan-stamp.sh"
  # shellcheck source=/dev/null
  . "$TLIB"
  # shellcheck source=/dev/null
  . "$GLIB"
  REPO=$(mktemp -d "$HOME/dev/.qptest.XXXXXX")
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Real Human"
  git -C "$REPO" config user.email "h@example.com"
  git -C "$REPO" commit -q --allow-empty -m init
  git -C "$REPO" branch -M main
  git -C "$REPO" checkout -q -b feat/thing
  GITDIR=$(git -C "$REPO" rev-parse --absolute-git-dir)
}

teardown() { rm -rf "$REPO"; }

# A PostToolUse:AskUserQuestion payload. `answers` is the map the HARNESS fills in
# from the human's click; that is the field an agent cannot forge, and the whole
# fix rests on it.
ask_payload() {  # <header> <question> <answer>
  jq -nc --arg h "$1" --arg q "$2" --arg a "$3" --arg cwd "$REPO" \
    '{tool_name:"AskUserQuestion", cwd:$cwd, session_id:"s1",
      tool_input:{questions:[{question:$q, header:$h, options:[], multiSelect:false}]},
      tool_response:{answers:{($q):$a}}}'
}
mint_approval() { ask_payload "QA plan" "Approve the plan?" "Approve" | bash "$MINT"; }

# ========================================================================
# Pure: qpt_is_approve / qpt_header_is_qa_plan
# ========================================================================

@test "is_approve: exact Approve" {
  run qpt_is_approve "Approve"
  [ "$output" = "approve" ]; [ "$status" -eq 0 ]
}

@test "is_approve: tolerates a trailing parenthetical and case" {
  run qpt_is_approve "  APPROVE (recommended) "
  [ "$output" = "approve" ]; [ "$status" -eq 0 ]
}

@test "is_approve: Rework it is not approval" {
  run qpt_is_approve "Rework it"
  [ "$output" = "no" ]; [ "$status" -eq 1 ]
}

@test "is_approve: Skip the gate is not approval" {
  run qpt_is_approve "Skip the gate"
  [ "$output" = "no" ]; [ "$status" -eq 1 ]
}

@test "is_approve: a label merely STARTING with approve does not count" {
  # Guards the exact-match choice: a future option like this must not mint.
  run qpt_is_approve "Approve without QA"
  [ "$output" = "no" ]; [ "$status" -eq 1 ]
}

@test "header: only the QA plan header matches" {
  run qpt_header_is_qa_plan "QA plan"
  [ "$output" = "qa-plan" ]
  run qpt_header_is_qa_plan "Memory writes"
  [ "$output" = "no" ]
}

# ========================================================================
# Pure: qpt_token_valid
# ========================================================================

@test "token_valid: fresh token for this branch is valid" {
  run qpt_token_valid '{"branch":"feat/x","approved_at_epoch":1000}' "feat/x" 1010
  [ "$output" = "valid" ]; [ "$status" -eq 0 ]
}

@test "token_valid: empty -> no-token" {
  run qpt_token_valid "" "feat/x" 1000
  [ "$output" = "no-token" ]; [ "$status" -eq 1 ]
}

@test "token_valid: corrupt json -> malformed" {
  run qpt_token_valid '{not json' "feat/x" 1000
  [ "$output" = "malformed" ]; [ "$status" -eq 1 ]
}

@test "token_valid: a token for another branch cannot authorize this one" {
  run qpt_token_valid '{"branch":"feat/other","approved_at_epoch":1000}' "feat/x" 1010
  [ "$output" = "wrong-branch" ]; [ "$status" -eq 1 ]
}

@test "token_valid: past the TTL -> expired" {
  run qpt_token_valid '{"branch":"feat/x","approved_at_epoch":1000}' "feat/x" 99999
  [ "$output" = "expired" ]; [ "$status" -eq 1 ]
}

@test "token_valid: a future timestamp is rejected, not treated as fresh" {
  # Otherwise a hand-written far-future epoch would buy an unlimited window.
  run qpt_token_valid '{"branch":"feat/x","approved_at_epoch":9999999}' "feat/x" 1000
  [ "$output" = "future" ]; [ "$status" -eq 1 ]
}

# ========================================================================
# The minting hook
# ========================================================================

@test "mint: a real QA plan Approve mints a token bound to the branch" {
  mint_approval
  [ -f "$GITDIR/qa-plan-approval-token" ]
  run jq -r .branch "$GITDIR/qa-plan-approval-token"
  [ "$output" = "feat/thing" ]
  run jq -r .source "$GITDIR/qa-plan-approval-token"
  [ "$output" = "AskUserQuestion" ]
}

@test "mint: Rework it mints nothing" {
  ask_payload "QA plan" "Approve the plan?" "Rework it" | bash "$MINT"
  [ ! -f "$GITDIR/qa-plan-approval-token" ]
}

@test "mint: Skip the gate mints nothing" {
  ask_payload "QA plan" "Approve the plan?" "Skip the gate" | bash "$MINT"
  [ ! -f "$GITDIR/qa-plan-approval-token" ]
}

@test "mint: an unrelated modal answered Approve mints nothing" {
  # The load-bearing negative. Without the header check, any modal in the session
  # whose answer happened to read "Approve" would mint a QA-plan approval.
  ask_payload "Memory writes" "Save this memory?" "Approve" | bash "$MINT"
  [ ! -f "$GITDIR/qa-plan-approval-token" ]
}

@test "mint: an Approve belonging to a DIFFERENT question does not mint" {
  # Two questions in one modal: the QA plan one is reworked, another is approved.
  # The answer must be matched to the QA-plan question by its own text.
  jq -nc --arg cwd "$REPO" '{tool_name:"AskUserQuestion", cwd:$cwd, session_id:"s1",
     tool_input:{questions:[{question:"Approve the plan?",header:"QA plan"},
                            {question:"Something else?",header:"Other"}]},
     tool_response:{answers:{"Approve the plan?":"Rework it","Something else?":"Approve"}}}' \
    | bash "$MINT"
  [ ! -f "$GITDIR/qa-plan-approval-token" ]
}

@test "mint: a tool other than AskUserQuestion mints nothing" {
  jq -nc --arg cwd "$REPO" '{tool_name:"Bash", cwd:$cwd, tool_input:{command:"echo hi"}}' | bash "$MINT"
  [ ! -f "$GITDIR/qa-plan-approval-token" ]
}

# ========================================================================
# The stamp writer's refusal (the defect in #71)
# ========================================================================

@test "stamp: write REFUSES with no approval token" {
  run bash -c "cd '$REPO' && bash '$STAMP' write"
  [ "$status" -ne 0 ]
  [ ! -f "$GITDIR/qa-plan-approved" ]
  echo "$output" | grep -q "REFUSING"
}

@test "stamp: --approver is not a bypass" {
  # Passing the field by hand must not stand in for the human's click.
  run bash -c "cd '$REPO' && bash '$STAMP' write --approver 'Real Human'"
  [ "$status" -ne 0 ]
  [ ! -f "$GITDIR/qa-plan-approved" ]
}

@test "stamp: the refusal never writes the human's git name anywhere" {
  # The false-audit half of #71: an unauthorized write must not produce an
  # artifact bearing the human's name.
  bash -c "cd '$REPO' && bash '$STAMP' write" || true
  # Scoped to the gate's own artifacts. git's config legitimately holds user.name;
  # what must never happen is that name reaching a STAMP no human authorized.
  run bash -c "cat '$GITDIR'/qa-plan-* 2>/dev/null | grep -c 'Real Human'"
  [ "$output" = "0" ]
}

@test "stamp: write SUCCEEDS after a real approval, and records the human" {
  mint_approval
  run bash -c "cd '$REPO' && bash '$STAMP' write --digest abc123"
  [ "$status" -eq 0 ]
  [ -f "$GITDIR/qa-plan-approved" ]
  run jq -r .approver "$GITDIR/qa-plan-approved"
  [[ "$output" == *"Real Human"* ]]
  [[ "$output" == *"AskUserQuestion"* ]]
}

@test "stamp: the token is SINGLE USE (one click, one stamp)" {
  mint_approval
  bash -c "cd '$REPO' && bash '$STAMP' write >/dev/null"
  [ ! -f "$GITDIR/qa-plan-approval-token" ]
  # A second write, e.g. after the agent rewrote the plan, must ask again.
  run bash -c "cd '$REPO' && bash '$STAMP' write"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "REFUSING"
}

@test "stamp: a token minted on another branch cannot stamp this one" {
  mint_approval
  git -C "$REPO" checkout -q -b feat/other
  run bash -c "cd '$REPO' && bash '$STAMP' write"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "different branch"
}

@test "stamp: the stamp it writes carries the proof field the gates require" {
  mint_approval
  bash -c "cd '$REPO' && bash '$STAMP' write --digest d1 >/dev/null"
  run qpg_stamp_valid "$(cat "$GITDIR/qa-plan-approved")" "feat/thing"
  [ "$output" = "valid" ]
}

@test "stamp: status reports whether a token is present" {
  run bash -c "cd '$REPO' && bash '$STAMP' status"
  echo "$output" | grep -q "approval token: none"
  mint_approval
  run bash -c "cd '$REPO' && bash '$STAMP' status"
  echo "$output" | grep -q "approval token: present \[valid\]"
}

@test "stamp: clear leaves an unused token alone" {
  # Clearing a stamp must not burn an approval the human gave for something else.
  mint_approval
  bash -c "cd '$REPO' && bash '$STAMP' write >/dev/null"
  mint_approval
  bash -c "cd '$REPO' && bash '$STAMP' clear >/dev/null"
  [ -f "$GITDIR/qa-plan-approval-token" ]
}
