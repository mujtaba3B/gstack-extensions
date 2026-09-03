#!/bin/bash
# qa-plan-prompt-override.sh - mint a QA-plan approval token from a phrase the
# HUMAN types, so an approval the human has already given can be spent without
# restarting Claude Code.
#
# UserPromptSubmit hook. This is the second root of trust for the approval stamp,
# alongside qa-plan-approval-token.sh.
#
# WHY IT EXISTS. On 2026-09-03 a session held a real human approval it could not
# spend. The AskUserQuestion minter had been added to hooks.json AFTER that
# session started, and hook REGISTRATION is read at session start while script
# CONTENT is live immediately, so the gate ran the new logic while the minter was
# dormant. `qa-plan-stamp.sh write` refused, correctly, and the only documented
# remedy was "restart Claude Code". The operator, who is the person whose approval
# was being refused, asked for a way to give that approval himself.
#
# WHY `.prompt` IS THE RIGHT FIELD. Same argument as the sibling hook, applied to
# a different harness-filled value. The model emits assistant turns and tool
# calls; it cannot submit a USER prompt. `.prompt` on this event is the human's
# literal typed message, so "the human typed this exact sentence" is a fact an
# agent cannot fabricate, exactly like "the human clicked this option". It is also
# INDEPENDENT of the AskUserQuestion hook, which is what makes it a recovery path
# rather than a second copy of the thing that was broken.
#
# WHY NOT A COMMAND THE HUMAN TYPES WITH `!`. That was the first proposal and it
# does not work. Measured on 2026-09-03: the agent's Bash tool has no controlling
# terminal at all (`/dev/tty` -> "device not configured"), and neither does a
# `!`-prefixed command (a real transcript shows `! sudo ...` failing with "sudo: a
# terminal is required to read the password"). Both are non-TTY children of the
# same CLI process, so no script can tell them apart, and a sanctioned
# `qa-plan-stamp.sh approve` would have been a one-word bypass any agent could
# run. That is the "sanctioned tool at an unsanctioned moment" failure #71 exists
# to prevent. The hook-free route for the human is the TTY break-glass
# (`qa-plan-stamp.sh override`), which needs a REAL terminal.
#
# What it writes: <gitdir>/qa-plan-approval-token, the same single-use token the
# click path mints, but carrying `source: "UserPromptSubmit"`. The stamp writer
# maps that to `approval_source: "human-prompt-override"` via qpt_stamp_source_for
# and gives the stamp an expiry, so an override is never mistaken for a modal
# approval by anything reading the stamp later.
#
# It carries NO plan digest, because a typed sentence is not a plan. That is why
# the resulting stamp expires (QPG_OVERRIDE_TTL): with no digest, the drift check
# can never invalidate it, so time is the only bound left.
#
# OUTPUT PROTOCOL. A UserPromptSubmit hook's stdout is injected into the model's
# context. This one prints NOTHING and always exits 0. There is nothing it needs
# to tell the agent that the agent will not already see: the human's prompt IS the
# phrase, so it is visible in the conversation anyway. Staying silent keeps this
# hook incapable of steering the model.
#
# Fails CLOSED everywhere: missing jq or git, an unreadable payload, a prompt that
# is not exactly the phrase, or a detached HEAD all mint NOTHING.

set -u

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

LIBDIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TLIB="$LIBDIR/qa-plan-token-lib.sh"
[ -f "$TLIB" ] || exit 0
# shellcheck source=/dev/null
. "$TLIB"

PROMPT=$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null) || exit 0

# Cheapest discriminator first: this hook fires on EVERY prompt the human sends,
# so the overwhelmingly common case must cost one string comparison and nothing
# else. No git call, no filesystem work, no log line for an ordinary message.
[ "$(qpt_prompt_is_override "$PROMPT")" = "override" ] || exit 0

# Resolve the repo from the session cwd, matching the AskUserQuestion minter: a
# typed prompt has no command line either, and the human is overriding for the
# repo the session is working in.
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null || echo "")
{ [ -n "$CWD" ] && [ -d "$CWD" ]; } || CWD="$PWD"
GITDIR=$(git -C "$CWD" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

LOG="$HOME/.claude/qa-plan-gate.log"

# THE decision, in one pure call whose truth table is enumerated in bats. Logged
# either way. A no-mint here is worth a line for the same reason it is in the
# sibling hook: the human typed a sentence expecting something to happen, and
# "nothing happened" with no record is the failure mode that cost a session.
_MINT=$(qpt_should_mint_prompt "$PROMPT" "$BRANCH")
if [ "$_MINT" != "mint" ]; then
  printf '%s prompt-override no-mint(%s) branch=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_MINT" "${BRANCH:-?}" >> "$LOG" 2>/dev/null || true
  exit 0
fi

# The human's identity, read HERE and only here, for the same reason the sibling
# hook reads it at mint time: this is the moment we know a real person acted, so
# it is the only point entitled to attach their name. qa-plan-stamp.sh still reads
# `git config` nowhere.
APPROVER=$(git -C "$CWD" config user.name 2>/dev/null || true)
[ -n "$APPROVER" ] && APPROVER="$APPROVER (via typed override)"
[ -n "$APPROVER" ] || APPROVER="human (via typed override)"

SESSION=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null || echo "")
HEAD_SHA=$(git -C "$CWD" rev-parse HEAD 2>/dev/null || echo "")
NOW=$(date +%s)
NONCE=$( { head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n'; } || echo "" )
[ -n "$NONCE" ] || NONCE="$NOW-$$"

# Atomic write (temp in the same dir, then mv) so a concurrent stamp read never
# sees a half-written token. `plan_digest` is deliberately absent: a typed
# sentence attests to no specific plan text, and inventing a digest here would
# make an override look drift-checked when it is not.
tmp=$(mktemp "$GITDIR/.qa-plan-approval-token.XXXXXX" 2>/dev/null) || exit 0
jq -nc \
  --arg branch "$BRANCH" \
  --arg head "$HEAD_SHA" \
  --argjson epoch "$NOW" \
  --arg approver "$APPROVER" \
  --arg session "$SESSION" \
  --arg nonce "$NONCE" \
  '{branch:$branch, head:$head, approved_at_epoch:$epoch, approver:$approver,
    session:$session, question:"(typed override)", nonce:$nonce, plan_digest:"",
    source:"UserPromptSubmit"}' \
  > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; exit 0; }
mv -f "$tmp" "$GITDIR/qa-plan-approval-token" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; exit 0; }

# Logged only AFTER the token is actually in place, and kept off the success
# chain: an unwritable log must not be able to look like a failed mint. An
# earlier cut had the log line inside the `&&` chain with `|| rm -f "$tmp"`,
# which made a full disk or a read-only log read as "minting failed" while the
# token sat there minted.
printf '%s prompt-override mint branch=%s session=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "${SESSION:-?}" >> "$LOG" 2>/dev/null || true

exit 0
