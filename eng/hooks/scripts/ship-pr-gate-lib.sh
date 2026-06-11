#!/bin/bash
# Pure, side-effect-free decision logic for the ship-PR gate, extracted so it can
# be unit tested (tests/ship-pr-gate.bats) without a live repo, a session, or any
# hook plumbing. Every function takes everything it needs as arguments (including
# "now", so the TTL check is deterministic) and writes only to stdout.
#
# Consumer:
#   scripts/ship-pr-gate.sh - sources sg_sentinel_valid to decide whether a
#                             `gh pr create` is part of a genuine /ship run.
#
# Requires jq for JSON parsing. The gate fails OPEN (allowing the PR) before ever
# sourcing this when jq is absent, so a jq-less host never reaches here.

# sg_sentinel_valid <sentinel_json> <now_epoch> <default_ttl_seconds>
#   Decide whether a ship-gate sentinel authorizes a `gh pr create` right now.
#   Echoes "valid" on success; otherwise a single-word reason
#   (no-sentinel | malformed | expired). Return code mirrors the verdict
#   (0 valid, 1 otherwise) so callers can branch on either.
#
#   A sentinel is a JSON object written by ship-gate-sentinel.sh when /ship is
#   invoked (either the user typing `/ship` at the prompt, or the agent calling
#   the Skill tool with skill "ship"):
#     { "set_at_epoch": <int>, "ttl_seconds": <int>, "trigger": "skill|prompt" }
#   The sentinel's own ttl_seconds wins when it is a positive integer (so the
#   writer / repo marker controls the window); <default_ttl_seconds> is the
#   fallback for an absent or non-numeric value.
#
#   This binds on FRESHNESS, not on HEAD: a /ship run rewrites the working tree
#   (version bump, changelog) and may create the PR on a commit made moments
#   earlier, so pinning to a pre-create HEAD would false-block. Freshness plus the
#   opt-in marker plus ~/dev scoping is the accident-guard contract; this is not a
#   tamper-proof sandbox (the agent can write inside .git).
sg_sentinel_valid() {
  local sentinel="$1" now="$2" default_ttl="$3"

  if [ -z "$sentinel" ]; then echo "no-sentinel"; return 1; fi

  # One jq pass pulls both fields; a parse failure (truncated / corrupt sentinel)
  # surfaces as "malformed" rather than a false "valid".
  local parsed
  parsed=$(printf '%s' "$sentinel" | jq -r '
    [ (.set_at_epoch // "") , (.ttl_seconds // "") ] | @tsv
  ' 2>/dev/null) || { echo "malformed"; return 1; }

  local s_epoch s_ttl
  IFS=$'\t' read -r s_epoch s_ttl <<<"$parsed"

  case "$s_epoch" in ''|*[!0-9]*) echo "malformed"; return 1 ;; esac
  case "$now"     in ''|*[!0-9]*) echo "malformed"; return 1 ;; esac

  # ttl: sentinel's own value if it is a positive integer, else the caller default.
  local ttl="$default_ttl"
  case "$s_ttl" in ''|*[!0-9]*) : ;; *) [ "$s_ttl" -gt 0 ] && ttl="$s_ttl" ;; esac
  case "$ttl" in ''|*[!0-9]*) echo "malformed"; return 1 ;; esac

  local age=$(( now - s_epoch ))
  if [ "$age" -lt 0 ] || [ "$age" -gt "$ttl" ]; then echo "expired"; return 1; fi

  echo "valid"; return 0
}
