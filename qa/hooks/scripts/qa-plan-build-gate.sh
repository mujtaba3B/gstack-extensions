#!/bin/bash
# PreToolUse hook on Edit|Write. Gate 1 of the QA-plan approval policy: in an
# OPTED-IN ~/dev repo, block edits to application SOURCE on a feature branch until
# the two-phase QA plan has been approved (an approval stamp exists for the
# branch). The plan is approved-and-stamped by /qa:plan's closing AskUserQuestion.
#
# "Approve the plan, THEN build" (the two-phase QA-plan approval policy). Reading
# code is never gated (this is Edit|Write only), so you can fully investigate
# before writing the plan. Genuine spikes bypass via a `spike/` branch.
#
# Output protocol (Claude Code PreToolUse hook):
#   exit 0 + empty stdout                          -> allow
#   stdout JSON {"decision":"block","reason":...}  -> block, reason shown to Claude
#
# Fail-OPEN posture (same as the merge / ship gates): any missing dependency
# (jq/git), file outside ~/dev, no marker, or unresolvable branch leaves the edit
# ALLOWED. A local gate that fails closed on its own bug trains the human to rip
# it out. The deploy gate (QA-passed at merge) is the hard backstop.

set -u

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')
case "$TOOL" in Edit|Write|MultiEdit) ;; *) exit 0 ;; esac

FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // empty')
[ -n "$FILE" ] || exit 0

# Resolve a relative path against the session cwd from the payload.
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty')
case "$FILE" in /*) ;; *) [ -n "$CWD" ] && FILE="$CWD/$FILE" ;; esac

# Find an existing ancestor dir of the (possibly not-yet-created) target so we can
# ask git which repo it lives in.
DIR=$(dirname "$FILE")
while [ ! -d "$DIR" ] && [ "$DIR" != "/" ] && [ "$DIR" != "." ]; do DIR=$(dirname "$DIR"); done
[ -d "$DIR" ] || exit 0

TOP=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
# No path pre-filter here: gp_gate_config below makes the whole scope decision,
# and a duplicate path-only test would wrongly exempt a worktree parked outside
# ~/dev (a worktree of the ~/dev repo itself has to live outside it).

LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa-plan-gate-lib.sh"
[ -f "$LIB" ] || exit 0
# shellcheck source=/dev/null
. "$LIB"

# Cheapest discriminator FIRST. This hook fires on every Edit/Write, and most of
# them are docs, config or tests, which are carved out regardless of policy. The
# classifier is pure string matching; resolving the gate config costs a git call
# and a couple of jq calls, so doing it first would tax every markdown edit for an
# answer that never changes. (Order did not matter when the opt-in check was a
# single stat; it does now.)
REL="${FILE#"$TOP"/}"
qpg_path_needs_plan "$REL" >/dev/null || exit 0

# Effective gate config; see qa-plan-pr-gate.sh and gate-policy-lib.sh. Inherited
# by default, so a fresh worktree with no marker file is gated like its main checkout.
GPLIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gate-policy-lib.sh"
[ -f "$GPLIB" ] || exit 0
# shellcheck source=/dev/null
. "$GPLIB"
MARKER=$(gp_gate_config "$TOP" qa-plan) || exit 0

qpg_gate_enabled "$MARKER" build || exit 0   # build gate not enabled -> allow

BRANCH=$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
[ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || exit 0   # detached / unresolved -> allow

# On a base branch itself (main) there is no feature work to gate here.
if [ "$(qpg_base_in_scope "$MARKER" "$BRANCH")" = "in" ]; then exit 0; fi

# Spike escape hatch.
if qpg_is_spike "$BRANCH" >/dev/null; then exit 0; fi

GITDIR=$(git -C "$DIR" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
STAMP=$(cat "$GITDIR/qa-plan-approved" 2>/dev/null || echo "")
VERDICT=$(qpg_stamp_valid "$STAMP" "$BRANCH")
[ "$VERDICT" = "valid" ] && exit 0

# A pre-fix stamp (no approval_source) still lets you BUILD but never ship; see
# qpg_unattested_disposition for why the build and PR gates split here. Logged
# rather than silent, so the migration is visible in the gate log instead of
# looking like the stamp was fine all along.
if [ "$VERDICT" = "unattested" ] && [ "$(qpg_unattested_disposition build)" = "allow" ]; then
  printf '%s build-gate ALLOW(unattested-prefix-stamp) branch=%s file=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$REL" >> "$HOME/.claude/qa-plan-gate.log" 2>/dev/null || true
  exit 0
fi

# Blocked: record for visibility (a rotted/bypassed gate should be auditable).
LOG="$HOME/.claude/qa-plan-gate.log"
printf '%s build-gate BLOCK branch=%s file=%s verdict=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$REL" "$VERDICT" >> "$LOG" 2>/dev/null || true

REASON="QA-plan gate: this repo requires an approved two-phase QA plan BEFORE building. You are about to edit source (\`$REL\`) on \`$BRANCH\` with no approved-plan stamp [${VERDICT}]. This repo's QA-plan policy: the Development + Production QA plan is presented to and approved by the human before implementation. Run \`/qa:plan\` now: it pulls the success criteria, writes the two-phase plan, presents it for approval, and on your yes writes the stamp that unblocks editing. Reading code is NOT gated, so investigate freely first. For a genuine spike/exploration where the plan cannot be written yet, branch as \`spike/<name>\` to bypass this gate. Docs, tests, and config edits are also ungated."
_BP_REF=$(qpg_build_procedure_ref "$MARKER")
[ -n "$_BP_REF" ] && REASON="$REASON (This repo also follows your workspace build procedure: $_BP_REF.)"
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
