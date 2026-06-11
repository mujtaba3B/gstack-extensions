#!/usr/bin/env bats
# Tests for qa-plan-present-gate.sh: the PreToolUse AskUserQuestion hook that
# requires "QA plan" approvals to carry a fit-in-box plan summary in an option
# preview. Pure stdin -> stdout; no network, no git.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/qa-plan-present-gate.sh"
}

# A conforming preview: both headings, well under 20 lines x 60 cols.
GOOD_PREVIEW="QA PLAN: example\n\nDEVELOPMENT QA (before PR)\n1. run the bats file alone\n\nPRODUCTION QA (after deploy)\n- smoke the live endpoint"

# gate <questions-json> : pipe an AskUserQuestion payload, echo "block"/"allow".
gate() {
  local payload out
  payload=$(printf '{"tool_name":"AskUserQuestion","tool_input":{"questions":%s}}' "$1")
  out=$(printf '%s' "$payload" | bash "$SCRIPT" 2>/dev/null)
  if printf '%s' "$out" | grep -q '"decision":"block"'; then echo "block"; else echo "allow"; fi
}

# question <header> <multiSelect> <preview-json-or-null> : one-question array.
question() {
  jq -nc --arg h "$1" --argjson ms "$2" --argjson p "$3" \
    '[{question:"Approve?",header:$h,multiSelect:$ms,
       options:[({label:"Approve",description:"yes"}
                 + (if $p == null then {} else {preview:$p} end)),
                {label:"Rework it",description:"no"}]}]'
}

# ---- blocks the non-conforming forms ----------------------------------------

@test "blocks QA plan question with no preview at all" {
  q=$(question "QA plan" false null)
  [ "$(gate "$q")" = "block" ]
}

@test "blocks QA plan preview missing the PRODUCTION QA heading" {
  p=$(jq -nc '"DEVELOPMENT QA\n- only dev items here"')
  q=$(question "QA plan" false "$p")
  [ "$(gate "$q")" = "block" ]
}

@test "blocks QA plan preview over 20 lines" {
  p=$(jq -nc '("DEVELOPMENT QA\nPRODUCTION QA\n" + ([range(25)|"line"]|join("\n")))')
  q=$(question "QA plan" false "$p")
  [ "$(gate "$q")" = "block" ]
}

@test "blocks QA plan preview with a line over 60 chars" {
  p=$(jq -nc '("DEVELOPMENT QA\n" + ("x"*80) + "\nPRODUCTION QA")')
  q=$(question "QA plan" false "$p")
  [ "$(gate "$q")" = "block" ]
}

@test "blocks multiSelect QA plan question even with a good preview" {
  p=$(printf '%b' "$GOOD_PREVIEW" | jq -Rs .)
  q=$(question "QA plan" true "$p")
  [ "$(gate "$q")" = "block" ]
}

# ---- allows the conforming form ----------------------------------------------

@test "allows QA plan question with a conforming preview" {
  p=$(printf '%b' "$GOOD_PREVIEW" | jq -Rs .)
  q=$(question "QA plan" false "$p")
  [ "$(gate "$q")" = "allow" ]
}

@test "allows when only one of several options carries the plan preview" {
  p=$(printf '%b' "$GOOD_PREVIEW" | jq -Rs .)
  q=$(jq -nc --argjson p "$p" \
    '[{question:"Approve?",header:"QA plan",multiSelect:false,
       options:[{label:"Approve",description:"yes",preview:$p},
                {label:"Rework it",description:"no"},
                {label:"Skip the gate",description:"build unapproved"}]}]')
  [ "$(gate "$q")" = "allow" ]
}

@test "allows exactly 20 lines with a trailing newline (no false oversized)" {
  p=$(jq -nc '(["DEVELOPMENT QA","PRODUCTION QA"] + [range(18)|"item"] | join("\n")) + "\n"')
  q=$(question "QA plan" false "$p")
  [ "$(gate "$q")" = "allow" ]
}

@test "blocks when headings appear only mid-line prose, not at line start" {
  p=$(jq -nc '"this change needs no DEVELOPMENT QA and no PRODUCTION QA at all"')
  q=$(question "QA plan" false "$p")
  [ "$(gate "$q")" = "block" ]
}

# ---- out of scope ------------------------------------------------------------

@test "ignores questions with other headers" {
  q=$(question "Enforcement" false null)
  [ "$(gate "$q")" = "allow" ]
}

@test "ignores non-AskUserQuestion tools" {
  run bash -c 'printf "%s" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi\"}}" | bash "'"$SCRIPT"'"'
  [ -z "$output" ]
}

@test "ignores payload with no questions array" {
  run bash -c 'printf "%s" "{\"tool_name\":\"AskUserQuestion\",\"tool_input\":{}}" | bash "'"$SCRIPT"'"'
  [ -z "$output" ]
}

# ---- bypass ------------------------------------------------------------------

@test "QA_PLAN_PRESENT_OK=1 bypasses the gate" {
  q=$(question "QA plan" false null)
  payload=$(printf '{"tool_name":"AskUserQuestion","tool_input":{"questions":%s}}' "$q")
  out=$(printf '%s' "$payload" | QA_PLAN_PRESENT_OK=1 bash "$SCRIPT" 2>/dev/null)
  [ -z "$out" ]
}
