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

# Claude Code's Bash tool strips the PATH (no homebrew), so append the usual
# gh/jq homes. Append rather than prepend: a caller-provided PATH entry (e.g.
# a test's stubbed gh) must win over the real binaries.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# Bootstrap guards cannot rely on the lib or jq, so they echo the full output
# schema as a literal (the one-JSON contract holds even here).
bootstrap_error() {
  printf '{"outcome":"error","polled_for_seconds":0,"ticks":0,"head_sha_at_return":"","cr_status_state":null,"cr_status_updated_at":null,"settled_via":"n/a","new_issue_comments":[],"new_reviews":[],"new_review_comments":[],"error_message":"%s"}\n' "$1"
  exit 0
}

LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sensor-poll-lib.sh"
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || bootstrap_error "failed to source sensor-poll-lib.sh"
command -v gh >/dev/null && command -v jq >/dev/null \
  || bootstrap_error "gh or jq not on PATH"

OWNER="" REPO="" PR_NUM="" STATE_DIR=""
SLICE_SECONDS=540
TOTAL_SECONDS=1800
QUIET_SECONDS=180
TICK_SECONDS="${SENSOR_TICK_SECONDS:-15}"  # env seam for tests; 15s in real use
FALLBACK_EVERY=4       # comment-stream fallback every Nth tick (~60s)
MAX_CONSEC_FAILURES=40 # ~10 min of consecutive failing ticks -> outcome error

arg_error() { sp_emit error 0 0 "" "" "" "n/a" '[]' '[]' '[]' "$1"; exit 0; }
while [ $# -gt 0 ]; do
  case "$1" in
    # A flag with no value would hit an unset "$2" under set -u and crash past
    # the one-JSON contract; catch it as a normal arg error first.
    --owner|--repo|--pr|--state-dir|--slice-seconds|--total-seconds)
      [ $# -ge 2 ] || arg_error "missing value for $1" ;;
  esac
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR_NUM="$2"; shift 2 ;;
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --slice-seconds) SLICE_SECONDS="$2"; shift 2 ;;
    --total-seconds) TOTAL_SECONDS="$2"; shift 2 ;;
    *) arg_error "unknown arg: $1" ;;
  esac
done
[ -n "$OWNER" ] && [ -n "$REPO" ] && [ -n "$PR_NUM" ] && [ -n "$STATE_DIR" ] \
  || arg_error "--owner/--repo/--pr/--state-dir are required"

STATE_FILE="$STATE_DIR/sensor-state.json"
GH_ERR_FILE="$STATE_DIR/.gh-stderr"
mkdir -p "$STATE_DIR"

# baseline <kind>: a missing, empty, or corrupt baseline file reads as [] so a
# bad file degrades to one extra processing cycle, never to broken JSON output.
baseline() {
  local b
  b=$(cat "$STATE_DIR/baseline_$1.json" 2>/dev/null || true)
  jq -e . >/dev/null 2>&1 <<<"$b" && printf '%s' "$b" || printf '[]'
}

last_gh_err() { tr -d '\n' < "$GH_ERR_FILE" 2>/dev/null | tail -c 200; }

# --- state (persisted across slices; one sense cycle = one state-file lifetime)
POLL_STARTED="" TICKS=0 LAST_TERMINAL="" PREV_FP="" FALLBACK_TICKS=0 CONSEC_FAILURES=0
load_state() {
  [ -f "$STATE_FILE" ] || return 1
  # A corrupt/truncated file (non-numeric poll_started) reads as absent, so the
  # init pass simply runs again instead of crashing the arithmetic below.
  jq -e '.poll_started | numbers' "$STATE_FILE" >/dev/null 2>&1 || return 1
  POLL_STARTED=$(jq -r '.poll_started' "$STATE_FILE")
  TICKS=$(jq -r '.ticks // 0' "$STATE_FILE")
  LAST_TERMINAL=$(jq -r '.last_terminal // ""' "$STATE_FILE")
  PREV_FP=$(jq -r '.prev_fp // ""' "$STATE_FILE")
  FALLBACK_TICKS=$(jq -r '.fallback_ticks // 0' "$STATE_FILE")
  CONSEC_FAILURES=$(jq -r '.consecutive_failures // 0' "$STATE_FILE")
}
save_state() {
  local tmp="$STATE_FILE.tmp"
  jq -cn --argjson started "$POLL_STARTED" --argjson ticks "$TICKS" \
    --arg last "$LAST_TERMINAL" --arg fp "$PREV_FP" \
    --argjson fb "$FALLBACK_TICKS" --argjson fails "$CONSEC_FAILURES" \
    '{poll_started: $started, ticks: $ticks,
      last_terminal: (if $last == "" then null else $last end),
      prev_fp: (if $fp == "" then null else $fp end),
      fallback_ticks: $fb, consecutive_failures: $fails}' > "$tmp" \
    && mv "$tmp" "$STATE_FILE"
}

# finish <outcome> <settled_via> <cr_state> <cr_updated> <ic> <rv> <rc> [err]
#   Terminal emit: the sense cycle is over, so the state file is removed.
CURRENT_SHA=""
finish() {
  local outcome="$1" via="$2" cstate="$3" cupdated="$4" ic="$5" rv="$6" rc="$7" err="${8:-}"
  local now polled=0
  now=$(date +%s)
  [ -n "$POLL_STARTED" ] && polled=$((now - POLL_STARTED))
  rm -f "$STATE_FILE"
  sp_emit "$outcome" "$polled" "$TICKS" "$CURRENT_SHA" "$cstate" "$cupdated" "$via" "$ic" "$rv" "$rc" "$err"
  exit 0
}

# fail_tick <what>: one failing gh tick. Counts toward the error threshold,
# surfaces the captured gh stderr when the threshold trips, else waits out the
# tick. Callers `continue` (loop) or `return 1` propagation is not needed:
# this either exits via finish or sleeps and returns.
fail_tick() {
  CONSEC_FAILURES=$((CONSEC_FAILURES + 1))
  echo "sensor-poll: $1 (consecutive failures: $CONSEC_FAILURES)" >&2
  [ "$CONSEC_FAILURES" -ge "$MAX_CONSEC_FAILURES" ] \
    && finish error "n/a" "" "" '[]' '[]' '[]' "$1; gh said: $(last_gh_err)"
  sleep "$TICK_SECONDS"
}

# --- gh fetch helpers (set globals; return non-zero on API failure)
PR_STATE="" LATEST_STATUS="" NEW_IC="" NEW_RV="" NEW_RC=""
fetch_pr() {
  local out
  out=$(gh pr view "$PR_NUM" --repo "$OWNER/$REPO" --json state,headRefOid 2>"$GH_ERR_FILE") || return 1
  PR_STATE=$(jq -r '.state' <<<"$out")
  CURRENT_SHA=$(jq -r '.headRefOid' <<<"$out")
}
fetch_status() {
  local out
  out=$(gh api "repos/$OWNER/$REPO/commits/$CURRENT_SHA/statuses?per_page=100" 2>"$GH_ERR_FILE") || return 1
  LATEST_STATUS=$(sp_latest_cr_status "$out")
}
# --paginate follows every page (these endpoints return oldest-first, so page
# 1 alone goes blind to NEW items once a stream passes 100); it emits one JSON
# array per page, which `jq -s add` flattens back to a single array.
fetch_page_all() {
  ( set -o pipefail
    gh api --paginate "$1" 2>"$GH_ERR_FILE" | jq -s 'add // []' )
}
fetch_streams() {
  local ic rv rc
  ic=$(fetch_page_all "repos/$OWNER/$REPO/issues/$PR_NUM/comments?per_page=100") || return 1
  rv=$(fetch_page_all "repos/$OWNER/$REPO/pulls/$PR_NUM/reviews?per_page=100") || return 1
  rc=$(fetch_page_all "repos/$OWNER/$REPO/pulls/$PR_NUM/comments?per_page=100") || return 1
  NEW_IC=$(sp_filter_new issue_comments "$ic" "$(baseline issue_comments)")
  NEW_RV=$(sp_filter_new reviews "$rv" "$(baseline reviews)")
  NEW_RC=$(sp_filter_new review_comments "$rc" "$(baseline review_comments)")
}
new_total() { jq -n --argjson a "$NEW_IC" --argjson b "$NEW_RV" --argjson c "$NEW_RC" '($a|length)+($b|length)+($c|length)'; }
all_new()  { jq -cn --argjson a "$NEW_IC" --argjson b "$NEW_RV" --argjson c "$NEW_RC" '$a+$b+$c'; }
status_state()   { jq -r 'if . == null then "" else .state end' <<<"$LATEST_STATUS"; }
status_updated() { jq -r 'if . == null then "" else .updated_at end' <<<"$LATEST_STATUS"; }
pr_closed_check() {
  case "$PR_STATE" in
    MERGED|CLOSED) finish pr_closed "n/a" "" "" '[]' '[]' '[]' ;;
  esac
}

# --- init pass (first slice of a sense cycle only)
if ! load_state; then
  POLL_STARTED=$(date +%s)
  # Tolerate brief API blips at cycle start (~2 tick-lengths), then error: a
  # persistently dead API at init is likely auth/config, not weather.
  INIT_OK=""
  for attempt in 1 2 3; do
    if fetch_pr; then
      pr_closed_check
      if fetch_status && fetch_streams; then INIT_OK=1; break; fi
    fi
    [ "$attempt" -lt 3 ] && sleep "$TICK_SECONDS"
  done
  [ -n "$INIT_OK" ] || finish error "n/a" "" "" '[]' '[]' '[]' \
    "init fetch failed after 3 attempts; gh said: $(last_gh_err)"
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
    [ "$(sp_fallback_settled "$(all_new)")" = "yes" ] \
      && finish new_cr_feedback marker "$STATE" "$UPDATED" "$NEW_IC" "$NEW_RV" "$NEW_RC"
    [ "$(sp_all_quiet "$(all_new)" "$(date +%s)" "$QUIET_SECONDS")" = "yes" ] \
      && finish new_cr_feedback quiet_period "$STATE" "$UPDATED" "$NEW_IC" "$NEW_RV" "$NEW_RC"
  fi
  # Only pending/absent statuses reach here (terminal ones finished above),
  # so the cycle starts with no consumed terminal.
  save_state
fi

# --- 15s polling loop (one slice)
SLICE_STARTED=$(date +%s)
while true; do
  NOW=$(date +%s)
  if [ $((NOW - POLL_STARTED)) -ge "$TOTAL_SECONDS" ]; then
    finish idle_timeout "n/a" "$(status_state)" "$(status_updated)" '[]' '[]' '[]'
  fi
  if [ $((NOW - SLICE_STARTED)) -ge "$SLICE_SECONDS" ]; then
    save_state
    sp_emit continue $((NOW - POLL_STARTED)) "$TICKS" "$CURRENT_SHA" \
      "$(status_state)" "$(status_updated)" "n/a" '[]' '[]' '[]'
    exit 0
  fi

  TICKS=$((TICKS + 1))
  fetch_pr || { fail_tick "gh pr view failed"; continue; }
  pr_closed_check
  fetch_status || { fail_tick "commit status fetch failed"; continue; }
  STATE=$(status_state); UPDATED=$(status_updated)

  if [ "$(sp_fresh_transition "$STATE" "$UPDATED" "$LAST_TERMINAL")" = "yes" ]; then
    # Let CR's comment writes settle: the status sometimes flips slightly
    # before the last review_comment write is visible to the API.
    sleep 5
    # Do NOT mark the transition consumed until the streams are in hand: a
    # failed fetch here must leave the transition fresh so the next tick
    # retries the drain (a consumed-but-undrained round would idle to
    # timeout, the exact failure this script exists to prevent).
    fetch_streams || { fail_tick "comment stream fetch failed after transition"; continue; }
    # Even zero new items is a settled round (0-finding pass): the dispatcher
    # marks it seen and runs its all-clear exit check.
    finish new_cr_feedback status_transition "$STATE" "$UPDATED" "$NEW_IC" "$NEW_RV" "$NEW_RC"
  fi

  if [ -z "$STATE" ] || [ "$STATE" = "pending" ]; then
    FALLBACK_TICKS=$((FALLBACK_TICKS + 1))
    if [ "$FALLBACK_TICKS" -ge "$FALLBACK_EVERY" ]; then
      FALLBACK_TICKS=0
      fetch_streams || { fail_tick "comment stream fetch failed in fallback"; continue; }
      if [ "$(new_total)" -gt 0 ]; then
        [ "$(sp_fallback_settled "$(all_new)")" = "yes" ] \
          && finish new_cr_feedback marker "$STATE" "$UPDATED" "$NEW_IC" "$NEW_RV" "$NEW_RC"
        FP=$(sp_fingerprint "$NEW_IC" "$NEW_RV" "$NEW_RC")
        if [ "$FP" = "$PREV_FP" ] && [ "$(sp_all_quiet "$(all_new)" "$(date +%s)" "$QUIET_SECONDS")" = "yes" ]; then
          finish new_cr_feedback quiet_period "$STATE" "$UPDATED" "$NEW_IC" "$NEW_RV" "$NEW_RC"
        fi
        PREV_FP="$FP"
      fi
    fi
  fi

  # Reaching here means every gh call this tick succeeded.
  CONSEC_FAILURES=0
  sleep "$TICK_SECONDS"
done
