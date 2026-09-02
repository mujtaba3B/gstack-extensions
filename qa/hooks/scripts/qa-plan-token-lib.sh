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
# The fix chains the stamp to a HUMAN ACT. A PostToolUse hook on AskUserQuestion
# sees `.tool_response.answers`, which the HARNESS fills in from the human's
# actual click; nothing the model emits can set it. When that map shows the
# "QA plan" question answered "Approve", the hook mints a token, and
# `qa-plan-stamp.sh write` refuses without one and CONSUMES it on success. One
# click therefore yields exactly one stamp.
#
# HONEST SCOPE, because the next person hardening this will read this comment as
# a closed problem otherwise. Two things are NOT closed:
#
#   1. The ANSWER is unforgeable; the QUESTION is not. The agent authors the
#      header and the option labels, so an agent that puts up a modal headed
#      "QA plan" with an option labelled "Approve" gets a real token when the
#      human clicks it. What the human saw on screen is not constrained by
#      anything mechanical. The plan digest (below) narrows this: the token
#      binds to the specific plan text that was on screen, so a click cannot be
#      recycled onto different content.
#   2. The token is a FILE. An agent with shell access can hand-write it, just as
#      it could forge ship-pr-clearance or land-deploy-clearance. This is the
#      same posture those sentinels document: an accident-guard, not a
#      tamper-proof sandbox. What changed is the cost. Forging went from running
#      the sanctioned tool at an unsanctioned moment (invisible, and exactly what
#      happened on 2026-09-02) to hand-writing JSON into the git dir, which is a
#      recognizably illegitimate act rather than a plausible slip.
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
#   Canonicalize an AskUserQuestion option label for comparison: trim, lowercase,
#   and drop ONLY the recommendation marker. Echoes the normalized string.
#
#   It deliberately does NOT strip an arbitrary trailing parenthetical. An earlier
#   cut did, and that turned every qualifier into an unconditional approval:
#   "Approve (skip Prod QA)" and "Approve (without running dev QA)" both
#   normalized to "approve" and minted a full, unqualified token. Since /qa:plan's
#   house style is a parenthesized label ("**Approve** (recommended)"), the next
#   option carrying a real qualifier would have become a silent bypass. Only the
#   two known-inert markers are removed; anything else stays in the string and
#   therefore fails the exact match in qpt_is_approve.
qpt_normalize_label() {
  local s="$1"
  s=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
  s=$(printf '%s' "$s" | sed -e 's/[[:space:]]*(recommended)[[:space:]]*$//' \
                             -e 's/[[:space:]]*(default)[[:space:]]*$//')
  s=$(printf '%s' "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  # Markdown emphasis around the label ("**Approve**") is presentation, not meaning.
  s=$(printf '%s' "$s" | sed -e 's/^\*\{1,2\}//' -e 's/\*\{1,2\}$//')
  printf '%s' "$s"
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

# qpt_should_mint <tool_name> <header> <answer> <branch>
#   THE mint decision, composed in one pure place. Echoes "mint" or a single-word
#   refusal reason (wrong-tool | wrong-header | not-approve | no-branch), and
#   returns 0 only for "mint".
#
#   WHY THIS IS EXTRACTED. This repo's CLAUDE.md requires that any decision
#   determining whether something may merge, build or deploy live in a lib as a
#   pure function with its truth table in bats, precisely because an inline guard
#   chain in an I/O script can only ever be hand-verified. That rule earned itself
#   again here: the first cut composed these seven guards inline, and the header
#   check silently diverged from this lib (the hook matched the header byte-exact
#   while the comparator lowercased and trimmed), so a modal headed "QA Plan"
#   minted nothing, the stamp write then refused, and its refusal text blamed an
#   unregistered hook. That is an unsatisfiable gate with a misleading diagnosis,
#   the same shape as the outage this fix already caused once today. A truth table
#   cannot diverge from itself.
qpt_should_mint() {
  local tool="$1" header="$2" answer="$3" branch="$4"
  [ "$tool" = "AskUserQuestion" ] || { echo "wrong-tool"; return 1; }
  [ "$(qpt_header_is_qa_plan "$header")" = "qa-plan" ] || { echo "wrong-header"; return 1; }
  [ "$(qpt_is_approve "$answer")" = "approve" ] || { echo "not-approve"; return 1; }
  # A detached HEAD cannot be stamped (qa-plan-stamp.sh refuses one by design), so
  # minting for it would only leave a confusing dead file.
  { [ -n "$branch" ] && [ "$branch" != "HEAD" ]; } || { echo "no-branch"; return 1; }
  echo "mint"; return 0
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

# qpt_digest_from_question <question_text>
#   Extract the approved plan's digest from the marker /qa:plan embeds in the
#   approval question: `<qa-plan-digest:HEX>`. Echoes the hex, or nothing.
#
#   WHY THE DIGEST TRAVELS IN THE QUESTION. It has to be captured at the moment
#   of the click, from something the human was actually shown, and the payload
#   this hook sees contains the question text and nothing else about the plan.
#   Binding it here is what stops an agent approving plan A and then stamping the
#   digest of plan B: `qa-plan-stamp.sh` takes the digest ONLY from the token, so
#   it is not an agent-supplied argument at all.
qpt_digest_from_question() {
  printf '%s' "$1" | sed -nE 's/.*<qa-plan-digest:([0-9a-fA-F]{16,128})>.*/\1/p' | head -1
}

# qpt_unattested_cutoff
#   Epoch before which a stamp lacking `approval_source` is honored as a genuine
#   pre-fix approval. Stamps FILE-MODIFIED at or after this instant are not
#   migration cases: the fix was live by then, so a field-less stamp written
#   after it was either hand-written or produced by a writer that should no
#   longer exist. 2026-09-02T00:00:00Z, the day the approval-token fix shipped.
#
#   This bound is the whole point. Keying the carve-out on SHAPE alone made a
#   forged stamp strictly EASIER to produce than a real one: two JSON fields and
#   both gates opened, permanently, for anyone. A migration allowance must never
#   be cheaper than the thing it is migrating from.
QPT_UNATTESTED_CUTOFF=1788307200

# qpt_unattested_in_window <stamp_mtime_epoch> [cutoff]
#   Echo "in" / "out"; return 0 when the stamp predates the cutoff and may
#   therefore be honored as a pre-fix approval. A missing or non-numeric mtime is
#   "out" (fails closed): if we cannot date the stamp, we do not grandfather it.
qpt_unattested_in_window() {
  local mtime="$1" cutoff="${2:-$QPT_UNATTESTED_CUTOFF}"
  case "$mtime" in ''|*[!0-9]*) echo "out"; return 1 ;; esac
  [ "$mtime" -lt "$cutoff" ] && { echo "in"; return 0; }
  echo "out"; return 1
}

# qpt_token_approver <token_json>
#   The identity to record in the stamp's `approver` field. Echoes the token's
#   own `approver` value, or "unknown" when it carries none.
#
#   This is the ONLY source of that field. qa-plan-stamp.sh no longer reads
#   `git config user.name` at all, AND no longer accepts an --approver argument,
#   which together are the half of #71 that made a stamp read as the human's own
#   approval. An earlier cut of this fix kept --approver as an override; that was
#   wrong, because it let an arbitrary name be recorded under a genuine
#   approval_source. The name now reaches a stamp only through a token, and a
#   token exists only because a human clicked.
qpt_token_approver() {
  local a
  a=$(printf '%s' "$1" | jq -r '.approver // empty' 2>/dev/null) || a=""
  [ -n "$a" ] || a="unknown"
  printf '%s' "$a"
}
