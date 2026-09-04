#!/bin/bash
# PostToolUse hook on Bash. Gate 1b of the QA-plan approval policy, and the other
# half of gate 1.
#
# THE HOLE THIS CLOSES. qa-plan-build-gate.sh is registered on Edit|MultiEdit|Write
# only, so source written through Bash never reached a gate at all. The one
# Bash-matched hook was qa-plan-pr-gate.sh, which guards `gh pr create`, a
# completely different moment. Observed live on 2026-09-04 in
# ~/dev/tooling/local-bin on branch `mu-agents-terminal-default`: an agent edited
# three tracked source files (probe.py, inventory.sh, render.py) with
# `python3 - <<'PY'` heredocs and nothing fired. The gate spoke up only on the
# FOURTH edit, which happened to use the Write tool for a new file. Its message
# was accurate; its coverage was not.
#
# This is not an exotic path. Under bypass-permissions mode the harness instructs
# agents to prefer Bash heredocs and `sed` over the edit tools, so for at least
# one live configuration the ungated route is the DEFAULT route.
#
# WHY PostToolUse AND NOT A PreToolUse PARSER. To block this before the write you
# would have to decide, from the command string alone, whether arbitrary shell
# writes tracked source. The observed case is precisely the undecidable one: the
# write is inside an interpreter's source text, at a path that may be computed,
# read from argv, or built in a loop. A shell-shape matcher catches `sed -i`,
# `tee` and `cat > f`, for which there is no incident, and misses the heredoc,
# for which there is. It also cannot resolve `"$VAR"`, because PreToolUse sees
# the RAW command string.
#
# So the decision is made from what the VCS OBSERVED. That is exact and blind to
# mechanism: heredocs, `-c`, `-e`, `eval`, base64, `xargs`, a Makefile, and a
# script the command merely invoked all land identically, with no special case
# for any of them. Read-only commands change nothing and therefore cannot fire.
#
# WHAT THAT COSTS, STATED PLAINLY: the write has already happened when this runs.
# PostToolUse cannot un-write it, so this INTERRUPTS, it does not PREVENT, and it
# never reverts anything on its own. The hard invariant is unaffected (the PR
# gate still refuses `gh pr create` on an unstamped branch); the soft invariant
# goes from nothing firing at all to an immediate interrupt naming the files. On
# the 2026-09-04 incident that is a block at file #1 instead of file #4.
# docs/build-gate-coverage.md is the full statement of what both halves of the
# build gate do and do not intercept.
#
# Output protocol (Claude Code PostToolUse hook):
#   exit 0 + empty stdout                          -> allow
#   stdout JSON {"decision":"block","reason":...}  -> the tool has already run;
#                                                     the reason is fed back to
#                                                     Claude as feedback.
#
# Fail-OPEN posture, matching every sibling gate: a missing dependency (jq/git),
# an unresolvable repo, an out-of-scope repo, a detached HEAD, or an unreadable
# snapshot all leave the call ALLOWED. A local gate that fails closed on its own
# bug trains the human to rip it out.

set -u

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty')
case "$EVENT" in PostToolUse|"") ;; *) exit 0 ;; esac

TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty')

# Resolve the repo the command targeted, honoring a leading `cd <dir>`, the same
# shape qa-plan-pr-gate.sh uses so the two can never disagree about which repo a
# `cd ... &&` refers to. A command that writes into a DIFFERENT repo than this
# one is not seen; that limit is documented rather than papered over.
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty')
WORKDIR=$(printf '%s\n' "$CMD" | sed -nE 's/^[[:space:]]*cd[[:space:]]+([^[:space:];&|]+).*/\1/p' | head -1)
case "$WORKDIR" in "~") WORKDIR="$HOME" ;; "~/"*) WORKDIR="${HOME}/${WORKDIR#\~/}" ;; esac
{ [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; } || WORKDIR="$CWD"
{ [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; } || WORKDIR="$PWD"

TOP=$(git -C "$WORKDIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
# No path pre-filter: gp_gate_config below makes the whole scope decision, and a
# duplicate path-only test would wrongly exempt a worktree parked outside ~/dev.

LIBDIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$LIBDIR/qa-plan-gate-lib.sh"
TLIB="$LIBDIR/qa-plan-token-lib.sh"
GPLIB="$LIBDIR/gate-policy-lib.sh"
{ [ -f "$LIB" ] && [ -f "$TLIB" ] && [ -f "$GPLIB" ]; } || exit 0
# shellcheck source=/dev/null
. "$LIB"
# shellcheck source=/dev/null
. "$TLIB"
# shellcheck source=/dev/null
. "$GPLIB"

BRANCH=$(git -C "$WORKDIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
[ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || exit 0   # detached / unresolved -> allow

GITDIR=$(git -C "$WORKDIR" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
STAMP=$(cat "$GITDIR/qa-plan-approved" 2>/dev/null || echo "")
VERDICT=$(qpg_stamp_valid "$STAMP" "$BRANCH")

# CHEAPEST DISCRIMINATOR FIRST, and taken FROM the decision function rather than
# rewritten inline. This hook fires on EVERY Bash call, and the overwhelmingly
# common case is a branch whose plan is already approved, where no snapshot is
# needed and the call should cost nothing beyond the rev-parses above. Asking the
# function whether the verdict ALONE already allows (holding the other two inputs
# at their most block-favouring values) keeps that shortcut honest: writing
# `[ "$VERDICT" = valid ] && exit 0` here would put a second, unverifiable copy
# of that arm in the I/O script, which is the shape this repo has been bitten by.
if [ "$(qpg_bash_build_disposition "$VERDICT" have probe)" = "allow-stamped" ]; then
  exit 0
fi

# Effective gate config; inherited by DEFAULT from the tracked ~/dev/gate-policy.json,
# so a fresh worktree or clone is gated like its main checkout. Non-zero means the
# repo is genuinely out of scope -> allow.
MARKER=$(gp_gate_config "$TOP" qa-plan) || exit 0
qpg_gate_enabled "$MARKER" build || exit 0   # this IS the build gate, same switch

# On a base branch itself there is no feature work to gate here.
[ "$(qpg_base_in_scope "$MARKER" "$BRANCH")" = "in" ] && exit 0
# Spike escape hatch, identical to gate 1's.
qpg_is_spike "$BRANCH" >/dev/null && exit 0

LOG=$(qpt_gate_log)

# ---- observe ---------------------------------------------------------------
# -uall so a new untracked source FILE is seen individually; the default -unormal
# collapses an untracked directory to a bare "dir/" entry, whose empty basename
# would classify as source and fire on a directory rather than a file.
# core.quotePath=false so ordinary non-ASCII names arrive unquoted.
STATUS=$(git -C "$WORKDIR" -c core.quotePath=false status --porcelain -uall 2>/dev/null) || exit 0
PATHS=$(qpg_status_source_paths "$STATUS")

NPATHS=0
[ -n "$PATHS" ] && NPATHS=$(printf '%s\n' "$PATHS" | grep -c '' )

# Content digests, not a bare path list: see qpg_snapshot_delta. Degrade to
# path-only comparison rather than silently doing nothing when digesting is not
# possible, and LOG the degrade, because a check that quietly stops checking is
# how a dead feature survives a passing suite.
HASHER=""
command -v shasum    >/dev/null 2>&1 && HASHER="shasum -a 256"
[ -n "$HASHER" ] || { command -v sha256sum >/dev/null 2>&1 && HASHER="sha256sum"; }
DEGRADED=""
[ -n "$HASHER" ] || DEGRADED="no-sha256-tool"
# A branch carrying hundreds of dirty source files is already outside this gate's
# design point; bound the work instead of hashing without limit.
[ "$NPATHS" -gt 200 ] && DEGRADED="too-many-paths=$NPATHS"
[ -n "$DEGRADED" ] && printf '%s bash-build-gate delta-degraded(%s) branch=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DEGRADED" "$BRANCH" >> "$LOG" 2>/dev/null

CURR=""
if [ -n "$PATHS" ]; then
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    d="-"
    if [ -z "$DEGRADED" ] && [ -r "$TOP/$p" ]; then
      d=$($HASHER "$TOP/$p" 2>/dev/null | cut -d' ' -f1)
      [ -n "$d" ] || d="-"
    fi
    CURR="${CURR}${d} ${p}
"
  done <<PATHS_EOF
$PATHS
PATHS_EOF
fi
CURR=${CURR%$'\n'}

# ---- attribute -------------------------------------------------------------
# The snapshot is keyed to the per-worktree git dir (like the stamp and the
# token), and carries the branch it was taken on so a branch switch cannot be
# read as a delta.
SNAP="$GITDIR/qa-plan-bash-snapshot"
BASELINE="none"
PREV=""
if [ -r "$SNAP" ]; then
  if [ "$(head -1 "$SNAP" 2>/dev/null)" = "#branch $BRANCH" ]; then
    BASELINE="have"
    PREV=$(tail -n +2 "$SNAP" 2>/dev/null)
  fi
fi

DELTA=$(qpg_snapshot_delta "$PREV" "$CURR")
DISPOSITION=$(qpg_bash_build_disposition "$VERDICT" "$BASELINE" "$DELTA")

# Record the new state UNCONDITIONALLY, including on the block path AND when
# there is nothing dirty to record. Two separate reasons, both load-bearing:
#
#   - On the block path: without it, every subsequent Bash call would re-report
#     the same delta, which is the block storm that makes a gate unusable. One
#     interrupt per new change, not one per call.
#   - On a CLEAN tree: a header-only snapshot is what establishes the baseline
#     for a branch nobody has dirtied yet. Skipping it leaves BASELINE="none" on
#     the next call, so the FIRST source write on a clean branch is attributed to
#     no baseline and allowed. That is this gate's own hole, reopened.
#
# The `[ -n "$CURR" ]` test must therefore not be the last command in the group:
# as written with `&&`, its exit status became the group's, the mv was skipped
# and the `|| rm -f` deleted the temp, silently. Caught by a trace, not by a
# test, because the first test written for it happened to dirty the tree first.
if TMP=$(mktemp "$GITDIR/.qa-plan-bash-snapshot.XXXXXX" 2>/dev/null); then
  {
    printf '#branch %s\n' "$BRANCH"
    [ -n "$CURR" ] && printf '%s\n' "$CURR"
    :
  } > "$TMP" 2>/dev/null
  mv -f "$TMP" "$SNAP" 2>/dev/null || rm -f "$TMP" 2>/dev/null
fi

[ "$DISPOSITION" = "block" ] || exit 0

# ---- report ----------------------------------------------------------------
NCHANGED=$(printf '%s\n' "$DELTA" | grep -c '')
NAMES=$(printf '%s\n' "$DELTA" | cut -d' ' -f2- | head -12 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
[ "$NCHANGED" -gt 12 ] && NAMES="$NAMES, and $((NCHANGED - 12)) more"

printf '%s bash-build-gate BLOCK branch=%s verdict=%s n=%s files=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$VERDICT" "$NCHANGED" "$NAMES" >> "$LOG" 2>/dev/null

# No cached-stale-writer scan here, unlike gates 1 and 2. That walk exists to
# catch a pre-token stamp writer, it is already duplicated between those two, and
# `qa-plan-stamp.sh doctor` reports the same thing on demand. Pointing at doctor
# beats a third copy.
REASON="QA-plan gate (Bash path): a Bash command just modified application source on \`$BRANCH\`, and the approval stamp for this branch is [${VERDICT}]. Changed: ${NAMES}. This gate reads what the repo actually observed rather than the command text, so source written through a heredoc, \`sed -i\`, \`tee\`, \`python3 -c\`, \`node -e\` or any other shell mechanism reaches it exactly as an Edit does. IMPORTANT: this fires AFTER the write, so nothing was prevented and NOTHING HAS BEEN REVERTED for you. Two ways forward: (1) run \`/qa:plan\` now, get the plan approved, and carry on with the work you just started; or (2) if that write was not meant to be part of this change, undo it yourself (restore the tracked files from HEAD, delete the new ones). $(qpg_block_advice "$VERDICT") Reading is never gated, and neither are docs, tests, config, ignored files, or anything outside the repo. For a genuine spike where the plan cannot be written yet, branch as \`spike/<name>\`. $(qpg_override_hint)"
_BP_REF=$(qpg_build_procedure_ref "$MARKER")
[ -n "$_BP_REF" ] && REASON="$REASON (This repo also follows your workspace build procedure: $_BP_REF.)"
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
