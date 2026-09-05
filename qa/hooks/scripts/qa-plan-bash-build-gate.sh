#!/bin/bash
# PostToolUse + PostToolUseFailure hook on Bash. Gate 1b of the QA-plan approval
# policy, and the other half of gate 1.
#
# THE HOLE THIS CLOSES. qa-plan-build-gate.sh is registered on Edit|MultiEdit|Write
# only, so source written through Bash reached no gate at all. The one Bash-matched
# hook was qa-plan-pr-gate.sh, which guards `gh pr create`, a completely different
# moment. Observed live on 2026-09-04 in ~/dev/tooling/local-bin on branch
# `mu-agents-terminal-default`: an agent edited three tracked source files
# (probe.py, inventory.sh, render.py) with `python3 - <<'PY'` heredocs and nothing
# fired. The gate spoke up only on the FOURTH edit, which happened to use Write.
# Its message was accurate; its coverage was not.
#
# Not an exotic path: under bypass-permissions mode the harness instructs agents
# to prefer Bash heredocs and `sed` over the edit tools, so for at least one live
# configuration the ungated route is the DEFAULT route.
#
# WHY IT OBSERVES INSTEAD OF PARSING. Deciding whether arbitrary shell writes
# tracked source is undecidable from the command string: the observed write lived
# inside an interpreter's source text at a path that may be computed, and
# PreToolUse cannot even expand "$VAR". A shell-shape matcher catches `sed -i` and
# `tee`, for which there is no incident, and misses the heredoc, for which there
# is. So the decision comes from what the repo OBSERVED changing, which is exact
# and blind to mechanism.
#
# WHAT THIS COSTS, AND WHAT IT CANNOT KNOW. Two separate limits, both real:
#
#   1. It runs AFTER the tool, so it INTERRUPTS rather than PREVENTS, and it never
#      reverts anything. The PR gate remains the hard backstop.
#   2. It knows that the dirty-source set differs from the snapshot taken at this
#      SESSION's previous Bash call. It does NOT know that the current command is
#      what changed it. A human editing in their editor, a background process, or
#      a `git stash pop` all surface on the next call. The block message is worded
#      to say what is actually known ("changed since the last Bash call"), never
#      "this command did it", because the earlier wording was a false claim and
#      its remediation advice was actively harmful after a merge or a stash pop.
#
# STATE IS KEYED BY SESSION, not just by branch. Two Claude sessions in one
# checkout previously shared a snapshot, so whichever hook fired first consumed
# the delta: the innocent session got blocked for the other's write and the
# writing session was never blocked at all. That is the inversion of the gate's
# purpose, so the snapshot file carries the session id.
#
# Output protocol (Claude Code PostToolUse / PostToolUseFailure hook):
#   exit 0 + empty stdout                          -> allow
#   stdout JSON {"decision":"block","reason":...}  -> the tool has already run;
#                                                     the reason is fed back to
#                                                     Claude as feedback.
#
# Fail-OPEN posture, matching every sibling gate: a missing dependency (jq/git),
# an unresolvable repo, an out-of-scope repo, or a detached HEAD leaves the call
# ALLOWED. But never SILENTLY: anything that turns an unknown into an allow is
# written to the gate log, because a check that quietly stops checking is how a
# dead feature survives a passing suite.

set -u

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

# ONE jq call for the scalars, and the command's FIRST LINE only. Four separate
# jq spawns plus three git spawns was most of this hook's per-call cost, and it
# is paid on every Bash tool call in every session.
{
  IFS= read -r EVENT
  IFS= read -r TOOL
  IFS= read -r CWD
  IFS= read -r SESSION
  IFS= read -r CMDLINE1
} < <(printf '%s' "$PAYLOAD" | jq -r '
  [ (.hook_event_name // ""), (.tool_name // ""), (.cwd // ""), (.session_id // ""),
    ((.tool_input.command // "") | split("\n")[0] // "") ] | .[]')

# PostToolUseFailure is registered too, and that is load-bearing rather than
# defensive. PostToolUse fires only for a SUCCESSFUL tool call, so
# `sed -i ... src/app.py && npm test` with a failing test wrote source and this
# hook never ran. Verified on CLI 2.1.261 by registering a probe on both events:
# a Bash call exiting non-zero fires PostToolUseFailure and not PostToolUse.
case "$EVENT" in PostToolUse|PostToolUseFailure|"") ;; *) exit 0 ;; esac
[ "$TOOL" = "Bash" ] || exit 0

# Resolve the repo the command targeted, honoring a leading `cd <dir>`.
#
# FIRST LINE ONLY. The extraction used to run over the whole command with a
# per-line anchor (sed applies `^` per line), so a `cd` on ANY line won: a
# heredoc writing a shell script whose body contains `cd /tmp` retargeted the
# gate to /tmp, where rev-parse fails and the call exits ungated. Writing shell
# scripts through heredocs is this gate's own use case, so that was
# self-defeating.
#
# The property is enforced TWICE, deliberately, and both halves are load-bearing
# to know about: the jq `split("\n")[0]` above, AND the `IFS= read -r CMDLINE1`
# that reads it, which stops at the first newline regardless. Mutation-tested:
# removing either one alone does not change behavior, so do not read a green
# suite as licence to delete the surviving one. Removing BOTH reopens the hole.
WORKDIR=$(printf '%s' "$CMDLINE1" | sed -nE 's/^[[:space:]]*cd[[:space:]]+([^[:space:];&|]+).*/\1/p')
case "$WORKDIR" in "~") WORKDIR="$HOME" ;; "~/"*) WORKDIR="${HOME}/${WORKDIR#\~/}" ;; esac
# A relative `cd` resolves against the SESSION cwd, not this hook process's cwd.
case "$WORKDIR" in
  ""|/*) ;;
  *) [ -n "$CWD" ] && WORKDIR="$CWD/$WORKDIR" ;;
esac
{ [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; } || WORKDIR="$CWD"
{ [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; } || WORKDIR="$PWD"

LIBDIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$LIBDIR/qa-plan-gate-lib.sh"
TLIB="$LIBDIR/qa-plan-token-lib.sh"
GPLIB="$LIBDIR/gate-policy-lib.sh"
{ [ -f "$LIB" ] && [ -f "$TLIB" ] && [ -f "$GPLIB" ]; } || {
  # A half-populated plugin cache version dir is an INSTALL error, not a routine
  # not-applicable, and this repo's own memory flags the cache as the thing that
  # actually executes. Log it without the library that is missing.
  printf '%s bash-build-gate FAIL-OPEN(libs-missing) dir=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LIBDIR" \
    >> "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/qa-plan-gate.log" 2>/dev/null
  exit 0
}
# shellcheck source=/dev/null
. "$LIB"
# shellcheck source=/dev/null
. "$TLIB"
# shellcheck source=/dev/null
. "$GPLIB"

LOG=$(qpt_gate_log)
# The log directory may not exist (a fresh machine, or CLAUDE_CONFIG_DIR pointing
# somewhere not yet created). Without this the append fails, and because
# `>> "$LOG" 2>/dev/null` opens the file while stderr is still real, the failure
# leaked a raw bash error into the transcript on every gated call while the line
# it was supposed to record was lost.
mkdir -p "$(dirname "$LOG")" 2>/dev/null
glog() { { printf '%s bash-build-gate %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; } 2>/dev/null || true; }

# ONE rev-parse for all three values instead of three spawns.
GITINFO=$(git -C "$WORKDIR" rev-parse --show-toplevel --absolute-git-dir --abbrev-ref HEAD 2>/dev/null) || exit 0
{ IFS= read -r TOP; IFS= read -r GITDIR; IFS= read -r BRANCH; } <<GITEOF
$GITINFO
GITEOF
{ [ -n "$TOP" ] && [ -n "$GITDIR" ]; } || exit 0
[ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || exit 0   # detached / unresolved -> allow

STAMPFILE="$GITDIR/qa-plan-approved"
# An existing-but-unreadable stamp collapses to "" and is then reported as
# "no stamp exists", whose remedy (run /qa:plan) can never clear it. Say so.
if [ -e "$STAMPFILE" ] && [ ! -r "$STAMPFILE" ]; then
  glog "stamp-unreadable path=$STAMPFILE branch=$BRANCH"
fi
STAMP=$(cat "$STAMPFILE" 2>/dev/null || echo "")
VERDICT=$(qpg_stamp_valid "$STAMP" "$BRANCH")

# Effective gate config; inherited by DEFAULT from the tracked ~/dev/gate-policy.json.
# Non-zero means the repo is genuinely out of scope -> allow.
MARKER=$(gp_gate_config "$TOP" qa-plan) || exit 0
qpg_gate_enabled "$MARKER" build || exit 0   # this IS the build gate, same switch
[ "$(qpg_base_in_scope "$MARKER" "$BRANCH")" = "in" ] && exit 0
qpg_is_spike "$BRANCH" >/dev/null && exit 0

# ---- state file ------------------------------------------------------------
# Keyed by the per-worktree git dir AND the session. See the header: sharing one
# file across sessions made the gate block the wrong session and miss the right
# one. Sanitized because the id is payload-supplied.
SESSION_KEY=$(printf '%s' "${SESSION:-nosession}" | tr -c 'A-Za-z0-9_.-' '_')
[ -n "$SESSION_KEY" ] || SESSION_KEY="nosession"
SNAP="$GITDIR/qa-plan-bash-snapshot-$SESSION_KEY"

# ---- observe ---------------------------------------------------------------
# -uall so a new untracked source FILE is seen individually; the default -unormal
# collapses an untracked directory to a bare "dir/" entry, and a directory is not
# a file to gate on. -uall does NOT finish that job: a NESTED REPOSITORY (a linked
# worktree, a submodule, a parked clone) still arrives collapsed however -u is
# set, so qpg_status_source_paths drops trailing-slash entries.
# core.quotePath=false so ordinary non-ASCII names arrive unquoted.
if ! STATUS=$(git -C "$WORKDIR" -c core.quotePath=false status --porcelain -uall 2>/dev/null); then
  # A TOTAL loss of gating, and it used to be silent while a strictly milder
  # degrade three lines below was logged. `status` exits non-zero on a corrupt
  # index, a `safe.directory` refusal (persistent: every call fails identically,
  # so the gate is permanently and invisibly off), a failing fsmonitor hook, or
  # `.git` on a stalled mount.
  glog "FAIL-OPEN(status-failed) branch=$BRANCH workdir=$WORKDIR"
  exit 0
fi
PATHS=$(qpg_status_source_paths "$STATUS")

NPATHS=0
[ -n "$PATHS" ] && NPATHS=$(printf '%s\n' "$PATHS" | grep -c '')

HASHER=""
command -v shasum    >/dev/null 2>&1 && HASHER="shasum -a 256"
[ -n "$HASHER" ] || { command -v sha256sum >/dev/null 2>&1 && HASHER="sha256sum"; }
DEGRADED=""
[ -n "$HASHER" ] || DEGRADED="no-sha256-tool"
[ "$NPATHS" -gt 200 ] && DEGRADED="${DEGRADED:+$DEGRADED,}too-many-paths=$NPATHS"
# MODE is recorded in the snapshot header and is not cosmetic. Degraded lines are
# `- <path>` and normal lines are `<digest> <path>`, so the instant the mode flips
# EVERY line differs verbatim and the delta reports every dirty path at once. That
# fired a block naming 200 files on a bare `ls`. A mode change is treated as "no
# baseline" below, which re-baselines quietly instead.
MODE="digest"; [ -n "$DEGRADED" ] && MODE="paths"
[ -n "$DEGRADED" ] && glog "delta-degraded($DEGRADED) branch=$BRANCH"

CURR=""
if [ -n "$PATHS" ]; then
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # A DIRECTORY here is a dirty SUBMODULE gitlink: the superproject reports it
    # as one path with no trailing slash, so the classifier's nested-repo rule
    # does not catch it. Skip it outright, for the same reason that rule exists:
    # the source inside belongs to that repo and is governed by that repo's own
    # hook. Recording it instead was worse than useless, because a directory
    # cannot be hashed, so it stored `- <path>` and every further edit inside the
    # already-dirty submodule produced a byte-identical line that never fired.
    [ -d "$TOP/$p" ] && continue
    d="-"
    if [ -z "$DEGRADED" ] && [ -f "$TOP/$p" ] && [ -r "$TOP/$p" ]; then
      d=$($HASHER "$TOP/$p" 2>/dev/null)
      d=${d%% *}
      if [ -z "$d" ]; then
        d="-"
        glog "hash-failed path=$p branch=$BRANCH"
      fi
    fi
    CURR="${CURR}${d} ${p}
"
  done <<PATHS_EOF
$PATHS
PATHS_EOF
fi
CURR=${CURR%$'\n'}

# ---- attribute -------------------------------------------------------------
HEADER="#branch $BRANCH mode=$MODE"
BASELINE="none"
PREV=""
if [ -r "$SNAP" ]; then
  if [ "$(head -1 "$SNAP" 2>/dev/null)" = "$HEADER" ]; then
    BASELINE="have"
    PREV=$(tail -n +2 "$SNAP" 2>/dev/null)
  fi
fi

DELTA=$(qpg_snapshot_delta "$PREV" "$CURR")
DISPOSITION=$(qpg_bash_build_disposition "$VERDICT" "$BASELINE" "$DELTA")

# Record the new state. UNCONDITIONALLY, including on the block path (otherwise
# every later call replays the same delta, which is the block storm that makes a
# gate unusable) and including when nothing is dirty (a header-only snapshot is
# what baselines a clean branch; without it the first source write on any clean
# branch was attributed to no baseline and allowed).
#
# The write is CHECKED. Every branch here used to be silent, and with the git dir
# unwritable the result was the block storm this code exists to prevent: call 1
# blocked correctly, and every call after it, `ls` included, reblocked forever
# with no clue why. A truncated write under ENOSPC is just as bad in the other
# direction. So a failure is logged AND surfaced in the block reason, which is the
# one moment anyone is looking.
snap_write() {
  local tmp
  tmp=$(mktemp "$GITDIR/.qa-plan-bash-snapshot.XXXXXX" 2>/dev/null) || return 1
  if { printf '%s\n' "$HEADER"; [ -n "$CURR" ] && printf '%s\n' "$CURR"; : ; } > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$SNAP" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}
SNAP_OK=1
snap_write || SNAP_OK=0
[ "$SNAP_OK" = 1 ] || glog "snapshot-write-failed snap=$SNAP branch=$BRANCH"

# A session establishing its first baseline is the one ALLOW worth recording: it
# can mean "source just changed and I am declining to attribute it". Also the
# natural moment to sweep this git dir's abandoned session snapshots, since it
# happens once per session per branch rather than per call.
if [ "$BASELINE" = "none" ]; then
  glog "baseline-established branch=$BRANCH session=$SESSION_KEY n=$NPATHS mode=$MODE"
  find "$GITDIR" -maxdepth 1 -name 'qa-plan-bash-snapshot-*' -mtime +7 -delete 2>/dev/null
  find "$GITDIR" -maxdepth 1 -name '.qa-plan-bash-snapshot.*' -mtime +1 -delete 2>/dev/null
fi

[ "$DISPOSITION" = "block" ] || exit 0

# ---- report ----------------------------------------------------------------
NCHANGED=$(printf '%s\n' "$DELTA" | grep -c '')
NAMES=$(printf '%s\n' "$DELTA" | cut -d' ' -f2- | head -12 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
[ "$NCHANGED" -gt 12 ] && NAMES="$NAMES, and $((NCHANGED - 12)) more"

glog "BLOCK branch=$BRANCH verdict=$VERDICT n=$NCHANGED files=$NAMES"

# The wording says only what the gate KNOWS. It used to assert "a Bash command
# just modified application source", which the mechanism cannot establish, and
# then advised "undo it yourself". After a `git stash pop`, `git merge`, `git
# rebase` or `git apply` that advice destroys work. Both are fixed here.
#
# No cached-stale-writer scan, unlike gates 1 and 2: that walk is already
# duplicated between those two and `qa-plan-stamp.sh doctor` reports the same
# thing on demand. Pointing at doctor beats a third copy.
REASON="QA-plan gate (Bash path): application source on \`$BRANCH\` changed since this session's previous Bash call, and the approval stamp for this branch is [${VERDICT}]. Changed: ${NAMES}. This gate reads what the repo observed rather than the command text, so source written through a heredoc, \`sed -i\`, \`tee\`, \`python3 -c\`, \`node -e\` or any other shell mechanism reaches it exactly as an Edit does. TWO THINGS IT CANNOT TELL YOU: it fires AFTER the write, so nothing was prevented and NOTHING HAS BEEN REVERTED for you; and it does not know that the command you just ran is what changed these files, only that they differ from the previous observation. If a \`git\` tree operation (stash pop, merge, rebase, cherry-pick, apply) or an edit made outside this session produced them, this is a false alarm and you should NOT undo anything. Otherwise: (1) run \`/qa:plan\` now, get the plan approved, and carry on; or (2) if that write was not meant to be part of this change, undo it yourself. $(qpg_block_advice "$VERDICT") Reading is not gated, and neither are docs, tests, config, data and build artifacts, ignored files, or anything outside the repo. For a genuine spike, branch as \`spike/<name>\`. $(qpg_override_hint)"
[ "$SNAP_OK" = 1 ] || REASON="$REASON WARNING: this gate could not record state at \`$SNAP\`, so it will repeat this message on every Bash call until that path is writable."
_BP_REF=$(qpg_build_procedure_ref "$MARKER")
[ -n "$_BP_REF" ] && REASON="$REASON (This repo also follows your workspace build procedure: $_BP_REF.)"
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
