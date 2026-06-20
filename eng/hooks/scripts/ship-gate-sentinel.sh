#!/bin/bash
# ship-gate-sentinel - mint the "/ship is genuinely running" sentinel.
#
# Wired to THREE hook events (one script, payload tells it which):
#   - PreToolUse on the Skill tool  (PRIMARY)   : the agent invoked /ship; the
#     skill body is about to run. This is the strong signal.
#   - UserPromptSubmit              (SECONDARY) : the user literally typed `/ship`
#     at the prompt. Weaker (a prompt could name /ship without running it), so we
#     require the prompt to START with `/ship`, not merely contain it.
#   - PreToolUse on the Bash tool   (TARGET-MINT): while a /ship invocation has
#     ARMED this session (above), a Bash command that operates in a ~/dev repo
#     mints the sentinel into THAT repo's git dir. This is the fix for the
#     cwd-vs-target mismatch: the gate evaluates the repo the `gh pr create`
#     command targets (honoring a leading `cd`), but the Skill/prompt events only
#     ever see the SESSION cwd. When the session is anchored outside the target
#     repo (a non-~/dev folder, or a different ~/dev repo) the cwd-keyed mint
#     wrote clearance to the wrong git dir and the gate blocked forever. Minting
#     on the armed Bash command resolves the repo the SAME way the gate does
#     (shared ship-gate-repo-lib.sh), so they can never disagree.
#
# On a match it writes a short-TTL sentinel JSON to <gitdir>/ship-pr-clearance.
# ship-pr-gate.sh reads it to decide whether a `gh pr create` belongs to a real
# /ship run. The sentinel lives in the git dir (ephemeral, never committed) and
# is keyed to the PER-WORKTREE git dir (`--absolute-git-dir`, never the common
# dir) so clearance does not bleed across linked worktrees.
#
# ARMING: the Skill/prompt events write a session-scoped marker
# ($TMPDIR/gstack-ship-armed-<session_id>) so the later Bash event knows a real
# /ship is in flight. The accident-guard property is preserved: a bare
# `cd ~/dev/repo && gh pr create` with NO prior /ship leaves the session unarmed,
# the Bash path mints nothing, and the gate blocks. Only a genuine /ship arms the
# session. (This is an accident-guard, not a tamper-proof sandbox: the agent has
# shell access and could forge either file. The point is to funnel the "I'll just
# open the PR" reflex through /ship.)
#
# This hook NEVER blocks: it always exits 0 with empty stdout (its only effect is
# the side-effect write). It is not a gate; it is the gate's input.
#
# Scope: only ~/dev git repos. Writing a sentinel in a repo that has not opted in
# is harmless (the gate ignores repos with no .ship-gate.json marker), but we
# still scope to ~/dev to avoid scattering files in unrelated repos.

set -u

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# Shared repo resolver (single source of truth with ship-pr-gate.sh). Resolve it
# relative to THIS script so the executing copy binds its own dependency. Without
# it we cannot mint for the right repo, so exit quietly (the gate fails open too).
RLIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-gate-repo-lib.sh"
[ -f "$RLIB" ] || exit 0
# shellcheck source=/dev/null
. "$RLIB"

EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty')
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty')
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD="$PWD"
SESSION=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty')

# Session-armed marker. Keyed by session id (sanitized for a filename); absent
# session id -> arming is unavailable and the Bash target-mint path is skipped,
# degrading to the legacy cwd-only behavior rather than misfiring.
#
# ARM_TTL bounds how long after a /ship invocation an armed Bash command may still
# mint, i.e. it must span a whole /ship run (invocation -> review/build -> the
# final `gh pr create`). Kept at 1200s to MATCH the legacy window: the old design
# minted a 1200s freshness sentinel at /ship invocation, so the create already had
# to land within 1200s of invocation. Do not widen this without reason; a longer
# window only enlarges the post-/ship blast radius (any ~/dev repo cd'd into during
# the window self-clears), which is the accident-guard's main cost.
ARM_TTL=1200
ARM_DIR="${TMPDIR:-/tmp}"
arm_file() {
  local sid; sid=$(printf '%s' "$SESSION" | tr -c 'A-Za-z0-9._-' '_')
  [ -n "$sid" ] && [ "$sid" != "_" ] || return 1
  printf '%s/gstack-ship-armed-%s' "${ARM_DIR%/}" "$sid"
}
arm_session() {
  local f; f=$(arm_file) || return 0
  printf '%s\n' "$(date +%s)" > "$f" 2>/dev/null || true
}
session_armed_fresh() {
  local f now armed; f=$(arm_file) || return 1
  [ -f "$f" ] || return 1
  armed=$(head -1 "$f" 2>/dev/null)
  case "$armed" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ $(( now - armed )) -ge 0 ] && [ $(( now - armed )) -le "$ARM_TTL" ]
}

# mint <gitdir> <top> <trigger> : write the freshness sentinel for one repo.
mint() {
  local gitdir="$1" top="$2" trigger="$3" ttl=1200 marker now sentinel tmp
  marker="$top/.ship-gate.json"
  if [ -f "$marker" ]; then
    local mttl; mttl=$(jq -r '.ttl_seconds // empty' "$marker" 2>/dev/null)
    case "$mttl" in ''|*[!0-9]*) : ;; *) [ "$mttl" -gt 0 ] && ttl="$mttl" ;; esac
  fi
  now=$(date +%s)
  sentinel=$(jq -nc \
    --argjson epoch "$now" --argjson ttl "$ttl" --arg trigger "$trigger" \
    '{set_at_epoch:$epoch, ttl_seconds:$ttl, trigger:$trigger}')
  # Atomic write (temp in the same dir, then mv) so a concurrent gate read never
  # sees a half-written sentinel.
  tmp=$(mktemp "$gitdir/.ship-pr-clearance.XXXXXX" 2>/dev/null) || return 0
  printf '%s\n' "$sentinel" > "$tmp" 2>/dev/null && mv -f "$tmp" "$gitdir/ship-pr-clearance" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

# mint_for_dir <workdir> <trigger> : mint iff <workdir> is a ~/dev repo.
mint_for_dir() {
  local resolved top gitdir
  resolved=$(sg_dev_repo_gitdir "$1") || return 0
  top=${resolved%%$'\t'*}
  gitdir=${resolved#*$'\t'}
  mint "$gitdir" "$top" "$2"
}

case "$EVENT" in
  PreToolUse)
    TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')
    case "$TOOL" in
      Skill)
        # The skill identifier may live under a few keys depending on harness
        # version; check the likely ones and match the basename "ship" (exact, or
        # namespaced as "<plugin>:ship" / a path ending in "/ship"). Liberal on
        # purpose: a missed match false-BLOCKS a real /ship, the costlier error.
        SKILL=$(printf '%s' "$PAYLOAD" | jq -r '
          (.tool_input.skill // .tool_input.name // .tool_input.command // "") | ascii_downcase' 2>/dev/null)
        case "$SKILL" in
          ship|*:ship|*/ship) ;;
          *) exit 0 ;;
        esac
        # Arm the session (so a later `cd <target> && gh pr create` mints for the
        # target), AND direct-mint for the cwd in case the cwd IS the target repo.
        arm_session
        mint_for_dir "$CWD" "skill"
        ;;
      Bash)
        # TARGET-MINT: only while a real /ship has armed this session. Resolve the
        # repo the command targets exactly as the gate does, and mint there.
        session_armed_fresh || exit 0
        CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty')
        [ -n "$CMD" ] || exit 0
        WORKDIR=$(sg_workdir_from_cmd "$CMD" "$CWD")
        mint_for_dir "$WORKDIR" "ship-bash"
        ;;
      *) exit 0 ;;
    esac
    ;;
  UserPromptSubmit)
    PROMPT=$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty')
    # Require the prompt to START with `/ship` as a whole token (so "/shipment" or
    # prose like "should I use /ship here?" does NOT mint clearance).
    printf '%s' "$PROMPT" | grep -Eiq '^[[:space:]]*/ship([[:space:]]|$)' || exit 0
    arm_session
    mint_for_dir "$CWD" "prompt"
    ;;
  *)
    exit 0 ;;
esac

exit 0
