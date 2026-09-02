#!/bin/bash
# PreToolUse hook on Bash. Gate 2 of the QA-plan approval policy: in an OPTED-IN
# ~/dev repo, block `gh pr create` until the branch has an approved two-phase QA
# plan (an approval stamp written by /qa:plan). "The plan is in place before the
# PR goes up" (the two-phase QA-plan approval policy).
#
# This is a separate hook from ship-pr-gate.sh (which forces /ship to be the PR
# path); keeping it separate leaves that tested gate untouched. Both run on the
# same Bash PreToolUse event; either can block. The spike escape hatch is NOT
# honored here: a spike that graduates to a PR is shipping, so it needs a plan
# (running /qa:plan on the branch writes the stamp and unblocks).
#
# Output protocol (Claude Code PreToolUse hook):
#   exit 0 + empty stdout                          -> allow
#   stdout JSON {"decision":"block","reason":...}  -> block, reason shown to Claude
#
# Fail-OPEN: any missing dependency, file outside ~/dev, no marker, or
# unresolvable branch leaves the create ALLOWED. The deploy gate is the backstop.

set -u

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty')
# Match `gh pr create` at command position (line start or after a shell
# separator), tolerating env-var prefixes and an absolute/relative path to gh, so
# the phrase inside a quoted arg / heredoc body does not trip the gate.
printf '%s' "$CMD" | grep -Eq '(^|[;&|(])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|]*/)?gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' || exit 0

# Resolve the repo the command targets, honoring a leading `cd <dir>` (hooks run
# from the session cwd, not the cwd a `cd ... &&` switched into).
WORKDIR=$(printf '%s\n' "$CMD" | sed -nE 's/^[[:space:]]*cd[[:space:]]+([^[:space:];&|]+).*/\1/p' | head -1)
case "$WORKDIR" in "~") WORKDIR="$HOME" ;; "~/"*) WORKDIR="${HOME}/${WORKDIR#\~/}" ;; esac
{ [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; } || WORKDIR="$PWD"

TOP=$(git -C "$WORKDIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
case "$TOP" in
  "$HOME/dev"|"$HOME/dev/"*) ;;
  *) exit 0 ;;
esac

# Effective gate config. Every repo under the policy root is gated by DEFAULT,
# resolved from the tracked ~/dev/gate-policy.json; per-repo tuning lives in that
# file's `overrides` block, keyed by repo identity. There are no marker files.
# Returns non-zero only when the repo is genuinely out of scope, in which case we
# allow. See gate-policy-lib.sh for why.
GPLIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gate-policy-lib.sh"
[ -f "$GPLIB" ] || exit 0
# shellcheck source=/dev/null
. "$GPLIB"
MARKER=$(gp_gate_config "$TOP" qa-plan) || exit 0

LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa-plan-gate-lib.sh"
[ -f "$LIB" ] || exit 0
# shellcheck source=/dev/null
. "$LIB"

qpg_gate_enabled "$MARKER" pr || exit 0   # pr gate not enabled -> allow

# Base scoping: a create with --base outside the marker's list is allowed.
PRBASE=$(printf '%s' "$CMD" | grep -oE '(--base[ =]|[[:space:]]-B[ =])[^[:space:]]+' | head -1 | sed -E 's/.*[ =]//')
if [ -n "$PRBASE" ] && [ "$(qpg_base_in_scope "$MARKER" "$PRBASE")" = "out" ]; then exit 0; fi

BRANCH=$(git -C "$WORKDIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
[ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || exit 0

# Bookkeeping fast lane: a branch whose ENTIRE diff vs base is docs / the
# cross-host inventory is a zero-risk, non-code change. Opening its PR does not
# need an approved two-phase plan - the merge gate still runs CI + CodeRabbit on
# it, only the plan ceremony is waived. Fails safe: if the base ref cannot be
# resolved or the diff is empty, we fall through to the normal stamp check below,
# never to a false allow. The classifier (qpg_is_bookkeeping, sourced from LIB)
# itself fails closed: any one non-allowlisted path means "no".
DIFFBASE="$PRBASE"
[ -n "$DIFFBASE" ] || DIFFBASE=$(printf '%s' "$MARKER" | jq -r '(.base_branches // ["main"])[0] // "main"' 2>/dev/null || echo "main")
BASEREF=""
for _cand in "origin/$DIFFBASE" "$DIFFBASE"; do
  if git -C "$WORKDIR" rev-parse -q --verify "$_cand" >/dev/null 2>&1; then BASEREF="$_cand"; break; fi
done
if [ -n "$BASEREF" ]; then
  CHANGED=$(git -C "$WORKDIR" diff --name-only "$BASEREF...HEAD" 2>/dev/null)
  if [ -n "$CHANGED" ] && [ "$(qpg_is_bookkeeping "$CHANGED")" = "yes" ]; then
    LOG="$HOME/.claude/qa-plan-gate.log"
    printf '%s pr-gate ALLOW(bookkeeping) branch=%s files=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$(printf '%s' "$CHANGED" | tr '\n' ',')" >> "$LOG" 2>/dev/null || true
    exit 0
  fi
fi

GITDIR=$(git -C "$WORKDIR" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
STAMP=$(cat "$GITDIR/qa-plan-approved" 2>/dev/null || echo "")
VERDICT=$(qpg_stamp_valid "$STAMP" "$BRANCH")
[ "$VERDICT" = "valid" ] && exit 0

LOG="$HOME/.claude/qa-plan-gate.log"
printf '%s pr-gate BLOCK branch=%s verdict=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$VERDICT" >> "$LOG" 2>/dev/null || true

REASON="QA-plan gate: this repo requires an approved two-phase QA plan BEFORE the PR goes up. Branch \`$BRANCH\` has no approved-plan stamp [${VERDICT}]. This repo's QA-plan policy: the Development + Production QA plan must be presented to and approved by the human before opening the PR. Run \`/qa:plan\`: it writes the two-phase plan into the PR body, presents it for approval, and on your yes writes the stamp that unblocks \`gh pr create\` (and \`/ship\` folds the plan into the body). A spike branch is not exempt here: opening a PR is shipping, so the plan is required."
_BP_REF=$(qpg_build_procedure_ref "$MARKER")
[ -n "$_BP_REF" ] && REASON="$REASON (This repo also follows your workspace build procedure: $_BP_REF.)"
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
