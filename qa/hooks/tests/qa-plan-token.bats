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
  # The gates are ~/dev-scoped, so the scratch repo must live there. Create the
  # parent first: a clean CI runner has no ~/dev, and mktemp would fail in setup,
  # taking the whole suite down before a single test ran (CodeRabbit, PR #76).
  mkdir -p "$HOME/dev"
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
# ---- substring assertions ---------------------------------------------------
#
# WHY THESE EXIST INSTEAD OF `[[ "$output" == *"x"* ]]`. Measured on bats-core
# 1.13: a failing `[[ ]]` in any position OTHER than the last line of a test body
# does not fail the test. `[[` is a shell keyword, and errexit does not fire for
# it there, so an assertion followed by any other line is a silent no-op that
# passes no matter what the output says. A single-bracket `[ ]` and a function
# call both fail correctly in the same position.
#
# This was found by mutation-testing this suite: the TTY guard on
# `qa-plan-stamp.sh override` was deleted and every test still passed, because
# the assertion pinning it sat above another line. Thirty-two assertions across
# the repo's suites had the same shape. Use these helpers, never a bare `[[ ]]`.
assert_contains() {  # <haystack> <needle>
  case "$1" in *"$2"*) return 0 ;; esac
  echo "assert_contains failed" >&2
  echo "  wanted substring: $2" >&2
  echo "  actual:           $1" >&2
  return 1
}
assert_missing() {  # <haystack> <needle-that-must-not-appear>
  case "$1" in *"$2"*)
    echo "assert_missing failed" >&2
    echo "  unwanted substring: $2" >&2
    echo "  actual:             $1" >&2
    return 1 ;;
  esac
  return 0
}


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
  assert_contains "$output" "Real Human"
  assert_contains "$output" "AskUserQuestion"
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

@test "is_approve: every markdown emphasis shape still mints" {
  # Emphasis can wrap the whole label or just the word. An end-anchored strip
  # fixes one and breaks the other, which is exactly what the first fix for this
  # did (CodeRabbit, PR #76). Both shapes, and the plain one, must agree.
  for l in "Approve" "**Approve** (recommended)" "**Approve (recommended)**" "*Approve (default)*" "__Approve__"; do
    run qpt_is_approve "$l"
    [ "$output" = "approve" ]
  done
}

@test "is_approve: emphasis does not rescue a QUALIFIED approve" {
  for l in "**Approve (skip Prod QA)**" "*Approve without QA*"; do
    run qpt_is_approve "$l"
    [ "$output" = "no" ]
  done
}

@test "stamp_mtime is gone as an authorization input" {
  # The function may still exist for diagnostics, but nothing may treat a
  # backdated mtime as approval. qpg_unattested_disposition covers the verdict.
  . "$BATS_TEST_DIRNAME/../scripts/qa-plan-gate-lib.sh"
  run qpg_unattested_disposition pr
  [ "$output" = "block" ]
}

# ========================================================================
# HUMAN OVERRIDES (2026-09-03)
#
# The property under test: an override reaches a stamp ONLY through a signal a
# human produces and an agent cannot. Two such signals exist, and each gets its
# own truth table plus an end-to-end pass through the real hook / script.
# ========================================================================

# A UserPromptSubmit payload. `.prompt` is the human's literal typed message,
# filled in by the harness. The model emits assistant turns and tool calls; it
# cannot submit a user prompt, which is what makes this field evidence.
prompt_payload() {  # <prompt>
  jq -nc --arg p "$1" --arg cwd "$REPO" \
    '{hook_event_name:"UserPromptSubmit", prompt:$p, cwd:$cwd, session_id:"s1"}'
}

# ---- qpt_prompt_is_override -------------------------------------------------

@test "prompt_is_override: the exact phrase" {
  run qpt_prompt_is_override "qa-plan: I approve this plan"
  [ "$output" = "override" ]; [ "$status" -eq 0 ]
}

@test "prompt_is_override: case, surrounding space and a trailing period" {
  for p in "QA-PLAN: I APPROVE THIS PLAN" \
           "  qa-plan: I approve this plan  " \
           "qa-plan: I approve this plan." \
           "qa-plan: I approve this plan!"; do
    run qpt_prompt_is_override "$p"
    [ "$output" = "override" ]
  done
}

@test "prompt_is_override: a prompt that merely CONTAINS the phrase does not count" {
  # This is the load-bearing case. The phrase is written down in the lib, the
  # skill body and the README, so it gets quoted in ordinary conversation about
  # the feature; a substring match would let a question about the override BE an
  # override. Every string below contains the phrase verbatim.
  for p in "should I type qa-plan: I approve this plan?" \
           "the phrase is \"qa-plan: I approve this plan\", right?" \
           "qa-plan: I approve this plan and also ship it" \
           "run this first, then qa-plan: I approve this plan" \
           "qa-plan: I approve this plan
and then merge"; do
    run qpt_prompt_is_override "$p"
    [ "$output" = "no" ]; [ "$status" -eq 1 ]
  done
}

@test "prompt_is_override: near misses do not count" {
  for p in "qa-plan: I approve" \
           "I approve this plan" \
           "qa-plan: approve this plan" \
           "qa plan: I approve this plan" \
           ""; do
    run qpt_prompt_is_override "$p"
    [ "$output" = "no" ]
  done
}

# ---- qpt_should_mint_prompt -------------------------------------------------

@test "should_mint_prompt: truth table" {
  run qpt_should_mint_prompt "qa-plan: I approve this plan" "feat/thing"
  [ "$output" = "mint" ]; [ "$status" -eq 0 ]

  run qpt_should_mint_prompt "do the thing" "feat/thing"
  [ "$output" = "no-phrase" ]; [ "$status" -eq 1 ]

  run qpt_should_mint_prompt "qa-plan: I approve this plan" ""
  [ "$output" = "no-branch" ]; [ "$status" -eq 1 ]

  run qpt_should_mint_prompt "qa-plan: I approve this plan" "HEAD"
  [ "$output" = "no-branch" ]; [ "$status" -eq 1 ]
}

# ---- qpt_stamp_source_for ---------------------------------------------------

@test "stamp_source_for: closed mapping, unknown sources yield nothing" {
  run qpt_stamp_source_for "AskUserQuestion"
  [ "$output" = "AskUserQuestion" ]; [ "$status" -eq 0 ]

  run qpt_stamp_source_for "UserPromptSubmit"
  [ "$output" = "human-prompt-override" ]; [ "$status" -eq 0 ]

  # A hand-written token must not get to name its own approval_source. Note the
  # STAMP values are rejected as TOKEN sources too: the two vocabularies are
  # deliberately different, so echoing a stamp value back in a token fails.
  for src in "" "human-tty-override" "human-prompt-override" "askuserquestion" "anything" "true"; do
    run qpt_stamp_source_for "$src"
    [ "$output" = "" ]; [ "$status" -eq 1 ]
  done
}

# ---- qpt_liveness_verdict ---------------------------------------------------

@test "liveness_verdict: truth table" {
  run qpt_liveness_verdict "s1" "yes"
  [ "$output" = "observed" ]; [ "$status" -eq 0 ]

  run qpt_liveness_verdict "s1" "no"
  [ "$output" = "never-observed" ]; [ "$status" -eq 1 ]

  run qpt_liveness_verdict "" "yes"
  [ "$output" = "unknown" ]; [ "$status" -eq 1 ]
}

@test "liveness_file: a session id cannot steer the write out of the heartbeat dir" {
  # Path traversal: whatever comes back must sit directly inside the heartbeat
  # directory, with no way up and out of it.
  for raw in "../../evil" "a/b" "/etc/passwd" "..%2F.." "x\$(touch /tmp/pwned)"; do
    run qpt_liveness_file "$raw"
    [ -n "$output" ]
    case "$output" in "$(qpt_liveness_dir)/"*) ;; *) false ;; esac
    case "$output" in *"/../"*|*"/..") false ;; *) ;; esac
  done
  [ ! -f /tmp/pwned ]

  for bad in "" "/"; do
    run qpt_liveness_file "$bad"
    if [ -n "$output" ]; then
      case "$output" in "$(qpt_liveness_dir)/"*) ;; *) false ;; esac
    fi
  done
}

@test "liveness_file: sanitizing alone would collide, so distinct ids stay distinct" {
  # The bug CodeRabbit found on PR #80. Stripping unsafe characters is LOSSY:
  # "a/b" and "ab" both sanitize to "ab", so two sessions shared one heartbeat
  # and qp_minter_liveness could answer "observed" for a session that never ran
  # the hook. That is a wrong answer in the fail-OPEN direction, on the one
  # readout whose whole job is to stop a wasted restart. A digest of the RAW id
  # disambiguates; the readable prefix survives for grepping by hand.
  a=$(qpt_liveness_file "a/b")
  b=$(qpt_liveness_file "ab")
  [ -n "$a" ]; [ -n "$b" ]
  [ "$a" != "$b" ]

  # Same id in, same file out: liveness would be useless if it were not stable.
  [ "$(qpt_liveness_file "sess-1")" = "$(qpt_liveness_file "sess-1")" ]
  [ "$(qpt_liveness_file "sess-1")" != "$(qpt_liveness_file "sess-2")" ]

  # And the readable part is still there, so the directory can be read by eye.
  assert_contains "$(qpt_liveness_file "633cfee0-15fc")" "633cfee0-15fc"
}

@test "liveness_file: with no digest tool it refuses rather than colliding" {
  # The fail-open CodeRabbit found in the first cut of the collision fix: when
  # neither shasum nor sha256sum exists, falling back to the sanitized name alone
  # restores the very collision the digest was added to prevent. A degraded
  # answer is worse than none here, because the collision makes liveness report
  # `observed` for a session that never ran the hook.
  # A PATH carrying everything the function needs EXCEPT a digest tool. Emptying
  # PATH outright would break `tr` too and the test would pass for the wrong
  # reason (an early return on an empty sanitized name).
  nodigest="$BATS_TEST_TMPDIR/nodigest"; mkdir -p "$nodigest"
  for t in tr cut env; do
    src=$(command -v "$t") && ln -sf "$src" "$nodigest/$t"
  done
  run env PATH="$nodigest" /bin/bash -c ". '$TLIB'; qpt_liveness_file 'a/b'; echo \"rc=\$?\""
  assert_contains "$output" "rc=1"
  assert_missing "$output" "qa-plan-minter-seen"
}

@test "minter liveness: an unanswerable lookup reads unknown, not never-observed" {
  # The verdict must distinguish "asked, and the answer is no" from "could not
  # ask". Reporting never-observed on a lookup that never happened is what sends
  # someone to restart for nothing, which is the failure this whole change exists
  # to stop.
  run env PATH="/nonexistent:/usr/bin:/bin" bash -c "cd '$REPO' && CLAUDE_CODE_SESSION_ID=s1 bash '$STAMP' doctor"
  assert_contains "$output" "minter:"
}

@test "claude_dir: CLAUDE_CONFIG_DIR relocates the heartbeat dir and the gate log" {
  # Claude Code moves its whole config root when this is set, so hardcoding
  # ~/.claude writes to a directory the runtime is not using and liveness then
  # reports never-observed forever. Raised by CodeRabbit on PR #80.
  run env CLAUDE_CONFIG_DIR=/tmp/cc-alt bash -c ". '$TLIB'; qpt_claude_dir"
  [ "$output" = "/tmp/cc-alt" ]
  run env CLAUDE_CONFIG_DIR=/tmp/cc-alt bash -c ". '$TLIB'; qpt_liveness_dir"
  [ "$output" = "/tmp/cc-alt/qa-plan-minter-seen" ]
  run env CLAUDE_CONFIG_DIR=/tmp/cc-alt bash -c ". '$TLIB'; qpt_gate_log"
  [ "$output" = "/tmp/cc-alt/qa-plan-gate.log" ]

  # Unset falls back to ~/.claude, and an unset HOME must not abort under set -u.
  run env -u CLAUDE_CONFIG_DIR bash -c ". '$TLIB'; qpt_claude_dir"
  [ "$output" = "$HOME/.claude" ]
  run env -u CLAUDE_CONFIG_DIR -u HOME bash -c "set -u; . '$TLIB'; qpt_gate_log"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "writer probe: a hanging cached writer cannot block the gate forever" {
  # The Major finding on PR #80. qpt_writer_is_guarded RUNS a foreign script from
  # inside a synchronous PreToolUse hook, so an unbounded call is a session-wide
  # hang, not a slow function. A writer that reads stdin or sleeps must not win.
  cat > "$REPO/hanging-writer.sh" <<'HANG'
#!/bin/bash
cat            # blocks forever on stdin unless stdin is closed
sleep 600
HANG
  start=$(date +%s)
  run qpt_writer_is_guarded "$REPO/hanging-writer.sh"
  elapsed=$(( $(date +%s) - start ))
  # A TIMEOUT IS NOT A PASS. The verdict is "no", because the probe learned
  # nothing: reporting a writer guarded on the strength of "it did not finish"
  # is a fail-open, and the writer below proves why.
  [ "$output" = "no" ]
  [ "$elapsed" -lt 30 ]
}

@test "writer probe: a SLOW unguarded writer is not mistaken for a guarded one" {
  # The fail-open an adversarial pass found in the fix for the previous finding.
  # Bounding the probe created a new way to pass it: sleep past the deadline,
  # then write. The probe kills the writer, sees no stamp, and under a two-state
  # verdict would report "guarded" and leave an unguarded writer on disk. The
  # timeout is now recorded separately and renders as "no".
  cat > "$REPO/slow-unguarded.sh" <<'SLOW'
#!/bin/bash
sleep 11
printf '{"branch":"x"}' > "$(git rev-parse --absolute-git-dir)/qa-plan-approved"
SLOW
  run qpt_writer_is_guarded "$REPO/slow-unguarded.sh"
  [ "$output" = "no" ]; [ "$status" -eq 1 ]
}

# ---- qpt_writer_is_guarded --------------------------------------------------

@test "writer_is_guarded: distinguishes a pre-token writer from the current one" {
  # The real current writer requires a token.
  run qpt_writer_is_guarded "$STAMP"
  [ "$output" = "yes" ]; [ "$status" -eq 0 ]

  # A pre-#71 writer: no token logic at all. This is the 3.8.0 shape that wrote a
  # stamp bearing the human's name for nobody's approval on 2026-09-03.
  cat > "$REPO/old-stamp.sh" <<'OLD'
#!/bin/bash
# writes the stamp with no guard, --approver defaults to git config user.name
APPROVER=$(git config user.name)
jq -nc --arg a "$APPROVER" '{approver:$a}' > .git/qa-plan-approved
OLD
  run qpt_writer_is_guarded "$REPO/old-stamp.sh"
  [ "$output" = "no" ]; [ "$status" -eq 1 ]

  run qpt_writer_is_guarded "$REPO/does-not-exist.sh"
  [ "$output" = "no" ]; [ "$status" -eq 1 ]

  # A COMMENT mentioning the token file must not make an unguarded writer look
  # guarded. The first cut grepped for that string and this exact two-line
  # mutation defeated it, leaving the unguarded writer un-pruned.
  cat > "$REPO/old-stamp-with-comment.sh" <<'OLD2'
#!/bin/bash
# reads qa-plan-approval-token ... except it does not
APPROVER=$(git config user.name)
jq -nc --arg a "$APPROVER" '{approver:$a}' > "$(git rev-parse --absolute-git-dir)/qa-plan-approved"
OLD2
  run qpt_writer_is_guarded "$REPO/old-stamp-with-comment.sh"
  [ "$output" = "no" ]; [ "$status" -eq 1 ]
}

# ---- the prompt-override hook, end to end -----------------------------------

@test "prompt-override hook: the exact phrase mints a UserPromptSubmit token" {
  OVR="$BATS_TEST_DIRNAME/../scripts/qa-plan-prompt-override.sh"
  run bash -c "cd '$REPO' && prompt_payload_out=\$(jq -nc --arg p 'qa-plan: I approve this plan' --arg cwd '$REPO' '{prompt:\$p, cwd:\$cwd, session_id:\"s1\"}') && printf '%s' \"\$prompt_payload_out\" | bash '$OVR'"
  [ "$status" -eq 0 ]
  # Silent by contract: stdout on UserPromptSubmit is injected into the model's
  # context, so this hook must never emit anything.
  [ "$output" = "" ]
  [ -f "$GITDIR/qa-plan-approval-token" ]
  [ "$(jq -r .source "$GITDIR/qa-plan-approval-token")" = "UserPromptSubmit" ]
  [ "$(jq -r .branch "$GITDIR/qa-plan-approval-token")" = "feat/thing" ]
  # No plan digest: a typed sentence attests to no plan text, and pretending
  # otherwise would make an override look drift-checked when it is not.
  [ "$(jq -r .plan_digest "$GITDIR/qa-plan-approval-token")" = "" ]
}

@test "prompt-override hook: an ordinary prompt mints nothing" {
  OVR="$BATS_TEST_DIRNAME/../scripts/qa-plan-prompt-override.sh"
  for p in "fix the bug" "should I type qa-plan: I approve this plan?" "qa-plan: I approve this plan now"; do
    prompt_payload "$p" | bash "$OVR"
    [ ! -f "$GITDIR/qa-plan-approval-token" ]
  done
}

# ---- the stamp writer, on an override token ---------------------------------

@test "write: a UserPromptSubmit token yields a human-prompt-override stamp with an expiry" {
  OVR="$BATS_TEST_DIRNAME/../scripts/qa-plan-prompt-override.sh"
  prompt_payload "qa-plan: I approve this plan" | bash "$OVR"
  run bash -c "cd '$REPO' && bash '$STAMP' write"
  [ "$status" -eq 0 ]
  [ "$(jq -r .approval_source "$GITDIR/qa-plan-approved")" = "human-prompt-override" ]
  # An override binds to no plan digest, so time is the only bound it can have.
  exp=$(jq -r .expires_at_epoch "$GITDIR/qa-plan-approved")
  [ "$exp" != "null" ]
  [ "$exp" -gt "$(date +%s)" ]
  # Single-use, exactly like the click path.
  [ ! -f "$GITDIR/qa-plan-approval-token" ]
}

@test "write: a modal-click stamp WITH a digest gets no expiry" {
  # The asymmetry is keyed on the DIGEST, not the source: a click that binds to a
  # plan digest is re-verified by the drift check and can stand for the branch's
  # life. A digest-less click does NOT get that exemption (covered in
  # qa-plan-gate.bats), which is the hole adversarial review found.
  mint_approval
  run bash -c "cd '$REPO' && bash '$STAMP' write"
  [ "$status" -eq 0 ]
  [ "$(jq -r .approval_source "$GITDIR/qa-plan-approved")" = "AskUserQuestion" ]
  [ "$(jq -r .expires_at_epoch "$GITDIR/qa-plan-approved")" = "null" ]
}

@test "write: a hand-written token with an invented source writes NO stamp" {
  # The whole point of qpt_stamp_source_for being a closed mapping. Copying the
  # token's own `source` into the stamp would let this file choose its own
  # approval_source and sail through the gate.
  jq -nc --arg b feat/thing --argjson e "$(date +%s)" \
    '{branch:$b, approved_at_epoch:$e, approver:"Real Human", nonce:"x",
      source:"human-tty-override"}' > "$GITDIR/qa-plan-approval-token"
  run bash -c "cd '$REPO' && bash '$STAMP' write"
  [ "$status" -ne 0 ]
  [ ! -f "$GITDIR/qa-plan-approved" ]
  assert_contains "$output" "not one this script recognizes"
}

# ---- the TTY break-glass ----------------------------------------------------

@test "override verb: refuses without a controlling terminal" {
  # bats runs with stdin redirected and no controlling terminal, which is the
  # same condition every agent invocation has: the Bash tool cannot open
  # /dev/tty at all. This is the ONLY thing standing behind the verb, so it is
  # the one behaviour that must never regress.
  run bash -c "cd '$REPO' && bash '$STAMP' override < /dev/null"
  # Exit 1 specifically, and the refusal must be the TTY one. Asserting only
  # "non-zero" would pass for any failure at all, including the script not
  # existing, which is how a test like this quietly stops testing anything.
  [ "$status" -eq 1 ]
  assert_contains "$output" "no controlling terminal"
  [ ! -f "$GITDIR/qa-plan-approved" ]
}

@test "override verb: writes no stamp and consumes no token when it refuses" {
  mint_approval
  run bash -c "cd '$REPO' && bash '$STAMP' override < /dev/null"
  [ "$status" -ne 0 ]
  # A refused override must not burn an unrelated pending approval.
  [ -f "$GITDIR/qa-plan-approval-token" ]
}

@test "doctor: reports the stamp verdict, its remedy and the liveness state" {
  run bash -c "cd '$REPO' && bash '$STAMP' doctor"
  [ "$status" -eq 0 ]
  assert_contains "$output" "stamp:"
  assert_contains "$output" "minter:"
  assert_contains "$output" "remedy:"
  # It must name both human routes, since the whole point is that a blocked
  # agent can tell the human what THEY can do.
  assert_contains "$output" "qa-plan: I approve this plan"
  assert_contains "$output" "override"
}

# ---- the TTY break-glass, WITH a real terminal -------------------------------
#
# Everything above proves the verb REFUSES without a terminal. That is only half
# the contract, and the missing half was found by mutation-testing: deleting the
# confirmation-phrase check entirely left every test green, because no test ever
# reached the confirmation step. A guard whose success path is untested is a
# guard that can silently stop guarding.
#
# `script` allocates a pty, which is the only way to give a child a controlling
# terminal from a non-interactive test. The BSD and GNU spellings differ, so both
# are tried and the test skips where neither works rather than failing CI on a
# platform difference.

# PTY_RUN: run a shell command line on a REAL pty and type one line at it.
#
# `script` cannot be used here: bats redirects stdin away from a terminal and BSD
# `script` refuses in that situation, so it silently skipped on this machine and
# the terminal-only code path went untested. The python helper uses pty.fork,
# which needs no existing terminal and gives the child a CONTROLLING terminal,
# the exact condition the override verb requires and an agent's Bash tool can
# never have.
PTY_RUN() {  # <shell-command-line> <line-to-type>
  # The opt-in the helper requires before it will drive the override verb. It
  # ships inside the installed plugin, so without this it would be a turnkey way
  # to manufacture the controlling terminal the gate asks for.
  QA_PLAN_PTY_SELFTEST=1 python3 "$BATS_TEST_DIRNAME/helpers/pty-run.py" "$1" "$2"
}

@test "override verb: a real terminal plus the exact phrase writes a tty-override stamp" {
  run PTY_RUN "cd '$REPO' && bash '$STAMP' override" "override qa plan for feat/thing"
  [ "$status" -eq 0 ]
  [ -f "$GITDIR/qa-plan-approved" ]
  [ "$(jq -r .approval_source "$GITDIR/qa-plan-approved")" = "human-tty-override" ]
  # It binds to no plan text, so it must carry an expiry and no digest.
  [ "$(jq -r .criteria_digest "$GITDIR/qa-plan-approved")" = "none" ]
  exp=$(jq -r .expires_at_epoch "$GITDIR/qa-plan-approved")
  [ "$exp" -gt "$(date +%s)" ]
  # The human's own name, read from git config at the moment they confirmed.
  assert_contains "$(jq -r .approver "$GITDIR/qa-plan-approved")" "terminal override"
}

@test "override verb: a real terminal with the WRONG phrase writes nothing" {
  # This is the case the mutation exposed: with a terminal available, the ONLY
  # thing left between an accidental keypress and a stamp is the phrase check.
  for reply in "yes" "y" "override" "override qa plan for main" ""; do
    rm -f "$GITDIR/qa-plan-approved"
    PTY_RUN "cd '$REPO' && bash '$STAMP' override" "$reply" >/dev/null 2>&1 || true
    [ ! -f "$GITDIR/qa-plan-approved" ]
  done
}

@test "override verb: the confirmation phrase is branch-specific" {
  # A phrase remembered from another repo must not work here, so a copied
  # transcript of one override does not spell out the next one.
  run qpt_tty_confirm_phrase "feat/thing"
  [ "$output" = "override qa plan for feat/thing" ]
  run qpt_tty_confirm_phrase "other/branch"
  [ "$output" = "override qa plan for other/branch" ]
}

@test "override verb: an agent CAN self-grant a pty, and that limitation is pinned here" {
  # This test asserts a WEAKNESS, deliberately. The first version of this feature
  # claimed in code comments, the skill body, the README and a message to another
  # session that the TTY route was unreachable by an agent. Running the exploit
  # during review disproved it in one command: pty.fork() gives a process its own
  # controlling terminal, so an agent can drive the confirmation prompt.
  #
  # Rather than delete the route (it is the only hook-free recovery, which is the
  # whole reason it exists) the limitation is documented and pinned. If someone
  # later "hardens" the check and believes they have closed this, THIS test going
  # red is the signal that the claim needs re-verifying, not that the test is
  # stale. And if it stays green, nobody can honestly write "an agent cannot".
  run PTY_RUN "cd '$REPO' && bash '$STAMP' override" "override qa plan for feat/thing"
  [ -f "$GITDIR/qa-plan-approved" ]
  [ "$(jq -r .approval_source "$GITDIR/qa-plan-approved")" = "human-tty-override" ]
  # The mitigation that IS real: the stamp records where the terminal came from,
  # so a spawned pty is visible to whoever reads it. Enforcement would be theatre
  # (the spawner picks its own parent), but evidence is not.
  [ "$(jq -r .override_tty "$GITDIR/qa-plan-approved")" != "null" ]
  [ "$(jq -r .override_parent "$GITDIR/qa-plan-approved")" != "null" ]
}

@test "the UserPromptSubmit route is the one that is genuinely unforgeable" {
  # Stated as a test so the two routes are never conflated. Nothing an agent runs
  # produces a UserPromptSubmit event: the hook only ever fires on a real typed
  # message. An agent CAN hand-write the token file, which is the documented
  # file-level residual shared by every sentinel here, but it cannot cause the
  # harness to deliver a prompt it did not receive. Its only lever is the same
  # one it has on every other file, and qpt_stamp_source_for still refuses any
  # token source it does not recognize.
  for bogus in "human-tty-override" "human-prompt-override" "typed" "user"; do
    run qpt_stamp_source_for "$bogus"
    [ "$output" = "" ]; [ "$status" -eq 1 ]
  done
}

@test "write: a digest-less approval gets an expiry whatever its source" {
  # The writer side of the rule the gate enforces. mint_approval embeds a digest,
  # so this mints from a question with no <qa-plan-digest:...> marker instead.
  ask_payload "QA plan" "Approve the plan?" "Approve" | bash "$MINT"
  run bash -c "cd '$REPO' && bash '$STAMP' write"
  [ "$status" -eq 0 ]
  [ "$(jq -r .approval_source "$GITDIR/qa-plan-approved")" = "AskUserQuestion" ]
  [ "$(jq -r .criteria_digest "$GITDIR/qa-plan-approved")" = "none" ]
  exp=$(jq -r .expires_at_epoch "$GITDIR/qa-plan-approved")
  [ "$exp" != "null" ]
  [ "$exp" -gt "$(date +%s)" ]
}

@test "pty helper: refuses to drive the override verb without the test opt-in" {
  # The shipped-exploit finding, pinned. bin/install copies this helper into the
  # plugin cache on every machine, so a blocked agent would otherwise find a
  # documented tool inside the plugin whose job is to defeat the plugin's own
  # gate. This is a speed bump, not a boundary (the variable is settable, the
  # file is copyable, the stdlib is fifteen lines away), and the comments say so.
  run env -u QA_PLAN_PTY_SELFTEST python3 "$BATS_TEST_DIRNAME/helpers/pty-run.py" \
    "cd '$REPO' && bash '$STAMP' override" "override qa plan for feat/thing"
  [ "$status" -eq 2 ]
  [ ! -f "$GITDIR/qa-plan-approved" ]
  assert_contains "$output" "forges it"
}

@test "doctor: never claims Claude cannot reach the terminal override" {
  # THE regression this pins. 3.10.0 retracted "an agent cannot reach the TTY
  # route" in the block message, the skill body and both READMEs after pty.fork
  # disproved it, but missed this footer, so doctor contradicted the gate three
  # lines of output away. A wrong claim about a security property is worse in
  # doctor than anywhere else: doctor is what someone runs precisely when they
  # are trying to work out what is true.
  run bash -c "cd '$REPO' && bash '$STAMP' doctor"
  [ "$status" -eq 0 ]
  assert_missing "$output" "neither is reachable by Claude"
  assert_missing "$output" "Claude cannot"
  # And it must still say something useful about each route's actual strength.
  assert_contains "$output" "nothing Claude does can produce that event"
  assert_contains "$output" "accident-guard only"
}

# ---- --worktree targeting ---------------------------------------------------
#
# The property: --worktree changes WHICH checkout is addressed and grants
# nothing. Per-worktree keying is unchanged, and qpt_token_valid still requires
# token.branch == resolved branch, so the flag cannot move an approval from one
# branch onto another. The bypass test below is the load-bearing one.
#
# Added after 2026-09-04, when an approval given for a plan in a linked worktree
# minted into the SESSION's repo and could only be spent via a terminal override
# run from inside the target. `cd` was load-bearing and nothing said so.

_wt_setup() {  # adds a linked worktree on branch feat/wt; echoes its path
  git -C "$REPO" checkout -q main
  git -C "$REPO" branch -q feat/wt 2>/dev/null || true
  git -C "$REPO" worktree add -q "$REPO-wt" feat/wt 2>/dev/null
  echo "$REPO-wt"
}

_mint_token_for() {  # <gitdir> <branch>
  printf '{"branch":"%s","approved_at_epoch":%s,"approver":"Real Human (via AskUserQuestion)","plan_digest":"deadbeef","source":"AskUserQuestion"}' \
    "$2" "$(date +%s)" > "$1/qa-plan-approval-token"
}

@test "worktree: --worktree stamps the TARGET git dir, not the process cwd's" {
  WT=$(_wt_setup)
  WGD=$(git -C "$WT" rev-parse --absolute-git-dir)
  _mint_token_for "$WGD" "feat/wt"
  run bash -c "cd '$REPO' && '$STAMP' write --worktree '$WT'"
  [ "$status" -eq 0 ]
  [ -f "$WGD/qa-plan-approved" ]
  [ ! -f "$GITDIR/qa-plan-approved" ]
  run jq -r .branch "$WGD/qa-plan-approved"
  assert_contains "$output" "feat/wt"
  git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
}

@test "worktree: the token is CONSUMED from the target, so one approval is one stamp" {
  WT=$(_wt_setup)
  WGD=$(git -C "$WT" rev-parse --absolute-git-dir)
  _mint_token_for "$WGD" "feat/wt"
  # `run`, not a bare subshell: under bats errexit a command EXPECTED to fail
  # aborts the test at that line, so `cmd; st=$?` never reaches the assertion.
  run bash -c "cd '$REPO' && '$STAMP' write --worktree '$WT'"
  [ "$status" -eq 0 ]
  [ ! -f "$WGD/qa-plan-approval-token" ]
  rm -f "$WGD/qa-plan-approved"
  run bash -c "cd '$REPO' && '$STAMP' write --worktree '$WT' 2>&1"
  [ "$status" -ne 0 ]
  [ ! -f "$WGD/qa-plan-approved" ]
  git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
}

@test "worktree: NO BYPASS - a token minted for another branch cannot stamp the target" {
  WT=$(_wt_setup)
  WGD=$(git -C "$WT" rev-parse --absolute-git-dir)
  _mint_token_for "$WGD" "main"          # target is on feat/wt, token says main
  run bash -c "cd '$REPO' && '$STAMP' write --worktree '$WT' 2>&1"
  [ "$status" -ne 0 ]
  assert_contains "$output" "different branch"
  [ ! -f "$WGD/qa-plan-approved" ]
  [ ! -f "$GITDIR/qa-plan-approved" ]
  git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
}

@test "worktree: a stray token in a sibling is NAMED, and the false hook guess is suppressed" {
  WT=$(_wt_setup)
  _mint_token_for "$GITDIR" "main"       # token in the PRIMARY, not the worktree
  run bash -c "cd '$WT' && '$STAMP' write 2>&1"
  [ "$status" -ne 0 ]
  assert_contains "$output" "the approval WAS minted"
  assert_contains "$output" "$GITDIR"
  assert_contains "$output" "--worktree"
  # The liveness paragraph claims the hook "declined to mint". That is FALSE when
  # we can see the token, so a stray hit must suppress it entirely.
  assert_missing "$output" "declined to"
  rm -f "$GITDIR/qa-plan-approval-token"
  git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
}

@test "worktree: with no stray found, the cross-repo session-cwd note is shown instead" {
  run bash -c "cd '$REPO' && '$STAMP' write 2>&1"
  [ "$status" -ne 0 ]
  assert_contains "$output" "SESSION cwd"
  assert_missing "$output" "the approval WAS minted"
}

@test "worktree: the flag is additive - no flag behaves as before, junk args still rejected" {
  run bash -c "cd '$REPO' && '$STAMP' status 2>&1"
  [ "$status" -eq 0 ]
  run bash -c "cd '$REPO' && '$STAMP' status --bogus 2>&1"
  [ "$status" -eq 2 ]
  assert_contains "$output" "only --worktree"
  run bash -c "cd '$REPO' && '$STAMP' status --worktree 2>&1"
  [ "$status" -eq 2 ]
  assert_contains "$output" "needs a path argument"
  run bash -c "cd '$REPO' && '$STAMP' status --worktree /nonexistent/xyz 2>&1"
  [ "$status" -eq 2 ]
  assert_contains "$output" "not a directory"
}
