#!/bin/bash
# PreToolUse hook on Bash. Block a bare `gh pr create` in an OPTED-IN ~/dev repo
# unless a fresh ship-gate sentinel proves the create is part of a real /ship run.
#
# This makes gstack `/ship` the only sanctioned way to open a PR in opted-in
# ~/dev repos. The motivating failure: the agent improvises `gh pr create` itself
# (skipping /ship's base reconciliation + tests + review + version bump), and once
# swept another agent's commits into a PR off a contaminated shared checkout.
#
# The signal: ship-gate-sentinel.sh writes <gitdir>/ship-pr-clearance when /ship
# is invoked (Skill PreToolUse, or the user typing `/ship`). /ship cannot be
# edited to announce itself (gstack-upgrade clobbers it), so the announcement is
# captured by a hook on the invocation instead. A genuine /ship run has a fresh
# sentinel; a bare manual/agent create does not.
#
# Output protocol (Claude Code PreToolUse hook):
#   exit 0 + empty stdout                          -> allow
#   stdout JSON {"decision":"block","reason":...}  -> block, reason shown to Claude
#
# Fail-OPEN posture: any missing dependency (jq/git), unreadable marker, or
# inability to resolve the repo leaves the create ALLOWED. A local gate that fails
# closed on its own bug trains the human to rip it out. Fail-open paths that hit
# AFTER we have decided this is a gated create are LOGGED (see sg_log) so gate-rot
# is detectable rather than a silent bypass.
#
# Accident-guard, NOT an adversary-proof sandbox: the agent has shell access and
# could forge the sentinel or lift the marker. The point is to funnel the agent's
# "I'll just open the PR" reflex through /ship, not to defeat deliberate evasion.
#
# Deliberate human one-off (no agent-facing override by design): temporarily
# remove or rename the repo's .ship-gate.json marker, create the PR, then restore
# it. That is an out-of-band human act, not a lever the agent is handed.

set -u

LOGFILE="$HOME/.claude/ship-pr-gate.log"
sg_log() {
  # Best-effort, never fatal. Records non-trivial decisions (block + fail-open
  # after the create was identified as gated) so a rotted/bypassed gate is visible.
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$*" >> "$LOGFILE" 2>/dev/null || true
}

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty')

# Match `gh pr create` at command position (line start or after a shell
# separator), so the phrase inside a quoted argument / heredoc body (e.g. a PR
# description that documents this very hook) does NOT trip the gate. Tolerate
# non-malicious prefixes: leading env-var assignments (`GH_TOKEN=x gh pr create`)
# and an absolute/relative path to gh (`/opt/homebrew/bin/gh pr create`). This is
# an accident-guard, so deeply obfuscated forms (bash -c "...") are out of scope.
printf '%s' "$CMD" | grep -Eq '(^|[;&|(])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*([^[:space:];&|]*/)?gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' || exit 0

# Resolve the repo the command targets. Hooks run from the session cwd, not the
# cwd a leading `cd <dir>` switched into, so a worktree or cross-repo create would
# otherwise be evaluated against the wrong repo. Honor a leading `cd <dir>`;
# fall back to $PWD when there is none.
WORKDIR=$(printf '%s\n' "$CMD" | sed -nE 's/^[[:space:]]*cd[[:space:]]+([^[:space:];&|]+).*/\1/p' | head -1)
case "$WORKDIR" in "~") WORKDIR="$HOME" ;; "~/"*) WORKDIR="${HOME}/${WORKDIR#\~/}" ;; esac
{ [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; } || WORKDIR="$PWD"

command -v git >/dev/null 2>&1 || exit 0

# Scope: only ~/dev repos (where the policy lives).
TOP=$(git -C "$WORKDIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
case "$TOP" in
  "$HOME/dev"|"$HOME/dev/"*) ;;
  *) exit 0 ;;
esac

# Opt-in marker. No marker -> this repo has not opted in -> allow (untouched).
MARKER="$TOP/.ship-gate.json"
[ -f "$MARKER" ] || exit 0

# Cross-repo guard (mirrors pr-merge-gate.sh). If the command explicitly targets a
# DIFFERENT repo (`--repo` / `-R` / a `GH_REPO=` env prefix), the marker + sentinel
# here belong to WORKDIR's repo, not the target. Validating them would mis-evaluate
# (a bypass: open an ungated PR in repo B by running `gh pr create --repo B` from
# inside opted-in repo A, whose fresh /ship sentinel would wrongly clear it). We
# cannot validate a clearance for a repo we are not in, so block and point at /ship.
# Only runs when such a flag is present, so the common case pays no extra cost.
TARGETREPO=$(printf '%s' "$CMD" | grep -oE '(--repo[ =]|[[:space:]]-R[ =])[^[:space:]]+' | head -1 | sed -E 's/.*[ =]//')
[ -z "$TARGETREPO" ] && TARGETREPO=$(printf '%s' "$CMD" | grep -oE 'GH_REPO=[^[:space:]]+' | head -1 | sed 's/GH_REPO=//')
if [ -n "$TARGETREPO" ] && command -v gh >/dev/null 2>&1; then
  WDREPO=$(cd "$WORKDIR" 2>/dev/null && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
  TNORM=$(printf '%s' "$TARGETREPO" | sed -E 's#^https?://[^/]+/##; s#\.git$##')
  if [ -z "$WDREPO" ]; then
    # This checkout's repo identity could not be resolved (no remote, gh auth or
    # network failure). An explicit cross-repo target with an unverifiable local
    # identity is exactly the bypass this guard exists for, so refuse rather
    # than let a local sentinel clear a PR in an unknown other repo.
    REASON="Ship gate: this command targets $TNORM via --repo/-R/GH_REPO, but this checkout's own repo identity could not be resolved (no remote, or gh auth/network failure), so the gate cannot verify the target matches. Open the PR via /ship from a checkout of $TNORM, or fix gh auth and retry."
    sg_log "BLOCK cross-repo gh pr create from $TOP targeting $TNORM (WDREPO unresolved)"
    jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
    exit 0
  fi
  if [ "$TNORM" != "$WDREPO" ]; then
    REASON="Ship gate: this command targets a different repo ($TNORM) via --repo/-R/GH_REPO from inside an opted-in checkout ($WDREPO). The ship gate can only validate a /ship sentinel for the repo you are in, so it refuses rather than mis-evaluate. Open the PR via /ship from a checkout of $TNORM (its own gate applies there)."
    sg_log "BLOCK cross-repo gh pr create from $TOP targeting $TNORM"
    jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
    exit 0
  fi
fi

# Base-branch scoping. The marker may restrict enforcement to specific base
# branches (default ["main"]). The base is in the command (`--base X` / `-B X`)
# when present; when absent we cannot cheaply resolve the repo default here, so we
# gate (the common /ship path always passes `--base`). When a base IS named and is
# out of scope, allow.
CMDBASE=$(printf '%s' "$CMD" | grep -oE '(--base[ =]|[[:space:]]-B[ =])[^[:space:]]+' | head -1 | sed -E 's/.*[ =]//')
if [ -n "$CMDBASE" ]; then
  # An UNPARSEABLE marker (jq errors -> empty output) must not silently disable the
  # gate: the repo is already confirmed opted-in above, so a corrupt config falls
  # CLOSED onto gating (and is logged) rather than allowing. Only a successfully
  # parsed, genuinely out-of-scope base allows.
  BASES=$(jq -r '(.base_branches // ["main"]) | .[]' "$MARKER" 2>/dev/null)
  if [ -z "$BASES" ]; then
    sg_log "FAIL-CLOSED .ship-gate.json unparseable in $TOP; gating regardless of --base=$CMDBASE"
  else
    printf '%s\n' "$BASES" | grep -qxF "$CMDBASE" || exit 0   # base in scope check; out of scope -> allow
  fi
fi

# Per-worktree git dir (never the common dir) so we read the same sentinel the
# writer keyed to this worktree.
GITDIR=$(git -C "$WORKDIR" rev-parse --absolute-git-dir 2>/dev/null) || {
  sg_log "FAIL-OPEN could not resolve git dir for $WORKDIR (gated create allowed)"
  exit 0
}

# Load the pure validator (lives alongside this hook after install).
LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-pr-gate-lib.sh"
[ -f "$LIB" ] || { sg_log "FAIL-OPEN validator missing ($LIB); gated create allowed"; exit 0; }
# shellcheck source=/dev/null
. "$LIB"

# Default TTL: the marker may tune it; else 1200s. The sentinel carries its own
# ttl_seconds (written from the same marker), which wins inside the validator;
# this is only the fallback for a sentinel without one.
DEFAULT_TTL=1200
mttl=$(jq -r '.ttl_seconds // empty' "$MARKER" 2>/dev/null)
case "$mttl" in ''|*[!0-9]*) : ;; *) [ "$mttl" -gt 0 ] && DEFAULT_TTL="$mttl" ;; esac

SENTINEL=$(cat "$GITDIR/ship-pr-clearance" 2>/dev/null || echo "")
NOW=$(date +%s)
VERDICT=$(sg_sentinel_valid "$SENTINEL" "$NOW" "$DEFAULT_TTL")
[ "$VERDICT" = "valid" ] && exit 0

REASON="Ship gate: open PRs in this repo via /ship, not a bare \`gh pr create\` [sentinel: ${VERDICT}]. /ship reconciles the base branch, runs tests/review, bumps VERSION, and opens the PR consistently; a bare create skips all of that and can sweep unrelated commits off a stale checkout. Run /ship to ship this change (it mints the clearance this gate checks). This is intentional: there is no agent-facing override. For a deliberate human one-off, temporarily remove this repo's .ship-gate.json marker, create the PR, then restore it."
sg_log "BLOCK gh pr create in $TOP [sentinel: $VERDICT]"
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
