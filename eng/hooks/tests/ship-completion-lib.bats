#!/usr/bin/env bats
# Tests for the pure decision logic of the ship COMPLETION-evidence gate
# (ship-completion-lib.sh): sc_mode, sc_required, sc_dim_verdict, sc_blockers.
# No repo / session / hook plumbing needed - every function is a pure transform.

setup() {
  LIB="$BATS_TEST_DIRNAME/../scripts/ship-completion-lib.sh"
  # shellcheck source=/dev/null
  . "$LIB"
}

# ---- sc_mode ----------------------------------------------------------------

@test "sc_mode: absent completion block -> record" {
  run sc_mode '{"base_branches":["main"]}'
  [ "$status" -eq 0 ]; [ "$output" = "record" ]
}

@test "sc_mode: explicit require" {
  run sc_mode '{"completion":{"mode":"require"}}'
  [ "$output" = "require" ]
}

@test "sc_mode: explicit record" {
  run sc_mode '{"completion":{"mode":"record"}}'
  [ "$output" = "record" ]
}

@test "sc_mode: unknown mode value -> record (safe non-blocking default)" {
  run sc_mode '{"completion":{"mode":"banana"}}'
  [ "$output" = "record" ]
}

@test "sc_mode: unparseable marker -> record" {
  run sc_mode 'not json'
  [ "$output" = "record" ]
}

# ---- sc_required ------------------------------------------------------------

@test "sc_required: lists known dims in a stable order" {
  run sc_required '{"completion":{"require":["review","changelog","version","base_merged"]}}'
  [ "$output" = "base_merged changelog review version" ]  # jq unique sorts
}

@test "sc_required: drops unknown tokens (a typo can never invent a blocking dim)" {
  run sc_required '{"completion":{"require":["review","bogus","tests"]}}'
  [ "$output" = "review" ]
}

@test "sc_required: absent -> empty" {
  run sc_required '{"completion":{"mode":"require"}}'
  [ "$output" = "" ]
}

@test "sc_required: dedupes" {
  run sc_required '{"completion":{"require":["review","review"]}}'
  [ "$output" = "review" ]
}

# ---- sc_dim_verdict <state> <skip_present> ----------------------------------

@test "sc_dim_verdict: ok -> ok" {
  run sc_dim_verdict ok no
  [ "$output" = "ok" ]
}

@test "sc_dim_verdict: na -> na" {
  run sc_dim_verdict na no
  [ "$output" = "na" ]
}

@test "sc_dim_verdict: missing + no skip -> block" {
  run sc_dim_verdict missing no
  [ "$output" = "block" ]
}

@test "sc_dim_verdict: missing + recorded skip -> skipped" {
  run sc_dim_verdict missing yes
  [ "$output" = "skipped" ]
}

@test "sc_dim_verdict: unknown (uncomputable) + no skip -> block" {
  run sc_dim_verdict unknown no
  [ "$output" = "block" ]
}

@test "sc_dim_verdict: unknown + recorded skip -> skipped" {
  run sc_dim_verdict unknown yes
  [ "$output" = "skipped" ]
}

@test "sc_dim_verdict: unrecognized state -> block (safe direction)" {
  run sc_dim_verdict weird no
  [ "$output" = "block" ]
}

# ---- sc_blockers <mode> <required> <states> <skips> -------------------------

@test "sc_blockers: record mode never blocks even when a dim is missing" {
  run sc_blockers record "review changelog" '{"review":"missing","changelog":"missing"}' '{}'
  [ "$output" = "" ]
}

@test "sc_blockers: require blocks a missing required dim" {
  run sc_blockers require "review" '{"review":"missing"}' '{}'
  [ "$output" = "review" ]
}

@test "sc_blockers: require passes when all required dims are ok" {
  run sc_blockers require "review changelog version base_merged" \
    '{"review":"ok","changelog":"ok","version":"ok","base_merged":"ok"}' '{}'
  [ "$output" = "" ]
}

@test "sc_blockers: na satisfies a required dim (docs-only / no package.json)" {
  run sc_blockers require "version changelog" '{"version":"na","changelog":"na"}' '{}'
  [ "$output" = "" ]
}

@test "sc_blockers: unknown (base unresolved) blocks a required dim, unlike na" {
  run sc_blockers require "base_merged changelog version" \
    '{"base_merged":"unknown","changelog":"unknown","version":"unknown"}' '{}'
  [ "$output" = "$(printf 'base_merged\nchangelog\nversion')" ]
}

@test "sc_blockers: a recorded skip unblocks an unknown required dim too" {
  run sc_blockers require "base_merged" '{"base_merged":"unknown"}' '{"base_merged":"reason=shallow-checkout"}'
  [ "$output" = "" ]
}

@test "sc_blockers: a recorded skip unblocks a missing required dim" {
  run sc_blockers require "changelog" '{"changelog":"missing"}' '{"changelog":"reason=docs-only"}'
  [ "$output" = "" ]
}

@test "sc_blockers: only the missing-and-unskipped dims block" {
  run sc_blockers require "review changelog version base_merged" \
    '{"review":"ok","changelog":"missing","version":"na","base_merged":"missing"}' \
    '{"base_merged":"reason=already-based"}'
  # changelog missing+unskipped blocks; base_merged missing but skipped; review ok; version na
  [ "$output" = "changelog" ]
}

@test "sc_blockers: a required dim absent from states defaults to missing -> block" {
  run sc_blockers require "review" '{}' '{}'
  [ "$output" = "review" ]
}

@test "sc_blockers: empty required list never blocks" {
  run sc_blockers require "" '{"review":"missing"}' '{}'
  [ "$output" = "" ]
}
