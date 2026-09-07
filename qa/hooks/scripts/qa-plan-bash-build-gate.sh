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

# Logging BEFORE the libs are sourced. The paths that fail earliest (no jq, a
# half-populated plugin cache, an unparseable payload) are exactly the ones worth
# recording, and they cannot use qpt_gate_log because it lives in a lib they have
# not reached. Note the shapes: the directory is created first, and the append is
# GROUPED before `2>/dev/null`. Ungrouped, the redirection order opens the file
# while stderr is still real, so a missing directory leaks a raw bash error into
# the transcript AND loses the line. That bug was fixed in glog() and left behind
# in these two.
early_log() {
  # Nested default: with BOTH CLAUDE_CONFIG_DIR and HOME unset, `${X:-$HOME/...}`
  # aborts the whole hook under `set -u`, turning a log call into a crash.
  local d="${CLAUDE_CONFIG_DIR:-${HOME:-/tmp}/.claude}"
  mkdir -p "$d" 2>/dev/null
  { printf '%s bash-build-gate %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$d/qa-plan-gate.log"; } 2>/dev/null || true
}

PAYLOAD=$(cat)
if ! command -v jq >/dev/null 2>&1; then
  # The header promises no dependency turns into a silent allow. jq was the one
  # exception, and a raw printf needs no library, so there was no reason for it.
  early_log "FAIL-OPEN(jq-missing)"
  exit 0
fi

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
    ((.tool_input.command // "") | split("\n")[0] // "") ] | .[]' 2>/dev/null)
# stderr suppressed deliberately: on a malformed payload jq would otherwise print
# a raw parse error into the agent's transcript on every Bash call. The failure
# is not swallowed, it is detected below and logged.

# PostToolUseFailure is registered too, and that is load-bearing rather than
# defensive. PostToolUse fires only for a SUCCESSFUL tool call, so
# `sed -i ... src/app.py && npm test` with a failing test wrote source and this
# hook never ran. Verified on CLI 2.1.261 by registering a probe on both events:
# a Bash call exiting non-zero fires PostToolUseFailure and not PostToolUse.
case "$EVENT" in PostToolUse|PostToolUseFailure|"") ;; *) exit 0 ;; esac

# A TOOL that came back empty means the parse produced nothing, not that some
# other tool ran: jq failed, or the payload was malformed. `read` fills absent
# fields with empty strings, so this exits quietly rather than crashing under
# `set -u`, and that quiet exit is exactly the unlogged fail-open worth catching.
# Logged before the libs are sourced, so without the helper.
if [ -z "$TOOL" ]; then
  early_log "FAIL-OPEN(payload-parse) event=${EVENT:-none}"
  exit 0
fi
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
# QUOTED OPERANDS TOO. The bare-token pattern captured `"/path/repo` from
# `cd "/path/repo B" && ...`, so the directory test failed and the gate silently
# fell back to the session cwd, inspecting the wrong repo. One sed with an
# alternation rather than three passes, because this runs on every Bash call:
# exactly one of the three groups can match, so concatenating them yields the
# operand. The command text is matched, never evaluated.
_SQ=\'
WORKDIR=$(printf '%s' "$CMDLINE1" | sed -nE "s/^[[:space:]]*cd[[:space:]]+(\"([^\"]*)\"|${_SQ}([^${_SQ}]*)${_SQ}|([^[:space:];&|]+)).*/\2\3\4/p")
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
  # actually executes.
  early_log "FAIL-OPEN(libs-missing) dir=$LIBDIR"
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
# stderr is CAPTURED rather than discarded, so two very different causes can be
# told apart with no temp file and no second spawn. "not a git repository" is
# routine and must stay quiet, or every Bash call outside a repo writes a line.
# A missing `git`, or a `safe.directory` refusal, is a TOTAL and PERSISTENT loss
# of gating and must never be invisible.
#
# Deliberately NOT gated on a `$HOME/dev` path test. An earlier revision filtered
# the logging that way and reintroduced the exact blind spot this script removes
# elsewhere: a governed worktree parked outside ~/dev (a worktree of the ~/dev
# repo itself has to live outside it) would have been silently ungated.
# stderr is DISCARDED on the success path and re-read only on failure. An earlier
# revision used `2>&1` to classify the error, which contaminated the success path:
# git warns on stdout's neighbour for plenty of benign reasons (a fsmonitor
# notice, an advice.* hint), and any such line would shift this three-line
# protocol so TOP, GITDIR or BRANCH silently held the wrong value. A second spawn
# on the rare failure path is far cheaper than a wrong repo on the common one.
if ! GITINFO=$(git -C "$WORKDIR" rev-parse --show-toplevel --absolute-git-dir --abbrev-ref HEAD 2>/dev/null); then
  _gerr=$(git -C "$WORKDIR" rev-parse --show-toplevel 2>&1 >/dev/null)
  case "$_gerr" in
    *"dubious ownership"*|*"detected dubious"*)
      glog "FAIL-OPEN(safe-directory-refusal) workdir=$WORKDIR" ;;
    *)
      command -v git >/dev/null 2>&1 || glog "FAIL-OPEN(git-missing) workdir=$WORKDIR" ;;
  esac
  exit 0
fi
{ IFS= read -r TOP; IFS= read -r GITDIR; IFS= read -r BRANCH; } <<GITEOF
$GITINFO
GITEOF
{ [ -n "$TOP" ] && [ -n "$GITDIR" ]; } || exit 0
[ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || exit 0   # detached / unresolved -> allow

STAMPFILE="$GITDIR/qa-plan-approved"
# An existing-but-unreadable stamp collapses to "" and is then reported as
# "no stamp exists", whose remedy (approve a plan) can never clear it: the file
# is already there. Logging it was not enough, because the person who needs to
# know is reading the BLOCK, so it is carried into the reason as well.
STAMP_UNREADABLE=0
if [ -e "$STAMPFILE" ] && [ ! -r "$STAMPFILE" ]; then
  STAMP_UNREADABLE=1
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
# BOUNDED. The id is payload-supplied, and an overlong one would exceed NAME_MAX,
# making every snapshot write fail, which is the block-storm condition. Truncated
# rather than hashed because no hasher is guaranteed here. Two ids colliding
# after sanitising degrade to sharing one snapshot, which is the old behavior:
# noisier, never unsafe.
# Sanitised AND disambiguated. Truncation alone lets two ids sharing a 64-char
# prefix share one snapshot, and sanitising alone maps `a/b` and `a_b` together;
# either recreates the cross-session inversion this keying exists to prevent, so
# "noisier, never unsafe" would have been wrong. A cksum of the RAW id is
# appended whenever sanitising or truncating actually changed something, which
# for an ordinary UUID session id is never, so the common path costs no spawn.
SESSION_KEY=$(printf '%s' "${SESSION:-nosession}" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-64)
[ -n "$SESSION_KEY" ] || SESSION_KEY="nosession"
if [ -n "$SESSION" ] && [ "$SESSION_KEY" != "$SESSION" ]; then
  SESSION_KEY="${SESSION_KEY}-$(printf '%s' "$SESSION" | cksum | tr -cd '0-9')"
fi
# A payload with no session_id collapses every session onto one key, which
# silently restores the cross-session inversion this keying exists to fix. Say so
# rather than letting a harness change reintroduce it quietly.
[ -n "$SESSION" ] || glog "no-session-id branch=$BRANCH (snapshot shared across sessions)"

SNAP="$GITDIR/qa-plan-bash-snapshot-$SESSION_KEY"
# Fallback location, used only when the git dir cannot be written. Keyed by the
# git dir so two repos cannot collide. Read here as well as written below: a
# fallback that is written but never read leaves BASELINE="none" on every call,
# which is the gate silently off.
# The key carries a cksum of the FULL git dir, because sanitising alone collides
# readily: `/a/repo-b/.git` and `/a/repo/b/.git` both flatten to `_a_repo_b__git`,
# and a colliding fallback would then be read as another repo's baseline.
_SNAPKEY=$(printf '%s' "$GITDIR" | tr -c 'A-Za-z0-9' '_' | cut -c1-80)
_SNAPSUM=$(printf '%s' "$GITDIR" | cksum | tr -cd '0-9')
SNAP_FALLBACK="${TMPDIR:-/tmp}/qa-plan-bash-snapshot-${_SNAPKEY}-${_SNAPSUM}-${SESSION_KEY}"
# IF A FALLBACK EXISTS IT WINS, unconditionally. Two wrong versions preceded
# this, both caught by the regression test rather than by reading:
#   - "primary if readable" kept reading a FROZEN baseline, because `chmod a-w`
#     on the git dir leaves the old snapshot perfectly readable while every new
#     write goes to the fallback. The same delta replayed forever, so the storm
#     survived the fallback entirely.
#   - "newer wins" via `-nt` failed too: both files are written in the same
#     second, mtime compares equal, and `-nt` is false.
# The condition is "the git dir cannot be written", not "a fallback file exists".
# Existence alone let a stale or colliding fallback win even when the primary was
# perfectly writable. `-w` is one stat and is the actual thing being asked.
#
# Cost of being precise: when a git dir becomes writable again the primary is
# preferred immediately, and it is stale, so that one call can report a delta the
# fallback had already accounted for. A single spurious interrupt during a
# permissions recovery beats reading another repo's baseline indefinitely.
if [ ! -w "$GITDIR" ] && [ -r "$SNAP_FALLBACK" ]; then SNAP="$SNAP_FALLBACK"; fi

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
# NOT logged here. Written unconditionally it emitted one line per Bash call for
# as long as the repo stayed above the cap, growing an unrotated log at ~100x the
# rate of the Edit gate. It is emitted below instead, on the TRANSITION and when a
# baseline is established, which is once per state change rather than per call.
# `gp_warn_once` cannot help: it keys on $$ and every hook run is a new process.

CURR=""
HASH_SKIPPED=""
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
    elif [ -z "$DEGRADED" ]; then
      # NOT readable, or not a regular file (a broken symlink, a fifo, a file
      # inside a directory a build step chmod'd). This arm was silent, and its
      # silence defeats the whole point of digests: the entry records `- <path>`,
      # a second genuine write to that same already-dirty file produces a
      # byte-identical line, and the delta reports nothing. Reproduced with
      # `chmod 000`: block on the first write, ALLOW on the second.
      #
      # ACCUMULATED, not logged here. Logging inside the loop wrote a line per
      # unreadable path per Bash call for as long as the condition lasted, which
      # is the unbounded growth just removed from the degrade path. Emitted once
      # below, on the baseline or block line.
      HASH_SKIPPED="${HASH_SKIPPED:+$HASH_SKIPPED,}$p"
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
CMP_CURR="$CURR"
if [ -r "$SNAP" ]; then
  _hdr=$(head -1 "$SNAP" 2>/dev/null)
  _prev_branch=${_hdr#\#branch }; _prev_branch=${_prev_branch%% mode=*}
  _prev_mode=${_hdr##* mode=}
  if [ "$_prev_branch" = "$BRANCH" ]; then
    BASELINE="have"
    PREV=$(tail -n +2 "$SNAP" 2>/dev/null)
    # A MODE CHANGE MUST NOT DISCARD THE BASELINE. Treating it as "no baseline"
    # re-baselined quietly, which meant the very write that crossed the 200-path
    # threshold (or the call where a hasher went missing) was itself allowed. The
    # earlier code blocked there, noisily and wrongly; discarding the baseline
    # swapped a false positive for a false negative, which is the worse trade in
    # a gate. Instead, normalize BOTH sides to path-only and keep comparing: a
    # newly dirty path is still a delta, and only content-change detection is
    # lost for that one call.
    if [ "$_prev_mode" != "$MODE" ]; then
      PREV=$(printf '%s\n' "$PREV" | sed -E 's/^[^ ]+ /- /')
      CMP_CURR=$(printf '%s\n' "$CURR" | sed -E 's/^[^ ]+ /- /')
      glog "mode-transition from=$_prev_mode to=$MODE branch=$BRANCH${DEGRADED:+ degraded=$DEGRADED} (comparing on paths for this call)"
    fi
  fi
fi

DELTA=$(qpg_snapshot_delta "$PREV" "$CMP_CURR")
if [ $? -eq 2 ]; then
  # grep itself failed, so the empty delta means "could not tell", not "nothing
  # changed". Never let that read as an allow without a record.
  glog "FAIL-OPEN(delta-compare-failed) branch=$BRANCH"
fi
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
# NO `:` TERMINATOR. An earlier revision ended the group with `:` to stop the
# `[ -n "$CURR" ]` test leaking its status as the group's. That fixed one bug and
# created a worse one: `:` also masks a FAILING printf, so a write truncated by
# ENOSPC was installed as the baseline and reported as success. A truncated
# snapshot is worse than none, because missing lines read as a delta and produce
# a false block sourced from a partial write nobody logged.
#
# The shape below needs no terminator: with CURR empty the `[ -z ]` test is TRUE
# so the `||` short-circuits at status 0, and with CURR set the group's status is
# the second printf's. A failing first printf short-circuits the `&&`.
snap_write() {
  local tmp
  # mktemp beside the TARGET, not in $GITDIR: the fallback path below lives
  # elsewhere, and a temp file on a different filesystem would make `mv` a copy
  # (or fail), defeating the atomic replace.
  tmp=$(mktemp "$(dirname "$SNAP")/.qa-plan-bash-snapshot.XXXXXX" 2>/dev/null) || return 1
  if { printf '%s\n' "$HEADER" && { [ -z "$CURR" ] || printf '%s\n' "$CURR"; }; } > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$SNAP" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}
SNAP_OK=1
if ! snap_write; then
  # FALL BACK RATHER THAN GIVE UP. Checking the write stopped it lying, but left
  # an unwritable git dir with two failure shapes, both bad and opposite:
  #   - a snapshot already exists -> the same delta replays on every call, so
  #     `ls` blocks forever. That is the block storm, with a note attached.
  #   - no snapshot yet -> BASELINE is "none" every call, so every write is
  #     allowed. The gate is silently and completely OFF.
  # Both reproduced. Neither is acceptable, and the cause (an unwritable .git) is
  # not something this hook can fix. So state moves to a writable place instead:
  # keyed by the git dir so two repos cannot collide, and it is only a cache, so
  # losing it on reboot costs one baseline.
  SNAP="$SNAP_FALLBACK"
  if snap_write; then
    glog "snapshot-fallback gitdir-unwritable using=$SNAP branch=$BRANCH"
  else
    SNAP_OK=0
    glog "snapshot-write-failed snap=$SNAP branch=$BRANCH"
  fi
fi

# A session establishing its first baseline is the one ALLOW worth recording: it
# can mean "source just changed and I am declining to attribute it". Also the
# natural moment to sweep this git dir's abandoned session snapshots, since it
# happens once per session per branch rather than per call.
# Guarded on SNAP_OK, not just on BASELINE: with the write failing, this arm
# logged "baseline-established" on every single call while establishing nothing,
# which is the one line an operator reads as "the gate is working". It also ran
# both find sweeps per call in that state.
if [ "$BASELINE" = "none" ] && [ "$SNAP_OK" = 1 ]; then
  glog "baseline-established branch=$BRANCH session=$SESSION_KEY n=$NPATHS mode=$MODE${DEGRADED:+ delta-degraded=$DEGRADED}${HASH_SKIPPED:+ hash-skipped=$HASH_SKIPPED}"
  # 30 days, not 7: a session can sit open without making a Bash call, and
  # deleting its still-valid snapshot hands it a free baseline on its next write.
  # Scoped to one directory level and to these two reserved prefixes, so it
  # cannot wander the repo or touch the approval stamp.
  find "$GITDIR" -maxdepth 1 -name 'qa-plan-bash-snapshot-*' -mtime +30 -delete 2>/dev/null
  find "$GITDIR" -maxdepth 1 -name '.qa-plan-bash-snapshot.*' -mtime +1 -delete 2>/dev/null
  # The fallbacks live in TMPDIR, so the git-dir sweep never saw them and the
  # comment claiming they were swept was simply wrong. Same prefixes, same depth.
  find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'qa-plan-bash-snapshot-*' -mtime +30 -delete 2>/dev/null
  find "${TMPDIR:-/tmp}" -maxdepth 1 -name '.qa-plan-bash-snapshot.*' -mtime +1 -delete 2>/dev/null
fi

[ "$DISPOSITION" = "block" ] || exit 0

# ---- report ----------------------------------------------------------------
NCHANGED=$(printf '%s\n' "$DELTA" | grep -c '')
NAMES=$(printf '%s\n' "$DELTA" | cut -d' ' -f2- | head -12 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
[ "$NCHANGED" -gt 12 ] && NAMES="$NAMES, and $((NCHANGED - 12)) more"

glog "BLOCK branch=$BRANCH verdict=$VERDICT n=$NCHANGED files=$NAMES${HASH_SKIPPED:+ hash-skipped=$HASH_SKIPPED}"

# The wording says only what the gate KNOWS. It used to assert "a Bash command
# just modified application source", which the mechanism cannot establish, and
# then advised "undo it yourself". After a `git stash pop`, `git merge`, `git
# rebase` or `git apply` that advice destroys work. Both are fixed here.
#
# No cached-stale-writer scan, unlike gates 1 and 2: that walk is already
# duplicated between those two and `qa-plan-stamp.sh doctor` reports the same
# thing on demand. Pointing at doctor beats a third copy.
REASON="QA-plan gate (Bash path): application source on \`$BRANCH\` changed since this session's previous Bash call, and the approval stamp for this branch is [${VERDICT}]. Changed: ${NAMES}. This gate reads what the repo observed rather than the command text, so source written through a heredoc, \`sed -i\`, \`tee\`, \`python3 -c\`, \`node -e\` or any other shell mechanism reaches it exactly as an Edit does. TWO THINGS IT CANNOT TELL YOU: it fires AFTER the write, so nothing was prevented and NOTHING HAS BEEN REVERTED for you; and it does not know that the command you just ran is what changed these files, only that they differ from the previous observation. If a \`git\` tree operation (stash pop, merge, rebase, cherry-pick, apply) or an edit made outside this session produced them, this is a false alarm and you should NOT undo anything. Otherwise: (1) run \`/qa:qa-plan\` now, get the plan approved, and carry on; or (2) if that write was not meant to be part of this change, undo it yourself. $(qpg_block_advice "$VERDICT") Reading is not gated, and neither are docs, tests, config, data and build artifacts, ignored files, or anything outside the repo. For a genuine spike, branch as \`spike/<name>\`. $(qpg_override_hint)"
[ "$SNAP_OK" = 1 ] || REASON="$REASON WARNING: this gate could not record state at \`$SNAP\`, so it will repeat this message on every Bash call until that path is writable."
[ "$STAMP_UNREADABLE" = 1 ] && REASON="$REASON NOTE: an approval stamp FILE exists at \`$STAMPFILE\` but could not be read (permissions, or a truncated write), which is why the verdict above reads as though none exists. Approving a new plan will not clear this; fix the file's readability or remove it first."
_BP_REF=$(qpg_build_procedure_ref "$MARKER")
[ -n "$_BP_REF" ] && REASON="$REASON (This repo also follows your workspace build procedure: $_BP_REF.)"
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
