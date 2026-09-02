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
# No path pre-filter here: gp_gate_config below makes the whole scope decision,
# and a duplicate path-only test would wrongly exempt a worktree parked outside
# ~/dev (a worktree of the ~/dev repo itself has to live outside it).

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
TLIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa-plan-token-lib.sh"
{ [ -f "$LIB" ] && [ -f "$TLIB" ]; } || exit 0
# shellcheck source=/dev/null
. "$LIB"
# shellcheck source=/dev/null
. "$TLIB"

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

# Plan-drift input: digest the `## QA` section of the body this create is about
# to publish, so a plan edited AFTER the human approved it does not ship on the
# old approval. Best-effort by design: when the body cannot be read (an inline
# --body, an unreadable path, no QA section, no sha256 tool) CURRENT_DIGEST stays
# empty and qpg_stamp_valid skips the drift check, leaving the stamp requirement
# itself untouched. This check can only ADD a block, never remove one.
LOG="$HOME/.claude/qa-plan-gate.log"
CURRENT_DIGEST=""
_skipwhy=""
_bodyfile=$(qpg_body_file_from_cmd "$CMD")
if [ -z "$_bodyfile" ]; then
  _skipwhy="no-body-file-flag"
else
  case "$_bodyfile" in
    \$*) _skipwhy="unexpanded-body-path" ;;   # e.g. /ship's --body-file "$PR_BODY_FILE"
    /*) : ;;
    *) _bodyfile="$WORKDIR/$_bodyfile" ;;
  esac
  if [ -z "$_skipwhy" ]; then
    if [ -r "$_bodyfile" ]; then
      _qasec=$(qpg_extract_qa_section "$(cat "$_bodyfile" 2>/dev/null || echo "")")
      if [ -n "$_qasec" ]; then
        CURRENT_DIGEST=$(qpg_plan_digest "$_qasec")
        [ -n "$CURRENT_DIGEST" ] || _skipwhy="no-sha256-tool"
      else
        _skipwhy="no-qa-section-in-body"
      fi
    else
      _skipwhy="unreadable-body-file"
    fi
  fi
fi
# Never let the drift check no-op silently. A green gate that quietly checked
# nothing is how a dead feature survives a passing test suite: every drift test
# passed an already-expanded absolute path, a shape /ship never produces.
[ -n "$_skipwhy" ] && printf '%s pr-gate drift-check-skipped(%s) branch=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_skipwhy" "$BRANCH" >> "$LOG" 2>/dev/null || true

VERDICT=$(qpg_stamp_valid "$STAMP" "$BRANCH" "$CURRENT_DIGEST")
[ "$VERDICT" = "valid" ] && exit 0

# A pre-fix stamp (no approval_source) is honored rather than blocked; see
# qpg_unattested_disposition for why blocking it produced an unsatisfiable gate.
# Logged, never silent, so the remaining population stays visible.
if [ "$VERDICT" = "unattested" ]; then
  _mtime=$(qpt_stamp_mtime "$GITDIR/qa-plan-approved" || echo "")
  _win=$(qpt_unattested_in_window "$_mtime")
  # A legacy stamp is honored at PR time only if it carries a REAL digest. Without
  # one the drift check has nothing to compare and skips, so a digest-less stamp
  # would be a permanent, drift-immune standing approval: strictly LESS checked
  # than a forged token, which at least yields a digest that does get compared.
  # A genuine pre-fix stamp written through the old --digest path has one. The
  # build gate stays lenient, so this costs a re-approval at ship time only.
  _sdig=$(printf '%s' "$STAMP" | jq -r '.criteria_digest // empty' 2>/dev/null || echo "")
  { [ -n "$_sdig" ] && [ "$_sdig" != "none" ]; } || _win="out"
  if [ "$(qpg_unattested_disposition pr "$_win")" = "allow" ]; then
    printf '%s pr-gate ALLOW(unattested-prefix-stamp) branch=%s mtime=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "${_mtime:-?}" >> "$LOG" 2>/dev/null || true
    exit 0
  fi
fi

printf '%s pr-gate BLOCK branch=%s verdict=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$VERDICT" >> "$LOG" 2>/dev/null || true

# The two verdicts introduced with the approval-token fix get their own wording,
# because "no approved-plan stamp" would be actively misleading for both: in one
# case a stamp exists but predates the fix, in the other a stamp exists and is
# valid but covers a DIFFERENT plan than the one being shipped.
case "$VERDICT" in
  plan-changed)
    REASON="QA-plan gate: the QA plan changed after it was approved. Branch \`$BRANCH\` has a valid approval stamp, but the \`## QA\` section in the PR body you are about to create does not match the plan the human approved (the stamp's criteria_digest differs from the digest of the body's plan). An approval covers the plan it was given for, not whatever the plan later became. Re-run \`/qa:plan\` so the current plan is presented and approved on its own terms, then retry. If the only difference is tick state, that is normalized out and would not have triggered this, so the plan text itself really did change."
    ;;
  unattested)
    REASON="QA-plan gate: branch \`$BRANCH\` carries a stamp with no proof a human approved it (no \`approval_source\`), and the stamp file is NOT old enough to be a genuine pre-fix approval. Stamps written before the approval-token fix are honored; one written after it was either hand-written or produced by a writer that should no longer exist, so it is refused. Run \`/qa:plan\` and approve the plan; that mints the token the stamp writer requires."
    ;;
  *)
    REASON="QA-plan gate: this repo requires an approved two-phase QA plan BEFORE the PR goes up. Branch \`$BRANCH\` has no approved-plan stamp [${VERDICT}]. This repo's QA-plan policy: the Development + Production QA plan must be presented to and approved by the human before opening the PR. Run \`/qa:plan\`: it writes the two-phase plan into the PR body, presents it for approval, and on your yes writes the stamp that unblocks \`gh pr create\` (and \`/ship\` folds the plan into the body). A spike branch is not exempt here: opening a PR is shipping, so the plan is required."
    ;;
esac
_BP_REF=$(qpg_build_procedure_ref "$MARKER")
[ -n "$_BP_REF" ] && REASON="$REASON (This repo also follows your workspace build procedure: $_BP_REF.)"
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
