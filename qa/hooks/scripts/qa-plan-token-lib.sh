#!/bin/bash
# Pure, side-effect-free decision logic for the QA-plan APPROVAL TOKEN, extracted
# so it can be unit tested (tests/qa-plan-token.bats) without a live repo, a
# harness payload, or any hook plumbing. Every function takes everything it needs
# as arguments and writes only to stdout.
#
# WHY THIS EXISTS (gstack-extensions#71). The QA-plan approval stamp attests to a
# HUMAN act: "a person was shown the two-phase QA plan and approved it". Until
# now the stamp was written by `qa-plan-stamp.sh write`, which had no guard of any
# kind, so an agent could mint one at any moment; and because the writer defaulted
# `approver` to `git config user.name`, an agent-written stamp was byte-identical
# to a real approval and recorded under the human's name. On 2026-09-02 that
# produced approval stamps on four pull requests that no human approved, one of
# which merged (Mu-5-Music/music#2).
#
# The asymmetry that made it a bug: every OTHER soft stamp in this codebase
# attests to an AGENT act (review-skill-head says "an agent reviewed",
# ship-skip-<dim> says "an agent chose to skip"), so an agent writing one is
# telling the truth. This is the only stamp that claims a human did something, so
# an agent writing it is a lie by construction.
#
# The fix chains the stamp to something an agent cannot produce. A PostToolUse
# hook on AskUserQuestion sees `.tool_response.answers`, which the HARNESS fills
# in from the human's actual click; nothing the model emits can set it. When that
# map shows the "QA plan" question answered "Approve", the hook mints a token, and
# `qa-plan-stamp.sh write` refuses without one and CONSUMES it on success. One
# click therefore yields exactly one stamp.
#
# Consumers:
#   scripts/qa-plan-approval-token.sh - the PostToolUse hook that mints the token.
#   scripts/qa-plan-stamp.sh          - requires + consumes it before writing.
#
# Requires jq for the JSON helper (qpt_token_valid). The minting hook exits 0
# without minting when jq is absent, which fails CLOSED: no token means no stamp.

# The header that marks the QA-plan approval question. /qa:plan Step 6 fires its
# AskUserQuestion with exactly this header; anything else is some other modal and
# must never mint an approval (a "Memory writes" question answered "Approve" is
# approving a memory write, not a QA plan).
QPT_HEADER="QA plan"

# The token's freshness window. The stamp is written moments after the click by
# /qa:plan Step 6, so this only has to survive that gap; it exists so a token left
# behind by an abandoned run cannot authorize a stamp hours later. Deliberately
# short. The token is also single-use, so this is the second of two limits.
QPT_TTL=1800

# qpt_normalize_label <label>
#   Canonicalize an AskUserQuestion option label for comparison: strip a trailing
#   parenthetical (so "Approve (recommended)" and "Approve" agree), trim outer
#   whitespace, and lowercase. Echoes the normalized string.
qpt_normalize_label() {
  local s="$1"
  s=${s%%\(*}                                   # drop a trailing "(recommended)" etc
  s=$(printf '%s' "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  printf '%s' "$s" | tr '[:upper:]' '[:lower:]'
}

# qpt_is_approve <label>
#   Does this answer label mean "approve the plan"? Echoes "approve" / "no";
#   return code 0 only for approve.
#
#   Deliberately EXACT after normalization, not a prefix match. /qa:plan's other
#   two options are "Rework it" and "Skip the gate", and a future option that
#   merely STARTS with the word approve ("Approve without QA", say) must not mint
#   a token by accident. Fails CLOSED: anything unrecognized is "no".
qpt_is_approve() {
  local n; n=$(qpt_normalize_label "$1")
  case "$n" in
    approve) echo "approve"; return 0 ;;
    *) echo "no"; return 1 ;;
  esac
}

# qpt_header_is_qa_plan <header>
#   Is this the QA-plan approval question? Echoes "qa-plan" / "no"; return code 0
#   on a match. Compared case-insensitively after trimming, but otherwise exact,
#   so an unrelated modal cannot mint a QA-plan approval.
qpt_header_is_qa_plan() {
  local n; n=$(qpt_normalize_label "$1")
  local want; want=$(qpt_normalize_label "$QPT_HEADER")
  if [ "$n" = "$want" ]; then echo "qa-plan"; return 0; fi
  echo "no"; return 1
}

# qpt_token_valid <token_json> <branch> <now_epoch> [ttl]
#   Decide whether an approval token authorizes writing a stamp on <branch>.
#   Echoes "valid" on success, else a single-word reason (no-token | malformed |
#   wrong-branch | expired | future). Return code mirrors the verdict.
#
#   A token is JSON written by qa-plan-approval-token.sh:
#     { "branch": "<name>", "head": "<sha>", "approved_at_epoch": <int>,
#       "approver": "<who>", "session": "<id>", "question": "<text>",
#       "nonce": "<hex>", "source": "AskUserQuestion" }
#
#   Validity is keyed on BRANCH plus freshness, NOT on head. /qa:plan writes the
#   stamp immediately after the click, but binding to a sha would make an
#   innocuous commit between the click and the stamp look like tampering, and the
#   protection it would add is already covered: the token is single-use, so a
#   stale one cannot be replayed at all.
#
#   A token minted in the FUTURE (clock skew, or a hand-written file) is rejected
#   rather than treated as fresh, so a far-future timestamp cannot buy an
#   unlimited window.
qpt_token_valid() {
  local token="$1" branch="$2" now="$3" ttl="${4:-$QPT_TTL}"

  if [ -z "$token" ]; then echo "no-token"; return 1; fi

  local t_branch t_epoch
  t_branch=$(printf '%s' "$token" | jq -r '.branch // empty' 2>/dev/null) \
    || { echo "malformed"; return 1; }
  [ -n "$t_branch" ] || { echo "malformed"; return 1; }

  t_epoch=$(printf '%s' "$token" | jq -r '.approved_at_epoch // empty' 2>/dev/null) \
    || { echo "malformed"; return 1; }
  case "$t_epoch" in ''|*[!0-9]*) echo "malformed"; return 1 ;; esac

  [ "$t_branch" = "$branch" ] || { echo "wrong-branch"; return 1; }

  local age=$(( now - t_epoch ))
  [ "$age" -ge 0 ] || { echo "future"; return 1; }
  [ "$age" -le "$ttl" ] || { echo "expired"; return 1; }

  echo "valid"; return 0
}

# qpt_token_approver <token_json>
#   The identity to record in the stamp's `approver` field. Echoes the token's
#   own `approver` value, or "unknown" when it carries none.
#
#   This is the ONLY source of that field. qa-plan-stamp.sh no longer reads
#   `git config user.name` at all, which is the half of #71 that made a forged
#   stamp read as the human's own approval. The name can now reach a stamp only
#   through a token, and a token exists only because a human clicked.
qpt_token_approver() {
  local a
  a=$(printf '%s' "$1" | jq -r '.approver // empty' 2>/dev/null) || a=""
  [ -n "$a" ] || a="unknown"
  printf '%s' "$a"
}
