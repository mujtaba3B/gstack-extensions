#!/bin/bash
# Stop hook: make QA a first-class, STATED posture whenever the agent declares
# coding work done. If the final assistant message claims completion on a branch
# with commits ahead of the base branch, and it carries no QA_STATUS line, block
# the stop and tell the agent to state its QA posture before ending.
#
# Output protocol (Claude Code Stop hook):
#   exit 0 + empty stdout                              -> allow stop
#   stdout JSON {"decision":"block","reason":"..."}    -> block; agent continues
#
# Fail-open everywhere: any missing dependency, unreadable transcript, or git
# uncertainty exits 0 (allow). The PR CI backstop catches what this misses; a
# gate that nags on doubt trains the human to disable it.
#
# The block reason is deliberately SHORT (the human sees it verbatim at the end
# of every blocked turn; a 2,500-char menu buried the actual response). It names
# the posture keywords and points at the canonical contract:
# docs/qa-status-postures.md (in this repo). Keep the details there, not here.

set -u

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

# Infinite-loop guard: if this stop is already a stop-hook continuation, do not
# block again, or the agent can never end the turn.
ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$ACTIVE" = "true" ] && exit 0

# Prefer the just-finished assistant turn from the Stop payload. The transcript
# JSONL is not flushed until after the Stop hook returns, so tailing it reads
# the PREVIOUS turn (stale). Fall back to a transcript tail only if the payload
# field is absent (older Claude Code builds).
LAST=$(printf '%s' "$PAYLOAD" | jq -r '.last_assistant_message // empty' 2>/dev/null)
if [ -z "$LAST" ]; then
  TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null)
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    LAST=$(tail -n 600 "$TRANSCRIPT" 2>/dev/null | jq -rs '
      [ .[] | select(.type=="assistant") ] | (last // {})
      | (.message.content // [])
      | map(select(type=="object" and .type=="text") | .text) | join("\n")
    ' 2>/dev/null)
  fi
fi
[ -z "$LAST" ] && exit 0

# Shippable work in the SESSION cwd (from the payload, not the hook process cwd)?
# Commits ahead of the base branch ONLY. A dirty tree deliberately does NOT
# count: long-lived local edits (a modified WIREFRAMES.md, a sibling pane's
# work) armed the gate on every chatty turn, and the noise outweighed the
# catch. Uncommitted work gets caught at commit/ship time, when the commits
# exist. All best-effort; any failure leaves shippable=0 (allow).
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD="$(pwd)"
SHIPPABLE=0
if git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
  BASE=$(git -C "$CWD" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@')
  # origin/HEAD is often unset (plain `git remote add` never sets it). Probe the
  # usual base names so a master-default repo without origin/HEAD still arms the
  # gate; with rev-list now the SOLE arming signal, defaulting blindly to main
  # would silently disarm it there.
  if [ -z "$BASE" ]; then
    for B in main master; do
      if git -C "$CWD" rev-parse -q --verify "refs/remotes/origin/$B" >/dev/null 2>&1 \
         || git -C "$CWD" rev-parse -q --verify "refs/heads/$B" >/dev/null 2>&1; then
        BASE=$B; break
      fi
    done
  fi
  BASE=${BASE:-main}
  AHEAD=$(git -C "$CWD" rev-list --count "origin/${BASE}..HEAD" 2>/dev/null \
          || git -C "$CWD" rev-list --count "${BASE}..HEAD" 2>/dev/null || echo 0)
  if [ "${AHEAD:-0}" -gt 0 ] 2>/dev/null; then SHIPPABLE=1; fi
fi

LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa-status-gate-lib.sh"
[ -f "$LIB" ] || exit 0
# shellcheck source=/dev/null
. "$LIB"

DECISION=$(qa_gate_decision "$LAST" "$SHIPPABLE")
if [ "$DECISION" = "block" ]; then

REASON="QA gate: work declared done on a branch with commits ahead, but no QA posture stated. End the turn with one QA_STATUS line: dev_verified, deploy_branch_for_manual_qa, prod_verified, blocked, skip_requested, or no_tracked_change (plus EVIDENCE: / DRIVER: / DEPLOYED: / REASON: as the posture requires).
Full contract if unsure: read ~/.claude/docs/qa-status-postures.md"

jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
fi

# Posture is stated, so the "did you decide?" gate allows. Incident hardening:
# if the agent claims prod_verified and the PR's approved QA plan named a
# specific `Production artifacts:`, reject EVIDENCE that names only a base /
# upstream / proxy artifact instead of that one. Fail OPEN at every step: a
# missing gh, no PR, or no `Production artifacts:` field leaves PROD_ARTIFACT
# empty and the gate behaves exactly as before. The gh lookup is gated on the
# prod_verified keyword so a normal turn never pays for a network call.
if printf '%s' "$LAST" | grep -qiE 'QA_STATUS:[[:space:]]*prod_verified'; then
  PR_BODY=$( (cd "$CWD" && gh pr view --json body --jq '.body' 2>/dev/null) 2>/dev/null )
  PROD_ARTIFACT=$(qa_extract_prod_artifact "$PR_BODY" | head -n 20)
  if [ -n "$PROD_ARTIFACT" ]; then
    ADECISION=$(qa_artifact_gate "$LAST" "$PROD_ARTIFACT")
    if [ "$ADECISION" = "block" ]; then
      AREASON="QA gate (artifact-evidence): you stated QA_STATUS: prod_verified, but your EVIDENCE names a base / upstream / proxy artifact, not the exact production artifact your approved QA plan named:
${PROD_ARTIFACT}
Production runs a DERIVED artifact, not the upstream you exercised. This is the exact failure mode that shipped a stale per-agent image: the shared base was tested, but the per-agent image that actually runs was never rebuilt and went stale. Re-verify THROUGH the production artifact named above (the exact image digest/tag on its host / running container), then restate QA_STATUS: prod_verified with EVIDENCE that cites that artifact. If the plan's named artifact is itself wrong, fix it with /qa:plan and re-approve before claiming prod_verified."
      jq -nc --arg r "$AREASON" '{decision: "block", reason: $r}'
      exit 0
    fi
  fi
fi

exit 0
