#!/bin/bash
# PreToolUse hook on Bash. Block `gh pr merge` in an OPTED-IN ~/dev repo unless a
# valid merge-clearance stamp exists for the PR's current HEAD.
#
# This is the local accident-guard half of "make /land-and-deploy the only merge
# path". The hard authority is a GitHub branch ruleset requiring the
# `local-review/merge-clearance` status check (which binds the web button and
# --admin too); this hook is the fast, offline catch for a bare `gh pr merge` from
# the CLI. Both are satisfied by the same act: `merge-clearance clear` (run by
# /land-and-deploy after CR + CI + /review + QA pass) writes the stamp AND posts
# the status. Running /review alone no longer clears a merge - only the full
# gauntlet does.
#
# Opt-in: this gate only enforces in a repo that carries a `.merge-clearance.json`
# marker at its root AND whose PR base branch is listed there (default ["main"]).
# Every other ~/dev repo is untouched, so a bug here cannot brick merges fleet-wide.
#
# Output protocol (Claude Code PreToolUse hook):
#   exit 0 + empty stdout                          -> allow
#   stdout JSON {"decision":"block","reason":...}  -> block, reason shown to Claude
#
# Fail-open posture: any missing dependency (jq/git/gh), unreadable marker, or
# inability to resolve the PR leaves the merge ALLOWED. A local gate that fails
# closed on its own bug trains the human to rip it out; the GitHub required check
# is the backstop that never fails open.

set -u

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty')
# Match `gh pr merge` at command position (line start or after a shell separator),
# so the phrase appearing inside a quoted argument / heredoc body (e.g. a PR
# description that documents this very hook) does NOT trip the gate. Tolerate
# realistic non-malicious prefixes that the old anchor missed: leading env-var
# assignments (`GH_REPO=o/r gh pr merge`) and an absolute/relative path to gh
# (`/opt/homebrew/bin/gh pr merge`). This is an accident-guard, not an
# adversary-proof sandbox (the GitHub required check is the real authority), so
# deeply obfuscated forms like `bash -c "..."` are out of scope by design.
printf '%s' "$CMD" | grep -Eq '(^|[;&|(])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*([^[:space:];&|]*/)?gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' || exit 0

# Resolve the repo the command actually targets. Hooks run from the session cwd,
# not the cwd a leading `cd <dir> && ...` switched into, so a worktree or
# cross-repo merge would otherwise be evaluated against the wrong repo. Honor a
# leading `cd <dir>` prefix; fall back to $PWD when there is none.
WORKDIR=$(printf '%s\n' "$CMD" | sed -nE 's/^[[:space:]]*cd[[:space:]]+([^[:space:];&|]+).*/\1/p' | head -1)
case "$WORKDIR" in "~") WORKDIR="$HOME" ;; "~/"*) WORKDIR="${HOME}/${WORKDIR#\~/}" ;; esac
{ [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; } || WORKDIR="$PWD"

# Scope: only consider ~/dev repos (where the policy lives).
TOP=$(git -C "$WORKDIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
case "$TOP" in
  "$HOME/dev"|"$HOME/dev/"*) ;;
  *) exit 0 ;;
esac

# Opt-in marker. No marker -> this repo has not opted in -> allow (untouched).
MARKER="$TOP/.merge-clearance.json"
[ -f "$MARKER" ] || exit 0

GITDIR=$(git -C "$WORKDIR" rev-parse --absolute-git-dir 2>/dev/null) || exit 0

# Cross-repo guard. If the command explicitly targets a DIFFERENT repo (--repo,
# -R, or a GH_REPO= env prefix), the marker + stamp here belong to WORKDIR's repo,
# not the target. Validating them would mis-evaluate (a bypass vector: merge an
# uncleared PR of repo B from inside opted-in repo A). We cannot validate a
# clearance for a repo we do not have checked out, so block and point at the
# sanctioned path. Only runs when such a flag is present, so the common case pays
# no extra cost.
TARGETREPO=$(printf '%s' "$CMD" | grep -oE '(--repo[ =]|[[:space:]]-R[ =])[^[:space:]]+' | head -1 | sed -E 's/.*[ =]//')
[ -z "$TARGETREPO" ] && TARGETREPO=$(printf '%s' "$CMD" | grep -oE 'GH_REPO=[^[:space:]]+' | head -1 | sed 's/GH_REPO=//')
if [ -n "$TARGETREPO" ] && command -v gh >/dev/null 2>&1; then
  WDREPO=$(cd "$WORKDIR" 2>/dev/null && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
  TNORM=$(printf '%s' "$TARGETREPO" | sed -E 's#^https?://[^/]+/##; s#\.git$##')
  if [ -n "$WDREPO" ] && [ "$TNORM" != "$WDREPO" ]; then
    REASON="Merge gate: this command targets a different repo ($TNORM) via --repo/-R/GH_REPO from inside an opted-in checkout ($WDREPO). The local clearance gate can only validate a stamp for the repo you are in, so it refuses rather than mis-evaluate. Merge from a checkout of $TNORM (its clearance gets validated there), or run /land-and-deploy in that repo."
    jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
    exit 0
  fi
fi

# Resolve the PR's HEAD and BASE. Prefer an explicit PR number in the command,
# else the PR for the local branch. gh has no -C, so run inside WORKDIR.
PRNUM=$(printf '%s' "$CMD" | grep -oE 'gh pr merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+$')
PRHEAD=""; PRBASE=""
if command -v gh >/dev/null 2>&1; then
  if [ -n "$PRNUM" ]; then
    read -r PRHEAD PRBASE < <(cd "$WORKDIR" 2>/dev/null && gh pr view "$PRNUM" --json headRefOid,baseRefName -q '.headRefOid + " " + .baseRefName' 2>/dev/null)
  else
    read -r PRHEAD PRBASE < <(cd "$WORKDIR" 2>/dev/null && gh pr view --json headRefOid,baseRefName -q '.headRefOid + " " + .baseRefName' 2>/dev/null)
  fi
fi
[ -z "$PRHEAD" ] && PRHEAD=$(git -C "$WORKDIR" rev-parse HEAD 2>/dev/null)

# Base-branch scoping. The marker may restrict enforcement to specific base
# branches (default ["main"]). When we could resolve the base, only gate if it is
# in scope; an unresolved base falls through to gating (fail closed on the scope
# check, since the rest of the gate still fails open on its own errors).
BASES=$(jq -r '(.base_branches // ["main"]) | .[]' "$MARKER" 2>/dev/null)
if [ -n "$PRBASE" ]; then
  printf '%s\n' "$BASES" | grep -qxF "$PRBASE" || exit 0   # base not in scope -> allow
fi

# Load the pure validator (lives alongside this hook after install).
LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/merge-clearance-lib.sh"
[ -f "$LIB" ] || exit 0   # validator missing -> fail open
# shellcheck source=/dev/null
. "$LIB"

STAMP=$(cat "$GITDIR/merge-clearance-head" 2>/dev/null || echo "")
NOW=$(date +%s)
VERDICT=$(mc_stamp_valid "$STAMP" "$PRHEAD" "$NOW" 900)
[ "$VERDICT" = "valid" ] && exit 0

REASON="Merge gate: no valid merge-clearance for this PR HEAD (${PRHEAD:-unknown}) [${VERDICT}]. This repo requires the full pre-merge gauntlet before \`gh pr merge\`: CodeRabbit resolved + CI green + local /review + QA. Run /land-and-deploy (the sanctioned path) - it verifies all four, writes the clearance stamp, and posts the required GitHub check. To clear manually: \`~/.claude/scripts/merge-clearance.sh clear\` on the PR HEAD. A stale-head/expired verdict means the clearance no longer matches the current HEAD or its TTL lapsed; re-clear on the current HEAD."
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
