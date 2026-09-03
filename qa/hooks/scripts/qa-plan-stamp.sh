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
#   qa-plan-stamp.sh override
#       THE BREAK-GLASS. Write a stamp on the strength of a human confirming at a
#       REAL CONTROLLING TERMINAL. Refuses outright when stdin/dev/tty is not a
#       terminal, which is every agent invocation: the Bash tool runs with no
#       controlling terminal at all (`/dev/tty` -> "device not configured",
#       measured 2026-09-03), and so does a `!`-prefixed command typed in Claude
#       Code (a real transcript shows `! sudo ...` failing with "sudo: a terminal
#       is required to read the password"). So this verb is reachable from a
#       terminal tab and from nowhere inside a Claude session, by either party.
#
#       It is the ONLY route that needs no hook, which is what makes it the
#       recovery for the failure that prompted it: on 2026-09-03 the minting hook
#       was dormant (registration is read at session start), so every hook-based
#       route, including the typed-phrase override, was dead in that session.
#
#       The resulting stamp records approval_source "human-tty-override" and an
#       expiry, so it is never mistaken for a modal approval.
#
#   qa-plan-stamp.sh doctor
#       Explain the current state instead of making the caller guess: the stamp
#       and its verdict, the remedy for that verdict, the token, whether the
#       minting hook has actually been observed in THIS session, and whether the
#       installed plugin copy has drifted from this source tree. Written because
#       the 2026-09-03 dead end was diagnosable in principle and undiagnosable in
#       practice.
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

# qp_minter_liveness <session_id>
#   The one I/O wrapper around the pure qpt_liveness_verdict: turn "is there a
#   heartbeat file for this session" into the verdict. Kept here rather than in
#   the token lib because that lib is pure by contract and this touches the disk.
qp_minter_liveness() {
  local session="$1" hb seen="no" ran="yes"
  hb=$(qpt_liveness_file "$session" 2>/dev/null || echo "")
  [ -n "$hb" ] && [ -f "$hb" ] && seen="yes"
  [ -d "$(qpt_liveness_dir)" ] || ran="no"
  qpt_liveness_verdict "$session" "$seen" "$ran"
}

VERB="${1:-status}"; shift || true

# `digest` takes an optional path; `write` and the rest take no options at all.
DIGEST_PATH="${1:-}"
case "$VERB" in
  write|status|clear|override|doctor)
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
    _SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
    _LIVENESS=$(qp_minter_liveness "$_SESSION_ID")
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
        # The liveness readout. This paragraph used to GUESS ("the hook is
        # probably not registered") and send the operator to restart. That guess
        # is wrong whenever the hook IS registered and simply declined to mint,
        # and a restart cannot fix those cases; on 2026-09-03 it sent the operator
        # to restart for a problem a restart could not solve. The minter now drops
        # a heartbeat for every AskUserQuestion it sees, so this reports what was
        # observed instead of what is likely.
        case "$_LIVENESS" in
          never-observed)
            echo "DIAGNOSIS: the token-minting hook has NOT run at all in this session"
            echo "(session $_SESSION_ID). Hook REGISTRATION is read at session start, so a"
            echo "hook added since this session began is dormant no matter how current the"
            echo "script on disk is."
            echo
            echo "FIX, IN THIS ORDER: run bin/install, THEN restart Claude Code. Restarting"
            echo "alone is not enough and has already cost a session: the hook set is read"
            echo "from the INSTALLED plugin copy, so a restart with a stale cache re-registers"
            echo "the stale hooks and lands you right back here. Run 'qa-plan-stamp.sh doctor'"
            echo "to see whether the installed version has drifted from this source tree."
            echo
            echo "CAVEAT: a session that started before qa 3.10.0 (which added this heartbeat)"
            echo "records nothing even when its minter IS registered, so this reads"
            echo "never-observed during the upgrade itself. If /qa:plan has already stamped"
            echo "successfully in this session, the minter IS registered and the cause is one"
            echo "of the ones listed for the observed case, not a missing hook." ;;
          observed)
            echo "DIAGNOSIS: the token-minting hook IS registered and HAS run in this"
            echo "session, so a restart will not help. It saw a question and declined to"
            echo "mint. The usual causes are a modal whose header is not exactly \"QA plan\","
            echo "an answer that is not exactly \"Approve\" (a qualified label like"
            echo "\"Approve (skip Prod QA)\" deliberately does not count), or an approval"
            echo "given on a different branch. Check ~/.claude/qa-plan-gate.log: the hook"
            echo "logs its refusal reason on every no-mint." ;;
          *)
            echo "DIAGNOSIS: cannot tell whether the minting hook is registered (no session"
            echo "id in the environment). Check ~/.claude/qa-plan-gate.log for"
            echo "approval-token lines." ;;
        esac
        echo
        echo "IF YOU ARE THE HUMAN and you have already approved this plan, you can override"
        echo "without restarting. Neither route below is reachable by Claude:"
        echo "  1. Send \"$QPT_OVERRIDE_PHRASE\" as a message on its own."
        echo "  2. Run 'qa-plan-stamp.sh override' in a real terminal tab."
        echo "Route 1 needs the hooks to be registered; route 2 needs nothing but a terminal."
        echo "Run 'qa-plan-stamp.sh doctor' for the full state."
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

    # The stamp's approval_source is DERIVED from the token's source through a
    # closed mapping, never copied from it. There are two minting hooks now (the
    # modal click and the typed override), so the literal can no longer be
    # hardcoded; the naive fix, echoing the token's own `source`, would hand a
    # hand-written token a free choice of approval_source, which is exactly the
    # degree of freedom PR #76 removed from the gate side. An unrecognized source
    # maps to empty and refuses here rather than producing a stamp the gates will
    # reject later with a confusing verdict.
    TOKEN_SOURCE=$(printf '%s' "$TOKEN_JSON" | jq -r '.source // empty' 2>/dev/null || echo "")
    APPROVAL_SOURCE=$(qpt_stamp_source_for "$TOKEN_SOURCE") || APPROVAL_SOURCE=""
    if [ -z "$APPROVAL_SOURCE" ]; then
      {
        echo "qa-plan-stamp.sh: REFUSING to write the approval stamp: the token's source"
        echo "(\"${TOKEN_SOURCE:-<absent>}\") is not one this script recognizes. A token is"
        echo "written only by qa-plan-approval-token.sh (source AskUserQuestion) or"
        echo "qa-plan-prompt-override.sh (source UserPromptSubmit); anything else means the"
        echo "file was hand-written. Delete $TOKEN and get a real approval."
      } >&2
      exit 1
    fi

    HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
    NOW_EPOCH=$(date +%s)
    NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # An override stamp carries an expiry; a modal-click stamp does not. See
    # QPG_OVERRIDE_TTL and the reasoning in qpg_stamp_valid: an override binds to
    # no plan digest, so the drift check can never invalidate it and time is the
    # only bound left. jq emits `null` for the click path, and
    # `.expires_at_epoch // empty` on the gate side reads null as absent, which is
    # exactly the "no expiry" the click path wants.
    if [ "$(qpg_source_is_override "$APPROVAL_SOURCE")" = "override" ]; then
      EXPIRES=$(( NOW_EPOCH + QPG_OVERRIDE_TTL ))
    else
      EXPIRES="null"
    fi

    tmp=$(mktemp "$GITDIR/.qa-plan-approved.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
    jq -nc \
      --arg branch "$BRANCH" \
      --arg iso "$NOW_ISO" \
      --argjson epoch "$NOW_EPOCH" \
      --arg head "$HEAD" \
      --arg digest "$DIGEST" \
      --arg approver "$APPROVER" \
      --arg nonce "$NONCE" \
      --arg source "$APPROVAL_SOURCE" \
      --argjson expires "$EXPIRES" \
      '{branch:$branch, approved_at:$iso, approved_at_epoch:$epoch,
        head_at_approval:$head, criteria_digest:$digest, approver:$approver,
        approval_source:$source, approval_nonce:$nonce,
        expires_at_epoch:$expires, tool:"qa-plan"}' > "$tmp" || { rm -f "$tmp"; echo "jq write failed" >&2; exit 1; }
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

  override)
    # THE BREAK-GLASS. Authorized by a human confirming at a REAL CONTROLLING
    # TERMINAL, which is the only human signal in this system that needs no hook.
    # That matters because the failure this exists for is a DORMANT HOOK: on
    # 2026-09-03 the minting hook had been added after the session started, so
    # every hook-based route was dead and restarting was the only option.
    #
    # WHY A TTY IS REAL EVIDENCE HERE. Measured 2026-09-03: the agent's Bash tool
    # runs with no controlling terminal whatsoever. `[ -t 0 ]` is false and
    # `/dev/tty` cannot even be opened ("device not configured"), because the
    # process has no controlling terminal to open, and a process cannot acquire
    # another session's terminal. A `!`-prefixed command in Claude Code is the
    # same: a real transcript shows `! sudo ...` failing with "sudo: a terminal is
    # required to read the password". So this verb is reachable from a terminal
    # tab and from nowhere inside a Claude session, by the agent OR the human.
    # That last part is the cost of the design and it is deliberate: a route the
    # human can take from the Claude prompt is a route the agent can take too.
    command -v jq >/dev/null 2>&1 || { echo "qa-plan-stamp.sh: jq required" >&2; exit 1; }
    [ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || {
      echo "qa-plan-stamp.sh: refusing to stamp a detached HEAD; checkout a branch" >&2; exit 1; }

    # fd 9, deliberately not fd 3. bats reserves fd 3 for its own TAP stream, so a
    # prompt written to fd 3 corrupts the harness output instead of being captured,
    # and a test around this verb then reports a mangled count rather than a clean
    # failure. Found while mutation-testing this guard: the mutant that deleted it
    # broke bats itself, which is indistinguishable from "no test noticed".
    if ! exec 9<>/dev/tty 2>/dev/null; then
      {
        echo "qa-plan-stamp.sh: REFUSING to override: no controlling terminal."
        echo
        echo "This verb writes a stamp attesting that a HUMAN approved the QA plan, and the"
        echo "only thing standing behind it is that a person typed a confirmation at a real"
        echo "terminal. A process with no controlling terminal cannot be that person."
        echo
        echo "If you are Claude: this is not a step to work around. Stop and tell the human"
        echo "the two routes open to them: sending \"$QPT_OVERRIDE_PHRASE\" as a message on"
        echo "its own, or running this command themselves in a terminal tab."
        echo
        echo "If you are the human: you are seeing this because you ran it through Claude"
        echo "(the Bash tool and the ! prefix are both non-TTY). Open a terminal tab, cd to"
        echo "this repo, and run it there."
      } >&2
      exit 1
    fi

    WANT=$(qpt_tty_confirm_phrase "$BRANCH")
    {
      echo "QA-plan approval override for branch: $BRANCH"
      echo
      echo "You are about to record that YOU approved this branch's two-phase QA plan."
      echo "This override binds to no plan text, so it expires in $(( QPG_OVERRIDE_TTL / 3600 ))h and is recorded"
      echo "as approval_source \"human-tty-override\", never as a modal approval."
      echo
      echo "Type this exactly to confirm, or anything else to abort:"
      echo "  $WANT"
    } >&9
    printf '> ' >&9
    IFS= read -r REPLY_LINE <&9 || REPLY_LINE=""
    exec 9<&- 9>&- 2>/dev/null || true

    # Compared through the same normalizer the typed-phrase override uses, so
    # case and stray whitespace do not turn a correct confirmation into a
    # mysterious abort. Still exact otherwise, and branch-specific so a
    # remembered phrase cannot be replayed into the wrong repo.
    if [ "$(qpt_normalize_prompt "$REPLY_LINE")" != "$(qpt_normalize_prompt "$WANT")" ]; then
      echo "qa-plan-stamp.sh: override aborted (confirmation did not match)." >&2
      exit 1
    fi

    # `git config user.name` IS consulted here, and only here, for the same reason
    # the minting hooks consult it: this is a moment we know a real person acted,
    # which is what entitles the record to carry their name. `write` still reads
    # it nowhere.
    APPROVER=$(git config user.name 2>/dev/null || true)
    [ -n "$APPROVER" ] && APPROVER="$APPROVER (via terminal override)"
    [ -n "$APPROVER" ] || APPROVER="human (via terminal override)"

    HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
    NOW_EPOCH=$(date +%s)
    NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    NONCE=$( { head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n'; } || echo "" )
    [ -n "$NONCE" ] || NONCE="$NOW_EPOCH-$$"

    tmp=$(mktemp "$GITDIR/.qa-plan-approved.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
    jq -nc \
      --arg branch "$BRANCH" \
      --arg iso "$NOW_ISO" \
      --argjson epoch "$NOW_EPOCH" \
      --arg head "$HEAD" \
      --arg approver "$APPROVER" \
      --arg nonce "$NONCE" \
      --argjson expires "$(( NOW_EPOCH + QPG_OVERRIDE_TTL ))" \
      '{branch:$branch, approved_at:$iso, approved_at_epoch:$epoch,
        head_at_approval:$head, criteria_digest:"none", approver:$approver,
        approval_source:"human-tty-override", approval_nonce:$nonce,
        expires_at_epoch:$expires, tool:"qa-plan"}' > "$tmp" \
      || { rm -f "$tmp"; echo "jq write failed" >&2; exit 1; }
    mv -f "$tmp" "$STAMP" || { rm -f "$tmp"; echo "stamp write failed" >&2; exit 1; }
    printf '%s tty-override stamp branch=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" >> "$HOME/.claude/qa-plan-gate.log" 2>/dev/null || true
    echo "$STAMP"
    ;;

  doctor)
    # Explain the state instead of making the caller infer it. Every line here
    # answers a question that on 2026-09-03 could only be answered by reading
    # source: which stamp is on the branch, why the gate rejects it, what actually
    # fixes that, whether the minting hook is alive, and whether the copy of the
    # plugin that the runtime loads matches this source tree.
    echo "qa-plan doctor"
    echo "  repo:    $(git rev-parse --show-toplevel 2>/dev/null || echo '?')"
    echo "  branch:  ${BRANCH:-<detached>}"
    echo "  git dir: $GITDIR"
    echo

    _STAMP_JSON=$(cat "$STAMP" 2>/dev/null || echo "")
    _V=$(qpg_stamp_valid "$_STAMP_JSON" "$BRANCH")
    echo "  stamp:   $([ -n "$_STAMP_JSON" ] && echo "present" || echo "absent") [$_V]"
    if [ -n "$_STAMP_JSON" ]; then
      echo "           source=$(printf '%s' "$_STAMP_JSON" | jq -r '.approval_source // "<none>"' 2>/dev/null || echo '?')"            "approver=$(printf '%s' "$_STAMP_JSON" | jq -r '.approver // "<none>"' 2>/dev/null || echo '?')"
      _EXP=$(printf '%s' "$_STAMP_JSON" | jq -r '.expires_at_epoch // empty' 2>/dev/null || echo "")
      [ -n "$_EXP" ] && echo "           expires=$_EXP (now=$(date +%s))"
    fi
    [ "$_V" = "valid" ] || echo "           remedy: $(qpg_block_advice "$_V")"
    echo

    if [ -f "$TOKEN" ]; then
      echo "  token:   present [$(qpt_token_valid "$(cat "$TOKEN" 2>/dev/null || echo "")" "$BRANCH" "$(date +%s)")]"            "source=$(jq -r '.source // "<none>"' "$TOKEN" 2>/dev/null || echo '?')"
    else
      echo "  token:   none"
    fi

    _SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
    _L=$(qp_minter_liveness "$_SESSION_ID")
    echo "  minter:  $_L (session ${_SESSION_ID:-<unset>})"
    case "$_L" in
      never-observed)
        echo "           the AskUserQuestion minting hook has not run in this session;"
        echo "           if it was added since the session started, only a restart registers it"
        # The transitional false alarm, reported from a consumer repo. A session
        # that started before this heartbeat existed records nothing no matter how
        # well registered its minter is, and the operator who trusts a bare
        # "not registered" there restarts for nothing. Say so rather than assert.
        echo "           CAVEAT: a session that started before qa 3.10.0 (which added this"
        echo "           heartbeat) records nothing even when its minter IS registered, so"
        echo "           this reads never-observed during the upgrade itself. A session"
        echo "           started after 3.10.0 was installed gives a reliable answer." ;;
      observed)       echo "           the minting hook is registered and running; a restart will not change anything" ;;
      *)              echo "           no session id in the environment, so liveness cannot be determined" ;;
    esac
    echo

    # Version skew between this source tree and the installed plugin copies. The
    # 2026-09-03 incident had the gate running 3.9.5 logic from the checkout while
    # the newest INSTALLED copy was 3.8.0, whose stamp writer predates the token
    # guard entirely. Nothing reported that, and the blocked agent found the old
    # writer and used it.
    _SRC_MANIFEST="$LIBDIR/../../.claude-plugin/plugin.json"
    _SRC_VER=$(jq -r '.version // empty' "$_SRC_MANIFEST" 2>/dev/null || echo "")
    _CACHE="$HOME/.claude/plugins/cache/gstack-extensions/qa"
    _INST_VER=$(ls -1 "$_CACHE" 2>/dev/null | sort -V | tail -1)
    echo "  source version:    ${_SRC_VER:-?}"
    echo "  installed version: ${_INST_VER:-<none installed>}"
    if [ -n "$_SRC_VER" ] && [ -n "$_INST_VER" ] && [ "$_SRC_VER" != "$_INST_VER" ]; then
      echo "           SKEW: run bin/install and restart Claude Code."
    fi
    _UNGUARDED=""
    for _d in "$_CACHE"/*; do
      [ -d "$_d" ] || continue
      if [ "$(qpt_writer_is_guarded "$_d/hooks/scripts/qa-plan-stamp.sh")" = "no" ]; then
        _UNGUARDED="$_UNGUARDED $(basename "$_d")"
      fi
    done
    if [ -n "$_UNGUARDED" ]; then
      echo "           WARNING: cached plugin versions whose stamp writer predates the"
      echo "           approval-token guard are still on disk:$_UNGUARDED"
      echo "           Each is a writer that will happily stamp without a human. Run"
      echo "           bin/install to prune them."
    fi
    echo

    echo "  human override routes (neither is reachable by Claude):"
    echo "    1. send \"$QPT_OVERRIDE_PHRASE\" as a message on its own (needs hooks registered)"
    echo "    2. run 'qa-plan-stamp.sh override' in a real terminal tab (needs no hooks)"
    ;;

  *)
    echo "qa-plan-stamp.sh: unknown verb '$VERB' (write|status|clear|digest|override|doctor)" >&2; exit 2 ;;
esac
