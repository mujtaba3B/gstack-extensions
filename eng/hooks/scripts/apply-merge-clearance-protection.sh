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
#   apply-merge-clearance-protection.sh <owner/repo> [base-branch] [--yes] [--dry-run]
#     base-branch defaults to the repo's default branch.
#     --dry-run  print the payload, change nothing.
#     --yes      skip the confirmation prompt (for automation).
#
# Idempotent: a PUT replaces the protection wholesale, so re-running converges.
# Requires admin on the repo (the PUT 403s otherwise).

set -euo pipefail

REPO=""; BRANCH=""; ASSUME_YES=0; DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) if [ -z "$REPO" ]; then REPO="$arg"; elif [ -z "$BRANCH" ]; then BRANCH="$arg"; fi ;;
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

# The required checks: CI plus the clearance context. Pull the CI context name(s)
# from the repo's .merge-clearance.json marker if we can read it from the API,
# else default to "ci". The clearance context is always appended.
REQUIRED='["ci","local-review/merge-clearance"]'
# Fetch the raw file (raw media type) rather than the base64 `.content` field, so
# we avoid `base64 -d` (GNU) vs `-D` (BSD/macOS) portability gotchas entirely.
marker=$(gh api "repos/$REPO/contents/.merge-clearance.json" -H "Accept: application/vnd.github.raw" 2>/dev/null || true)
if [ -n "$marker" ]; then
  checks=$(printf '%s' "$marker" | jq -c '(.required_checks // ["ci"]) + ["local-review/merge-clearance"] | unique' 2>/dev/null || true)
  [ -n "$checks" ] && REQUIRED="$checks"
fi

PAYLOAD=$(jq -nc --argjson contexts "$REQUIRED" '{
  required_status_checks: { strict: false, contexts: $contexts },
  enforce_admins: true,
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

printf '%s' "$PAYLOAD" | gh api -X PUT "repos/$REPO/branches/$BRANCH/protection" \
  -H "Accept: application/vnd.github+json" --input - >/dev/null

echo "Applied. Current required checks + admin enforcement:"
gh api "repos/$REPO/branches/$BRANCH/protection" \
  -q '{checks: .required_status_checks.contexts, enforce_admins: .enforce_admins.enabled, reviews: .required_pull_request_reviews, conversation_resolution: .required_conversation_resolution.enabled}' 2>/dev/null \
  || gh api "repos/$REPO/branches/$BRANCH/protection" | jq '{required_status_checks, enforce_admins, required_conversation_resolution}'
