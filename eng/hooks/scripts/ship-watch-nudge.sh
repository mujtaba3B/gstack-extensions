#!/bin/bash
# PostToolUse hook on Bash. After a genuine /ship opens a PR in an opted-in ~/dev
# repo, inject a system-reminder-style nudge so the main agent starts a CodeRabbit
# watcher (or, when CR is rate-limited, moves the PR forward) instead of leaving a
# shipped PR unwatched.
#
# Why a NUDGE and not an auto-run: a hook cannot launch a foreground skill. The
# canonical watcher /eng:pr-watcher runs its dispatcher loop (and its foreground
# sensor script) in the main agent's own turn, so only the model can start it. A PostToolUse
# hook CAN return additionalContext that the model reads next turn - verified against
# Claude Code 2.1.x: {"hookSpecificOutput":{"hookEventName":"PostToolUse",
# "additionalContext":"..."}} on stdout with exit 0 reliably reaches the model. So
# the durable mechanism is an auto-nudge; "auto-run" is not achievable from a hook
# (and would hijack the session). /ship itself is upgrade-clobbered (regenerated from
# a template into the plugin cache), so the nudge cannot live in /ship's body; it
# lives here in the plugin's hook layer, which ships to the cache via bin/install.
#
# Rate-limit awareness (agrees with the merge gate at the create moment): the nudge
# does NOT blindly push an open-ended watch. It detects a rate-limited CodeRabbit with
# the SAME mc_cr_rate_limited (from merge-clearance-lib.sh) the merge gate uses for a
# MISSING CR status - the literal "rate limited by coderabbit.ai" marker in the PR's
# issue comments - and, when found, nudges toward moving forward instead: a current
# local /eng:cr review backstops the rate-limited CR (merge-clearance's
# CR_RL_BACKSTOPPED interlock: review-skill-head == HEAD), and the PR is clear to land
# via /land-and-deploy. A fresh /ship create is exactly the missing-status state, so
# the nudge and the merge gate agree there. (The gate uses a stricter latest-comment
# variant, mc_cr_rate_limited_latest, only for a stuck-"pending" status, which cannot
# exist at create time; the two are not claimed to agree universally.)
#
# Belt-and-suspenders: at a brand-new PR CodeRabbit has almost never posted anything
# yet, so RATE_LIMITED is nearly always "no" and the hook emits the plain "watch"
# nudge. The land / review_then_land branches (and the gh comments lookup) exist for
# the rarer re-create / fast-CR case; the watch nudge text itself also carries the
# rate-limit fallback instructions, so the feature still works even when they never
# fire.
#
# Opt-in: the same per-repo opt-in as the ship-PR gate - the presence of
# .ship-gate.json. No new marker or flag (a repo that ships via /ship wants its PRs
# watched). Genuine-/ship gating: a fresh valid ship-pr-clearance sentinel (the same
# signal the ship-PR gate just cleared this create on), so a bare non-ship
# `gh pr create` never nudges.
#
# Output protocol (PostToolUse): this hook NEVER blocks (the tool already ran; there
# is no decision to make). It either prints the additionalContext JSON and exits 0,
# or exits 0 with empty stdout. Fail-OPEN everywhere: any missing dependency,
# unresolved repo, absent sentinel, or missing PR URL => no nudge. A failed CR
# rate-limit lookup degrades to the plain "watch" nudge, never to a wrong "land".
# Past the point where we know this is a genuine ship PR (opted-in + fresh sentinel)
# but then drop with no parseable PR URL, an audit line is written so that rot - e.g.
# gh's output shape drifting so the URL parse stops matching - shows up in the log
# instead of a silent stop. Never both a false claim and a wedged session.

set -u

LOGFILE="$HOME/.claude/ship-pr-gate.log"
sg_log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$*" >> "$LOGFILE" 2>/dev/null || true
}

PAYLOAD=$(cat)
command -v jq  >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty')
[ -n "$CMD" ] || exit 0

# Shared libs, resolved relative to THIS script so the executing copy binds its own
# deps (the scripts are dual-use: hook env, bats, the merge-clearance shim). Source
# ONLY the matcher lib first and take the `gh pr create` early exit before touching
# the heavier deps: this hook runs on EVERY Bash tool call, so a plain `ls` must not
# pay to source the repo resolver, sentinel validator, and merge-clearance lib. Only
# a genuine create path reaches those.
LIBDIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NLIB="$LIBDIR/ship-watch-nudge-lib.sh"
[ -f "$NLIB" ] || exit 0
# shellcheck source=/dev/null
. "$NLIB"

# Only a `gh pr create` at command position (cheap early exit for every other Bash).
[ "$(swn_is_pr_create "$CMD")" = "yes" ] || exit 0

# Past the create match: bind the rest. The repo resolver + sentinel validator are
# required (without them we cannot decide correctly, so exit quietly / fail open).
# merge-clearance-lib is needed ONLY for the rate-limit detector; if it is missing we
# degrade to "not rate-limited" (the plain watch nudge) rather than failing the hook.
RLIB="$LIBDIR/ship-gate-repo-lib.sh"
SLIB="$LIBDIR/ship-pr-gate-lib.sh"
CLIB="$LIBDIR/merge-clearance-lib.sh"
{ [ -f "$RLIB" ] && [ -f "$SLIB" ]; } || exit 0
# shellcheck source=/dev/null
. "$RLIB"
# shellcheck source=/dev/null
. "$SLIB"
# shellcheck source=/dev/null
[ -f "$CLIB" ] && . "$CLIB"

# Resolve the repo the command targets exactly as the gate does (honor a leading
# `cd`), so a worktree / cross-repo create is evaluated against the right repo.
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty')
{ [ -n "$CWD" ] && [ -d "$CWD" ]; } || CWD="$PWD"
WORKDIR=$(sg_workdir_from_cmd "$CMD" "$CWD")
RESOLVED=$(sg_dev_repo_gitdir "$WORKDIR") || exit 0   # not a ~/dev repo -> no nudge
TOP=${RESOLVED%%$'\t'*}
GITDIR=${RESOLVED#*$'\t'}

# Opt-in: same marker as the ship-PR gate. No marker -> repo has not opted in.
MARKER="$TOP/.ship-gate.json"
[ -f "$MARKER" ] || exit 0

# Genuine /ship: a fresh valid ship-pr-clearance sentinel (the signal the ship-PR
# gate itself cleared this create on). A bare non-ship create has none -> no nudge.
# The marker may tune the freshness window; else 1200s (the sentinel's own
# ttl_seconds wins inside the validator when present).
DEFAULT_TTL=1200
mttl=$(jq -r '.ttl_seconds // empty' "$MARKER" 2>/dev/null)
case "$mttl" in ''|*[!0-9]*) : ;; *) [ "$mttl" -gt 0 ] && DEFAULT_TTL="$mttl" ;; esac
SENTINEL=$(cat "$GITDIR/ship-pr-clearance" 2>/dev/null || echo "")
NOW=$(date +%s)
[ "$(sg_sentinel_valid "$SENTINEL" "$NOW" "$DEFAULT_TTL")" = "valid" ] || exit 0

# Parse the new PR URL from the command's stdout (gh pr create prints it). Verified
# against 2.1.x: the Bash tool output is under .tool_response.stdout. Fall back to
# the whole tool_response if stdout is absent. No URL -> the create did not open a
# PR we can point at -> no nudge (fail open).
OUT=$(printf '%s' "$PAYLOAD" | jq -r '.tool_response.stdout // .tool_response // empty' 2>/dev/null)
PR_URL=$(swn_extract_pr_url "$OUT")
# Silent drop here would be invisible rot: we already know this is a genuine ship PR
# (opted-in + fresh sentinel), so a create whose output carries no parseable PR URL
# (gh output shape drifted, URL only on stderr, etc.) means the nudge silently stops
# firing on every real ship. Log it (per the header's fail-open-with-audit contract).
if [ -z "$PR_URL" ]; then
  sg_log "NO-NUDGE $TOP no parseable PR URL in gh output past a valid ship sentinel"
  exit 0
fi
PR_NUM=$(swn_pr_num_from_url "$PR_URL")

# Dedupe: never nag twice for the same PR (a re-run of `gh pr create` on an existing
# branch reprints the same URL). The record lives in the per-worktree git dir.
NUDGED_FILE="$GITDIR/ship-watch-nudged"
NUDGED=$(cat "$NUDGED_FILE" 2>/dev/null || echo "")
[ "$(swn_already_nudged "$NUDGED" "$PR_URL")" = "yes" ] && exit 0

# Rate-limit detection (best-effort; fail open to "not rate-limited"). Reuse the
# merge gate's own mc_cr_rate_limited on the PR's issue comments so the nudge and
# the merge gate agree. Any gh/parse failure -> "no" -> the plain watch nudge. The
# gh call only happens once we have decided this is a real ship PR (opted-in, fresh
# sentinel, URL present), so a non-ship Bash command never pays for it.
#
# The gh call is bounded by `timeout` when available: this runs on the PostToolUse
# hot path, so a stalled network or a hung `gh` must NOT wedge turn completion. On a
# timeout (or a host with no `timeout` binary that then stalls) the pipeline yields
# empty output, COMMENTS falls back to '[]', and RATE_LIMITED stays "no" -> the plain
# watch nudge. Guarded by command -v so a host without `timeout` degrades to a plain
# call rather than erroring, consistent with the fail-open posture.
RATE_LIMITED=no
if command -v gh >/dev/null 2>&1 && command -v mc_cr_rate_limited >/dev/null 2>&1; then
  OWNER_REPO=$(printf '%s' "$PR_URL" | sed -nE 's#https://github\.com/([^/]+)/([^/]+)/pull/[0-9]+.*#\1/\2#p')
  if [ -n "$OWNER_REPO" ] && [ -n "$PR_NUM" ]; then
    GH_TIMEOUT=""; command -v timeout >/dev/null 2>&1 && GH_TIMEOUT="timeout 8"
    COMMENTS=$($GH_TIMEOUT gh api --paginate "repos/$OWNER_REPO/issues/$PR_NUM/comments" \
                 -q '[.[] | {author: (.user.login // ""), body: (.body // "")}]' 2>/dev/null \
               | jq -sc 'add // []' 2>/dev/null)
    { [ -n "$COMMENTS" ] && [ "$COMMENTS" != "null" ]; } || COMMENTS='[]'
    # mc_cr_rate_limited already echoes "no" on the negative/unparseable case, so no
    # `|| echo` fallback is needed; the case below normalizes any unexpected value.
    RATE_LIMITED=$(mc_cr_rate_limited "$COMMENTS" 2>/dev/null)
    case "$RATE_LIMITED" in yes|no) ;; *) RATE_LIMITED=no ;; esac
  fi
fi

# Backstop: only meaningful when rate-limited. Same interlock as merge-clearance's
# CR_RL_BACKSTOPPED - a current local /eng:cr review (review-skill-head stamp equals
# HEAD). At the create moment the local HEAD is the PR head (just pushed), so this
# matches the merge gate's REVIEW_STATE=current check.
BACKSTOP=no
if [ "$RATE_LIMITED" = "yes" ]; then
  RSTAMP=$(cat "$GITDIR/review-skill-head" 2>/dev/null || echo "")
  HEADSHA=$(git -C "$TOP" rev-parse HEAD 2>/dev/null || echo "")
  { [ -n "$RSTAMP" ] && [ -n "$HEADSHA" ] && [ "$RSTAMP" = "$HEADSHA" ]; } && BACKSTOP=yes
fi

MODE=$(swn_decide "$RATE_LIMITED" "$BACKSTOP")
CONTEXT=$(swn_build_context "$MODE" "$PR_URL" "$PR_NUM")

# Record the nudge (atomic temp-then-mv), keeping the last 50 PR URLs so the file
# stays bounded over the life of the repo.
tmp=$(mktemp "$GITDIR/.ship-watch-nudged.XXXXXX" 2>/dev/null)
if [ -n "$tmp" ]; then
  { printf '%s\n' "$NUDGED"; printf '%s\n' "$PR_URL"; } | grep -v '^[[:space:]]*$' | tail -50 > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$NUDGED_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
fi

sg_log "WATCH-NUDGE $TOP PR=$PR_URL decision=$MODE rate_limited=$RATE_LIMITED backstop=$BACKSTOP"
jq -nc --arg c "$CONTEXT" '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$c}}'
exit 0
