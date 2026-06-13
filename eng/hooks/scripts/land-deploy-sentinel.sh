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
# Wired to TWO hook events (one script, payload tells it which), mirroring
# ship-gate-sentinel.sh:
#   - PreToolUse on the Skill tool  (PRIMARY)   : the agent invoked
#     /land-and-deploy; the skill body is about to run. Strong signal.
#   - UserPromptSubmit              (SECONDARY) : the user literally typed
#     `/land-and-deploy` at the prompt. Weaker (a prompt could name it without
#     running it), so we require the prompt to START with `/land-and-deploy`.
#
# On a match it writes a short-lived sentinel JSON to <gitdir>/land-deploy-clearance.
# The sentinel is TARGET-BOUND: it records the repo, the local HEAD sha, and (when
# resolvable) the PR number, so a sentinel minted for one commit cannot authorize
# merging a newer pushed commit. It lives in the PER-WORKTREE git dir
# (`--absolute-git-dir`), so repo + worktree binding is implied by location and
# clearance never bleeds across linked worktrees.
#
# This hook NEVER blocks: it always exits 0 with empty stdout. It is not a gate;
# it is the gate's input. It uses only git (no `gh`, no network) so it stays fast
# and reliable even when fired on every prompt.
#
# Scope: only ~/dev git repos, to avoid scattering files in unrelated repos.

set -u

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty')
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty')
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD="$PWD"

# Decide whether this event is a genuine /land-and-deploy invocation, and capture
# any explicit PR target the invocation carried (e.g. "/land-and-deploy #123").
TRIGGER=""
ARGS=""
case "$EVENT" in
  PreToolUse)
    TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')
    [ "$TOOL" = "Skill" ] || exit 0
    # The skill identifier may live under a few keys depending on harness version;
    # match the basename "land-and-deploy" (exact, namespaced "<plugin>:land-and-deploy",
    # or a path ending in "/land-and-deploy"). Liberal on purpose: a missed match
    # false-BLOCKS a real /land-and-deploy at merge time, the costlier error.
    SKILL=$(printf '%s' "$PAYLOAD" | jq -r '
      (.tool_input.skill // .tool_input.name // .tool_input.command // "") | ascii_downcase' 2>/dev/null)
    case "$SKILL" in
      land-and-deploy|*:land-and-deploy|*/land-and-deploy) TRIGGER="skill" ;;
      *) exit 0 ;;
    esac
    ARGS=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.args // .tool_input.arguments // "")' 2>/dev/null)
    ;;
  UserPromptSubmit)
    PROMPT=$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty')
    # Require the prompt to START with `/land-and-deploy` as a whole token (so
    # "/land-and-deployer" or prose like "should I /land-and-deploy?" does NOT mint).
    printf '%s' "$PROMPT" | grep -Eiq '^[[:space:]]*/land-and-deploy([[:space:]]|$)' || exit 0
    TRIGGER="prompt"
    ARGS="$PROMPT"
    ;;
  *)
    exit 0 ;;
esac

# Resolve the per-worktree git dir + toplevel for the cwd. Outside a repo there is
# nothing to key the sentinel to; exit quietly.
GITDIR=$(git -C "$CWD" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
TOP=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0

# Scope: ~/dev only.
case "$TOP" in
  "$HOME/dev"|"$HOME/dev/"*) ;;
  *) exit 0 ;;
esac

# Target bindings, all from local git (no network):
#   head_sha - the commit land-and-deploy will merge (local HEAD == the pushed PR
#              head in the normal case; an unpushed local commit yields a mismatch
#              at the gate, which fails safe by re-requiring /land-and-deploy).
#   repo     - owner/name normalized from the origin remote (https or ssh form).
HEAD_SHA=$(git -C "$CWD" rev-parse HEAD 2>/dev/null || echo "")
REMOTE_URL=$(git -C "$CWD" remote get-url origin 2>/dev/null || echo "")
REPO=$(printf '%s' "$REMOTE_URL" | sed -E 's#^[^:]+://[^/]+/##; s#^[^@]+@[^:]+:##; s#\.git$##')

# Best-effort PR number from the invocation args. Anchored to a "#123" token (the
# documented /land-and-deploy arg form): a bare digit run is NOT accepted, so prose
# like "/land-and-deploy v2 ship it" or a URL's path digits never become a spurious
# pr_number that would later false-block a `gh pr merge <other-number>`. Omitted when
# absent; the gate enforces pr only when both sides carry one.
PR_NUMBER=$(printf '%s' "$ARGS" | grep -oE '#[0-9]+' | head -1 | tr -d '#')

# TTL: the repo's .merge-clearance.json may set ld_sentinel_ttl_seconds; else 1800s
# (30m). Generous on purpose: /land-and-deploy can wait on CI and a merge queue for
# many minutes between this mint and the actual `gh pr merge`. A long window is safe
# because the sentinel is bound to a specific head_sha, not just freshness.
TTL=1800
MARKER="$TOP/.merge-clearance.json"
if [ -f "$MARKER" ]; then
  mttl=$(jq -r '.ld_sentinel_ttl_seconds // empty' "$MARKER" 2>/dev/null)
  case "$mttl" in ''|*[!0-9]*) : ;; *) [ "$mttl" -gt 0 ] && TTL="$mttl" ;; esac
fi

NOW=$(date +%s)
SENTINEL=$(jq -nc \
  --argjson epoch "$NOW" --argjson ttl "$TTL" \
  --arg repo "$REPO" --arg head "$HEAD_SHA" --arg pr "$PR_NUMBER" --arg trigger "$TRIGGER" \
  '{set_at_epoch:$epoch, ttl_seconds:$ttl, repo:$repo, head_sha:$head, pr_number:$pr, source:$trigger}')

# Atomic write (temp in the same dir, then mv) so a concurrent gate read never sees
# a half-written sentinel.
tmp=$(mktemp "$GITDIR/.land-deploy-clearance.XXXXXX" 2>/dev/null) || exit 0
printf '%s\n' "$SENTINEL" > "$tmp" 2>/dev/null && mv -f "$tmp" "$GITDIR/land-deploy-clearance" 2>/dev/null || rm -f "$tmp" 2>/dev/null

exit 0
