#!/usr/bin/env bats
# Tests for the pure decision logic of the after-ship watcher nudge
# (ship-watch-nudge-lib.sh): swn_is_pr_create, swn_extract_pr_url,
# swn_pr_num_from_url, swn_decide, swn_build_context, swn_already_nudged. No repo /
# session / network / hook plumbing needed - every function is a pure transform.
#
# One case also sources merge-clearance-lib.sh to prove the nudge and the merge gate
# agree on the rate-limit signal (same mc_cr_rate_limited marker).

setup() {
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

@test "swn_decide: not rate-limited -> watch" {
  run swn_decide no no
  [ "$output" = "watch" ]
}

@test "swn_decide: rate-limited + backstop -> land" {
  run swn_decide yes yes
  [ "$output" = "land" ]
}

@test "swn_decide: rate-limited + no backstop -> review_then_land" {
  run swn_decide yes no
  [ "$output" = "review_then_land" ]
}

@test "swn_decide: unknown rate_limited value defaults to watch (safe)" {
  run swn_decide maybe yes
  [ "$output" = "watch" ]
}

@test "swn_decide: rate-limited + non-yes backstop must NOT emit land (only backstop==yes clears)" {
  run swn_decide yes maybe
  [ "$output" = "review_then_land" ]
  run swn_decide yes ''
  [ "$output" = "review_then_land" ]
}

# ---- swn_build_context ------------------------------------------------------

@test "swn_build_context: watch names /eng:pr-watcher and the URL" {
  run swn_build_context watch 'https://github.com/o/r/pull/9' 9
  [[ "$output" == *"/eng:pr-watcher https://github.com/o/r/pull/9"* ]]
  [[ "$output" == *"PR #9"* ]]
}

@test "swn_build_context: land names /land-and-deploy and forbids watching" {
  run swn_build_context land 'https://github.com/o/r/pull/9' 9
  [[ "$output" == *"/land-and-deploy"* ]]
  [[ "$output" == *"do NOT start /eng:pr-watcher"* ]]
  [[ "$output" == *"rate limited by coderabbit.ai"* ]]
}

@test "swn_build_context: review_then_land names /eng:cr then /land-and-deploy" {
  run swn_build_context review_then_land 'https://github.com/o/r/pull/9' 9
  [[ "$output" == *"/eng:cr"* ]]
  [[ "$output" == *"/land-and-deploy"* ]]
  [[ "$output" == *"Do NOT open-endedly watch"* ]]
}

@test "swn_build_context: unknown mode falls back to the watch nudge" {
  run swn_build_context banana 'https://github.com/o/r/pull/9' 9
  [[ "$output" == *"/eng:pr-watcher"* ]]
}

@test "swn_build_context: no em-dash in any branch (global style rule)" {
  local emdash; emdash=$(printf '\xe2\x80\x94')   # U+2014 UTF-8 bytes, so no literal em-dash lives in this file
  for m in watch land review_then_land; do
    run swn_build_context "$m" 'https://github.com/o/r/pull/9' 9
    [[ "$output" != *"$emdash"* ]]
  done
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

# ---- consistency with the merge gate (AC4) ----------------------------------

@test "rate-limit signal agrees with merge gate: mc_cr_rate_limited drives land" {
  MCLIB="$BATS_TEST_DIRNAME/../scripts/merge-clearance-lib.sh"
  # shellcheck source=/dev/null
  . "$MCLIB"
  comments='[{"author":"coderabbitai[bot]","body":"<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->"}]'
  run mc_cr_rate_limited "$comments"
  [ "$output" = "yes" ]
  # The same "yes" the hook feeds into swn_decide, with a current backstop, yields land.
  run swn_decide yes yes
  [ "$output" = "land" ]
}

@test "no rate-limit marker -> not rate-limited -> watch" {
  MCLIB="$BATS_TEST_DIRNAME/../scripts/merge-clearance-lib.sh"
  # shellcheck source=/dev/null
  . "$MCLIB"
  comments='[{"author":"coderabbitai[bot]","body":"Actionable comments posted: 0"}]'
  run mc_cr_rate_limited "$comments"
  [ "$output" = "no" ]
  run swn_decide no no
  [ "$output" = "watch" ]
}
