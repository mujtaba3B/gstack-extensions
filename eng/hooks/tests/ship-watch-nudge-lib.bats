#!/usr/bin/env bats
# Tests for the pure decision logic of the after-ship watcher nudge
# (ship-watch-nudge-lib.sh): swn_is_pr_create, swn_extract_pr_url,
# swn_pr_num_from_url, swn_build_context, swn_already_nudged. No repo /
# session / network / hook plumbing needed - every function is a pure transform.
#

setup() {
  # Hermetic: pin the gate-policy lookup at a path that cannot exist, so these
  # tests exercise the MARKER-FALLBACK contract (a machine with no gate policy)
  # deterministically, instead of inheriting whatever ~/dev/gate-policy.json this
  # machine happens to carry. Inheritance-by-default is covered end-to-end in
  # gate-inheritance.bats.
  export GATE_POLICY_TEST=1   # env overrides are honored only in test mode
  export GATE_POLICY_FILE="$BATS_TEST_TMPDIR/no-such-gate-policy.json"
  export GATE_LOCAL_FILE="$BATS_TEST_TMPDIR/no-such-gate-local.json"
  LIB="$BATS_TEST_DIRNAME/../scripts/ship-watch-nudge-lib.sh"
  # shellcheck source=/dev/null
  . "$LIB"
}

# ---- swn_is_pr_create -------------------------------------------------------

@test "swn_is_pr_create: plain create matches" {
  run swn_is_pr_create 'gh pr create --base main --title x'
  [ "$output" = "yes" ]
}

@test "swn_is_pr_create: after a cd separator matches" {
  run swn_is_pr_create 'cd ~/dev/tooling/gstack-extensions && gh pr create --fill'
  [ "$output" = "yes" ]
}

@test "swn_is_pr_create: env prefix + path to gh matches" {
  run swn_is_pr_create 'GH_TOKEN=x /opt/homebrew/bin/gh pr create --fill'
  [ "$output" = "yes" ]
}

@test "swn_is_pr_create: phrase inside a quoted arg does NOT match" {
  run swn_is_pr_create "gh pr comment 123 --body 'run gh pr create to open it'"
  [ "$output" = "no" ]
}

@test "swn_is_pr_create: unrelated command does not match" {
  run swn_is_pr_create 'git commit -m "wip"'
  [ "$output" = "no" ]
}

@test "swn_is_pr_create: semicolon separator matches" {
  run swn_is_pr_create 'echo done; gh pr create --fill'
  [ "$output" = "yes" ]
}

@test "swn_is_pr_create: pipe separator matches" {
  run swn_is_pr_create 'true | gh pr create --fill'
  [ "$output" = "yes" ]
}

@test "swn_is_pr_create: subshell open-paren matches" {
  run swn_is_pr_create '(gh pr create --fill)'
  [ "$output" = "yes" ]
}

@test "swn_is_pr_create: bare create with no args matches (the \$-anchor branch)" {
  run swn_is_pr_create 'gh pr create'
  [ "$output" = "yes" ]
}

@test "swn_is_pr_create: 'gh pr created' does not match (word-boundary anchor)" {
  run swn_is_pr_create 'gh pr created something'
  [ "$output" = "no" ]
}

@test "swn_is_pr_create: quoted body with an EMBEDDED separator followed by more args DOES match (documented accident-guard, same as ship-pr-gate)" {
  # Not a guaranteed non-match: the loose matcher is an accident-guard, not a parser.
  # A separator inside the quote (the `;`) plus whitespace after `create` (the trailing
  # `now`) satisfies the anchor, so this matches. The consequence is only a spurious
  # deduped nudge, never a block. (A body ending exactly `gh pr create'` does NOT match,
  # because `create` is then followed by `'`, not whitespace/end - see the next test.)
  run swn_is_pr_create "gh pr comment 1 --body 'done; gh pr create now'"
  [ "$output" = "yes" ]
}

@test "swn_is_pr_create: quoted body ending exactly at the create word does NOT match" {
  run swn_is_pr_create "gh pr comment 1 --body 'done; gh pr create'"
  [ "$output" = "no" ]
}

# ---- swn_extract_pr_url / swn_pr_num_from_url -------------------------------

@test "swn_extract_pr_url: pulls the PR URL from gh output" {
  run swn_extract_pr_url $'Creating pull request for x into main\nhttps://github.com/mujtaba3B/gstack-extensions/pull/77\n'
  [ "$output" = "https://github.com/mujtaba3B/gstack-extensions/pull/77" ]
}

@test "swn_extract_pr_url: ignores a non-PR github URL" {
  run swn_extract_pr_url 'see https://github.com/owner/repo/compare/main...x'
  [ -z "$output" ]
}

@test "swn_extract_pr_url: empty on no URL" {
  run swn_extract_pr_url 'nothing here'
  [ -z "$output" ]
}

@test "swn_extract_pr_url: trims a trailing path suffix to the PR URL" {
  run swn_extract_pr_url 'https://github.com/o/r/pull/77/files'
  [ "$output" = "https://github.com/o/r/pull/77" ]
}

@test "swn_extract_pr_url: returns the FIRST url when several are present (dedupe key)" {
  run swn_extract_pr_url $'https://github.com/o/r/pull/1\nhttps://github.com/o/r/pull/2'
  [ "$output" = "https://github.com/o/r/pull/1" ]
}

@test "swn_pr_num_from_url: trailing number" {
  run swn_pr_num_from_url 'https://github.com/o/r/pull/1234'
  [ "$output" = "1234" ]
}

# ---- swn_decide -------------------------------------------------------------

# ---- substring assertions ---------------------------------------------------
#
# WHY THESE EXIST INSTEAD OF `[[ "$output" == *"x"* ]]`. Measured on bats-core
# 1.13: a failing `[[ ]]` in any position OTHER than the last line of a test body
# does not fail the test. `[[` is a shell keyword and errexit does not fire for it
# there, so an assertion followed by any other line is a silent no-op that passes
# no matter what the output says. A single-bracket `[ ]` and a function call both
# fail correctly in the same position.
#
# Found by mutation-testing the qa plugin's suites, where a deleted guard left
# every test green. Nine of the assertions in THIS file were in that state: the
# last line of each test body was doing all the work and the ones above it were
# decoration. Use these helpers, never a bare `[[ ]]`.
assert_contains() {  # <haystack> <needle>
  case "$1" in *"$2"*) return 0 ;; esac
  echo "assert_contains failed" >&2
  echo "  wanted substring: $2" >&2
  echo "  actual:           $1" >&2
  return 1
}
assert_missing() {  # <haystack> <needle-that-must-not-appear>
  case "$1" in *"$2"*)
    echo "assert_missing failed" >&2
    echo "  unwanted substring: $2" >&2
    echo "  actual:             $1" >&2
    return 1 ;;
  esac
  return 0
}

# ---- swn_build_context ------------------------------------------------------

@test "swn_build_context: watch names /eng:pr-watcher and the URL" {
  run swn_build_context 'https://github.com/o/r/pull/9' 9
  assert_contains "$output" "/eng:pr-watcher https://github.com/o/r/pull/9"
  assert_contains "$output" "PR #9"
}

@test "swn_build_context: watch forbids presenting a land-choice menu" {
  # The standing default is "wait for CodeRabbit, then land" - the nudge must tell
  # the agent to just do it, not improvise a land-now / watch / pause question.
  run swn_build_context 'https://github.com/o/r/pull/9' 9
  assert_contains "$output" "Do NOT ask the user how to land"
  assert_contains "$output" "standing default"
}

@test "swn_build_context: no em-dash (global style rule)" {
  local emdash; emdash=$(printf '\xe2\x80\x94')   # U+2014 UTF-8 bytes, so no literal em-dash lives in this file
  run swn_build_context 'https://github.com/o/r/pull/9' 9
  assert_missing "$output" "$emdash"
}

# ---- swn_already_nudged -----------------------------------------------------

@test "swn_already_nudged: url present -> yes" {
  run swn_already_nudged $'https://github.com/o/r/pull/1\nhttps://github.com/o/r/pull/2' 'https://github.com/o/r/pull/2'
  [ "$output" = "yes" ]
}

@test "swn_already_nudged: url absent -> no" {
  run swn_already_nudged $'https://github.com/o/r/pull/1' 'https://github.com/o/r/pull/2'
  [ "$output" = "no" ]
}

@test "swn_already_nudged: empty url -> no" {
  run swn_already_nudged $'https://github.com/o/r/pull/1' ''
  [ "$output" = "no" ]
}

@test "swn_already_nudged: empty history -> no (the first-nudge base case on every new PR)" {
  run swn_already_nudged '' 'https://github.com/o/r/pull/9'
  [ "$output" = "no" ]
}

@test "swn_already_nudged: substring is not a false match (whole-line only)" {
  run swn_already_nudged $'https://github.com/o/r/pull/12' 'https://github.com/o/r/pull/1'
  [ "$output" = "no" ]
}
