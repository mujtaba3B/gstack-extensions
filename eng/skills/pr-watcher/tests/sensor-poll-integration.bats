#!/usr/bin/env bats
# Integration tests for sensor-poll.sh's deterministic init pass, driven by a
# stubbed `gh` on PATH (the script APPENDS its fallback dirs to PATH, so the
# stub wins). Only loop-free branches are exercised; slice/loop timing is
# covered by live QA. Run as an individual file:
#   bats eng/skills/pr-watcher/tests/sensor-poll-integration.bats

SCRIPT="$BATS_TEST_DIRNAME/../scripts/sensor-poll.sh"

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  STATE="$WORK/state"
  FIX="$WORK/fixtures"
  mkdir -p "$WORK/bin" "$STATE" "$FIX"

  # gh stub: serves fixture files per endpoint; GH_STUB_FAIL=1 fails every call.
  cat > "$WORK/bin/gh" <<'STUB'
#!/bin/bash
[ "${GH_STUB_FAIL:-0}" = "1" ] && { echo "HTTP 401: Bad credentials" >&2; exit 1; }
case "$1 $2" in
  "pr view") cat "$GH_FIXTURE_DIR/pr.json" ;;
  "api "*statuses*) cat "$GH_FIXTURE_DIR/statuses.json" ;;
  "api "*issues*comments*) cat "$GH_FIXTURE_DIR/issue_comments.json" ;;
  "api "*reviews*) cat "$GH_FIXTURE_DIR/reviews.json" ;;
  "api "*pulls*comments*) cat "$GH_FIXTURE_DIR/review_comments.json" ;;
  *) echo "gh stub: unmatched: $*" >&2; exit 64 ;;
esac
STUB
  chmod +x "$WORK/bin/gh"
  export PATH="$WORK/bin:$PATH"
  export GH_FIXTURE_DIR="$FIX"
  export SENSOR_TICK_SECONDS=0   # init retries sleep 0s in tests

  # Default fixtures: open PR, no CR status, empty streams, empty baselines.
  echo '{"state":"OPEN","headRefOid":"abc123"}' > "$FIX/pr.json"
  echo '[]' > "$FIX/statuses.json"
  echo '[]' > "$FIX/issue_comments.json"
  echo '[]' > "$FIX/reviews.json"
  echo '[]' > "$FIX/review_comments.json"
  for k in issue_comments reviews review_comments; do
    echo '[]' > "$STATE/baseline_$k.json"
  done
}

run_sensor() {
  run "$SCRIPT" --owner o --repo r --pr 1 --state-dir "$STATE" "$@"
}

@test "merged PR returns pr_closed immediately" {
  echo '{"state":"MERGED","headRefOid":"abc123"}' > "$FIX/pr.json"
  run_sensor
  [ "$status" -eq 0 ]
  [ "$(jq -r .outcome <<<"$output")" = "pr_closed" ]
}

@test "terminal success with nothing unprocessed returns already_settled" {
  echo '[{"context":"CodeRabbit","state":"success","updated_at":"2020-01-01T00:05:00Z","creator":{"login":"coderabbitai[bot]"}}]' > "$FIX/statuses.json"
  run_sensor
  echo "$output" | jq -e '.outcome == "already_settled" and .cr_status_state == "success"
    and .cr_status_updated_at == "2020-01-01T00:05:00Z" and .head_sha_at_return == "abc123"'
}

@test "terminal failure with nothing unprocessed returns cr_failure" {
  echo '[{"context":"CodeRabbit","state":"failure","updated_at":"2020-01-01T00:05:00Z","creator":{"login":"coderabbitai[bot]"}}]' > "$FIX/statuses.json"
  run_sensor
  echo "$output" | jq -e '.outcome == "cr_failure" and .cr_status_state == "failure"'
}

@test "unprocessed backlog with terminal status drains via status_transition" {
  echo '[{"context":"CodeRabbit","state":"success","updated_at":"2020-01-01T00:05:00Z","creator":{"login":"coderabbitai[bot]"}}]' > "$FIX/statuses.json"
  echo '[{"id":11,"user":{"login":"coderabbitai[bot]"},"updated_at":"2020-01-01T00:04:00Z","body":"finding"}]' > "$FIX/issue_comments.json"
  run_sensor
  echo "$output" | jq -e '.outcome == "new_cr_feedback" and .settled_via == "status_transition"
    and .new_issue_comments == [{"id":"11","updated_at":"2020-01-01T00:04:00Z","body":"finding"}]'
}

@test "unprocessed backlog with pending status and review-status sentinel drains via marker" {
  echo '[{"context":"CodeRabbit","state":"pending","updated_at":"2020-01-01T00:05:00Z","creator":{"login":"coderabbitai[bot]"}}]' > "$FIX/statuses.json"
  body="done <!-- This is an auto-generated comment by CodeRabbit for review status --> ok"
  jq -cn --arg b "$body" '[{"id":12,"user":{"login":"coderabbitai[bot]"},"updated_at":"2020-01-01T00:04:00Z","body":$b}]' > "$FIX/issue_comments.json"
  run_sensor
  echo "$output" | jq -e '.outcome == "new_cr_feedback" and .settled_via == "marker"'
}

@test "baselined items do not count as backlog (still already_settled)" {
  echo '[{"context":"CodeRabbit","state":"success","updated_at":"2020-01-01T00:05:00Z","creator":{"login":"coderabbitai[bot]"}}]' > "$FIX/statuses.json"
  echo '[{"id":11,"user":{"login":"coderabbitai[bot]"},"updated_at":"2020-01-01T00:04:00Z","body":"seen"}]' > "$FIX/issue_comments.json"
  echo '["11"]' > "$STATE/baseline_issue_comments.json"
  run_sensor
  [ "$(jq -r .outcome <<<"$output")" = "already_settled" ]
}

@test "persistent init API failure returns error JSON with gh stderr, exit 0" {
  export GH_STUB_FAIL=1
  run_sensor
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "error" and (.error_message | contains("401"))'
}

@test "corrupt sensor-state.json is treated as a fresh init pass" {
  echo '[{"context":"CodeRabbit","state":"success","updated_at":"2020-01-01T00:05:00Z","creator":{"login":"coderabbitai[bot]"}}]' > "$FIX/statuses.json"
  echo 'garbage{{' > "$STATE/sensor-state.json"
  run_sensor
  [ "$(jq -r .outcome <<<"$output")" = "already_settled" ]
  [ ! -f "$STATE/sensor-state.json" ]
}

@test "empty baseline file reads as [] and output stays valid JSON" {
  echo '[{"context":"CodeRabbit","state":"success","updated_at":"2020-01-01T00:05:00Z","creator":{"login":"coderabbitai[bot]"}}]' > "$FIX/statuses.json"
  echo '[{"id":11,"user":{"login":"coderabbitai[bot]"},"updated_at":"2020-01-01T00:04:00Z","body":"x"}]' > "$FIX/issue_comments.json"
  : > "$STATE/baseline_issue_comments.json"
  run_sensor
  echo "$output" | jq -e '.outcome == "new_cr_feedback" and (.new_issue_comments | length) == 1'
}

@test "bad usage still emits one error JSON and exits 0" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "error" and (.error_message | contains("unknown arg"))'
}
