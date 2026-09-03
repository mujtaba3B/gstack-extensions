#!/bin/bash
# qa-plan-stamp.sh - read / write the QA-plan approval stamp.
#
# The stamp records that a human PRESENTED-AND-APPROVED the two-phase QA plan for
# the current branch (the two-phase QA-plan approval policy). /qa:plan calls
# `write` at the end of its AskUserQuestion approval step; the build and PR gates
# (qa-plan-build-gate.sh / qa-plan-pr-gate.sh) read it via qpg_stamp_valid.
#
# WRITING REQUIRES A HUMAN APPROVAL TOKEN (gstack-extensions#71). `write` refuses
# unless <git-dir>/qa-plan-approval-token holds a valid token, and DELETES that
# token on success, so one human click authorizes exactly one stamp. The token is
# minted only by qa-plan-approval-token.sh, a PostToolUse hook that fires when a
# person answers the "QA plan" AskUserQuestion with "Approve"; that answer is
# written by the harness from a real click and cannot be forged by an agent.
#
# Before this, `write` had no guard at all and defaulted `approver` to
# `git config user.name`, so an agent could mint a stamp at any time and it read
# as the human's own approval. On 2026-09-02 that put approval stamps on four
# pull requests no human approved, one of which merged. This script now reads
# `git config` NOWHERE: the approver name can reach a stamp only through a token,
# and a token exists only because a human clicked.
#
# Usage (run from inside the repo / worktree):
#   qa-plan-stamp.sh write
#       Write <git-dir>/qa-plan-approved for the current branch, consuming the
#       approval token. Takes NO arguments: both the approver name and the plan
#       digest come from the token and from nowhere else.
#
#       --approver and --digest were removed after review. Each was an
#       agent-supplied input to a human-attested record, which is the whole defect
#       class this file exists to close: --approver let an arbitrary name be
#       recorded under a genuine approval_source, and --digest let an agent
#       approve plan A and then stamp the digest of plan B, defeating drift
#       detection entirely. An input an agent controls is not evidence.
#
#   qa-plan-stamp.sh digest [<path>]
#       Print the canonical digest of a PR body's `## QA` section (from <path>, or
#       stdin). /qa:plan calls this to embed <qa-plan-digest:HEX> in the approval
#       question. It exists so ONE code path computes the digest: the skill used to
#       hand-roll `shasum` over raw text while the gate hashed NORMALIZED text, so
#       a single trailing newline produced a stamp whose digest could never match
#       and a `gh pr create` that blocked forever with no way to satisfy it.
#   qa-plan-stamp.sh status
#       Print the current stamp (or "no stamp") and whether it matches the branch.
#   qa-plan-stamp.sh clear
#       Remove the stamp (e.g. to force re-approval after a plan rewrite).
#
# Keyed to the worktree git dir via `git rev-parse --absolute-git-dir`, never the
# common dir, so linked worktrees do not share an approval. Stdout is the stamp
# path on a successful write so the caller can show it.

set -u

LIBDIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TLIB="$LIBDIR/qa-plan-token-lib.sh"
# The token lib carries the pure verdicts. Resolve it relative to THIS script so
# the executing copy binds its own dependency (the scripts are dual-use: the
# skill, the gates and bats all invoke them without the hook env).
GLIB="$LIBDIR/qa-plan-gate-lib.sh"
[ -f "$TLIB" ] || { echo "qa-plan-stamp.sh: missing $TLIB; cannot verify approval" >&2; exit 1; }
[ -f "$GLIB" ] || { echo "qa-plan-stamp.sh: missing $GLIB; cannot compute a plan digest" >&2; exit 1; }
# shellcheck source=/dev/null
. "$TLIB"
# shellcheck source=/dev/null
. "$GLIB"

VERB="${1:-status}"; shift || true

# `digest` takes an optional path; `write` and the rest take no options at all.
DIGEST_PATH="${1:-}"
case "$VERB" in
  write|status|clear)
    [ $# -eq 0 ] || { echo "qa-plan-stamp.sh: '$VERB' takes no arguments (got: $*). --approver and --digest were removed; both come from the approval token." >&2; exit 2; } ;;
esac

GITDIR=$(git rev-parse --absolute-git-dir 2>/dev/null) || {
  echo "qa-plan-stamp.sh: not inside a git repo" >&2; exit 1; }
STAMP="$GITDIR/qa-plan-approved"
TOKEN="$GITDIR/qa-plan-approval-token"
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
    if [ -f "$TOKEN" ]; then
      tv=$(qpt_token_valid "$(cat "$TOKEN" 2>/dev/null || echo "")" "$BRANCH" "$(date +%s)")
      echo "# approval token: present [$tv]"
    else
      echo "# approval token: none (run /qa:plan and answer Approve to mint one)"
    fi
    ;;

  clear)
    # Only the stamp. `clear` removes an approval, so its failure direction is to
    # RE-BLOCK the gates, which is safe; it needs no token of its own. The token
    # is left untouched on purpose: it is single-use and short-lived, so it
    # expires on its own, and consuming it here would let a plan rewrite quietly
    # burn an approval the human gave for something else.
    rm -f "$STAMP" && echo "cleared $STAMP"
    ;;

  write)
    command -v jq >/dev/null 2>&1 || { echo "qa-plan-stamp.sh: jq required to write" >&2; exit 1; }
    [ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || {
      echo "qa-plan-stamp.sh: refusing to stamp a detached HEAD; checkout a branch" >&2; exit 1; }

    # THE GATE. Require a live approval token, and read the approver from it.
    # There is deliberately no environment escape hatch and no --force: an
    # override an agent can set is an override an agent will set, which is the
    # whole shape of the bug this closes. The only way to write a stamp is for a
    # person to answer the "QA plan" question with "Approve".
    TOKEN_JSON=$(cat "$TOKEN" 2>/dev/null || echo "")
    TVERDICT=$(qpt_token_valid "$TOKEN_JSON" "$BRANCH" "$(date +%s)")
    if [ "$TVERDICT" != "valid" ]; then
      case "$TVERDICT" in
        no-token)    _why="no approval token is present" ;;
        malformed)   _why="the approval token is malformed" ;;
        wrong-branch) _why="the approval token was minted for a different branch" ;;
        expired)     _why="the approval token has expired (older than ${QPT_TTL}s)" ;;
        future)      _why="the approval token is timestamped in the future" ;;
        *)           _why="the approval token is not valid [$TVERDICT]" ;;
      esac
      {
        echo "qa-plan-stamp.sh: REFUSING to write the approval stamp: $_why."
        echo
        echo "This stamp records that a HUMAN approved the two-phase QA plan, so it cannot"
        echo "be written on their behalf. Run /qa:plan: it presents the plan and asks for"
        echo "approval, and answering \"Approve\" is what mints the token this needs."
        echo
        echo "If you just approved and still see this, the PostToolUse hook that mints the"
        echo "token is probably not registered in the running session: hook REGISTRATION is"
        echo "read at session start, so a newly added hook needs a restart even where the"
        echo "script itself is live. Restart Claude Code (run bin/install first if this"
        echo "marketplace installs by copy rather than from a directory source), re-approve,"
        echo "and retry."
      } >&2
      exit 1
    fi

    # Approver AND digest come from the token and from nowhere else. `git config`
    # is deliberately not consulted anywhere in this script, and neither value is
    # reachable from an argument.
    APPROVER=$(qpt_token_approver "$TOKEN_JSON")
    NONCE=$(printf '%s' "$TOKEN_JSON" | jq -r '.nonce // "none"' 2>/dev/null || echo "none")
    DIGEST=$(printf '%s' "$TOKEN_JSON" | jq -r '.plan_digest // empty' 2>/dev/null || echo "")
    [ -n "$DIGEST" ] || DIGEST="none"
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
      --arg nonce "$NONCE" \
      '{branch:$branch, approved_at:$iso, approved_at_epoch:$epoch,
        head_at_approval:$head, criteria_digest:$digest, approver:$approver,
        approval_source:"AskUserQuestion", approval_nonce:$nonce,
        tool:"qa-plan"}' > "$tmp" || { rm -f "$tmp"; echo "jq write failed" >&2; exit 1; }
    mv -f "$tmp" "$STAMP" || { rm -f "$tmp"; echo "stamp write failed: could not move into $STAMP" >&2; exit 1; }
    # CONSUME the token. One click, one stamp: without this a single approval
    # could be replayed to stamp again after the plan changed, which is the
    # scoped-approval-treated-as-standing shape of the 2026-09-02 incident.
    # Done AFTER the stamp lands so a failed write leaves the token usable.
    rm -f "$TOKEN" 2>/dev/null || true
    echo "$STAMP"
    ;;

  digest)
    # One canonical digest path, shared with the gates by construction.
    if [ -n "$DIGEST_PATH" ]; then
      [ -r "$DIGEST_PATH" ] || { echo "qa-plan-stamp.sh: cannot read $DIGEST_PATH" >&2; exit 1; }
      _body=$(cat "$DIGEST_PATH")
    else
      _body=$(cat)
    fi
    _sec=$(qpg_extract_qa_section "$_body")
    [ -n "$_sec" ] || { echo "qa-plan-stamp.sh: no '## QA' section found" >&2; exit 1; }
    _d=$(qpg_plan_digest "$_sec")
    [ -n "$_d" ] || { echo "qa-plan-stamp.sh: no sha256 tool available" >&2; exit 1; }
    echo "$_d"
    ;;

  *)
    echo "qa-plan-stamp.sh: unknown verb '$VERB' (write|status|clear|digest)" >&2; exit 2 ;;
esac
