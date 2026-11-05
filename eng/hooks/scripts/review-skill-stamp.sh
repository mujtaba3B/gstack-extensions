#!/bin/bash
# PostToolUse hook on Bash. When the gstack /review skill records its completion
# (it runs `gstack-review-log '{"skill":"review",...}'` at the end of a full
# review pass), record the current HEAD as reviewed in <git-dir>/review-skill-head.
#
# The ship gate reads this stamp for its review dimension. Keying off the completion log line (not the
# Skill-tool invocation) means an interrupted /review does NOT stamp.
#
# Output protocol: exit 0 always (PostToolUse, no decision to make here).

set -u

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty')
# Stamp only on the /review skill's own completion log line: a gstack-review-log
# call carrying the eng-review marker "skill":"review". Requiring both tokens
# keeps a PR body or commit message that merely mentions the command from
# stamping. ("skill":"adversarial-review" does not contain "skill":"review", so
# the mid-review adversarial log line is correctly ignored.)
printf '%s' "$CMD" | grep -q 'gstack-review-log' || exit 0
# Tolerate both single-quoted JSON ("skill":"review") and double-quoted/escaped
# JSON (\"skill\":\"review\") forms, since a caller may write the log line either
# way; the \\? allows an optional backslash before each quote.
printf '%s' "$CMD" | grep -Eq '\\?"skill\\?"[[:space:]]*:[[:space:]]*\\?"review\\?"' || exit 0

# Resolve the repo the command actually targets. Without this, a worktree or
# cross-repo /review would otherwise stamp the wrong repo. Honor a leading
# `cd <dir>` prefix; fall back to the payload cwd when there is none. --absolute-git-dir
# keeps the stamp path correct even when WORKDIR differs from the hook cwd.
WORKDIR=$(printf '%s\n' "$CMD" | sed -nE 's/^[[:space:]]*cd[[:space:]]+([^[:space:];&|]+).*/\1/p' | head -1)
case "$WORKDIR" in "~") WORKDIR="$HOME" ;; "~/"*) WORKDIR="${HOME}/${WORKDIR#\~/}" ;; esac
# The session's directory comes from the payload: a hook process can run from the
# main checkout while the session sits in a worktree.
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty')
{ [ -n "$CWD" ] && [ -d "$CWD" ]; } || CWD="$PWD"
# A relative `cd` resolves against the SESSION directory, not this hook process's.
case "$WORKDIR" in ""|/*) ;; *) WORKDIR="$CWD/$WORKDIR" ;; esac
{ [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; } || WORKDIR="$CWD"

GITDIR=$(git -C "$WORKDIR" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
HEAD=$(git -C "$WORKDIR" rev-parse HEAD 2>/dev/null) || exit 0
printf '%s\n' "$HEAD" > "$GITDIR/review-skill-head" 2>/dev/null || true
exit 0
