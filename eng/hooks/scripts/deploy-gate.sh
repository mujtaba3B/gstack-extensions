#!/bin/bash
# deploy-gate - make a deploy ceremony the only way code reaches a host.
#
# The merge side of this plugin has been gated for a while: pr-merge-gate.sh
# refuses a bare `gh pr merge`, so /land-and-deploy is the single CLI merge path.
# The DEPLOY side had nothing. Every PreToolUse guard on the machine matched
# `gh pr merge` or `gh pr create`; a grep for deploy.sh / kickstart / deploy-mini
# across every hooks/scripts dir returned zero files. So "/land-and-deploy is the
# only way a PR reaches main AND production" was one sentence covering two things,
# only the first of which was enforced.
#
# The cost, 2026-07-24: a hand-rolled ssh deploy to the Mac mini skipped the
# upgrade-marker stamp, tripped nanoclaw's version tripwire, and the host
# crash-looped behind a 900s circuit breaker for 16h46m across 72 failed starts.
# Nothing was bypassed, because nothing was in the path. The agent was in fact
# FOLLOWING the repo's own CLAUDE.md, which documented the bare sequence.
#
# This hook is both the sentinel and the gate (like land-deploy-sentinel.sh it is
# wired to three events, and the payload says which):
#   - PreToolUse on Skill        (ARM) : /land-and-deploy or /eng:deploy invoked.
#   - UserPromptSubmit           (ARM) : the user typed one of those at the prompt.
#   - PreToolUse on Bash         (GATE): block a deploy-shaped command unless this
#                                        session is armed; slide the window if it is.
#
# It arms its OWN kind ("deploy") rather than reusing land-deploy-sentinel.sh's
# "land". That separation is load-bearing in one direction: a /eng:deploy must
# never be able to authorize a `gh pr merge`. Arming "land" here would have let
# the merge gate's Bash-mint path fire off a deploy-only ceremony.
#
# WHY /eng:deploy exists at all: gstack has no /deploy, and /land-and-deploy
# hard-stops once a PR is merged ("nothing to deploy, run /canary"). Retry after a
# failed deploy, recovery after a host wedge, and a --rebuild-base rerun are all
# real and all PR-less. Without a second ceremony this gate would have no path for
# them and the override below would become the routine deploy path, which is just
# the ungated state with extra typing.
#
# Opt-in: enforces only in a repo carrying a `.deploy-gate.json` marker at its
# root. Every other ~/dev repo is untouched, so a bug here cannot brick deploys
# fleet-wide.
#
# Output protocol (Claude Code PreToolUse hook):
#   exit 0 + empty stdout                          -> allow
#   stdout JSON {"decision":"block","reason":...}  -> block, reason shown to Claude
#
# Fail-open posture, matching every sibling gate: a missing dependency (jq/git),
# an unreadable marker, or an unresolvable repo leaves the command ALLOWED. A
# local gate that fails closed on its own bug trains the human to rip it out. This
# is an accident-guard, not an adversary-proof sandbox: a plain terminal outside
# Claude Code is invisible to any PreToolUse hook, and the arm window slides while
# a session stays active in ~/dev.

set -u

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

# Shared libs, resolved relative to THIS script so the executing copy binds its own
# deps. Missing -> exit quietly (fail open), like every other unmet dependency.
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

# Same idle budget and sliding behavior as the merge sentinel. A real
# /land-and-deploy runs long (merge -> wait on CI -> deploy), and only the Skill /
# prompt events can arm, so without sliding the window would lapse before the
# deploy step ever ran. Only an idle gap longer than ARM_TTL lapses it.
ARM_TTL=1800
ARM_DIR="${TMPDIR:-/tmp}"
arm_session()      { ga_arm         "deploy" "$SESSION" "$ARM_DIR" "$(date +%s)"; }
deploy_armed_fresh() { ga_armed_fresh "deploy" "$SESSION" "$ARM_DIR" "$(date +%s)" "$ARM_TTL"; }

# Escape a literal string for use inside an ERE (hosts and script names carry dots
# and dashes; an unescaped dot would match any character).
ere_escape() { printf '%s' "$1" | sed -e 's/[][\.^$*+?(){}|\\/]/\\&/g'; }

case "$EVENT" in
  PreToolUse)
    TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')
    ;;
  UserPromptSubmit)
    TOOL=""
    ;;
  *)
    exit 0 ;;
esac

# ---------------------------------------------------------------- ARM branches --
# Never block; they only record that a deploy ceremony is in flight this session.

if [ "$EVENT" = "PreToolUse" ] && [ "$TOOL" = "Skill" ]; then
  # Match the basename (exact, namespaced, or path form). Liberal on purpose: a
  # missed match false-BLOCKS a real ceremony at deploy time, the costlier error.
  SKILL=$(printf '%s' "$PAYLOAD" | jq -r '
    (.tool_input.skill // .tool_input.name // .tool_input.command // "") | ascii_downcase' 2>/dev/null)
  case "$SKILL" in
    land-and-deploy|*:land-and-deploy|*/land-and-deploy) arm_session ;;
    deploy|*:deploy|*/deploy)                            arm_session ;;
  esac
  exit 0
fi

if [ "$EVENT" = "UserPromptSubmit" ]; then
  PROMPT=$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty')
  # Require the prompt to START with the command as a whole token, so
  # "/land-and-deployer" or prose like "should I /eng:deploy?" does not arm.
  if printf '%s' "$PROMPT" | grep -Eiq '^[[:space:]]*/(land-and-deploy|eng:deploy)([[:space:]]|$)'; then
    arm_session
  fi
  exit 0
fi

# ----------------------------------------------------------------- GATE branch --

[ "$TOOL" = "Bash" ] || exit 0
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty')
[ -n "$CMD" ] || exit 0

# Resolve the repo the command actually targets, the SAME way pr-merge-gate.sh and
# land-deploy-sentinel.sh do, so the three can never disagree about which repo a
# `cd <dir> && ...` refers to. Out of ~/dev scope -> allow.
WORKDIR=$(sg_workdir_from_cmd "$CMD" "$CWD")
RESOLVED=$(sg_dev_repo_gitdir "$WORKDIR") || exit 0
TOP=${RESOLVED%%$'\t'*}

# Armed -> allow, and SLIDE the window forward so an actively-working ceremony
# keeps itself armed for its whole run. Checked before the matcher because an
# armed session allows everything anyway, and sliding should track real activity
# in the repo rather than only deploy commands.
if deploy_armed_fresh; then
  arm_session
  exit 0
fi

# Opt-in marker. Absent -> this repo is not gated -> allow.
MARKER="$TOP/.deploy-gate.json"
[ -f "$MARKER" ] || exit 0

# ---- Tier 1: the repo's declared deploy entrypoint --------------------------
# Basenames come from the marker's `deploy_commands` when set, else are derived
# from deploy.json's `.deploy.command` (the same field `devops lad-config` reads)
# plus the conventional scripts/deploy*.sh family. Deriving rather than hardcoding
# keeps the gate correct for repos whose entrypoint is named something else.
NAMES=$(jq -r '(.deploy_commands // []) | .[]' "$MARKER" 2>/dev/null)
if [ -z "$NAMES" ]; then
  NAMES=$(jq -r '.deploy.command // "scripts/deploy.sh"' "$TOP/deploy.json" 2>/dev/null || echo "scripts/deploy.sh")
fi
ALT=""
while IFS= read -r n; do
  [ -n "$n" ] || continue
  ALT="${ALT:+$ALT|}$(ere_escape "$(basename "$n")")"
done <<EOF
$NAMES
EOF
# The deploy-mini family is always in scope: deploy.sh is a thin wrapper over it,
# and running the inner script directly is exactly the fragmenting that orphaned a
# stash in a prior incident.
ALT="${ALT:+$ALT|}deploy-[A-Za-z0-9_-]+\\.sh"

# Matched per SEGMENT, not against the whole command. A single regex over the
# whole string cannot tell which invocation an argument belongs to, so
# `scripts/deploy.sh --dry-run && scripts/deploy.sh --force` read as read-only on
# the strength of the FIRST invocation's flag and let the second one deploy. Every
# invocation is now judged on its own argument list.
#
# Anchored at segment start, tolerating leading env assignments, a
# `bash`/`sh`/`exec` prefix, and any leading path.
T1_RE="^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*((bash|sh|exec)[[:space:]]+)*([^[:space:]]*/)?(${ALT})([[:space:]]|\$)"
RO_RE='(^|[[:space:]])(check|--status|--dry-run)([[:space:]]|$)'

# ---- Tier 2: the hand-rolled ssh shape (the 2026-07-24 incident) -------------
# Fires only on an ssh to a host the marker lists AND a mutating verb, so
# read-only diagnostics over the same ssh stay allowed. Hosts are listed
# explicitly rather than derived: deploy.json carries a where-things-run host id
# ("mac-mini"), not the ssh hostname ("mutwos-mac-mini").
HOSTS=$(jq -r '(.hosts // []) | .[]' "$MARKER" 2>/dev/null)
HOST_ALT=""
while IFS= read -r h; do
  [ -n "$h" ] || continue
  HOST_ALT="${HOST_ALT:+$HOST_ALT|}$(ere_escape "$h")"
done <<EOF
$HOSTS
EOF
# Each verb carries a trailing boundary, so `pnpm run builder` and
# `git pull-request` are not mutating verbs. Without it, ordinary remote commands
# that merely START with a verb's spelling read as deploys.
MUTATING_RE='(git[[:space:]]+pull|pnpm[[:space:]]+run[[:space:]]+build|npm[[:space:]]+run[[:space:]]+build|launchctl[[:space:]]+kickstart|systemctl([[:space:]]+--user)?[[:space:]]+restart)([[:space:]]|$)'

# Split the command into segments at shell separators, so each invocation can be
# judged on its own arguments.
#
# QUOTE-AWARE on purpose. A plain sed split also cuts at separators INSIDE a
# quoted argument, which shreds exactly the payload tier 2 needs to read: the
# `&&` in `ssh host 'cd ~/nanoclaw && git pull && pnpm run build'` is part of the
# REMOTE command, not a local separator, and splitting there left a first segment
# with no mutating verb in it. A `#` outside quotes starts a comment and ends the
# line; inside quotes it is ordinary text.
segments() {
  printf '%s' "$1" | awk '{
    n = length($0); q = ""; seg = "";
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1);
      if (q != "") { seg = seg c; if (c == q) q = ""; continue }
      if (c == "\047" || c == "\"") { q = c; seg = seg c; continue }
      if (c == ";" || c == "&" || c == "|" || c == "(" || c == ")") { print seg; seg = ""; continue }
      if (c == "#") break;
      seg = seg c;
    }
    print seg;
  }'
}

# ssh_payload <segment> : echo "<host>\t<remote command>" for an ssh invocation,
# or return 1. The remote command is the QUOTED argument when there is one, so a
# locally chained command after a read-only ssh (`ssh host 'tail log' ; git pull`)
# cannot masquerade as a hand-rolled deploy. Scoping the host this way also stops
# a host name appearing incidentally elsewhere in the command from matching.
ssh_payload() {
  local after host rest
  after=$(printf '%s' "$1" | sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:]]*\/)?ssh[[:space:]]+(.*)$/\3/p')
  [ -n "$after" ] || return 1
  # Skip ssh flags to reach the host token. A flag taking a value consumes it too.
  while :; do
    case "$after" in
      -[pilo]*[[:space:]]*) after=${after#* }; after=${after#* } ;;
      -*)                   after=${after#* } ;;
      *) break ;;
    esac
    [ -n "$after" ] || return 1
  done
  host=${after%% *}
  rest=${after#* }
  [ -n "$host" ] || return 1
  [ "$rest" = "$after" ] && rest=""      # host with no remote command
  case "$rest" in
    \'*) rest=${rest#\'}; rest=${rest%%\'*} ;;
    \"*) rest=${rest#\"}; rest=${rest%%\"*} ;;
  esac
  printf '%s\t%s' "$host" "$rest"
}

SHAPE=""
DEPLOY_SEG=0
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  # Tier 1: this segment invokes the declared entrypoint.
  if printf '%s' "$seg" | grep -Eq "$T1_RE"; then
    DEPLOY_SEG=1
    # A read-only invocation is never gated: a retry follows a failure, and
    # diagnosing that failure must not require a ceremony. The flag has to be in
    # THIS invocation's own arguments.
    printf '%s' "$seg" | grep -Eq "$RO_RE" || { SHAPE="entrypoint"; break; }
    continue
  fi
  # Tier 2: this segment is an ssh to a listed host whose REMOTE command mutates.
  [ -n "$HOST_ALT" ] || continue
  hp=$(ssh_payload "$seg") || continue
  h=${hp%%$'\t'*}; rc=${hp#*$'\t'}
  printf '%s' "$h"  | grep -Eq "(${HOST_ALT})" || continue
  printf '%s' "$rc" | grep -Eq "$MUTATING_RE" || continue
  SHAPE="hand-rolled"
  break
done <<EOF
$(segments "$CMD")
EOF

[ -n "$SHAPE" ] || exit 0

# Break-glass. Deliberately verbose and reason-carrying so it reads as an
# exception in a transcript rather than a shortcut. /eng:deploy, not this, is the
# routine path for a PR-less deploy.
#
# ANCHORED at command position, like every other matcher here. As a bare substring
# search this was a total gate defeat: the literal text `DEPLOY_GATE_OVERRIDE=x`
# anywhere in the command authorized the bypass with no variable ever being set,
# so `ssh host "git commit -m 'DEPLOY_GATE_OVERRIDE=oops' && git pull && pnpm run
# build"` walked straight through the gate this exists to enforce.
if printf '%s' "$CMD" | grep -Eq "(^|[;&|(])[[:space:]]*DEPLOY_GATE_OVERRIDE=([\"'][^\"']+[\"']|[^[:space:]]+)([[:space:]]|\$)"; then
  exit 0
fi

if [ "$SHAPE" = "hand-rolled" ]; then
  REASON="Deploy gate: this is a hand-rolled deploy (an ssh to a deploy host carrying a build/pull/restart), and no deploy ceremony is running in this session. A hand-rolled deploy is what caused the 2026-07-24 outage: it skips the upgrade-marker stamp that deploy-mini.sh performs, so the host's version tripwire rejects every boot and it crash-loops behind a 900s circuit breaker (16h46m, unnoticed). Deploy through a ceremony instead: /land-and-deploy to merge a PR and deploy it, or /eng:deploy to deploy what is already on main (retry, recovery, --rebuild-base). Both run the repo's scripts/deploy.sh, which stamps the marker and then gates on devops check. Read-only ssh (logs, launchctl list) is never blocked."
else
  REASON="Deploy gate: this repo's deploy entrypoint was invoked directly, with no deploy ceremony running in this session. Deploys go through a ceremony so the run is verified rather than merely started: /land-and-deploy to merge a PR and deploy it, or /eng:deploy to deploy what is already on main (retry after a failed deploy, recovery, --rebuild-base). Both end in devops check, which is what makes a deploy 'done'. To inspect without deploying, 'check' / --status / --dry-run are always allowed."
fi
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
