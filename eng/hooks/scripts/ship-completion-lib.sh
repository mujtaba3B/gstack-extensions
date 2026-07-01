#!/bin/bash
# Pure, side-effect-free decision logic for the ship COMPLETION-evidence gate,
# extracted so it can be unit tested (tests/ship-completion-lib.bats) without a
# live repo, a session, or any hook plumbing. Every function takes everything it
# needs as arguments and writes only to stdout.
#
# Consumer:
#   scripts/ship-pr-gate.sh - after the freshness sentinel says a /ship run is in
#   flight, this decides whether the create carries the FOOTPRINTS of a genuine
#   run (a review happened, the base was reconciled, the version/CHANGELOG were
#   touched) or is a partial/hand-driven ship missing them.
#
# The "why": the freshness sentinel proves /ship was INVOKED, not that its
# checklist RAN. An agent can invoke /ship (arming the sentinel), then hand-drive
# or skip the steps, and the create still passes. This layer records the
# footprint-checkable steps and, when a repo opts in (marker completion.mode =
# "require"), blocks a create that is missing a required footprint unless an
# explicit recorded skip makes the omission honest and auditable.
#
# It deliberately does NOT try to enforce the no-footprint quality steps
# (plan-completion, adversarial, TODOS): they leave no durable trace, so a hook
# cannot verify them. Those are recorded as "unverified", never blocked - the goal
# is "no SILENT partial ship", not "ship can never be adapted".
#
# Requires jq. The gate fails OPEN before sourcing this when jq is absent.

# The known dimension tokens. A dim outside this set is ignored (not blockable),
# so a typo in a repo's marker can never invent a dimension that always blocks.
SC_KNOWN_DIMS="review changelog version base_merged"

# sc_mode <marker_json>
#   Echo the completion enforcement mode from a .ship-gate.json marker.
#   "record" (default: snapshot only, never blocks) or "require" (named dims
#   hard-block). An absent completion block, an unparseable marker, or any value
#   other than "require" -> "record" (the non-blocking, backward-compatible
#   direction, so a repo that never opted in keeps its current behavior).
sc_mode() {
  local m
  m=$(printf '%s' "$1" | jq -r '.completion.mode // "record"' 2>/dev/null) || { echo "record"; return 0; }
  case "$m" in require) echo "require" ;; *) echo "record" ;; esac
}

# sc_required <marker_json>
#   Echo the space-separated list of dimensions the marker requires (from
#   completion.require[]). Only the known dimension tokens survive; anything else
#   is dropped. Empty output when the key is absent or unparseable.
sc_required() {
  printf '%s' "$1" | jq -r '
    (.completion.require // [])
    | map(select(. == "review" or . == "changelog" or . == "version" or . == "base_merged"))
    | unique | .[]' 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'
}

# sc_dim_verdict <state> <skip_present>
#   Decide one dimension. <state> is ok|missing|na (computed by the gate from the
#   repo). <skip_present> is "yes" when a recorded skip reason exists for the dim.
#     ok      -> "ok"        (footprint present)
#     na      -> "na"        (dim does not apply here, e.g. docs-only, no package.json)
#     missing -> "skipped"   when a recorded skip makes the omission honest
#     missing -> "block"     otherwise
sc_dim_verdict() {
  case "$1" in
    ok) echo "ok" ;;
    na) echo "na" ;;
    missing) [ "$2" = "yes" ] && echo "skipped" || echo "block" ;;
    *) echo "block" ;;  # unknown state -> safe (blocking) direction under require
  esac
}

# sc_blockers <mode> <required_space_list> <states_json> <skips_json>
#   The core decision. Echo (newline-separated) the required dimensions that BLOCK
#   the create. Empty output means allow.
#     - mode != "require"           -> never blocks (echo nothing).
#     - for each required dim: look up its state (default "missing") and whether a
#       skip reason is present, run sc_dim_verdict, emit the dim iff "block".
#   states_json: {"review":"ok","changelog":"missing",...}
#   skips_json:  {"changelog":"reason=docs-only ...", ...}  (presence => skip)
sc_blockers() {
  local mode="$1" required="$2" states="$3" skips="$4" dim state skipreason present
  [ "$mode" = "require" ] || return 0
  for dim in $required; do
    state=$(printf '%s' "$states" | jq -r --arg d "$dim" '.[$d] // "missing"' 2>/dev/null) || state="missing"
    skipreason=$(printf '%s' "$skips" | jq -r --arg d "$dim" '.[$d] // ""' 2>/dev/null) || skipreason=""
    present="no"; [ -n "$skipreason" ] && present="yes"
    [ "$(sc_dim_verdict "$state" "$present")" = "block" ] && printf '%s\n' "$dim"
  done
}
