#!/bin/bash
# PreToolUse hook on AskUserQuestion for the QA-plan approval PRESENTATION.
#
# As of Template B (/qa:plan v1.8.0) the QA plan is rendered FULL-WIDTH in a
# turn-final chat message (the whole `## QA` table + footer), and the approval
# question is a SLIM AskUserQuestion (header "QA plan": Approve / Rework it /
# Skip the gate) that no longer crams the plan into an option preview. So this
# gate no longer requires a fit-in-box plan summary, the literal DEVELOPMENT QA /
# PRODUCTION QA headings, single-select, or any 20x60 size cap inside the preview.
#
# The hook is kept (wired in hooks/hooks.json) but is now an allow: a "QA plan"
# question is permitted regardless of preview content. Questions with any other
# header were never touched and still are not. The plan-in-chat contract is
# stated from the skill side in /qa:plan Step 6.
#
# Bypass: QA_PLAN_PRESENT_OK=1 in the environment, same posture as the other
# gates (kept for parity even though the gate now always allows).
#
# Output protocol (Claude Code PreToolUse hook):
#   exit 0 + empty stdout                            -> allow
#   stdout JSON {"decision":"block","reason":"..."}  -> block, reason shown to Claude
# (Never use exit 2 to carry the reason: on exit 2 the reason goes to stderr and
# Claude does not see stdout, so it cannot self-correct.)

set -u

[ "${QA_PLAN_PRESENT_OK:-}" = "1" ] && exit 0

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || { exit 0; }   # fail open if jq missing

TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')
[ "$TOOL" = "AskUserQuestion" ] || exit 0

# Template B: the plan lives in chat, not in the preview. Nothing to enforce on a
# "QA plan" question here anymore; allow it (and every other header) through.
exit 0
