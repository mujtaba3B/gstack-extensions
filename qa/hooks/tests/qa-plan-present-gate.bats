#!/usr/bin/env bats
# Tests for qa-plan-present-gate.sh. As of Template B (/qa:plan v1.8.0) the QA
# plan is rendered full-width in chat and the approval question is slim, so this
# gate no longer requires a fit-in-box plan summary in an option preview. It now
# ALLOWS any "QA plan"-headered question regardless of preview content, and still
# ignores questions with any other header. Pure stdin -> stdout; no network, no git.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/qa-plan-present-gate.sh"
}

# A Template-B-era preview: a one-line option description, no crammed plan.
SLIM_PREVIEW="Approve the QA plan shown above and build against it."

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

# ---- allows the QA plan question regardless of preview content ----------------

@test "allows QA plan question with no preview at all (plan is in chat now)" {
  q=$(question "QA plan" false null)
  [ "$(gate "$q")" = "allow" ]
}

@test "allows QA plan question with only a slim one-line option description" {
  p=$(printf '%s' "$SLIM_PREVIEW" | jq -Rs .)
  q=$(question "QA plan" false "$p")
  [ "$(gate "$q")" = "allow" ]
}

@test "allows a multiSelect QA plan question (no single-select requirement anymore)" {
  q=$(question "QA plan" true null)
  [ "$(gate "$q")" = "allow" ]
}

@test "allows the three-option Approve / Rework / Skip form with no crammed plan" {
  q=$(jq -nc \
    '[{question:"Approve?",header:"QA plan",multiSelect:false,
       options:[{label:"Approve",description:"build against the plan above"},
                {label:"Rework it",description:"change the plan"},
                {label:"Skip the gate",description:"build unapproved"}]}]')
  [ "$(gate "$q")" = "allow" ]
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

@test "QA_PLAN_PRESENT_OK=1 bypasses the gate (allows, empty stdout)" {
  q=$(question "QA plan" false null)
  payload=$(printf '{"tool_name":"AskUserQuestion","tool_input":{"questions":%s}}' "$q")
  out=$(printf '%s' "$payload" | QA_PLAN_PRESENT_OK=1 bash "$SCRIPT" 2>/dev/null)
  [ -z "$out" ]
}
