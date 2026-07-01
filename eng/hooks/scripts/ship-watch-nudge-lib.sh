#!/bin/bash
# Pure, side-effect-free decision logic for the after-ship CodeRabbit watcher
# nudge, extracted so it can be unit tested (tests/ship-watch-nudge-lib.bats)
# without a live repo, a session, the network, or any hook plumbing. Every
# function takes everything it needs as arguments and writes only to stdout.
#
# Consumer:
#   scripts/ship-watch-nudge.sh - a PostToolUse Bash hook. After a genuine /ship
#   opens a PR in an opted-in ~/dev repo, it decides WHAT to nudge the main agent
#   toward and builds the additionalContext string.
#
# The "why": a hook cannot launch a foreground skill (/eng:pr-watcher pairs the
# main agent with a sensor subagent), but it CAN inject additionalContext that the
# model reads next turn. So the durable, reliable mechanism is an auto-NUDGE, not
# an auto-run. The nudge is rate-limit-aware: it must not push the agent into an
# open-ended watch loop when CodeRabbit will not actually review (rate-limited).
# In that case the right move is the one merge-clearance.sh already encodes - a
# current local /eng:cr review backstops the rate-limited CR, and the PR is clear
# to land via /land-and-deploy. The hook detects rate-limit with the SAME
# mc_cr_rate_limited (from merge-clearance-lib.sh) the merge gate uses for a MISSING
# CR status, which is exactly the state at a fresh /ship create, so the two agree in
# the case the nudge targets. (The merge gate additionally uses the stricter
# mc_cr_rate_limited_latest for a stuck-"pending" status; that state does not exist
# at create time, so the nudge does not need it and the two are not claimed to agree
# universally, only for the missing-status create moment.)
#
# Requires grep (present everywhere). No jq dependency here; the hook does the
# JSON parsing and passes plain strings in.

# swn_is_pr_create <cmd>
#   Echo "yes" iff <cmd> runs `gh pr create` at command position (line start or
#   after a shell separator), tolerating leading env-var assignments and an
#   absolute/relative path to gh. Mirrors ship-pr-gate.sh's matcher EXACTLY so the
#   nudge fires on precisely the creates the gate governs. Accident-guard, not a
#   real shell parser: a plain quoted argument (`--body 'run gh pr create'`) does
#   NOT trip it (the phrase is preceded by a word, not a separator), but a quoted
#   body that embeds a shell separator immediately before the phrase
#   (`--body 'done; gh pr create'`) WILL match, exactly as it does in the gate. The
#   cost of that false match HERE is only a single spurious, deduped nudge (never a
#   block, and still gated behind a fresh /ship sentinel plus a real PR URL in the
#   output), so the loose match is acceptable and kept byte-identical to the gate on
#   purpose. Echo "no" otherwise.
swn_is_pr_create() {
  printf '%s' "$1" | grep -Eq '(^|[;&|(])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*([^[:space:];&|]*/)?gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' \
    && { echo "yes"; return 0; }
  echo "no"; return 1
}

# swn_extract_pr_url <text>
#   Echo the first GitHub pull-request URL found in <text> (gh pr create prints it
#   on stdout), or nothing. Anchored on the `/pull/<digits>` shape so a repo URL or
#   a compare URL is not mistaken for a PR URL. Empty output => no PR URL => the
#   hook makes no nudge (fail-open).
swn_extract_pr_url() {
  printf '%s' "$1" \
    | grep -oE 'https://github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+' \
    | head -1
}

# swn_pr_num_from_url <url>
#   Echo the trailing PR number from a GitHub PR URL, or nothing.
swn_pr_num_from_url() {
  printf '%s' "$1" | grep -oE '[0-9]+$' | head -1
}

# swn_decide <rate_limited:yes|no> <backstop:yes|no>
#   The core branch. Echo the nudge MODE:
#     watch            - CR is not rate-limited (a real review is coming): nudge
#                        the agent to start /eng:pr-watcher.
#     land             - CR is rate-limited AND a current local /eng:cr review
#                        backstops this HEAD (same interlock as merge-clearance's
#                        CR_RL_BACKSTOPPED): nothing to watch, clear to land.
#     review_then_land - CR is rate-limited and NO current local review backstops
#                        it: do not watch; run /eng:cr, then land.
#   Any unrecognized <rate_limited> is treated as "no" (the safe default is the
#   watch nudge, which never asserts the PR is clear to land).
swn_decide() {
  local rate_limited="$1" backstop="$2"
  if [ "$rate_limited" = "yes" ]; then
    if [ "$backstop" = "yes" ]; then echo "land"; else echo "review_then_land"; fi
    return 0
  fi
  echo "watch"
}

# swn_build_context <mode> <pr_url> <pr_num>
#   Build the additionalContext string injected back to the model. Framed as
#   operational POLICY (not a bare command to repeat a value) so it reads as a
#   workflow reminder the agent acts on, the way the ship/merge gate reasons do.
#   Each branch names the exact next command. Unknown <mode> falls back to the
#   watch nudge (the conservative default).
swn_build_context() {
  local mode="$1" url="$2" num="$3"
  case "$mode" in
    land)
      printf '%s' "Post-ship policy: /ship just opened PR #${num} (${url}). CodeRabbit is rate-limited (its notice contains 'rate limited by coderabbit.ai') and did not review this HEAD, but a current local /eng:cr review already backstops it (the same condition merge-clearance honors). There is nothing to watch: do NOT start /eng:pr-watcher. This PR is clear to land via /land-and-deploy."
      ;;
    review_then_land)
      printf '%s' "Post-ship policy: /ship just opened PR #${num} (${url}). CodeRabbit is rate-limited (its notice contains 'rate limited by coderabbit.ai') and will not review this HEAD, and no current local /eng:cr review backstops it. Do NOT open-endedly watch with /eng:pr-watcher. Run /eng:cr on this HEAD to backstop the rate-limited CodeRabbit, then land via /land-and-deploy."
      ;;
    *)
      printf '%s' "Post-ship policy: /ship just opened PR #${num} (${url}). A shipped PR must not be left unwatched: start the CodeRabbit watcher now by running /eng:pr-watcher ${url}. If the watcher reports CodeRabbit is rate-limited (a comment containing 'rate limited by coderabbit.ai', or it exits via cr_failure / already_settled with no real review), stop watching: instead ensure a current /eng:cr review backstops this HEAD, then land via /land-and-deploy."
      ;;
  esac
}

# swn_already_nudged <nudged_file_contents> <pr_url>
#   Dedupe check: echo "yes" iff <pr_url> already appears (as a whole line) in the
#   newline-separated <nudged_file_contents>, so the same PR is never nagged twice
#   (a re-run of `gh pr create` on an existing branch prints the same URL). An
#   empty url is "no" (nothing to match). Pure: the hook reads the file and passes
#   its contents.
swn_already_nudged() {
  local nudged="$1" url="$2"
  [ -n "$url" ] || { echo "no"; return 1; }
  printf '%s\n' "$nudged" | grep -Fxq "$url" && { echo "yes"; return 0; }
  echo "no"; return 1
}
