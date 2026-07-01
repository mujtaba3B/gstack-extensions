#!/bin/bash
# PreToolUse hook on AskUserQuestion. Enforces the QA-plan approval PRESENTATION:
# any question with the reserved header "QA plan" must carry the plan summary
# inside an option's `preview` pane, so the human reads the plan and the approval
# in one unmissable modal (the two-phase QA-plan approval policy; the prose form
# "plan dumped in chat, bare Approve modal after it" is what this blocks).
#
# A conforming question:
#   - is single-select (previews do not render on multiSelect questions);
#   - has at least one option whose preview carries BOTH literal headings
#     "DEVELOPMENT QA" and "PRODUCTION QA", each at the start of a line;
#   - that preview fits the box: <= 20 lines, <= 60 chars per line. The preview
#     is a SUMMARY (change-under-test in 1-2 lines, one line per QA item); the
#     full canonical plan lives in the PR body, written by /qa:plan Step 4.
#
# Questions with any other header are never touched. /qa:plan Step 6 states the
# same contract from the skill side; this hook is the machine gate behind it.
#
# Bypass: QA_PLAN_PRESENT_OK=1 in the environment, same posture as the other gates.
#
# Output protocol (Claude Code PreToolUse hook):
#   exit 0 + empty stdout                            -> allow
#   stdout JSON {"decision":"block","reason":"..."}  -> block, reason shown to Claude
# (Never use exit 2 to carry the reason: on exit 2 the reason goes to stderr and
# Claude does not see stdout, so it cannot self-correct.)

set -u

MAX_LINES=20
MAX_COLS=60

[ "${QA_PLAN_PRESENT_OK:-}" = "1" ] && exit 0

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || { exit 0; }   # fail open if jq missing

TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')
[ "$TOOL" = "AskUserQuestion" ] || exit 0

# One verdict per "QA plan" question: "ok", "multiselect", "missing", or
# "oversized". The first non-ok verdict drives the block.
VERDICT=$(printf '%s' "$PAYLOAD" | jq -r --argjson maxl "$MAX_LINES" --argjson maxc "$MAX_COLS" '
  [ .tool_input.questions[]? | select(.header == "QA plan") |
    if .multiSelect == true then "multiselect"
    else
      ( [ .options[]? | (.preview // "")
          | select(test("(^|\n)DEVELOPMENT QA") and test("(^|\n)PRODUCTION QA")) ] ) as $plans |
      if ($plans | length) == 0 then "missing"
      elif ([ $plans[] | rtrimstr("\n") | split("\n")
              | select(length <= $maxl and (map(length) | max // 0) <= $maxc) ]
            | length) == 0 then "oversized"
      else "ok"
      end
    end
  ] | map(select(. != "ok")) | first // empty')

[ -z "$VERDICT" ] && exit 0

block() {
  jq -nc --arg r "$1" '{decision:"block",reason:$r}'
  exit 0
}

case "$VERDICT" in
  multiselect)
    block "Blocked: a \"QA plan\" approval must be single-select; the preview pane does not render on multiSelect questions. Re-fire with multiSelect: false and the plan summary in the Approve option's preview. Bypass: QA_PLAN_PRESENT_OK=1." ;;
  missing)
    block "Blocked: a \"QA plan\" approval must carry the QA plan summary inside an option's preview pane (see /qa:plan Step 6). Re-fire AskUserQuestion with the Approve option's preview holding the summary: change-under-test in 1-2 lines, then the DEVELOPMENT QA and PRODUCTION QA items (those two headings must appear literally) and the QA driver line, max ${MAX_LINES} lines x ${MAX_COLS} chars per line. Bypass: QA_PLAN_PRESENT_OK=1." ;;
  oversized)
    block "Blocked: the QA plan preview exceeds the fit-in-box cap (${MAX_LINES} lines x ${MAX_COLS} chars per line) and would truncate. Summarize, do not dump: keep the change description to 1-2 lines, compress each QA item to one line, and leave the full plan in the PR body. Bypass: QA_PLAN_PRESENT_OK=1." ;;
esac

exit 0
