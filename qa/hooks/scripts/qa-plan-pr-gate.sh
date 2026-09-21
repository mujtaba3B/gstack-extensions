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
# Literal "~/" is a match PATTERN here (input that starts with a tilde), not an
# expansion; SC2088 misreads it, so silence it for this case.
# shellcheck disable=SC2088
case "$WORKDIR" in "~") WORKDIR="$HOME" ;; "~/"*) WORKDIR="${HOME}/${WORKDIR#\~/}" ;; esac
{ [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; } || WORKDIR="$PWD"

# Libs first. The cross-cwd bind below asks the policy whether a candidate ~/dev
# checkout is governed and uses the repo resolver, so gate-policy-lib.sh, the pure
# gate lib, the token lib, and the repo lib must all be sourced BEFORE resolution,
# not after. Each fails OPEN (allow) when absent, like every other unmet dependency
# in this gate.
GPLIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gate-policy-lib.sh"
[ -f "$GPLIB" ] || exit 0
# shellcheck source=/dev/null
. "$GPLIB"
LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa-plan-gate-lib.sh"
TLIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa-plan-token-lib.sh"
RLIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa-plan-repo-lib.sh"
{ [ -f "$LIB" ] && [ -f "$TLIB" ] && [ -f "$RLIB" ]; } || exit 0
# shellcheck source=/dev/null
. "$LIB"
# shellcheck source=/dev/null
. "$TLIB"
# shellcheck source=/dev/null
. "$RLIB"
LOG=$(qpt_gate_log)

# Bind (TOP, REPODIR, BRANCH, GITDIR, MARKER) one of two ways:
#
#   CLASSIC: the cd / session cwd is a governed ~/dev repo, and the command does not
#     name a DIFFERENT repo via --repo/-R/GH_REPO. BRANCH is that worktree's checked-out
#     head, GITDIR its git dir, REPODIR the cwd - byte-identical to this gate's
#     long-standing behavior.
#   CROSS-CWD: the cwd is NOT a governed ~/dev repo (a session anchored in a Drive/tmp
#     workspace), or names another repo. Bind to the governed ~/dev WORKTREE of the
#     target repo that is on the PR's --head branch and read ITS stamp. This is the
#     QA-plan twin of the ship gate's out-of-~/dev binding (ship-gate-repo-lib.sh's
#     sg_dev_checkout_for_repo); it additionally needs the branch, because the QA-plan
#     stamp is per-branch and lives in the per-worktree git dir the stamp writer
#     targeted (gstack-extensions#89). Without this a create from outside ~/dev found
#     the repo "out of scope" and the QA-plan policy silently did not fire at all.
#
# Anything unresolvable -> out of scope -> ALLOW, logged (never a silent exit), the
# gate's standing fail-open posture with the deploy gate as the backstop.
TARGET=$(qpg_repo_from_flags "$CMD" || true)
HEADBR=$(qpg_head_branch_from_cmd "$CMD" || true)
CWD_TOP=""; CWD_ORIGIN=""
if CWD_TOP=$(git -C "$WORKDIR" rev-parse --show-toplevel 2>/dev/null) && gp_gate_config "$CWD_TOP" qa-plan >/dev/null 2>&1; then
  CWD_ORIGIN=$(qpg_norm_repo "$(git -C "$WORKDIR" remote get-url origin 2>/dev/null)")
else
  CWD_TOP=""
fi

TOP=""; REPODIR=""; BRANCH=""; GITDIR=""
if [ -n "$CWD_TOP" ] && { [ -z "$TARGET" ] || [ "$TARGET" = "$CWD_ORIGIN" ]; }; then
  TOP="$CWD_TOP"; REPODIR="$WORKDIR"
  BRANCH=$(git -C "$WORKDIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  GITDIR=$(git -C "$WORKDIR" rev-parse --absolute-git-dir 2>/dev/null || echo "")
  MARKER=$(gp_gate_config "$TOP" qa-plan) || exit 0
elif [ -n "$TARGET" ] && [ -n "$HEADBR" ] && RESOLVED=$(qpg_dev_worktree_for_repo_branch "$TARGET" "$HEADBR"); then
  TOP=${RESOLVED%%$'\t'*}; GITDIR=${RESOLVED#*$'\t'}; REPODIR="$TOP"; BRANCH="$HEADBR"
  if ! MARKER=$(gp_gate_config "$TOP" qa-plan); then
    printf '%s pr-gate OUT-OF-SCOPE(bound-repo-ungoverned) target=%s head=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TARGET" "$HEADBR" >> "$LOG" 2>/dev/null || true
    exit 0
  fi
else
  printf '%s pr-gate OUT-OF-SCOPE(no-bind) workdir=%s target=%s head=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WORKDIR" "${TARGET:-none}" "${HEADBR:-none}" >> "$LOG" 2>/dev/null || true
  exit 0
fi
[ -n "$GITDIR" ] || exit 0

qpg_gate_enabled "$MARKER" pr || exit 0   # pr gate not enabled -> allow

# Base scoping: a create with --base outside the marker's list is allowed.
PRBASE=$(printf '%s' "$CMD" | grep -oE '(--base[ =]|[[:space:]]-B[ =])[^[:space:]]+' | head -1 | sed -E 's/.*[ =]//')
if [ -n "$PRBASE" ] && [ "$(qpg_base_in_scope "$MARKER" "$PRBASE")" = "out" ]; then exit 0; fi

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
  if git -C "$REPODIR" rev-parse -q --verify "$_cand" >/dev/null 2>&1; then BASEREF="$_cand"; break; fi
done
if [ -n "$BASEREF" ]; then
  # REPODIR is checked out on BRANCH in both bind paths, so HEAD == the head branch.
  CHANGED=$(git -C "$REPODIR" diff --name-only "$BASEREF...HEAD" 2>/dev/null)
  if [ -n "$CHANGED" ] && [ "$(qpg_is_bookkeeping "$CHANGED")" = "yes" ]; then
    printf '%s pr-gate ALLOW(bookkeeping) branch=%s files=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$(printf '%s' "$CHANGED" | tr '\n' ',')" >> "$LOG" 2>/dev/null || true
    exit 0
  fi
fi

# GITDIR was resolved in the bind above (the classic cwd git dir, or the cross-cwd
# target worktree's git dir), so the stamp is read from wherever the writer put it.
STAMP=$(cat "$GITDIR/qa-plan-approved" 2>/dev/null || echo "")

# Plan-drift input: digest the `## QA` section of the body this create is about
# to publish, so a plan edited AFTER the human approved it does not ship on the
# old approval. Best-effort by design: when the body cannot be read (an inline
# --body, an unreadable path, no QA section, no sha256 tool) CURRENT_DIGEST stays
# empty and qpg_stamp_valid skips the drift check, leaving the stamp requirement
# itself untouched. This check can only ADD a block, never remove one.
LOG=$(qpt_gate_log)
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
  printf '%s pr-gate BLOCK(unattested) branch=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" >> "$LOG" 2>/dev/null || true
fi

printf '%s pr-gate BLOCK branch=%s verdict=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$VERDICT" >> "$LOG" 2>/dev/null || true

# Cached copies of the stamp writer that predate the approval-token guard. Scanned
# only on the BLOCK path (this is where an agent goes looking for another writer),
# so an allowed edit never pays for the directory walk.
_STALE=""
for _d in "$(qpt_claude_dir)/plugins/cache/gstack-extensions/qa"/*; do
  [ -d "$_d" ] || continue
  if [ "$(qpt_writer_is_guarded "$_d/hooks/scripts/qa-plan-stamp.sh")" = "no" ]; then
    _STALE="$_STALE $(basename "$_d")"
  fi
done
_STALE="${_STALE# }"
_STALE_WARN=$(qpg_stale_writer_warning "$_STALE" || true)

# The two verdicts introduced with the approval-token fix get their own wording,
# because "no approved-plan stamp" would be actively misleading for both: in one
# case a stamp exists but predates the fix, in the other a stamp exists and is
# valid but covers a DIFFERENT plan than the one being shipped.
case "$VERDICT" in
  plan-changed)
    REASON="QA-plan gate: the QA plan changed after it was approved. Branch \`$BRANCH\` has a valid approval stamp, but the \`## QA\` section in the PR body you are about to create does not match the plan the human approved (the stamp's criteria_digest differs from the digest of the body's plan). An approval covers the plan it was given for, not whatever the plan later became. Re-run \`/qa:plan\` so the current plan is presented and approved on its own terms, then retry. If the only difference is tick state, that is normalized out and would not have triggered this, so the plan text itself really did change."
    ;;
  unattested)
    # The gate-specific context stays here; the REMEDY comes from qpg_block_advice
    # so both gates say the same thing. This arm used to end with "Run /qa:plan and
    # approve the plan", which omits the step that actually matters: the stale
    # stamp has to be CLEARED first, because /qa:plan does not remove it. That
    # omission is what turned the 2026-09-03 block into a dead end.
    REASON="QA-plan gate: branch \`$BRANCH\` carries a stamp with no proof a human approved it (no trusted \`approval_source\`). Such a stamp was either hand-written or produced by a writer that predates the approval-token fix, and there is no way to tell those apart, so it is refused. The migration window that used to honor pre-fix stamps was removed because it keyed on file mtime, which the same shell that writes the stamp can rewrite. $(qpg_block_advice "$VERDICT")"
    ;;
  approval-expired)
    REASON="QA-plan gate: branch \`$BRANCH\` carries an approval that has lapsed. It binds to no plan digest, so nothing can re-verify it against what is being shipped, and time is the only bound it has. Every human override is in this category, and so is a modal approval whose question carried no digest marker. $(qpg_block_advice "$VERDICT")"
    ;;
  *)
    REASON="QA-plan gate: this repo requires an approved two-phase QA plan BEFORE the PR goes up. Branch \`$BRANCH\` has no usable approved-plan stamp [${VERDICT}]. This repo's QA-plan policy: the Development + Production QA plan must be presented to and approved by the human before opening the PR. $(qpg_block_advice "$VERDICT") \`/ship\` folds the plan into the body. A spike branch is not exempt here: opening a PR is shipping, so the plan is required."
    ;;
esac
REASON="$REASON $(qpg_override_hint)"
_BP_REF=$(qpg_build_procedure_ref "$MARKER")
[ -n "$_BP_REF" ] && REASON="$REASON (This repo also follows your workspace build procedure: $_BP_REF.)"
[ -n "$_STALE_WARN" ] && REASON="$REASON $_STALE_WARN"
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
