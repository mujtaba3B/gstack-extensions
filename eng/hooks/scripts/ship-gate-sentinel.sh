#!/bin/bash
# ship-gate-sentinel - mint the "/ship is genuinely running" sentinel.
#
# Wired to TWO hook events (one script, payload tells it which):
#   - PreToolUse on the Skill tool  (PRIMARY)   : the agent invoked /ship; the
#     skill body is about to run. This is the strong signal.
#   - UserPromptSubmit              (SECONDARY) : the user literally typed `/ship`
#     at the prompt. Weaker (a prompt could name /ship without running it), so we
#     require the prompt to START with `/ship`, not merely contain it.
#
# On a match it writes a short-TTL sentinel JSON to <gitdir>/ship-pr-clearance.
# ship-pr-gate.sh reads it to decide whether a `gh pr create` belongs to a real
# /ship run. The sentinel lives in the git dir (ephemeral, never committed) and
# is keyed to the PER-WORKTREE git dir (`--absolute-git-dir`, never the common
# dir) so clearance does not bleed across linked worktrees.
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

EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty')
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty')
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD="$PWD"

# Decide whether this event is a genuine /ship invocation.
TRIGGER=""
case "$EVENT" in
  PreToolUse)
    TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')
    [ "$TOOL" = "Skill" ] || exit 0
    # The skill identifier may live under a few keys depending on harness version;
    # check the likely ones and match the basename "ship" (exact, or namespaced as
    # "<plugin>:ship" / a path ending in "/ship"). Liberal on purpose: a missed
    # match false-BLOCKS a real /ship, the costlier error.
    SKILL=$(printf '%s' "$PAYLOAD" | jq -r '
      (.tool_input.skill // .tool_input.name // .tool_input.command // "") | ascii_downcase' 2>/dev/null)
    case "$SKILL" in
      ship|*:ship|*/ship) TRIGGER="skill" ;;
      *) exit 0 ;;
    esac
    ;;
  UserPromptSubmit)
    PROMPT=$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty')
    # Require the prompt to START with `/ship` as a whole token (so "/shipment" or
    # prose like "should I use /ship here?" does NOT mint clearance).
    printf '%s' "$PROMPT" | grep -Eiq '^[[:space:]]*/ship([[:space:]]|$)' || exit 0
    TRIGGER="prompt"
    ;;
  *)
    exit 0 ;;
esac

# Resolve the per-worktree git dir for the cwd. Outside a repo -> nothing to key
# the sentinel to; exit quietly.
GITDIR=$(git -C "$CWD" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
TOP=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0

# Scope: ~/dev only.
case "$TOP" in
  "$HOME/dev"|"$HOME/dev/"*) ;;
  *) exit 0 ;;
esac

# TTL: the repo's .ship-gate.json may set ttl_seconds; else default 1200s (20m),
# long enough to cover a slow /ship (review + version bump + push) without a wide
# manual window.
TTL=1200
MARKER="$TOP/.ship-gate.json"
if [ -f "$MARKER" ]; then
  mttl=$(jq -r '.ttl_seconds // empty' "$MARKER" 2>/dev/null)
  case "$mttl" in ''|*[!0-9]*) : ;; *) [ "$mttl" -gt 0 ] && TTL="$mttl" ;; esac
fi

NOW=$(date +%s)
SENTINEL=$(jq -nc \
  --argjson epoch "$NOW" --argjson ttl "$TTL" --arg trigger "$TRIGGER" \
  '{set_at_epoch:$epoch, ttl_seconds:$ttl, trigger:$trigger}')

# Atomic write (temp in the same dir, then mv) so a concurrent gate read never
# sees a half-written sentinel.
tmp=$(mktemp "$GITDIR/.ship-pr-clearance.XXXXXX" 2>/dev/null) || exit 0
printf '%s\n' "$SENTINEL" > "$tmp" 2>/dev/null && mv -f "$tmp" "$GITDIR/ship-pr-clearance" 2>/dev/null || rm -f "$tmp" 2>/dev/null

exit 0
