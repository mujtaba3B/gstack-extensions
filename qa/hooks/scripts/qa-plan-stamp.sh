#!/bin/bash
# qa-plan-stamp.sh - read / write the QA-plan approval stamp.
#
# The stamp records that a human PRESENTED-AND-APPROVED the two-phase QA plan for
# the current branch (BUILD-PROCEDURE.md non-negotiable #4). /qa:plan calls
# `write` at the end of its AskUserQuestion approval step; the build and PR gates
# (qa-plan-build-gate.sh / qa-plan-pr-gate.sh) read it via qpg_stamp_valid.
#
# Usage (run from inside the repo / worktree):
#   qa-plan-stamp.sh write [--approver <who>] [--digest <hex>]
#       Write <git-dir>/qa-plan-approved for the current branch. --digest is the
#       caller's hash of the approved plan text (so a later check can notice the
#       plan changed); omit and the field is "none". --approver defaults to the
#       git user.name, else $USER.
#   qa-plan-stamp.sh status
#       Print the current stamp (or "no stamp") and whether it matches the branch.
#   qa-plan-stamp.sh clear
#       Remove the stamp (e.g. to force re-approval after a plan rewrite).
#
# Keyed to the worktree git dir via `git rev-parse --absolute-git-dir`, never the
# common dir, so linked worktrees do not share an approval. Stdout is the stamp
# path on a successful write so the caller can show it.

set -u

VERB="${1:-status}"; shift || true

APPROVER=""
DIGEST="none"
while [ $# -gt 0 ]; do
  case "$1" in
    --approver)
      [ $# -ge 2 ] || { echo "qa-plan-stamp.sh: --approver requires a value" >&2; exit 2; }
      APPROVER="$2"; shift 2 ;;
    --digest)
      [ $# -ge 2 ] || { echo "qa-plan-stamp.sh: --digest requires a value" >&2; exit 2; }
      DIGEST="$2"; shift 2 ;;
    *) echo "qa-plan-stamp.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

GITDIR=$(git rev-parse --absolute-git-dir 2>/dev/null) || {
  echo "qa-plan-stamp.sh: not inside a git repo" >&2; exit 1; }
STAMP="$GITDIR/qa-plan-approved"
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

case "$VERB" in
  status)
    if [ -f "$STAMP" ]; then
      cat "$STAMP"
      sb=$(jq -r '.branch // empty' "$STAMP" 2>/dev/null || echo "")
      if [ "$sb" = "$BRANCH" ]; then echo "# matches current branch ($BRANCH)"; else
        echo "# stamp branch=${sb:-?} != current branch=$BRANCH (stale)"; fi
    else
      echo "no stamp at $STAMP"
    fi
    ;;

  clear)
    rm -f "$STAMP" && echo "cleared $STAMP"
    ;;

  write)
    command -v jq >/dev/null 2>&1 || { echo "qa-plan-stamp.sh: jq required to write" >&2; exit 1; }
    [ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || {
      echo "qa-plan-stamp.sh: refusing to stamp a detached HEAD; checkout a branch" >&2; exit 1; }
    [ -z "$APPROVER" ] && APPROVER=$(git config user.name 2>/dev/null || true)
    [ -z "$APPROVER" ] && APPROVER="${USER:-unknown}"
    HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
    NOW_EPOCH=$(date +%s)
    NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    tmp=$(mktemp "$GITDIR/.qa-plan-approved.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
    jq -nc \
      --arg branch "$BRANCH" \
      --arg iso "$NOW_ISO" \
      --argjson epoch "$NOW_EPOCH" \
      --arg head "$HEAD" \
      --arg digest "$DIGEST" \
      --arg approver "$APPROVER" \
      '{branch:$branch, approved_at:$iso, approved_at_epoch:$epoch,
        head_at_approval:$head, criteria_digest:$digest, approver:$approver,
        tool:"qa-plan"}' > "$tmp" || { rm -f "$tmp"; echo "jq write failed" >&2; exit 1; }
    mv -f "$tmp" "$STAMP" || { rm -f "$tmp"; echo "stamp write failed: could not move into $STAMP" >&2; exit 1; }
    echo "$STAMP"
    ;;

  *)
    echo "qa-plan-stamp.sh: unknown verb '$VERB' (write|status|clear)" >&2; exit 2 ;;
esac
