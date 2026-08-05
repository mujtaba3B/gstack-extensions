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

# Shared libs (single source of truth with ship-pr-gate.sh / land-deploy-sentinel.sh):
# the repo resolver and the session-arming primitive. Resolve them relative to THIS
# script so the executing copy binds its own deps. Without them we cannot mint for
# the right repo, so exit quietly (the gate fails open too).
LIBDIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RLIB="$LIBDIR/ship-gate-repo-lib.sh"
ALIB="$LIBDIR/ship-gate-arm-lib.sh"
{ [ -f "$RLIB" ] && [ -f "$ALIB" ]; } || exit 0
# shellcheck source=/dev/null
. "$RLIB"
# shellcheck source=/dev/null
. "$ALIB"

EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty')
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty')
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD="$PWD"
SESSION=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty')

# Session arming (shared ship-gate-arm-lib.sh, kind "ship"). The marker lets the
# later PreToolUse:Bash event know a real /ship is in flight.
#
# ARM_TTL bounds how long the armed window may go IDLE (no ~/dev-repo Bash activity)
# before the Bash-mint path goes inert. It is NOT a hard ceiling on the whole /ship
# run: the Bash branch SLIDES the window forward on every armed Bash command that
# mints into the target repo (see the Bash case below), so an actively-working
# /ship keeps itself armed for as long as it keeps running repo commands. This is
# the fix for the "unpassable long ship" bug: previously the arm marker was written
# ONCE at /ship invocation and never refreshed, so ARM_TTL after invocation the
# Bash-mint died, the sentinel froze at its last mint, and any /ship whose
# invocation->`gh pr create` span exceeded 1200s (routine: review + CodeRabbit + a
# QA-plan detour) found the sentinel expired at create time. With sliding, only an
# idle gap LONGER than ARM_TTL (a run left untouched for 20m) lapses the window; a
# genuine active run never does.
#
# 1200s is the per-slide IDLE budget, matched to the sentinel's own TTL. Do not
# widen it without reason: the sliding property (not a larger fixed window) is what
# spans a long run, and a bigger fixed TTL only makes clearance linger longer AFTER
# a ship ends. The post-/ship blast radius (any ~/dev repo cd'd into while armed
# self-clears) is unchanged in KIND and now activity-bounded rather than fixed at
# 1200s-from-invocation.
ARM_TTL=1200
ARM_DIR="${TMPDIR:-/tmp}"
arm_session()        { ga_arm       "ship" "$SESSION" "$ARM_DIR" "$(date +%s)"; }
session_armed_fresh() { ga_armed_fresh "ship" "$SESSION" "$ARM_DIR" "$(date +%s)" "$ARM_TTL"; }

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

# mint_for_dir <workdir> <trigger> : mint iff <workdir> is a ~/dev repo. Returns 0
# when <workdir> is an in-scope ~/dev repo (the mint path ran; the sentinel write
# itself is best-effort), non-zero when out of scope - the Bash branch reads this to
# slide the arm window only for an in-scope target repo. Skill/prompt callers ignore
# the return value.
mint_for_dir() {
  local resolved top gitdir
  resolved=$(sg_dev_repo_gitdir "$1") || return 1
  top=${resolved%%$'\t'*}
  gitdir=${resolved#*$'\t'}
  mint "$gitdir" "$top" "$2"
}

# write_ledger <workdir> <trigger> : record that a genuine /ship run began, for
# audit. Written only on the true START events (Skill invocation / typed /ship),
# NOT on the per-Bash re-mint - so run_started_epoch and head_at_start reflect the
# start of the run rather than being reset by every armed Bash command (which
# would zero out the "when did /ship begin" signal right before `gh pr create`).
# Best-effort and atomic (temp-in-same-dir then mv). The completion gate does NOT
# depend on this file (it recomputes evidence from the repo), so a failure here
# never affects enforcement - the ledger is an audit convenience only.
write_ledger() {
  local resolved top gitdir branch head now tmp
  resolved=$(sg_dev_repo_gitdir "$1") || return 0
  top=${resolved%%$'\t'*}
  gitdir=${resolved#*$'\t'}
  now=$(date +%s)
  branch=$(git -C "$top" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  head=$(git -C "$top" rev-parse HEAD 2>/dev/null || echo "")
  tmp=$(mktemp "$gitdir/.ship-run.XXXXXX" 2>/dev/null) || return 0
  jq -nc --argjson epoch "$now" --arg branch "$branch" --arg head "$head" \
     --arg session "$SESSION" --arg trigger "$2" \
     '{run_started_epoch:$epoch, branch:$branch, head_at_start:$head, session:$session, trigger:$trigger}' \
     > "$tmp" 2>/dev/null && mv -f "$tmp" "$gitdir/ship-run.json" 2>/dev/null || rm -f "$tmp" 2>/dev/null
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
        write_ledger "$CWD" "skill"
        ;;
      Bash)
        # TARGET-MINT: only while a real /ship has armed this session. Resolve the
        # repo the command targets exactly as the gate does, and mint there.
        session_armed_fresh || exit 0
        CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty')
        [ -n "$CMD" ] || exit 0
        WORKDIR=$(sg_workdir_from_cmd "$CMD" "$CWD")
        if mint_for_dir "$WORKDIR" "ship-bash"; then
          # SLIDE the arm window forward: an actively-working /ship (one still
          # running repo commands) keeps itself armed, so the Bash-mint keeps the
          # sentinel fresh for the WHOLE run instead of freezing ARM_TTL after
          # invocation. This is the core of the long-ship fix. It can only EXTEND an
          # already-armed session: we reach here only past `session_armed_fresh`
          # above, and only re-arm when the command resolved to an in-scope ~/dev
          # repo (mint_for_dir returned 0). It therefore never ARMS an unarmed session -
          # a bare `cd ~/dev/repo && gh pr create` with no prior /ship is still
          # never armed and still blocks - and never resurrects an expired window
          # (an idle gap > ARM_TTL fails session_armed_fresh and we exit before
          # here). The window thus tracks genuine, still-active /ship repo activity.
          arm_session
        fi
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
    write_ledger "$CWD" "prompt"
    ;;
  *)
    exit 0 ;;
esac

exit 0
