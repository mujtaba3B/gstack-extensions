#!/usr/bin/env bats
# review-skill-stamp.sh records the reviewed HEAD in the session's repo, even when
# the hook process runs from a different checkout.

setup() {
  HOOK="$BATS_TEST_DIRNAME/../scripts/review-skill-stamp.sh"
  REPO=$(mktemp -d "$BATS_TEST_TMPDIR/session.XXXXXX")
  OTHER=$(mktemp -d "$BATS_TEST_TMPDIR/other.XXXXXX")
  for r in "$REPO" "$OTHER"; do
    git -C "$r" init -q
    git -C "$r" -c user.name=T -c user.email=t@example.com commit -q --allow-empty -m init
  done
  CMD="gstack-review-log '{\"skill\":\"review\"}'"
}

stamp_payload() {  # <cwd or empty>
  jq -nc --arg c "$CMD" --arg d "$1" \
    '{tool_name:"Bash",tool_input:{command:$c}} + (if $d == "" then {} else {cwd:$d} end)'
}

@test "payload cwd wins: the stamp lands in the session repo, not the process repo" {
  stamp_payload "$REPO" > "$BATS_TEST_TMPDIR/p.json"
  run bash -c "cd '$OTHER' && bash '$HOOK' < '$BATS_TEST_TMPDIR/p.json'"
  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/.git/review-skill-head")" = "$(git -C "$REPO" rev-parse HEAD)" ]
  [ ! -e "$OTHER/.git/review-skill-head" ]
}

@test "no payload cwd: falls back to the hook process directory" {
  stamp_payload "" > "$BATS_TEST_TMPDIR/p.json"
  run bash -c "cd '$REPO' && bash '$HOOK' < '$BATS_TEST_TMPDIR/p.json'"
  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/.git/review-skill-head")" = "$(git -C "$REPO" rev-parse HEAD)" ]
}

@test "a leading cd still beats the payload cwd" {
  CMD="cd $REPO && $CMD"
  stamp_payload "$OTHER" > "$BATS_TEST_TMPDIR/p.json"
  run bash -c "cd '$OTHER' && bash '$HOOK' < '$BATS_TEST_TMPDIR/p.json'"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.git/review-skill-head" ]
  [ ! -e "$OTHER/.git/review-skill-head" ]
}

@test "stale payload cwd: falls back to the hook process directory" {
  stamp_payload "$REPO/no-such-dir" > "$BATS_TEST_TMPDIR/p.json"
  run bash -c "cd '$OTHER' && bash '$HOOK' < '$BATS_TEST_TMPDIR/p.json'"
  [ "$status" -eq 0 ]
  [ -f "$OTHER/.git/review-skill-head" ]
  [ ! -e "$REPO/.git/review-skill-head" ]
}

@test "relative cd resolves against the payload cwd" {
  CMD="cd . && $CMD"
  stamp_payload "$REPO" > "$BATS_TEST_TMPDIR/p.json"
  run bash -c "cd '$OTHER' && bash '$HOOK' < '$BATS_TEST_TMPDIR/p.json'"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.git/review-skill-head" ]
  [ ! -e "$OTHER/.git/review-skill-head" ]
}
