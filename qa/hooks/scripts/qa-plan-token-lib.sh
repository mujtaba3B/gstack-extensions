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
  # Emphasis markers are deleted WHEREVER they sit, not stripped from the ends,
  # because markdown emphasis can wrap the whole label ("**Approve
  # (recommended)**") or just the word ("**Approve** (recommended)"). Any
  # end-anchored strip fixes one shape and breaks the other: the parenthetical
  # strip is anchored at end-of-string, so leftover markers between the word and
  # the paren, or after it, defeat the match either way. A human clicking a
  # perfectly ordinary bolded option would then mint nothing and the writer would
  # blame an unregistered hook. `*` and `_` carry no meaning in an option label,
  # so deleting them is lossless here. Found by CodeRabbit on PR #76, whose first
  # fix reordered the strips and traded one broken shape for the other.
  s=$(printf '%s' "$s" | tr -d '*_')
  s=$(printf '%s' "$s" | sed -e 's/[[:space:]]*(recommended)[[:space:]]*$//' \
                             -e 's/[[:space:]]*(default)[[:space:]]*$//')
  s=$(printf '%s' "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
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

# The migration carve-out that used to live here (qpt_unattested_cutoff /
# qpt_unattested_in_window) is GONE, removed on PR #76 after CodeRabbit pointed
# out it was authorized by a MUTABLE attribute. Two commands defeated it:
#
#   printf '{"branch":"<b>","criteria_digest":"<current>"}' > .git/qa-plan-approved
#   touch -t 202601010000 .git/qa-plan-approved
#
# and both gates opened, with the digest set to whatever the body being shipped
# happened to hash to. A carve-out keyed on file mtime is keyed on something the
# same shell that writes the file can rewrite, so it was never a bound at all.
#
# It was only ever there because a pre-fix branch had NO WAY to obtain a token:
# the minting hook was not yet registered, so blocking those stamps produced an
# unsatisfiable gate (that outage is why the carve-out was introduced mid-build).
# That condition is gone. The hook ships in this PR and registers on the next
# session start, so the remedy for a pre-fix stamp is now simply to run /qa:plan
# and approve, which takes one click. Keeping a forgeable bypass alive to spare a
# population of roughly zero branches one modal is a bad trade.
#
# An unattested stamp is therefore refused at BOTH gates now. See
# qpg_unattested_disposition in qa-plan-gate-lib.sh.

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

# ---------------------------------------------------------------------------
# HUMAN OVERRIDES (gstack-extensions, 2026-09-03)
#
# WHY THESE EXIST. On 2026-09-03 a session held a real human approval and could
# not spend it. The minting hook was not registered in that session (hook
# REGISTRATION is read at session start, while script CONTENT is live the moment
# the file changes, so a newly added hook is dormant until a restart), the stamp
# writer refused, and the operator's only route was to restart Claude Code. He
# asked for an override he can give himself, since he is the one approving.
#
# THE CONSTRAINT THAT SHAPES THEM. An override an AGENT can invoke reopens the
# exact hole #71 closed. So the question is not "what command should exist" but
# "what signal in this system does a human produce and an agent cannot". Measured
# on 2026-09-03, there are exactly two:
#
#   1. `.prompt` on UserPromptSubmit. The harness fills it from the human's typed
#      message. The model emits assistant turns and tool calls; it cannot submit a
#      user prompt. Same class of evidence as `.tool_response.answers`, and it does
#      NOT depend on the AskUserQuestion hook that was dormant.
#   2. A controlling terminal. The agent's Bash tool runs with no TTY at all
#      (`/dev/tty` -> "device not configured"), so a prompt read from /dev/tty
#      cannot be answered by an agent. This one needs no hook of any kind, which
#      is what makes it the break-glass: it still works when EVERY hook is
#      dormant, which is precisely the state that caused the incident.
#
# WHAT WAS REJECTED, so it is not re-proposed. A plain sanctioned command the
# human types with Claude Code's `!` prefix. It carries no distinguishing signal:
# `!` runs without a TTY too (verified against a real transcript where
# `! sudo ...` failed with "sudo: a terminal is required to read the password"),
# so no script can tell the human's `!` from the agent's Bash. That would have
# restored a one-word, agent-runnable bypass, which is the "sanctioned tool at an
# unsanctioned moment" failure #71 exists to prevent.
#
# HONEST SCOPE. Both overrides land as a FILE, so both inherit the residual
# already documented above: an agent with shell access can hand-write a stamp or
# a token. Neither override lowers that floor; each one adds a legitimate human
# route to the same place. What they do change is the audit trail: an override
# records its own `approval_source` (human-prompt-override / human-tty-override),
# so it never masquerades as a modal click, and it carries an expiry because it
# binds to no plan digest (see QPG_OVERRIDE_TTL in qa-plan-gate-lib.sh).

# The exact phrase the human types to override. Deliberately a sentence rather
# than a command: it is typed INTO THE CONVERSATION, so it must not look like
# something an agent would run, and it must read as a deliberate act.
QPT_OVERRIDE_PHRASE="qa-plan: I approve this plan"

# qpt_normalize_prompt <text>
#   Canonicalize a typed prompt for comparison: lowercase, collapse every run of
#   whitespace (newlines included) to one space, trim, then drop trailing `.`/`!`.
#   Echoes the normalized string.
#
#   The trailing-punctuation strip is the one leniency, and it is safe because it
#   cannot broaden the match to a DIFFERENT phrase, only to the same phrase typed
#   with a full stop. Everything else is exact.
qpt_normalize_prompt() {
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')
  printf '%s' "$s" | sed -e 's/^ *//' -e 's/ *$//' -e 's/[.!]*$//' -e 's/ *$//'
}

# qpt_prompt_is_override <prompt>
#   Does this typed prompt mean "override the QA-plan gate"? Echoes "override" /
#   "no"; return code 0 only for override.
#
#   THE WHOLE PROMPT must be the phrase. Not a prefix, not a contained substring,
#   not one line of a longer message. That is not fussiness: the phrase is written
#   down in this file, in the skill body, and in the README, so it gets QUOTED in
#   ordinary conversation about the feature. A substring match would let the
#   sentence "should I type qa-plan: I approve this plan?" mint a real override,
#   which is an approval nobody gave. Requiring a standalone message also makes
#   the override a deliberate act rather than something that falls out of a
#   sentence. Fails CLOSED: an empty prompt is "no".
qpt_prompt_is_override() {
  local n want
  n=$(qpt_normalize_prompt "$1")
  want=$(qpt_normalize_prompt "$QPT_OVERRIDE_PHRASE")
  if [ -n "$n" ] && [ "$n" = "$want" ]; then echo "override"; return 0; fi
  echo "no"; return 1
}

# qpt_should_mint_prompt <prompt> <branch>
#   THE prompt-override mint decision, composed in one pure place, mirroring
#   qpt_should_mint. Echoes "mint" or a single-word refusal reason
#   (no-phrase | no-branch); returns 0 only for "mint".
qpt_should_mint_prompt() {
  local prompt="$1" branch="$2"
  [ "$(qpt_prompt_is_override "$prompt")" = "override" ] || { echo "no-phrase"; return 1; }
  # Same reason as qpt_should_mint: a detached HEAD cannot be stamped, so a token
  # for one would only be a confusing dead file.
  { [ -n "$branch" ] && [ "$branch" != "HEAD" ]; } || { echo "no-branch"; return 1; }
  echo "mint"; return 0
}

# qpt_stamp_source_for <token_source>
#   Map a TOKEN's `source` to the `approval_source` its stamp records. Echoes the
#   stamp value, or nothing for an unrecognized token source; return code mirrors.
#
#   This exists so the stamp writer cannot copy an arbitrary token field into the
#   stamp. Before overrides there was one source and the writer hardcoded the
#   literal; now there are two, and the naive change (echo the token's own value)
#   would let a hand-written token choose its own `approval_source` string, which
#   is exactly the degree of freedom PR #76 removed from the gate side by
#   requiring an EXACT literal. Fails CLOSED: an unknown source yields empty and
#   the writer refuses rather than inventing a value.
qpt_stamp_source_for() {
  case "$1" in
    AskUserQuestion)  printf 'AskUserQuestion'; return 0 ;;
    UserPromptSubmit) printf 'human-prompt-override'; return 0 ;;
    *)                printf ''; return 1 ;;
  esac
}

# qpt_liveness_verdict <session_id> <seen>
#   Was the approval-token minting hook actually registered in this session?
#   <seen> is "yes" when a heartbeat for <session_id> exists; <feature_ran> is
#   "no" when the heartbeat DIRECTORY does not exist at all, which means no
#   minter carrying this feature has ever run on this machine. Echoes
#   "observed" | "never-observed" | "unknown"; returns 0 only for "observed".
#
#   WHY THIS IS WORTH A FUNCTION. The stamp writer used to GUESS, telling the
#   operator the hook was "probably not registered" and to restart. That guess is
#   right sometimes and actively misleading otherwise: the same refusal appears
#   when the hook IS registered and the header simply did not match, and then a
#   restart cannot help and the operator burns a session finding that out. The
#   minter now drops a heartbeat on EVERY AskUserQuestion it sees, so "registered"
#   becomes an observed fact instead of a hypothesis. "unknown" is honest about
#   the case where the session id is not in the environment at all.
qpt_liveness_verdict() {
  local session="$1" seen="$2" feature_ran="${3:-yes}"
  [ -n "$session" ] || { echo "unknown"; return 1; }
  [ "$seen" = "yes" ] && { echo "observed"; return 0; }
  # A session that started BEFORE the heartbeat existed has no heartbeat no
  # matter how well registered its minter is, so "no file" would be a false
  # accusation. <feature_ran> is "no" when the heartbeat directory itself is
  # absent, i.e. this machine has never run a minter that writes one. Reported
  # from a consumer repo (the music session) whose post-restart doctor read
  # "never-observed" for exactly this reason, which would have sent the operator
  # to restart a second time for nothing.
  [ "$feature_ran" = "no" ] && { echo "unknown"; return 1; }
  echo "never-observed"; return 1
}

# qpt_tty_confirm_phrase <branch>
#   The phrase the human must type at the TTY break-glass prompt. Branch-specific
#   on purpose: it cannot be muscle-memoried into the wrong repo, and a copied
#   transcript of one override does not spell out the next one.
qpt_tty_confirm_phrase() {
  printf 'override qa plan for %s' "$1"
}

# qpt_writer_is_guarded <path_to_qa_plan_stamp_sh>
#   Does the stamp writer at <path> require an approval token? Echoes "yes"/"no";
#   returns 0 for "yes". An unreadable path is "no".
#
#   Used by bin/install to prune cached plugin versions whose writer PREDATES the
#   token guard. Those copies are not merely stale, they are a live bypass: on
#   2026-09-03 an agent that could not write a stamp with the repo's guarded
#   writer ran the cached 3.8.0 one by absolute path, and it wrote an unattested
#   stamp bearing the human's name from `git config user.name`, which is the whole
#   #71 defect reproduced after the fix had shipped. The gate rejected that stamp,
#   so nothing merged, but leaving the unguarded writers on disk means every future
#   session has the same wrong tool within reach.
qpt_writer_is_guarded() {
  local p="$1"
  [ -r "$p" ] || { echo "no"; return 1; }
  if grep -q 'qa-plan-approval-token' "$p" 2>/dev/null; then echo "yes"; return 0; fi
  echo "no"; return 1
}

# qpt_liveness_dir
#   Where minter heartbeats live: one file per Claude Code session id. A DIRECTORY
#   rather than a single file because sessions run concurrently on this machine and
#   a shared file would have them clobbering each other's evidence, turning a
#   liveness signal into a race.
qpt_liveness_dir() {
  printf '%s/.claude/qa-plan-minter-seen' "${HOME:-/tmp}"
}

# qpt_liveness_file <session_id>
#   The heartbeat path for one session, or nothing when the id is empty or has no
#   usable characters. The id is reduced to [A-Za-z0-9._-] before it is used as a
#   filename, so a session id carrying a slash or a `..` cannot steer the write
#   out of the heartbeat directory.
qpt_liveness_file() {
  local raw="$1" safe
  [ -n "$raw" ] || { printf ''; return 1; }
  safe=$(printf '%s' "$raw" | tr -cd 'A-Za-z0-9._-')
  # A name of only dots would still resolve to a directory entry we do not want.
  case "$safe" in ''|.|..) printf ''; return 1 ;; esac
  printf '%s/%s' "$(qpt_liveness_dir)" "$safe"
  return 0
}
