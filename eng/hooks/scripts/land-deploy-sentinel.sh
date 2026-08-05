#!/bin/bash
# land-deploy-sentinel - mint the "/land-and-deploy is genuinely running" sentinel.
#
# This is the half that makes /land-and-deploy the SINGLE sanctioned CLI merge
# path. pr-merge-gate.sh requires BOTH a valid merge-clearance stamp AND a fresh,
# target-matched sentinel before it allows `gh pr merge`. The stamp can be written
# by a bare `merge-clearance clear`; this sentinel can ONLY be minted by actually
# invoking /land-and-deploy. So a manual `merge-clearance clear` + `gh pr merge`
# no longer merges: it lacks the sentinel.
#
# Wired to THREE hook events (one script, payload tells it which), mirroring
# ship-gate-sentinel.sh:
#   - PreToolUse on the Skill tool  (PRIMARY)   : the agent invoked
#     /land-and-deploy; the skill body is about to run. Strong signal.
#   - UserPromptSubmit              (SECONDARY) : the user literally typed
#     `/land-and-deploy` at the prompt. Weaker, so we require the prompt to START
#     with `/land-and-deploy`.
#   - PreToolUse on the Bash tool   (TARGET-MINT): while a /land-and-deploy
#     invocation has ARMED this session, a Bash `cd <target> && gh pr merge` mints
#     the sentinel into THAT repo's git dir. This fixes the cwd-vs-target bug: the
#     gate evaluates the repo the merge command targets (honoring a leading `cd`),
#     but the Skill/prompt events only ever see the SESSION cwd. When the session
#     is anchored outside the target repo, the cwd-keyed mint wrote the sentinel
#     (and its head_sha / repo bindings) for the WRONG repo and the merge gate
#     blocked forever. The Bash mint resolves the target the SAME way the gate does
#     (shared ship-gate-repo-lib.sh) and binds head_sha / repo from the TARGET
#     checkout, so the two can never disagree.
#
# On a match it writes a short-lived sentinel JSON to <gitdir>/land-deploy-clearance.
# The sentinel is TARGET-BOUND: it records the repo, the local HEAD sha, and (when
# resolvable) the PR number, so a sentinel minted for one commit cannot authorize
# merging a newer pushed commit. It lives in the PER-WORKTREE git dir
# (`--absolute-git-dir`), so repo + worktree binding is implied by location and
# clearance never bleeds across linked worktrees.
#
# ARMING: the Skill/prompt events write a session-scoped marker (kind "land", via
# ship-gate-arm-lib.sh) so the later Bash event knows a real /land-and-deploy is in
# flight. The accident-guard holds: a bare `cd <repo> && gh pr merge` with no prior
# /land-and-deploy leaves the session unarmed, the Bash path mints nothing, and the
# merge gate blocks. (Accident-guard, not a tamper-proof sandbox: the agent could
# forge either file; the GitHub required check is the hard authority.)
#
# This hook NEVER blocks: it always exits 0 with empty stdout. It is not a gate;
# it is the gate's input. It uses only git (no `gh`, no network) so it stays fast
# and reliable even when fired on every prompt / Bash call.
#
# Scope: only ~/dev git repos, to avoid scattering files in unrelated repos.

set -u

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# Shared libs (single source of truth with pr-merge-gate.sh / ship-gate-sentinel.sh):
# repo resolver + session-arming primitive. Resolve relative to THIS script so the
# executing copy binds its own deps. Missing -> exit quietly (the gate fails open).
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

# ARM_TTL bounds how long the armed window may go IDLE (no ~/dev-repo Bash activity)
# before the Bash-mint path goes inert. It is NOT a hard ceiling on the whole run:
# the Bash branch SLIDES the window forward on every armed Bash command that mints
# into the target repo (see the Bash case below), so an actively-working
# /land-and-deploy keeps itself armed while it runs repo commands (invocation ->
# wait on CI + the merge queue -> the actual `gh pr merge`). This mirrors the
# ship-gate fix: previously the arm marker was written once at invocation and never
# refreshed, so ARM_TTL later the Bash-mint died and the sentinel froze - a
# /land-and-deploy longer than the window found it expired at merge time. With
# sliding, only an idle gap LONGER than ARM_TTL lapses the window. 1800s (30m) is
# the per-slide idle budget, matched to the sentinel's own default TTL; the
# sentinel is also head_sha-bound, so a live window is doubly safe (a stale commit
# cannot be merged on an old sentinel).
ARM_TTL=1800
ARM_DIR="${TMPDIR:-/tmp}"
arm_session()     { ga_arm       "land" "$SESSION" "$ARM_DIR" "$(date +%s)"; }
land_armed_fresh() { ga_armed_fresh "land" "$SESSION" "$ARM_DIR" "$(date +%s)" "$ARM_TTL"; }

# mint <workdir> <pr_number> <source> : write the target-bound sentinel for the
# repo that <workdir> resolves to, iff it is a ~/dev repo. head_sha + repo are read
# from THAT checkout (not the session cwd), so the bindings match what the gate
# validates against the target PR. Returns 0 when <workdir> is an in-scope ~/dev
# repo (the mint path ran; the sentinel write itself is best-effort), non-zero when
# out of scope - the Bash branch reads this to slide the arm window only for an
# in-scope target repo. Skill/prompt callers ignore the return value.
mint() {
  local workdir="$1" pr="$2" source="$3" resolved top gitdir head_sha remote repo ttl marker now sentinel tmp
  resolved=$(sg_dev_repo_gitdir "$workdir") || return 1
  top=${resolved%%$'\t'*}
  gitdir=${resolved#*$'\t'}
  head_sha=$(git -C "$workdir" rev-parse HEAD 2>/dev/null || echo "")
  remote=$(git -C "$workdir" remote get-url origin 2>/dev/null || echo "")
  repo=$(printf '%s' "$remote" | sed -E 's#^[^:]+://[^/]+/##; s#^[^@]+@[^:]+:##; s#\.git$##')
  ttl=1800
  marker="$top/.merge-clearance.json"
  if [ -f "$marker" ]; then
    local mttl; mttl=$(jq -r '.ld_sentinel_ttl_seconds // empty' "$marker" 2>/dev/null)
    case "$mttl" in ''|*[!0-9]*) : ;; *) [ "$mttl" -gt 0 ] && ttl="$mttl" ;; esac
  fi
  now=$(date +%s)
  sentinel=$(jq -nc \
    --argjson epoch "$now" --argjson ttl "$ttl" \
    --arg repo "$repo" --arg head "$head_sha" --arg pr "$pr" --arg source "$source" \
    '{set_at_epoch:$epoch, ttl_seconds:$ttl, repo:$repo, head_sha:$head, pr_number:$pr, source:$source}')
  tmp=$(mktemp "$gitdir/.land-deploy-clearance.XXXXXX" 2>/dev/null) || return 0
  printf '%s\n' "$sentinel" > "$tmp" 2>/dev/null && mv -f "$tmp" "$gitdir/land-deploy-clearance" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

# PR number from a "/land-and-deploy" arg string: anchored to a "#123" token (the
# documented arg form), so prose like "v2 ship it" or a URL's path digits never
# become a spurious pr_number that would later false-block a different merge.
pr_from_args() { printf '%s' "$1" | grep -oE '#[0-9]+' | head -1 | tr -d '#'; }
# PR number from a `gh pr merge <N>` command (mirrors pr-merge-gate.sh's parse).
# A flag-before-number form (`gh pr merge --squash 45`) yields empty, so the
# sentinel falls back to head-only binding; the gate parses with the identical
# regex, so both sides stay consistent (and head_sha + the stamp still gate).
pr_from_cmd()  { printf '%s' "$1" | grep -oE 'gh pr merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+$'; }

case "$EVENT" in
  PreToolUse)
    TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')
    case "$TOOL" in
      Skill)
        # Match the basename "land-and-deploy" (exact, namespaced, or path form).
        # Liberal on purpose: a missed match false-BLOCKS a real /land-and-deploy at
        # merge time, the costlier error.
        SKILL=$(printf '%s' "$PAYLOAD" | jq -r '
          (.tool_input.skill // .tool_input.name // .tool_input.command // "") | ascii_downcase' 2>/dev/null)
        case "$SKILL" in
          land-and-deploy|*:land-and-deploy|*/land-and-deploy) ;;
          *) exit 0 ;;
        esac
        ARGS=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.args // .tool_input.arguments // "")' 2>/dev/null)
        # Arm the session for the later Bash mint, AND direct-mint for the cwd in
        # case the cwd IS the target repo.
        arm_session
        mint "$CWD" "$(pr_from_args "$ARGS")" "skill"
        ;;
      Bash)
        # TARGET-MINT: only while a real /land-and-deploy has armed this session.
        land_armed_fresh || exit 0
        CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty')
        [ -n "$CMD" ] || exit 0
        WORKDIR=$(sg_workdir_from_cmd "$CMD" "$CWD")
        if mint "$WORKDIR" "$(pr_from_cmd "$CMD")" "land-bash"; then
          # SLIDE the arm window forward (mirrors ship-gate-sentinel.sh): an
          # actively-working /land-and-deploy keeps itself armed, so the Bash-mint
          # keeps the head_sha-bound sentinel fresh (and current with HEAD) for the
          # whole run instead of freezing ARM_TTL after invocation. Only EXTENDS an
          # already-armed session (we passed land_armed_fresh above) and only when the
          # command resolved to an in-scope ~/dev repo (mint returned 0), so it never
          # arms an unarmed session nor resurrects an expired window.
          arm_session
        fi
        ;;
      *) exit 0 ;;
    esac
    ;;
  UserPromptSubmit)
    PROMPT=$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty')
    # Require the prompt to START with `/land-and-deploy` as a whole token (so
    # "/land-and-deployer" or prose like "should I /land-and-deploy?" does NOT mint).
    printf '%s' "$PROMPT" | grep -Eiq '^[[:space:]]*/land-and-deploy([[:space:]]|$)' || exit 0
    arm_session
    mint "$CWD" "$(pr_from_args "$PROMPT")" "prompt"
    ;;
  *)
    exit 0 ;;
esac

exit 0
