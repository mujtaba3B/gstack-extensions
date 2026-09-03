#!/bin/bash
# qa-plan-approval-token.sh - mint the QA-plan APPROVAL token from a real human click.
#
# PostToolUse hook on AskUserQuestion. This is the root of trust for the QA-plan
# approval stamp, and the fix for gstack-extensions#71.
#
# WHY A PostToolUse HOOK. The payload of this event carries `.tool_response`,
# whose `.answers` map is filled in by the HARNESS from the option the human
# actually clicked. The model cannot write that field: it emits `.tool_input`
# (the questions), never the response. So "a human answered the QA plan question
# with Approve" is the one fact in this system an agent cannot fabricate, which
# makes it the right thing to chain the human-attested stamp to.
#
# Contrast with the sibling gates, which is the design this follows:
#   ship-gate-sentinel.sh   mints on the agent INVOKING /ship.
#   land-deploy-sentinel.sh mints on the agent INVOKING /land-and-deploy.
#   this script             mints on the HUMAN ANSWERING a question.
# The last is strictly stronger than the other two, because invoking a skill is
# something the agent decides and answering a modal is not.
#
# What it writes: <gitdir>/qa-plan-approval-token, a small JSON blob bound to the
# current branch and stamped with the mint time and a nonce. `qa-plan-stamp.sh
# write` requires a valid one and DELETES it on success, so one click authorizes
# exactly one stamp. Keyed to the PER-WORKTREE git dir (`--absolute-git-dir`,
# never the common dir), matching the stamp it authorizes, so an approval given
# in one worktree cannot stamp another.
#
# This hook NEVER blocks: PostToolUse has no decision to make here, so it always
# exits 0 with empty stdout. Its only effect is the side-effect write.
#
# It fails CLOSED in every direction. Missing jq, missing git, an unreadable
# payload, a non-"QA plan" header, any answer other than "Approve", or a detached
# HEAD all mint NOTHING, and no token means no stamp. The cost of failing closed
# is that /qa:plan cannot stamp until the problem is fixed, which is the safe
# direction for a privileged act.

set -u

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

LIBDIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TLIB="$LIBDIR/qa-plan-token-lib.sh"
[ -f "$TLIB" ] || exit 0
# shellcheck source=/dev/null
. "$TLIB"

TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')

# Resolve the repo from the session cwd. Unlike the ship/land sentinels there is
# no `cd <dir> &&` to honor: an AskUserQuestion has no command line, so the
# session cwd is the only signal, and it is the right one (the human is approving
# the plan for the repo the session is working in).
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty')
{ [ -n "$CWD" ] && [ -d "$CWD" ]; } || CWD="$PWD"
GITDIR=$(git -C "$CWD" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# Find the QA-plan question and the label the human picked for it.
#
# The header is matched through the LIB comparator, never in jq. jq emits every
# (header, question) pair and bash asks qpt_header_is_qa_plan about each, so the
# hook and the lib cannot disagree about what counts as the QA-plan header. An
# earlier cut pre-filtered byte-exact in jq, which made the lib's case/whitespace
# tolerance dead code and left a modal headed "QA Plan" minting nothing while the
# stamp writer blamed an unregistered hook.
#
# `.tool_response.answers` is keyed by QUESTION TEXT, so the answer is looked up
# by the matched question's own text. That ordering is what stops a modal asking
# several things at once from having an unrelated "Approve" harvested.
# Questions are keyed by INDEX, never by their text, and the matched header is
# reused rather than re-derived. Two bugs came out of doing it the other way:
#   - Re-deriving the header with a jq `select(.question == $q) | first` picked
#     the WRONG question's header when two questions in one modal shared text,
#     silently minting nothing.
#   - `read` is record-oriented, so a question containing a literal newline was
#     truncated, the answers lookup missed, and again nothing minted.
# Both fail closed, but a silent no-mint is the worst failure this file has: the
# stamp writer then tells the operator the hook is "probably not registered",
# which sends them to restart Claude Code for a problem a restart cannot fix.
QUESTION=""; HEADER=""
_count=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.questions // []) | length' 2>/dev/null) || _count=0
case "$_count" in ''|*[!0-9]*) _count=0 ;; esac
_i=0
while [ "$_i" -lt "$_count" ]; do
  _hdr=$(printf '%s' "$PAYLOAD" | jq -r --argjson i "$_i" '.tool_input.questions[$i].header // ""' 2>/dev/null)
  if [ "$(qpt_header_is_qa_plan "$_hdr")" = "qa-plan" ]; then
    HEADER="$_hdr"
    QUESTION=$(printf '%s' "$PAYLOAD" | jq -r --argjson i "$_i" '.tool_input.questions[$i].question // ""' 2>/dev/null)
    break
  fi
  _i=$(( _i + 1 ))
done
[ -n "$QUESTION" ] || exit 0

# `.tool_response.answers` is keyed by QUESTION TEXT, so the answer is looked up
# by the matched question's own text. That ordering is what stops a modal asking
# several things at once from having an unrelated "Approve" harvested.
ANSWER=$(printf '%s' "$PAYLOAD" | jq -r --arg q "$QUESTION" '
  .tool_response.answers[$q] // empty
' 2>/dev/null) || exit 0

# THE decision, in one pure call whose truth table is enumerated in bats. The
# refusal REASON is logged rather than discarded: a silent no-mint is this hook's
# worst failure mode, because the stamp writer then tells the operator the hook is
# "probably not registered" and sends them to restart for something a restart
# cannot fix. Twice during this feature's own development a no-mint was diagnosed
# that way. One line in the gate log turns "nothing happened" into "wrong-header".
_MINT=$(qpt_should_mint "$TOOL" "$HEADER" "$ANSWER" "$BRANCH")
if [ "$_MINT" != "mint" ]; then
  printf '%s approval-token no-mint(%s) branch=%s header=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_MINT" "${BRANCH:-?}" "${HEADER:-?}" \
    >> "$HOME/.claude/qa-plan-gate.log" 2>/dev/null || true
  exit 0
fi

# The plan digest the human was shown, carried in the question as
# <qa-plan-digest:HEX>. This is what makes the approval bind to SPECIFIC plan
# text rather than to the mere fact of a click: qa-plan-stamp.sh takes the
# stamp's criteria_digest from the token and from nowhere else, so an agent
# cannot approve plan A and stamp the digest of plan B. Empty when the skill did
# not embed one; the stamp then records "none" and drift checking stays inactive.
PLAN_DIGEST=$(qpt_digest_from_question "$QUESTION")

HEAD_SHA=$(git -C "$CWD" rev-parse HEAD 2>/dev/null || echo "")
SESSION=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty')
NOW=$(date +%s)

# The human's identity. Read here, at mint time, and ONLY here: this is the one
# moment we know a real person acted, so it is the only place entitled to attach
# their name to anything. qa-plan-stamp.sh reads `git config` nowhere at all now,
# which is what stops a forged stamp from wearing the human's name (#71).
APPROVER=$(git -C "$CWD" config user.name 2>/dev/null || true)
[ -n "$APPROVER" ] && APPROVER="$APPROVER (via AskUserQuestion)"
[ -n "$APPROVER" ] || APPROVER="human (via AskUserQuestion)"

# A nonce ties the resulting stamp back to this specific click in an audit, and
# makes two stamps minted from one approval impossible to confuse.
NONCE=$( { head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n'; } || echo "" )
[ -n "$NONCE" ] || NONCE="$NOW-$$"

# Atomic write (temp in the same dir, then mv) so a concurrent stamp read never
# sees a half-written token.
tmp=$(mktemp "$GITDIR/.qa-plan-approval-token.XXXXXX" 2>/dev/null) || exit 0
jq -nc \
  --arg branch "$BRANCH" \
  --arg head "$HEAD_SHA" \
  --argjson epoch "$NOW" \
  --arg approver "$APPROVER" \
  --arg session "$SESSION" \
  --arg question "$QUESTION" \
  --arg nonce "$NONCE" \
  --arg plandigest "$PLAN_DIGEST" \
  '{branch:$branch, head:$head, approved_at_epoch:$epoch, approver:$approver,
    session:$session, question:$question, nonce:$nonce, plan_digest:$plandigest,
    source:"AskUserQuestion"}' \
  > "$tmp" 2>/dev/null \
  && mv -f "$tmp" "$GITDIR/qa-plan-approval-token" 2>/dev/null \
  || rm -f "$tmp" 2>/dev/null

exit 0
