# Pure decision logic for sensor-poll.sh (the /eng:pr-watcher sensing script).
# Sourced by sensor-poll.sh and by tests/sensor-poll.bats. Every function here
# is side-effect free: JSON strings in, JSON/verdict strings out. Resolve
# siblings via BASH_SOURCE so the executing copy binds its own dependencies
# (repo checkout and plugin cache both work), matching the hooks convention.

# The literal sentinel CodeRabbit embeds in its auto-generated review-status
# comments. Single source of truth for the marker settle condition.
SP_CR_SENTINEL='<!-- This is an auto-generated comment by CodeRabbit for review status -->'

# sp_latest_cr_status <statuses_json>
#   From a GET /commits/<sha>/statuses payload, pick the latest CodeRabbit
#   entry: context == "CodeRabbit" AND (creator.login == "coderabbitai[bot]"
#   OR creator missing; some entries omit it). Echoes compact JSON
#   {"state":...,"updated_at":...} or the literal "null" when absent.
sp_latest_cr_status() {
  jq -c '
    [.[] | select(.context == "CodeRabbit")
         | select((.creator.login // "coderabbitai[bot]") == "coderabbitai[bot]")]
    | sort_by(.updated_at) | last
    | if . == null then null else {state, updated_at} end
  ' <<<"$1"
}

# sp_filter_new <kind> <stream_json> <baseline_json>
#   Filter a comment-stream payload to coderabbitai[bot] items whose stringified
#   id is NOT in the baseline array, mapped to the sensor schema fields for
#   <kind> (issue_comments | reviews | review_comments). Echoes a JSON array.
sp_filter_new() {
  local kind="$1" stream="$2" baseline="$3" fields
  case "$kind" in
    issue_comments)  fields='{id: (.id|tostring), updated_at, body}' ;;
    reviews)         fields='{id: (.id|tostring), state, submitted_at, body}' ;;
    review_comments) fields='{id: (.id|tostring), path, line, updated_at, body}' ;;
    *) echo "sp_filter_new: unknown kind: $kind" >&2; return 2 ;;
  esac
  jq -c --argjson base "$baseline" \
    "[.[] | select(.user.login == \"coderabbitai[bot]\")
          | select((.id|tostring) as \$id | \$base | index(\$id) | not)
          | $fields]" <<<"$stream"
}

# sp_fresh_transition <state> <updated_at> <last_terminal_updated_at>
#   Is this status a NEW terminal transition worth draining? Yes when state is
#   terminal AND we have not already consumed a terminal status at or after
#   this timestamp. The empty-last check is load-bearing: with no prior
#   terminal seen, the first terminal status must fire (the v3 sensor's
#   "updated_at > null is always false" bug). ISO-8601 Z timestamps compare
#   correctly as strings. Echoes yes/no; return code matches.
sp_fresh_transition() {
  local state="$1" updated="$2" last="$3"
  case "$state" in success|failure|error) ;; *) echo "no"; return 1 ;; esac
  if [ -z "$last" ] || [ "$last" = "null" ] || [[ "$updated" > "$last" ]]; then
    echo "yes"; return 0
  fi
  echo "no"; return 1
}

# sp_fallback_settled <items_json>
#   Fallback settle conditions (a)+(b) for repos/rounds without a status
#   transition: any new item whose body starts with "Actionable comments
#   posted:" or contains the CodeRabbit review-status sentinel. Echoes yes/no.
sp_fallback_settled() {
  local verdict
  verdict=$(jq -r --arg sentinel "$SP_CR_SENTINEL" '
    any(.[]; (.body // "") | (test("^Actionable comments posted:") or contains($sentinel)))
  ' <<<"$1")
  if [ "$verdict" = "true" ]; then echo "yes"; return 0; fi
  echo "no"; return 1
}

# sp_all_quiet <items_json> <now_epoch> <quiet_seconds>
#   Fallback settle condition (c): every item's effective timestamp
#   (updated_at, else submitted_at; review objects only expose the latter) is
#   at least <quiet_seconds> old. Empty arrays are NOT quiet (nothing to
#   drain). Echoes yes/no.
sp_all_quiet() {
  local items="$1" now="$2" quiet="$3" verdict
  verdict=$(jq -r --argjson now "$now" --argjson quiet "$quiet" '
    if length == 0 then false
    else all(.[]; ((.updated_at // .submitted_at // empty) | fromdateiso8601) <= ($now - $quiet))
    end
  ' <<<"$items")
  if [ "$verdict" = "true" ]; then echo "yes"; return 0; fi
  echo "no"; return 1
}

# sp_fingerprint <issue_comments_json> <reviews_json> <review_comments_json>
#   Stable fingerprint of a new-item set (ids + effective timestamps), used to
#   detect "no further changes between fallback polls" for the quiet-period
#   settle. Echoes a hex digest.
sp_fingerprint() {
  printf '%s\n%s\n%s\n' "$1" "$2" "$3" \
    | jq -c '.[] | [.id, (.updated_at // .submitted_at // null)]' \
    | shasum -a 256 | cut -d' ' -f1
}

# sp_emit <outcome> <polled_for_seconds> <ticks> <head_sha> <cr_state> \
#         <cr_updated_at> <settled_via> <new_ic_json> <new_rv_json> <new_rc_json> \
#         [error_message]
#   Assemble the sensor's single output JSON. cr_state/cr_updated_at may be
#   empty (emitted as null). error_message is included only when non-empty.
sp_emit() {
  jq -cn \
    --arg outcome "$1" --argjson polled "$2" --argjson ticks "$3" \
    --arg head "$4" --arg state "$5" --arg updated "$6" --arg via "$7" \
    --argjson ic "$8" --argjson rv "$9" --argjson rc "${10}" \
    --arg err "${11:-}" '
    {
      outcome: $outcome,
      polled_for_seconds: $polled,
      ticks: $ticks,
      head_sha_at_return: $head,
      cr_status_state: (if $state == "" then null else $state end),
      cr_status_updated_at: (if $updated == "" then null else $updated end),
      settled_via: $via,
      new_issue_comments: $ic,
      new_reviews: $rv,
      new_review_comments: $rc
    }
    + (if $err == "" then {} else {error_message: $err} end)
  '
}
