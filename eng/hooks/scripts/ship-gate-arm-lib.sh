#!/bin/bash
# Shared session-arming helpers for the ship-gate and merge-gate sentinels.
#
# WHY this exists: both sentinels (ship-gate-sentinel.sh, land-deploy-sentinel.sh)
# need the same trick to fix the cwd-vs-target bug. The Skill/prompt hook events
# only ever see the SESSION cwd, but the repo a `gh pr create` / `gh pr merge`
# actually targets is decided by a leading `cd` in the Bash command. So each
# sentinel must mint into the TARGET repo's git dir on the Bash event, not the
# session-cwd repo on the Skill event. To know a real /ship or /land-and-deploy is
# in flight at Bash time, the Skill/prompt event leaves a session-scoped "armed"
# marker that the later Bash event reads. This file is that arming primitive,
# shared so the two gates can never drift apart on how arming works.
#
# A marker is keyed by (kind, session_id): "ship" markers never satisfy a "land"
# check and vice versa, so a /ship cannot authorize a merge mint. The accident-
# guard property holds because the marker is written ONLY by a genuine skill/prompt
# invocation; an unarmed session mints nothing on the Bash path and the gate blocks.
#
# These touch only $TMPDIR (read/write a tiny marker file). "now" and "tmpdir" are
# passed in so the freshness check is deterministic and testable.

# ga_arm_file <kind> <session_id> <tmpdir>
#   Echo the arm-marker path for <kind> ("ship" | "land") and <session_id>, or
#   return 1 when the session id is empty / sanitizes to blank (arming
#   unavailable -> the Bash mint path is skipped, degrading to cwd-only minting
#   rather than misfiring). session_id is sanitized to a safe filename token, so a
#   crafted id cannot escape <tmpdir> (a "/" or ".." becomes a literal suffix).
ga_arm_file() {
  local kind="$1" session="$2" tmpdir="${3:-/tmp}" sid
  sid=$(printf '%s' "$session" | tr -c 'A-Za-z0-9._-' '_')
  [ -n "$sid" ] && [ "$sid" != "_" ] || return 1
  printf '%s/gstack-%s-armed-%s' "${tmpdir%/}" "$kind" "$sid"
}

# ga_arm <kind> <session_id> <tmpdir> <now_epoch>
#   Write the arm marker (best-effort; never fatal, since arming a no-op just means
#   the Bash mint path stays inert and the gate falls back to its other signals).
ga_arm() {
  local f; f=$(ga_arm_file "$1" "$2" "$3") || return 0
  printf '%s\n' "$4" > "$f" 2>/dev/null || true
}

# ga_armed_fresh <kind> <session_id> <tmpdir> <now_epoch> <ttl_seconds>
#   Return 0 iff a fresh (within ttl, non-negative age, numeric) arm marker exists
#   for (kind, session). A missing / malformed / stale marker returns 1, the safe
#   direction (the Bash mint stays inert -> the gate blocks).
ga_armed_fresh() {
  local f armed age; f=$(ga_arm_file "$1" "$2" "$3") || return 1
  [ -f "$f" ] || return 1
  armed=$(head -1 "$f" 2>/dev/null)
  case "$armed" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( $4 - armed ))
  [ "$age" -ge 0 ] && [ "$age" -le "$5" ]
}
