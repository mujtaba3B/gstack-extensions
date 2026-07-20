#!/bin/bash
# Deterministic sensing for /eng:pr-watcher. Implements the whole polling
# protocol (init pass, status-primary 15s loop, comment-stream fallback,
# settle conditions, budgets) and prints EXACTLY ONE JSON object to stdout,
# then exits 0. The dispatcher runs this in a FOREGROUND Bash call; a slice
# that runs out of time emits {"outcome":"continue"} and persists its place in
# <state-dir>/sensor-state.json so the next foreground call resumes.
#
# Outcomes: new_cr_feedback | already_settled | cr_failure | pr_closed |
#           idle_timeout | continue | error
#
# Usage:
#   sensor-poll.sh --owner O --repo R --pr N --state-dir DIR \
#     [--slice-seconds 540] [--total-seconds 1800]
#
# Reads baselines from DIR/baseline_{issue_comments,reviews,review_comments}.json
# (maintained by the dispatcher). Diagnostics go to stderr only.

set -u

# Claude Code's Bash tool strips the PATH (no homebrew); bind the usual homes
# for gh/jq explicitly so the script works in both stripped and full shells.
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sensor-poll-lib.sh"
# shellcheck source=/dev/null
. "$LIB" || { echo '{"outcome":"error","error_message":"sensor-poll-lib.sh not found"}'; exit 0; }

OWNER="" REPO="" PR_NUM="" STATE_DIR=""
SLICE_SECONDS=540
TOTAL_SECONDS=1800
QUIET_SECONDS=180
TICK_SECONDS=15
FALLBACK_EVERY=4      # comment-stream fallback every Nth tick (~60s)
MAX_CONSEC_FAILURES=40 # ~10 min of failing API calls -> outcome error

while [ $# -gt 0 ]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR_NUM="$2"; shift 2 ;;
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --slice-seconds) SLICE_SECONDS="$2"; shift 2 ;;
    --total-seconds) TOTAL_SECONDS="$2"; shift 2 ;;
    *) echo "sensor-poll.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$OWNER" ] && [ -n "$REPO" ] && [ -n "$PR_NUM" ] && [ -n "$STATE_DIR" ] \
  || { echo "sensor-poll.sh: --owner/--repo/--pr/--state-dir are required" >&2; exit 2; }
command -v gh >/dev/null && command -v jq >/dev/null \
  || { sp_emit error 0 0 "" "" "" "n/a" '[]' '[]' '[]' "gh or jq not on PATH"; exit 0; }

STATE_FILE="$STATE_DIR/sensor-state.json"
mkdir -p "$STATE_DIR"

baseline() { cat "$STATE_DIR/baseline_$1.json" 2>/dev/null || echo '[]'; }

# --- state (persisted across slices; one sense cycle = one state-file lifetime)
POLL_STARTED="" TICKS=0 LAST_TERMINAL="" PREV_FP="" FALLBACK_TICKS=0 CONSEC_FAILURES=0
load_state() {
  [ -f "$STATE_FILE" ] || return 1
  POLL_STARTED=$(jq -r '.poll_started' "$STATE_FILE")
  TICKS=$(jq -r '.ticks' "$STATE_FILE")
  LAST_TERMINAL=$(jq -r '.last_terminal // ""' "$STATE_FILE")
  PREV_FP=$(jq -r '.prev_fp // ""' "$STATE_FILE")
  FALLBACK_TICKS=$(jq -r '.fallback_ticks // 0' "$STATE_FILE")
  CONSEC_FAILURES=$(jq -r '.consecutive_failures // 0' "$STATE_FILE")
}
save_state() {
  jq -cn --argjson started "$POLL_STARTED" --argjson ticks "$TICKS" \
    --arg last "$LAST_TERMINAL" --arg fp "$PREV_FP" \
    --argjson fb "$FALLBACK_TICKS" --argjson fails "$CONSEC_FAILURES" \
    '{poll_started: $started, ticks: $ticks,
      last_terminal: (if $last == "" then null else $last end),
      prev_fp: (if $fp == "" then null else $fp end),
      fallback_ticks: $fb, consecutive_failures: $fails}' > "$STATE_FILE"
}

# finish <outcome> <settled_via> <cr_state> <cr_updated> <ic> <rv> <rc> [err]
#   Terminal emit: the sense cycle is over, so the state file is removed.
CURRENT_SHA=""
finish() {
  local now; now=$(date +%s)
  local polled=0
  [ -n "$POLL_STARTED" ] && polled=$((now - POLL_STARTED))
  rm -f "$STATE_FILE"
  sp_emit "$1" "$polled" "$TICKS" "$CURRENT_SHA" "$3" "$4" "$2" "$5" "$6" "$7" "${8:-}"
  exit 0
}

# --- gh fetch helpers (set globals; return non-zero on API failure)
PR_STATE="" LATEST_STATUS="" NEW_IC="" NEW_RV="" NEW_RC=""
fetch_pr() {
  local out
  out=$(gh pr view "$PR_NUM" --repo "$OWNER/$REPO" --json state,headRefOid 2>/dev/null) || return 1
  PR_STATE=$(jq -r '.state' <<<"$out")
  CURRENT_SHA=$(jq -r '.headRefOid' <<<"$out")
}
fetch_status() {
  local out
  out=$(gh api "repos/$OWNER/$REPO/commits/$CURRENT_SHA/statuses?per_page=100" 2>/dev/null) || return 1
  LATEST_STATUS=$(sp_latest_cr_status "$out")
}
fetch_streams() {
  local ic rv rc
  ic=$(gh api "repos/$OWNER/$REPO/issues/$PR_NUM/comments?per_page=100" 2>/dev/null) || return 1
  rv=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUM/reviews?per_page=100" 2>/dev/null) || return 1
  rc=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUM/comments?per_page=100" 2>/dev/null) || return 1
  NEW_IC=$(sp_filter_new issue_comments "$ic" "$(baseline issue_comments)")
  NEW_RV=$(sp_filter_new reviews "$rv" "$(baseline reviews)")
  NEW_RC=$(sp_filter_new review_comments "$rc" "$(baseline review_comments)")
}
new_total() { jq -n --argjson a "$NEW_IC" --argjson b "$NEW_RV" --argjson c "$NEW_RC" '($a|length)+($b|length)+($c|length)'; }
status_state()   { jq -r 'if . == null then "" else .state end' <<<"$LATEST_STATUS"; }
status_updated() { jq -r 'if . == null then "" else .updated_at end' <<<"$LATEST_STATUS"; }

# --- init pass (first slice of a sense cycle only)
if ! load_state; then
  POLL_STARTED=$(date +%s)
  fetch_pr || finish error "n/a" "" "" '[]' '[]' '[]' "gh pr view failed (auth? repo? network?)"
  [ "$PR_STATE" = "MERGED" ] || [ "$PR_STATE" = "CLOSED" ] && finish pr_closed "n/a" "" "" '[]' '[]' '[]'
  fetch_status || finish error "n/a" "" "" '[]' '[]' '[]' "commit status fetch failed"
  fetch_streams || finish error "n/a" "" "" '[]' '[]' '[]' "comment stream fetch failed"
  STATE=$(status_state); UPDATED=$(status_updated)
  if [ "$(new_total)" -eq 0 ]; then
    case "$STATE" in
      success) finish already_settled "n/a" "$STATE" "$UPDATED" '[]' '[]' '[]' ;;
      failure|error) finish cr_failure "n/a" "$STATE" "$UPDATED" '[]' '[]' '[]' ;;
    esac
  else
    # Backlog exists: drain it now only if a settle condition already holds;
    # otherwise CR is mid-review and returning would surface a partial batch.
    case "$STATE" in
      success|failure|error)
        finish new_cr_feedback status_transition "$STATE" "$UPDATED" "$NEW_IC" "$NEW_RV" "$NEW_RC" ;;
    esac
    ALL_NEW=$(jq -cn --argjson a "$NEW_IC" --argjson b "$NEW_RV" --argjson c "$NEW_RC" '$a+$b+$c')
    [ "$(sp_fallback_settled "$ALL_NEW")" = "yes" ] \
      && finish new_cr_feedback marker "$STATE" "$UPDATED" "$NEW_IC" "$NEW_RV" "$NEW_RC"
    [ "$(sp_all_quiet "$ALL_NEW" "$(date +%s)" "$QUIET_SECONDS")" = "yes" ] \
      && finish new_cr_feedback quiet_period "$STATE" "$UPDATED" "$NEW_IC" "$NEW_RV" "$NEW_RC"
  fi
  case "$STATE" in success|failure|error) LAST_TERMINAL="$UPDATED" ;; esac
  save_state
fi

# --- 15s polling loop (one slice)
SLICE_STARTED=$(date +%s)
while true; do
  NOW=$(date +%s)
  if [ $((NOW - POLL_STARTED)) -ge "$TOTAL_SECONDS" ]; then
    STATE=$(status_state); UPDATED=$(status_updated)
    finish idle_timeout "n/a" "$STATE" "$UPDATED" '[]' '[]' '[]'
  fi
  if [ $((NOW - SLICE_STARTED)) -ge "$SLICE_SECONDS" ]; then
    save_state
    sp_emit continue $((NOW - POLL_STARTED)) "$TICKS" "$CURRENT_SHA" \
      "$(status_state)" "$(status_updated)" "n/a" '[]' '[]' '[]'
    exit 0
  fi

  TICKS=$((TICKS + 1))
  if ! fetch_pr; then
    CONSEC_FAILURES=$((CONSEC_FAILURES + 1))
    [ "$CONSEC_FAILURES" -ge "$MAX_CONSEC_FAILURES" ] \
      && finish error "n/a" "" "" '[]' '[]' '[]' "gh API failing repeatedly (rate limit or auth?)"
    sleep "$TICK_SECONDS"; continue
  fi
  [ "$PR_STATE" = "MERGED" ] || [ "$PR_STATE" = "CLOSED" ] && finish pr_closed "n/a" "" "" '[]' '[]' '[]'
  if ! fetch_status; then
    CONSEC_FAILURES=$((CONSEC_FAILURES + 1))
    [ "$CONSEC_FAILURES" -ge "$MAX_CONSEC_FAILURES" ] \
      && finish error "n/a" "" "" '[]' '[]' '[]' "gh API failing repeatedly (rate limit or auth?)"
    sleep "$TICK_SECONDS"; continue
  fi
  CONSEC_FAILURES=0
  STATE=$(status_state); UPDATED=$(status_updated)

  if [ "$(sp_fresh_transition "$STATE" "$UPDATED" "$LAST_TERMINAL")" = "yes" ]; then
    LAST_TERMINAL="$UPDATED"
    # Let CR's comment writes settle: the status sometimes flips slightly
    # before the last review_comment write is visible to the API.
    sleep 5
    fetch_streams || { CONSEC_FAILURES=$((CONSEC_FAILURES + 1)); save_state; sleep "$TICK_SECONDS"; continue; }
    # Even zero new items is a settled round (0-finding pass): the dispatcher
    # marks it seen and runs its all-clear exit check.
    finish new_cr_feedback status_transition "$STATE" "$UPDATED" "$NEW_IC" "$NEW_RV" "$NEW_RC"
  fi

  if [ -z "$STATE" ] || [ "$STATE" = "pending" ]; then
    FALLBACK_TICKS=$((FALLBACK_TICKS + 1))
    if [ "$FALLBACK_TICKS" -ge "$FALLBACK_EVERY" ]; then
      FALLBACK_TICKS=0
      if fetch_streams && [ "$(new_total)" -gt 0 ]; then
        ALL_NEW=$(jq -cn --argjson a "$NEW_IC" --argjson b "$NEW_RV" --argjson c "$NEW_RC" '$a+$b+$c')
        [ "$(sp_fallback_settled "$ALL_NEW")" = "yes" ] \
          && finish new_cr_feedback marker "$STATE" "$UPDATED" "$NEW_IC" "$NEW_RV" "$NEW_RC"
        FP=$(sp_fingerprint "$NEW_IC" "$NEW_RV" "$NEW_RC")
        if [ "$FP" = "$PREV_FP" ] && [ "$(sp_all_quiet "$ALL_NEW" "$(date +%s)" "$QUIET_SECONDS")" = "yes" ]; then
          finish new_cr_feedback quiet_period "$STATE" "$UPDATED" "$NEW_IC" "$NEW_RV" "$NEW_RC"
        fi
        PREV_FP="$FP"
      fi
    fi
  fi

  sleep "$TICK_SECONDS"
done
