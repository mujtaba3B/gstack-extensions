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
DIGEST_A="aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb8888"
mint_approval() { ask_payload "QA plan" "Approve the plan? <qa-plan-digest:$DIGEST_A>" "Approve" | bash "$MINT"; }

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

@test "stamp: --approver was removed and is rejected even WITH a token" {
  # It used to be an override, which let an arbitrary name be recorded under a
  # genuine approval_source. An agent-supplied identity is not evidence.
  mint_approval
  run bash -c "cd '$REPO' && bash '$STAMP' write --approver 'Someone Who Never Clicked'"
  [ "$status" -ne 0 ]
  [ ! -f "$GITDIR/qa-plan-approved" ]
}

@test "stamp: --digest was removed and is rejected even WITH a token" {
  # It used to let an agent approve plan A and stamp the digest of plan B,
  # defeating drift detection entirely.
  mint_approval
  run bash -c "cd '$REPO' && bash '$STAMP' write --digest deadbeef"
  [ "$status" -ne 0 ]
  [ ! -f "$GITDIR/qa-plan-approved" ]
}

@test "stamp: no flag is a bypass" {
  for f in --force -f --yes --no-verify --skip-token --no-token; do
    run bash -c "cd '$REPO' && bash '$STAMP' write $f"
    [ "$status" -ne 0 ]
    [ ! -f "$GITDIR/qa-plan-approved" ]
  done
}

@test "stamp: no environment variable is a bypass" {
  run bash -c "cd '$REPO' && QA_PLAN_FORCE=1 QA_PLAN_SKIP_TOKEN=1 QA_PLAN_APPROVED=1 \
    QA_PLAN_TOKEN=1 GATE_POLICY_TEST=1 CLAUDE_QA_PLAN_APPROVER=x bash '$STAMP' write"
  [ "$status" -ne 0 ]
  [ ! -f "$GITDIR/qa-plan-approved" ]
}

@test "stamp: a token carrying no approver records unknown, never the git name" {
  # The false-audit half of #71, pinned at the only place git config could still
  # leak in. The previous version of this test grepped a glob that matched nothing
  # at that point, so it returned 0 by construction and would have passed for any
  # reason the write failed. It tested nothing.
  mint_approval
  jq 'del(.approver)' "$GITDIR/qa-plan-approval-token" > "$BATS_TEST_TMPDIR/t" \
    && mv "$BATS_TEST_TMPDIR/t" "$GITDIR/qa-plan-approval-token"
  run bash -c "cd '$REPO' && bash '$STAMP' write"
  [ "$status" -eq 0 ]
  run jq -r .approver "$GITDIR/qa-plan-approved"
  [ "$output" = "unknown" ]
  run bash -c "grep -c 'Real Human' '$GITDIR/qa-plan-approved'"
  [ "$output" = "0" ]
}

@test "token_approver: a token with no approver yields unknown" {
  run qpt_token_approver '{"branch":"x"}'
  [ "$output" = "unknown" ]
}

@test "stamp: an EXPIRED token on disk is refused (the TTL is wired, not just pure)" {
  mint_approval
  jq '.approved_at_epoch -= 99999' "$GITDIR/qa-plan-approval-token" > "$BATS_TEST_TMPDIR/t" \
    && mv "$BATS_TEST_TMPDIR/t" "$GITDIR/qa-plan-approval-token"
  run bash -c "cd '$REPO' && bash '$STAMP' write"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "expired"
  [ ! -f "$GITDIR/qa-plan-approved" ]
}

@test "stamp: a MALFORMED token on disk is refused" {
  mint_approval
  printf '{' > "$GITDIR/qa-plan-approval-token"
  run bash -c "cd '$REPO' && bash '$STAMP' write"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "malformed"
}

@test "stamp: criteria_digest comes from the TOKEN, not from the caller" {
  mint_approval
  bash -c "cd '$REPO' && bash '$STAMP' write >/dev/null"
  run jq -r .criteria_digest "$GITDIR/qa-plan-approved"
  [ "$output" = "$DIGEST_A" ]
}

@test "stamp: write SUCCEEDS after a real approval, and records the human" {
  mint_approval
  run bash -c "cd '$REPO' && bash '$STAMP' write"
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
  bash -c "cd '$REPO' && bash '$STAMP' write >/dev/null"
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

# ========================================================================
# Pure: qpt_should_mint (the composed decision, extracted per CLAUDE.md)
# ========================================================================

@test "should_mint: the one accepting row" {
  run qpt_should_mint "AskUserQuestion" "QA plan" "Approve" "feat/x"
  [ "$output" = "mint" ]; [ "$status" -eq 0 ]
}

@test "should_mint: every refusing row names its reason" {
  run qpt_should_mint "Bash" "QA plan" "Approve" "feat/x"
  [ "$output" = "wrong-tool" ]
  run qpt_should_mint "AskUserQuestion" "Memory writes" "Approve" "feat/x"
  [ "$output" = "wrong-header" ]
  run qpt_should_mint "AskUserQuestion" "QA plan" "Rework it" "feat/x"
  [ "$output" = "not-approve" ]
  run qpt_should_mint "AskUserQuestion" "QA plan" "Approve" "HEAD"
  [ "$output" = "no-branch" ]
  run qpt_should_mint "AskUserQuestion" "QA plan" "Approve" ""
  [ "$output" = "no-branch" ]
}

@test "should_mint: a QUALIFIED approve does not mint" {
  # "Approve (skip Prod QA)" is not an unqualified approval. An earlier cut
  # stripped any trailing parenthetical and minted a full token for it.
  run qpt_should_mint "AskUserQuestion" "QA plan" "Approve (skip Prod QA)" "feat/x"
  [ "$output" = "not-approve" ]; [ "$status" -eq 1 ]
}

@test "should_mint: the recommendation marker is inert" {
  run qpt_should_mint "AskUserQuestion" "QA plan" "**Approve** (recommended)" "feat/x"
  [ "$output" = "mint" ]
}

@test "mint: a header differing only in case still mints" {
  # The hook used to pre-filter byte-exact in jq, so "QA Plan" minted nothing
  # while the writer blamed an unregistered hook: an unsatisfiable gate with a
  # misleading diagnosis.
  ask_payload "QA Plan" "Approve? <qa-plan-digest:$DIGEST_A>" "Approve" | bash "$MINT"
  [ -f "$GITDIR/qa-plan-approval-token" ]
}

@test "mint: a header differing only in padding still mints" {
  ask_payload "  qa plan  " "Approve? <qa-plan-digest:$DIGEST_A>" "Approve" | bash "$MINT"
  [ -f "$GITDIR/qa-plan-approval-token" ]
}

@test "mint: a qualified Approve mints nothing end to end" {
  ask_payload "QA plan" "Approve?" "Approve (skip Prod QA)" | bash "$MINT"
  [ ! -f "$GITDIR/qa-plan-approval-token" ]
}

@test "mint: the plan digest travels from the question into the token" {
  mint_approval
  run jq -r .plan_digest "$GITDIR/qa-plan-approval-token"
  [ "$output" = "$DIGEST_A" ]
}

@test "mint: a question with no digest marker yields an empty plan_digest" {
  ask_payload "QA plan" "Approve the plan?" "Approve" | bash "$MINT"
  run jq -r .plan_digest "$GITDIR/qa-plan-approval-token"
  [ "$output" = "" ]
}

@test "digest_from_question: extracts the marker, ignores prose" {
  run qpt_digest_from_question "Approve? <qa-plan-digest:abc123abc123abc1>"
  [ "$output" = "abc123abc123abc1" ]
  run qpt_digest_from_question "Approve the plan?"
  [ -z "$output" ]
}

@test "unattested_in_window: only stamps predating the fix are grandfathered" {
  run qpt_unattested_in_window 1788220800     # 2026-09-01
  [ "$output" = "in" ]; [ "$status" -eq 0 ]
  run qpt_unattested_in_window 1900000000     # well after
  [ "$output" = "out" ]; [ "$status" -eq 1 ]
  run qpt_unattested_in_window ""             # undatable fails closed
  [ "$output" = "out" ]; [ "$status" -eq 1 ]
}

# ========================================================================
# The canonical digest verb (one code path shared with the gates)
# ========================================================================

@test "digest verb: agrees with the gate's own computation" {
  printf 'intro\n\n## QA\n\n| [ ] | claude | do it |\n\n## Next\nx\n' > "$BATS_TEST_TMPDIR/body.md"
  run bash "$STAMP" digest "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  a="$output"
  . "$BATS_TEST_DIRNAME/../scripts/qa-plan-gate-lib.sh"
  b=$(qpg_plan_digest "$(qpg_extract_qa_section "$(cat "$BATS_TEST_TMPDIR/body.md")")")
  [ -n "$a" ]; [ "$a" = "$b" ]
}

@test "digest verb: ticking a box does not change it" {
  printf '## QA\n\n| [ ] | claude | do it |\n' > "$BATS_TEST_TMPDIR/a.md"
  printf '## QA\n\n| [x] | claude | do it |\n' > "$BATS_TEST_TMPDIR/b.md"
  run bash "$STAMP" digest "$BATS_TEST_TMPDIR/a.md"; a="$output"
  run bash "$STAMP" digest "$BATS_TEST_TMPDIR/b.md"; b="$output"
  [ -n "$a" ]; [ "$a" = "$b" ]
}

@test "digest verb: a body with no QA section fails loudly" {
  printf 'just prose\n' > "$BATS_TEST_TMPDIR/c.md"
  run bash "$STAMP" digest "$BATS_TEST_TMPDIR/c.md"
  [ "$status" -ne 0 ]
}

# ========================================================================
# Second review round: portable mtime, header reuse, multi-line questions
# ========================================================================

@test "stamp_mtime: reads a real file's mtime on this host" {
  touch "$BATS_TEST_TMPDIR/f"
  run qpt_stamp_mtime "$BATS_TEST_TMPDIR/f"
  [ "$status" -eq 0 ]
  case "$output" in ''|*[!0-9]*) false ;; *) true ;; esac
}

@test "stamp_mtime: a missing file yields nothing and fails" {
  run qpt_stamp_mtime "$BATS_TEST_TMPDIR/nope"
  [ "$status" -ne 0 ]; [ -z "$output" ]
}

@test "stamp_mtime: the result is always numeric, never a stat error blob" {
  # GNU stat spells -f as --file-system, so `stat -f %m` prints a six-line
  # filesystem block to STDOUT and exits 1. A BSD-first chain captured that blob,
  # appended the real epoch, and produced a non-numeric string, which killed the
  # migration carve-out on every Linux host and turned CI red.
  touch "$BATS_TEST_TMPDIR/g"
  m=$(qpt_stamp_mtime "$BATS_TEST_TMPDIR/g")
  run qpt_unattested_in_window "$m" 9999999999
  [ "$output" = "in" ]
}

@test "mint: duplicate question text does not select another question's header" {
  # The header is reused from the matched question, not re-derived by text with
  # a jq `first`, which used to pick the wrong one and silently mint nothing.
  jq -nc --arg cwd "$REPO" --arg q "Approve? <qa-plan-digest:$DIGEST_A>" \
    '{tool_name:"AskUserQuestion", cwd:$cwd, session_id:"s1",
      tool_input:{questions:[{question:$q,header:"Memory writes"},{question:$q,header:"QA plan"}]},
      tool_response:{answers:{($q):"Approve"}}}' | bash "$MINT"
  [ -f "$GITDIR/qa-plan-approval-token" ]
}

@test "mint: a question containing a newline still mints" {
  # Questions are keyed by index now; `read` used to truncate at the first line,
  # the answers lookup missed, and the operator was told to restart Claude Code
  # for a problem a restart cannot fix.
  Q="Approve this plan?
Second line of context. <qa-plan-digest:$DIGEST_A>"
  jq -nc --arg cwd "$REPO" --arg q "$Q" \
    '{tool_name:"AskUserQuestion", cwd:$cwd, session_id:"s1",
      tool_input:{questions:[{question:$q,header:"QA plan"}]},
      tool_response:{answers:{($q):"Approve"}}}' | bash "$MINT"
  [ -f "$GITDIR/qa-plan-approval-token" ]
  run jq -r .plan_digest "$GITDIR/qa-plan-approval-token"
  [ "$output" = "$DIGEST_A" ]
}

@test "mint: an empty questions array mints nothing" {
  jq -nc --arg cwd "$REPO" '{tool_name:"AskUserQuestion", cwd:$cwd, session_id:"s1",
      tool_input:{questions:[]}, tool_response:{answers:{}}}' | bash "$MINT"
  [ ! -f "$GITDIR/qa-plan-approval-token" ]
}
