#!/usr/bin/env bats
# Unit tests for the pure decision logic in scripts/sensor-poll-lib.sh.
# Run as an individual file (never part of a full-suite invocation):
#   bats eng/skills/pr-watcher/tests/sensor-poll.bats

setup() {
  . "$BATS_TEST_DIRNAME/../scripts/sensor-poll-lib.sh"
}

# --- sp_latest_cr_status

@test "latest_cr_status picks newest CodeRabbit entry, ignores other contexts" {
  statuses='[
    {"context":"ci/build","state":"success","updated_at":"2020-01-01T00:09:00Z","creator":{"login":"github-actions[bot]"}},
    {"context":"CodeRabbit","state":"pending","updated_at":"2020-01-01T00:01:00Z","creator":{"login":"coderabbitai[bot]"}},
    {"context":"CodeRabbit","state":"success","updated_at":"2020-01-01T00:05:00Z","creator":{"login":"coderabbitai[bot]"}}
  ]'
  run sp_latest_cr_status "$statuses"
  [ "$status" -eq 0 ]
  [ "$output" = '{"state":"success","updated_at":"2020-01-01T00:05:00Z"}' ]
}

@test "latest_cr_status treats a missing creator as a match" {
  statuses='[{"context":"CodeRabbit","state":"pending","updated_at":"2020-01-01T00:01:00Z"}]'
  run sp_latest_cr_status "$statuses"
  [ "$output" = '{"state":"pending","updated_at":"2020-01-01T00:01:00Z"}' ]
}

@test "latest_cr_status returns null when no CodeRabbit status exists" {
  run sp_latest_cr_status '[]'
  [ "$output" = "null" ]
}

# --- sp_filter_new

@test "filter_new keeps only unbaselined coderabbitai[bot] items, stringifies ids" {
  stream='[
    {"id":1,"user":{"login":"coderabbitai[bot]"},"updated_at":"2020-01-01T00:00:00Z","body":"old"},
    {"id":2,"user":{"login":"coderabbitai[bot]"},"updated_at":"2020-01-01T00:01:00Z","body":"new"},
    {"id":3,"user":{"login":"mujtaba3B"},"updated_at":"2020-01-01T00:02:00Z","body":"human"}
  ]'
  run sp_filter_new issue_comments "$stream" '["1"]'
  [ "$output" = '[{"id":"2","updated_at":"2020-01-01T00:01:00Z","body":"new"}]' ]
}

@test "filter_new maps review fields (state, submitted_at)" {
  stream='[{"id":9,"user":{"login":"coderabbitai[bot]"},"state":"COMMENTED","submitted_at":"2020-01-01T00:01:00Z","body":"r"}]'
  run sp_filter_new reviews "$stream" '[]'
  [ "$output" = '[{"id":"9","state":"COMMENTED","submitted_at":"2020-01-01T00:01:00Z","body":"r"}]' ]
}

@test "filter_new maps review_comment fields and tolerates null line" {
  stream='[{"id":7,"user":{"login":"coderabbitai[bot]"},"path":"a.sh","line":null,"updated_at":"2020-01-01T00:01:00Z","body":"c"}]'
  run sp_filter_new review_comments "$stream" '[]'
  [ "$output" = '[{"id":"7","path":"a.sh","line":null,"updated_at":"2020-01-01T00:01:00Z","body":"c"}]' ]
}

# --- sp_fresh_transition

@test "fresh_transition fires on first terminal status when no prior terminal seen" {
  # The v3 incident edge: last_terminal unset must NOT suppress the transition.
  run sp_fresh_transition success "2020-01-01T00:05:00Z" ""
  [ "$output" = "yes" ]
  run sp_fresh_transition failure "2020-01-01T00:05:00Z" "null"
  [ "$output" = "yes" ]
}

@test "fresh_transition ignores pending and already-consumed terminals" {
  run sp_fresh_transition pending "2020-01-01T00:05:00Z" ""
  [ "$output" = "no" ]
  run sp_fresh_transition success "2020-01-01T00:05:00Z" "2020-01-01T00:05:00Z"
  [ "$output" = "no" ]
  run sp_fresh_transition success "2020-01-01T00:04:00Z" "2020-01-01T00:05:00Z"
  [ "$output" = "no" ]
}

@test "fresh_transition fires on a newer terminal than the last consumed one" {
  run sp_fresh_transition success "2020-01-01T00:06:00Z" "2020-01-01T00:05:00Z"
  [ "$output" = "yes" ]
}

# --- sp_fallback_settled

@test "fallback_settled detects the actionable-comments header" {
  run sp_fallback_settled '[{"body":"Actionable comments posted: 2\n\ndetail"}]'
  [ "$output" = "yes" ]
}

@test "fallback_settled detects the review-status sentinel" {
  items=$(jq -cn --arg s "$SP_CR_SENTINEL" '[{"body":("prefix " + $s + " suffix")}]')
  run sp_fallback_settled "$items"
  [ "$output" = "yes" ]
}

@test "fallback_settled says no for plain comments and null bodies" {
  run sp_fallback_settled '[{"body":"just a walkthrough"},{"body":null}]'
  [ "$output" = "no" ]
}

# --- sp_all_quiet  (2020-01-01T00:00:00Z == epoch 1577836800)

@test "all_quiet yes when every item is older than the quiet window" {
  items='[{"updated_at":"2020-01-01T00:00:00Z"},{"submitted_at":"2020-01-01T00:00:30Z"}]'
  run sp_all_quiet "$items" 1577837100 180
  [ "$output" = "yes" ]
}

@test "all_quiet no when any item is fresh, and no for an empty set" {
  items='[{"updated_at":"2020-01-01T00:00:00Z"},{"updated_at":"2020-01-01T00:04:00Z"}]'
  run sp_all_quiet "$items" 1577837100 180
  [ "$output" = "no" ]
  run sp_all_quiet '[]' 1577837100 180
  [ "$output" = "no" ]
}

@test "all_quiet no when an item has no parseable timestamp (never vacuously quiet)" {
  run sp_all_quiet '[{"updated_at":"2020-01-01T00:00:00Z"},{"foo":1}]' 1577837100 180
  [ "$output" = "no" ]
  run sp_all_quiet '[{"updated_at":"not-a-date"}]' 1577837100 180
  [ "$output" = "no" ]
}

# --- sp_fingerprint

@test "fingerprint is stable for identical input and changes with timestamps" {
  a=$(sp_fingerprint '[{"id":"1","updated_at":"2020-01-01T00:00:00Z"}]' '[]' '[]')
  b=$(sp_fingerprint '[{"id":"1","updated_at":"2020-01-01T00:00:00Z"}]' '[]' '[]')
  c=$(sp_fingerprint '[{"id":"1","updated_at":"2020-01-01T00:01:00Z"}]' '[]' '[]')
  [ "$a" = "$b" ]
  [ "$a" != "$c" ]
}

# --- sp_emit

@test "emit produces the full schema with nulled empty status fields" {
  run sp_emit already_settled 12 3 abc123 "" "" "n/a" '[]' '[]' '[]'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .outcome == "already_settled" and .polled_for_seconds == 12 and .ticks == 3
    and .head_sha_at_return == "abc123" and .cr_status_state == null
    and .cr_status_updated_at == null and .settled_via == "n/a"
    and .new_issue_comments == [] and .new_reviews == [] and .new_review_comments == []
    and (has("error_message") | not)'
}

@test "emit carries items and error_message when provided" {
  run sp_emit error 5 1 abc "pending" "2020-01-01T00:00:00Z" "n/a" '[{"id":"1"}]' '[]' '[]' "boom"
  echo "$output" | jq -e '
    .cr_status_state == "pending" and .new_issue_comments == [{"id":"1"}]
    and .error_message == "boom"'
}
