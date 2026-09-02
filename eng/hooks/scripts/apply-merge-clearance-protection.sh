#!/bin/bash
# apply-merge-clearance-protection.sh - the GitHub-enforced half ("A") of the
# merge-clearance design. Configures classic branch protection on a repo's base
# branch so that NOTHING lands without the sanctioned gauntlet:
#
#   required status checks : ci + local-review/merge-clearance
#   enforce_admins         : true   (binds the web "Merge" button and --admin too)
#   required PR reviews     : dropped to 0   (the clearance check replaces the
#                            code-owner approval, so a solo dev does not deadlock
#                            on self-approval)
#   conversation resolution: true   (unresolved CodeRabbit threads block natively)
#
# The local pr-merge-gate.sh hook is the fast offline catch for `gh pr merge`; THIS
# is the authority a local stamp cannot provide - it binds the GitHub web/admin
# path. The two are satisfied by the same act: `merge-clearance.sh clear`, which
# posts the local-review/merge-clearance status.
#
# Two deliberate posture notes:
#   - Dropping required PR reviews is intentional (the clearance check is the
#     review of record). Applying this to a repo that relied on code-owner reviews
#     REMOVES that requirement; only run it where the clearance check is meant to
#     replace human approval. It does a wholesale PUT, so existing protection is
#     replaced, not merged.
#   - The posted clearance status does not auto-expire, so a NEW CodeRabbit comment
#     after clearing would not flip it red on its own. `required_conversation_resolution`
#     (set true here) is the backstop: an unresolved CR thread blocks the merge
#     natively regardless of the clearance status. CI is an independent required
#     check too. Keep conversation-resolution ON for this reason.
#
# Usage:
#   apply-merge-clearance-protection.sh <owner/repo> [base-branch] [--yes] [--dry-run] [--soft]
#     base-branch defaults to the repo's default branch.
#     --dry-run  print the payload, change nothing.
#     --yes      skip the confirmation prompt (for automation).
#     --soft     enforce_admins=false (the soft protection tier: required checks
#                bind PRs and the web button for non-admins, but the repo admin
#                can still self-merge in an emergency; use on solo repos where
#                no other account authors PRs).
#
# Idempotent: a PUT replaces the protection wholesale, so re-running converges.
# Requires admin on the repo (the PUT 403s otherwise).

set -euo pipefail

REPO=""; BRANCH=""; ASSUME_YES=0; DRY_RUN=0; ENFORCE_ADMINS=true
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --soft) ENFORCE_ADMINS=false ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) if [ -z "$REPO" ]; then REPO="$arg"; elif [ -z "$BRANCH" ]; then BRANCH="$arg"; else echo "unexpected extra argument: $arg" >&2; exit 2; fi ;;
  esac
done
[ -n "$REPO" ] || { echo "usage: apply-merge-clearance-protection.sh <owner/repo> [base-branch] [--yes] [--dry-run]" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "gh required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }

if [ -z "$BRANCH" ]; then
  # Fail closed: applying protection to the wrong branch is worse than stopping.
  BRANCH=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null) || {
    echo "could not resolve default branch for $REPO; pass [base-branch] explicitly" >&2; exit 2; }
  [ -n "$BRANCH" ] || { echo "default branch for $REPO came back empty; pass [base-branch] explicitly" >&2; exit 2; }
fi

# The required checks: the repo's CI context name(s) plus the clearance context.
# Default when the policy cannot be resolved. Requiring a context the repo never
# produces would deadlock every merge, so this stays conservative and is warned about.
REQUIRED='["ci","local-review/merge-clearance"]'
# required_checks come from the tracked ~/dev/gate-policy.json, which is keyed by
# repo identity, so any checkout or worktree of the repo resolves the same answer.
# (Per-repo .merge-clearance.json markers were dropped on 2026-09-02; they were
# machine-local and git-ignored, so this used to be unreadable from the wrong
# checkout and fell back to a phantom "ci" context.)
marker=""
LOCAL_TOP=$(git rev-parse --show-toplevel 2>/dev/null || true)
GPLIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gate-policy-lib.sh"
if [ -n "$LOCAL_TOP" ] && [ -f "$GPLIB" ]; then
  # shellcheck source=/dev/null
  . "$GPLIB"
  LOCAL_REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#^[^:]+://[^/]+/##; s#^[^@]+@[^:]+:##; s#\.git$##')
  if [ "$(printf '%s' "$LOCAL_REPO" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" ]; then
    marker=$(gp_gate_config "$LOCAL_TOP" merge-clearance 2>/dev/null || true)
  fi
fi
if [ -n "$marker" ]; then
  checks=$(printf '%s' "$marker" | jq -c '(.required_checks // ["ci"]) + ["local-review/merge-clearance"] | unique' 2>/dev/null || true)
  [ -n "$checks" ] && REQUIRED="$checks"
else
  echo "WARNING: could not resolve required_checks for $REPO from the gate policy (run from a checkout of it). Defaulting to required checks $REQUIRED; verify the repo actually produces those checks or merges will deadlock." >&2
fi

PAYLOAD=$(jq -nc --argjson contexts "$REQUIRED" --argjson ea "$ENFORCE_ADMINS" '{
  required_status_checks: { strict: false, contexts: $contexts },
  enforce_admins: $ea,
  required_pull_request_reviews: null,
  restrictions: null,
  required_linear_history: false,
  allow_force_pushes: false,
  allow_deletions: false,
  block_creations: false,
  required_conversation_resolution: true,
  lock_branch: false,
  allow_fork_syncing: false
}')

echo "Target: $REPO @ $BRANCH"
echo "Protection payload:"; printf '%s\n' "$PAYLOAD" | jq .

if [ "$DRY_RUN" -eq 1 ]; then echo "(dry-run: no change applied)"; exit 0; fi

if [ "$ASSUME_YES" -ne 1 ]; then
  printf 'Apply this protection to %s @ %s? [y/N] ' "$REPO" "$BRANCH" >&2
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "aborted." >&2; exit 1 ;; esac
fi

# Branch names may contain '/' (release/2026.06); encode for the REST path.
BRANCH_API=${BRANCH//\//%2F}
printf '%s' "$PAYLOAD" | gh api -X PUT "repos/$REPO/branches/$BRANCH_API/protection" \
  -H "Accept: application/vnd.github+json" --input - >/dev/null

echo "Applied. Current required checks + admin enforcement:"
gh api "repos/$REPO/branches/$BRANCH_API/protection" \
  -q '{checks: .required_status_checks.contexts, enforce_admins: .enforce_admins.enabled, reviews: .required_pull_request_reviews, conversation_resolution: .required_conversation_resolution.enabled}' 2>/dev/null \
  || gh api "repos/$REPO/branches/$BRANCH_API/protection" | jq '{required_status_checks, enforce_admins, required_conversation_resolution}'
