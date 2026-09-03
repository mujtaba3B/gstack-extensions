#!/bin/bash
# merge-clearance - the sanctioned pre-merge gauntlet for an opted-in ~/dev repo.
#
# This is the workhorse behind the "make /land-and-deploy the only merge path"
# design. It answers one question for a PR: is this genuinely clear to land?
# "Clear" means, on the PR's CURRENT head commit:
#   - CI required checks are green
#   - CodeRabbit has finished reviewing and left nothing unresolved
#       (escape hatch: if CR signals a rate limit on this HEAD - whether its commit
#        status is "missing" (never started), stuck "pending" (started, then hit the
#        limit mid-flight), or resolved to "failure" with a rate-limit description
#        (an incremental pass burned the limit, often AFTER CR had already reviewed
#        HEAD) - a CURRENT local /eng:cr review backstops it. The dimension that
#        auto-satisfies differs by shape: reviewed-head for missing/pending, the
#        failure status itself for the failure shape. Fully audited either way.
#        Never both reviewers down.
#        A GENUINE CR failure has no such auto-satisfy; it takes the explicit
#        --override-cr-failure operator flag, which ALSO requires the current local
#        review and is recorded just as loudly.)
#   - a local /review was recorded (gstack review-skill stamp)   [soft, --skip-review]
#   - the PR body's QA checklist has no unchecked boxes          [soft, --skip-qa]
#
# Two verbs:
#   merge-clearance check  - evaluate and render a markdown checklist; exit 0 iff clear.
#   merge-clearance clear  - re-evaluate; on pass, WRITE the local clearance stamp
#                            (<gitdir>/merge-clearance-head, TTL-bounded) AND post the
#                            GitHub commit status `local-review/merge-clearance=success`
#                            on the head sha. This is the only thing that satisfies
#                            both the local pr-merge-gate hook and the GitHub ruleset.
#
# The stamp is written as LATE as possible and given a short TTL (default 600s) to
# minimize the clearance->merge window: CodeRabbit can post a NEW comment after we
# clear without the head sha changing, so a stale clearance must not stay valid.
#
# Design notes:
#   - CI + CR are machine-hard gates (objectively verifiable). /review + QA are
#     surfaced and block by default but have escape hatches, because they encode
#     human judgment that the orchestrator (land-and-deploy) confirms separately.
#   - Pure parsing logic lives in merge-clearance-lib.sh and is unit tested.
#   - Fails CLOSED here (refuse to clear on doubt) - the opposite of the gate hook,
#     which fails OPEN. Producing a clearance is the privileged act; withholding one
#     is always safe.
#   - Bookkeeping fast lane: a PR whose ENTIRE file list is docs / the cross-host
#     inventory (mc_is_bookkeeping) internally forces --skip-review + --skip-qa, so
#     zero-risk non-code changes do not pay the soft human-judgment ceremony. CI +
#     CR stay HARD. Recorded in the checklist, the stamp evidence, and the posted
#     status description so the fast lane is always auditable, never silent.

set -uo pipefail

LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/merge-clearance-lib.sh"
# shellcheck source=/dev/null
. "$LIB"
# Gate policy: which gates apply to this checkout and with what config. Read
# through the same helper the gate hooks use, so `status` can never report a
# different posture from the one pr-merge-gate.sh will enforce.
GPLIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gate-policy-lib.sh"
# shellcheck source=/dev/null
[ -f "$GPLIB" ] && . "$GPLIB"

DEFAULT_TTL=600
CLEARANCE_CONTEXT="local-review/merge-clearance"

err()  { printf '%s\n' "$*" >&2; }
die()  { err "merge-clearance: $*"; exit 2; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# ---- argument parsing -------------------------------------------------------

VERB="${1:-}"; shift || true
case "$VERB" in check|clear|status|enable) ;; *)
  cat >&2 <<EOF
usage: merge-clearance <check|clear|status|enable> [options]

  check / clear / status (PR-level):
    --pr N            PR number (default: PR for the current branch)
    --repo OWNER/REPO target repo (default: the repo of the cwd)
    --ttl SECONDS     clearance stamp TTL for 'clear' (default: $DEFAULT_TTL)
    --skip-review     do not require a recorded local /review
    --skip-qa         do not require the PR body QA checklist to be complete
    --override-cr-failure
                      operator override for a GENUINE CodeRabbit failure status on
                      this head. Still requires a CURRENT local /eng:cr review
                      (never a bare bypass) and is recorded in the checklist, the
                      --json verdict, the stamp evidence and the posted status
                      description. Without that current review the flag does not
                      clear: it swaps the generic failure blocker for one telling
                      you to run /eng:cr first. A rate-limited failure needs no
                      flag (it auto-satisfies on the same backstop, and is recorded
                      as rate-limited rather than as an override).
    --json            also emit a machine-readable JSON verdict (check only)

  enable (repo-level - opt a repo into the gate in one command):
    --repo OWNER/REPO  target repo (default: the repo of the cwd)
    --base BRANCH      protected base branch (default: the repo default branch)
    --checks a,b,c     required CI check contexts (default: auto-detected, else ci)
    --apply-protection also flip GitHub branch protection now (enforce_admins + checks)
EOF
  exit 2 ;;
esac

PR=""; REPO=""; TTL="$DEFAULT_TTL"; SKIP_REVIEW=0; SKIP_QA=0; WANT_JSON=0
BASE_ARG=""; CHECKS_ARG=""; APPLY_PROTECTION=0; OVERRIDE_CR_FAILURE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) PR="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --ttl) TTL="${2:-}"; shift 2 ;;
    --base) BASE_ARG="${2:-}"; shift 2 ;;
    --checks) CHECKS_ARG="${2:-}"; shift 2 ;;
    --apply-protection) APPLY_PROTECTION=1; shift ;;
    --skip-review) SKIP_REVIEW=1; shift ;;
    --skip-qa) SKIP_QA=1; shift ;;
    --override-cr-failure) OVERRIDE_CR_FAILURE=1; shift ;;
    --json) WANT_JSON=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

need gh; need jq; need git

# ---- enable: scaffold a repo's opt-in marker (and optionally protection) -----
# Every repo under the policy root is governed by default, so "porting" is now only
# recording the repo's real CI contexts (and, for the GitHub-enforced half, flipping
# branch protection). This subcommand does both, auto-detecting the check context
# names so the entry is correct without hand-editing.
if [ "$VERB" = "enable" ]; then
  TOP=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "enable must run inside a checkout of the target repo (so it can write the marker)"
  [ -z "$REPO" ] && REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
  [ -n "$REPO" ] || die "could not resolve repo (pass --repo)"
  BASE="$BASE_ARG"
  [ -z "$BASE" ] && BASE=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
  BASE=${BASE:-main}

  # Required checks: explicit --checks wins; else auto-detect from a RECENT PR's
  # head commit. CI gates run on pull_request events, so they appear on PR heads,
  # not on the base-branch head (which only carries push/post-merge jobs like
  # version bumps). Drop bot/meta contexts. A wrong name here would deadlock
  # merges, so fall back to the safe default ["ci"] when detection is uncertain.
  if [ -n "$CHECKS_ARG" ]; then
    CHECKS=$(printf '%s' "$CHECKS_ARG" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))')
  else
    CHECKS='["ci"]'
    prsha=$(gh pr list --repo "$REPO" --state all --base "$BASE" --limit 1 -q '.[0].headRefOid' \
              --json headRefOid 2>/dev/null || true)
    if [ -n "$prsha" ]; then
      detected=$(gh api --paginate "repos/$REPO/commits/$prsha/check-runs" -q '.check_runs[] | select(.conclusion!="skipped") | .name' 2>/dev/null \
        | grep -viE '^(coderabbit|label|setup|local-review/merge-clearance)$' | sort -u | jq -Rc . | jq -sc 'map(select(length>0))' || true)
      [ -n "$detected" ] && [ "$detected" != "[]" ] && CHECKS="$detected"
    fi
    err "merge-clearance enable: required CI checks = $CHECKS (verify; override with --checks)"
  fi

  # Write the repo's entry into the TRACKED policy, keyed by identity. Per-repo
  # marker files were dropped on 2026-09-02; every repo under the root is governed
  # by default, so "enable" now only records this repo's CI contexts and base.
  # Resolved through the lib, not re-derived: two copies of the default path drift,
  # and `enable` would then write to a file the gates do not read.
  POLICY=$(gp_policy_file)
  [ -f "$POLICY" ] || die "gate policy not found at $POLICY"
  IDENT=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')
  tmp=$(mktemp "${POLICY}.XXXXXX") || die "could not write next to $POLICY"
  jq --arg k "$IDENT" --arg base "$BASE" --argjson checks "$CHECKS" \
    '.overrides[$k]["merge-clearance"] = {base_branches:[$base], required_checks:$checks}' \
    "$POLICY" > "$tmp" && mv -f "$tmp" "$POLICY" || { rm -f "$tmp"; die "failed to update $POLICY"; }
  err "merge-clearance enable: recorded overrides[\"$IDENT\"][\"merge-clearance\"] in $POLICY"

  if [ "$APPLY_PROTECTION" -eq 1 ]; then
    proto="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apply-merge-clearance-protection.sh"
    [ -x "$proto" ] || proto="$HOME/.claude/scripts/apply-merge-clearance-protection.sh"
    if [ -x "$proto" ]; then
      "$proto" "$REPO" "$BASE" --yes
    else
      err "merge-clearance enable: apply-merge-clearance-protection.sh not found; apply protection manually"
    fi
  fi

  cat >&2 <<EOF

Next steps to finish opting $REPO into the gate:
  1. Commit the gate-policy.json change (it is tracked, and is what makes the
     setting survive every clone and worktree).
  2. Ensure the repo has CodeRabbit installed and a CI check named in required_checks.
$([ "$APPLY_PROTECTION" -eq 1 ] || echo "  3. Flip branch protection: $0 enable --repo $REPO --base $BASE --apply-protection (or run apply-merge-clearance-protection.sh).")
  $([ "$APPLY_PROTECTION" -eq 1 ] && echo "3." || echo "4.") From now on, land PRs via /land-and-deploy (it posts the clearance).
EOF
  exit 0
fi

# ---- resolve repo / PR / head ----------------------------------------------

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) \
    || die "could not resolve repo (run inside a gh-enabled checkout or pass --repo)"
fi
OWNER="${REPO%%/*}"; NAME="${REPO##*/}"

# One GraphQL round-trip gets head, base, threads, and reviews together.
PR_ARG=$PR
if [ -z "$PR_ARG" ]; then
  PR_ARG=$(gh pr view --repo "$REPO" --json number -q .number 2>/dev/null) \
    || die "no PR for the current branch (pass --pr N)"
fi

GQL=$(gh api graphql -F owner="$OWNER" -F repo="$NAME" -F pr="$PR_ARG" -f query='
  query($owner:String!,$repo:String!,$pr:Int!){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        number title headRefOid baseRefName state isDraft body
        files(first:100){ nodes { path } pageInfo { hasNextPage } }
        reviewThreads(first:100){ nodes { isResolved isOutdated comments(first:1){ nodes { author{ login } } } } }
        reviews(first:100){ nodes { author{ login } state submittedAt commit{ oid } } }
      }
    }
  }' 2>/dev/null) || die "GraphQL query failed for $REPO#$PR_ARG"

# gh exits 0 even when GraphQL returns field-level errors with partial data, so a
# transport-OK-but-degraded response could carry null nodes. Refuse on any errors
# array (fail closed: better to not clear than to clear on incomplete CR data).
if printf '%s' "$GQL" | jq -e '(.errors // []) | length > 0' >/dev/null 2>&1; then
  die "GraphQL returned errors for $REPO#$PR_ARG (refusing to act on partial data)"
fi

PR_JSON=$(printf '%s' "$GQL" | jq -c '.data.repository.pullRequest')
[ "$PR_JSON" != "null" ] && [ -n "$PR_JSON" ] || die "PR $REPO#$PR_ARG not found"

PR_NUM=$(printf '%s' "$PR_JSON" | jq -r '.number')
PR_TITLE=$(printf '%s' "$PR_JSON" | jq -r '.title')
HEAD=$(printf '%s' "$PR_JSON" | jq -r '.headRefOid')
BASE=$(printf '%s' "$PR_JSON" | jq -r '.baseRefName')
STATE=$(printf '%s' "$PR_JSON" | jq -r '.state')
IS_DRAFT=$(printf '%s' "$PR_JSON" | jq -r '.isDraft')
BODY=$(printf '%s' "$PR_JSON" | jq -r '.body // ""')
THREADS=$(printf '%s' "$PR_JSON" | jq -c '.reviewThreads.nodes')
REVIEWS=$(printf '%s' "$PR_JSON" | jq -c '.reviews.nodes')

# ---- bookkeeping fast lane --------------------------------------------------
# A PR whose ENTIRE file list is docs / the cross-host inventory is a zero-risk,
# non-code change. It should not pay the soft human-judgment ceremony (the /eng:cr
# stamp + the QA checklist), so we internally force the same --skip-review /
# --skip-qa hatches the operator could pass by hand. CI and CodeRabbit stay HARD
# (they are machine-objective and cheap), so a bookkeeping PR still needs green CI
# and a clean CR pass. mc_is_bookkeeping fails CLOSED: any one non-allowlisted
# path -> "no". A truncated file list (>100 files, hasNextPage) can never be
# bookkeeping, so we refuse to fast-lane it rather than classify a partial list.
# 100 is GitHub's hard cap on the `files` connection's `first` (a larger value is
# rejected with EXCESSIVE_PAGINATION), and it is stricter than the PR-create gate
# (which reads an uncapped local `git diff`): a >100-file docs-only PR can fast-lane
# at create
# time but lands here with no plan and is correctly told to get the stamps. The
# merge gate is the authoritative one, and refusing on truncation is the safe
# direction; the divergence is friction on a pathological PR, never a wrongful clear.
# mc_is_bookkeeping returns rc=1 on "no", but it is in a $(...) compared by string,
# so only its stdout token is authoritative here; the rc is intentionally ignored.
PR_FILES=$(printf '%s' "$PR_JSON" | jq -r '.files.nodes[]?.path // empty')
FILES_TRUNCATED=$(printf '%s' "$PR_JSON" | jq -r '.files.pageInfo.hasNextPage // false')
IS_BOOKKEEPING=no
if [ "$FILES_TRUNCATED" != "true" ] && [ "$(mc_is_bookkeeping "$PR_FILES")" = "yes" ]; then
  IS_BOOKKEEPING=yes
  SKIP_REVIEW=1
  SKIP_QA=1
fi

# ---- required CI checks from the repo's opt-in marker -----------------------
# The marker lists which check contexts must be green. We deliberately do NOT
# include the clearance context itself (that would be circular: this script is
# what produces it). Default to ["ci"] when the marker is silent.
# Empty, not ["ci"]. A hardcoded default here is exactly the phantom `ci=missing`
# this change exists to remove: when the policy cannot be read we know NOTHING about
# this repo's checks, and inventing a context it never runs reports broken CI.
REQUIRED_CHECKS='[]'
REQUIRE_QA_PLAN=0
# Globs whose files CodeRabbit does not review (gitignore / minimatch style).
# When a HEAD's only change is files matching these (or git-binary blobs), CR
# legitimately posts no review and the "CR reviewed HEAD" gate is auto-satisfied
# (see the CR-reviewed-head block below). Defaults to ["*.pen"] - encrypted-
# looking Pencil wireframes are plaintext JSON git treats as text, yet CR skips
# them - so the common case needs no per-repo config. A marker may override the
# list (extend it, or set [] to require CR on every file type).
CR_UNREVIEWABLE_GLOBS='["*.pen"]'
# Policy-resolved config, NOT a raw marker file. This is what fixes the phantom
# `ci=missing`: in a fresh worktree there is no marker (git-ignored files are not
# carried into one), so required_checks used to fall back to a context literally
# named "ci" and the verdict read as broken CI. The policy carries the repo's real
# required_checks regardless of which checkout you are standing in.
MARKER=""
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$TOPLEVEL" ] && command -v gp_gate_config >/dev/null 2>&1; then
  MARKER=$(gp_gate_config "$TOPLEVEL" merge-clearance 2>/dev/null) || MARKER=""
fi
if [ -n "$MARKER" ]; then
  mk=$(printf '%s' "$MARKER" | jq -c '.required_checks // empty' 2>/dev/null || true)
  [ -n "$mk" ] && REQUIRED_CHECKS="$mk"
  # Opt-in: when require_qa_plan is true, a PR with no Dev QA checklist blocks
  # (run /qa:plan). Default false preserves prior behavior (no checklist -> n/a).
  case "$(printf '%s' "$MARKER" | jq -r '.require_qa_plan // false' 2>/dev/null)" in true|1) REQUIRE_QA_PLAN=1 ;; esac
  # An explicit array (incl. []) wins over the default; an absent OR null key
  # leaves the default in place. "// empty" yields no output for both absent and
  # null (so $ug stays empty and the default holds), but emits [] for an explicit
  # empty array (so a marker can disable the default by setting []).
  ug=$(printf '%s' "$MARKER" | jq -c '.cr_unreviewable_globs // empty' 2>/dev/null || true)
  [ -n "$ug" ] && CR_UNREVIEWABLE_GLOBS="$ug"
fi

# Gate 3 of the QA-plan approval policy:
# a repo carrying a `.qa-plan-gate.json` marker with the "deploy" gate enabled
# requires QA to have PASSED before deploy. Folding it into REQUIRE_QA_PLAN reuses
# the mc_qa_state classifier: with it on, a PR whose Dev QA boxes are unchecked
# ("incomplete") or whose plan is absent ("missing") blocks, so only an all-boxes-
# checked ("complete") plan clears the merge. The build/PR halves of the same
# policy live in qa-plan-build-gate.sh / qa-plan-pr-gate.sh.
QPG_GATE_ACTIVE=""
QPG_MARKER_JSON=""
if [ -n "$TOPLEVEL" ] && command -v gp_gate_config >/dev/null 2>&1; then
  QPG_MARKER_JSON=$(gp_gate_config "$TOPLEVEL" qa-plan 2>/dev/null) || QPG_MARKER_JSON=""
  # A sentinel, not a path: the only consumer tests it for non-emptiness. The
  # config itself travels in QPG_MARKER_JSON.
  [ -n "$QPG_MARKER_JSON" ] && QPG_GATE_ACTIVE="policy"
fi
if [ -n "$QPG_GATE_ACTIVE" ]; then
  # qa-plan-gate-lib.sh ships in the qa plugin, not this (eng) one. Try the
  # sibling first (flat deployments), then the HIGHEST-VERSION installed qa
  # plugin copy (sort -V on the version dirs; deterministic, unlike mtime,
  # which selects whatever was installed or touched last).
  QPG_LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa-plan-gate-lib.sh"
  if [ ! -f "$QPG_LIB" ]; then
    QPG_LIB=""
    for _qadir in $(ls -d "$HOME/.claude/plugins/cache/gstack-extensions/qa"/*/ 2>/dev/null | sort -rV); do
      if [ -f "${_qadir}hooks/scripts/qa-plan-gate-lib.sh" ]; then
        QPG_LIB="${_qadir}hooks/scripts/qa-plan-gate-lib.sh"
        break
      fi
    done
  fi
  if [ -n "$QPG_LIB" ] && [ -f "$QPG_LIB" ]; then
    # shellcheck source=/dev/null
    . "$QPG_LIB"
    # Only enforce when the deploy gate is on AND this PR's base is in the
    # marker's scope (default ["main"]), mirroring qa-plan-build/pr-gate.sh.
    if qpg_gate_enabled "$QPG_MARKER_JSON" deploy \
       && [ "$(qpg_base_in_scope "$QPG_MARKER_JSON" "$BASE")" = "in" ]; then
      REQUIRE_QA_PLAN=1
    fi
  fi
fi

# ---- gather check / status state for HEAD ----------------------------------
# Merge check-runs (Actions) and commit statuses (CodeRabbit et al.) into one
# name->state map. Statuses come newest-first; keep only the first per context.
# Check-runs need more care: GitHub keeps every historical run on a commit and a
# re-run opens a NEW suite rather than replacing the old one, so the raw list can
# hold a stale failure alongside the passing re-run. mc_collapse_checkruns keeps
# only each name's newest SUITE (and every run of that name within it, so a
# multi-run name still needs them all green). Without it, a check fixed by a
# re-run could never clear the gate until the head moved.
CHECKRUNS=$(gh api --paginate "repos/$REPO/commits/$HEAD/check-runs" \
              -q '.check_runs[] | {name:.name, state:(.conclusion // .status), suite:.check_suite.id, started:.started_at}' 2>/dev/null \
            | jq -sc '.' || echo '[]')
CHECKRUNS=$(mc_collapse_checkruns "$CHECKRUNS")
STATUSES=$(gh api "repos/$REPO/commits/$HEAD/statuses" \
              -q '.[] | {name:.context, state:.state}' 2>/dev/null \
            | jq -sc 'reduce .[] as $s ({}; if has($s.name) then . else . + {($s.name):$s.state} end)
                      | to_entries | map({name:.key, state:.value})' || echo '[]')
CHECKMAP=$(jq -cn --argjson a "$CHECKRUNS" --argjson b "$STATUSES" '$a + $b')

# state_of <context-name> -> success|failure|pending|missing. A commit status whose
# state is failure/error, or a check-run whose conclusion is timed_out / cancelled /
# action_required, all fold to "failure" (the fold the CodeRabbit failure branch
# below is built on); any other completed state is "success"; everything not yet
# conclusive is "pending"; absent is "missing".
state_of() {
  printf '%s' "$CHECKMAP" | jq -r --arg n "$1" '
    [ .[] | select(.name==$n) | .state ] as $s
    | if ($s|length)==0 then "missing"
      elif ($s|index("failure")) or ($s|index("timed_out")) or ($s|index("cancelled")) or ($s|index("action_required")) or ($s|index("error")) then "failure"
      elif ($s|index("success")) then "success"
      else "pending" end'
}

# head_changed_files <sha> -> JSON [ {path, binary}, ... ] for the INCREMENTAL
# change at <sha> (vs its parent), feeding mc_head_cr_unreviewable. Prefer local
# git: numstat is authoritative for binary detection ("-\t-"), and --root handles
# a root commit. Fall back to the GitHub commit API (filenames only, binary=false)
# when the commit is not in the local object store - a remote-only run then relies
# on the marker's globs rather than binary inference, which keeps the API path
# conservative (it never invents a binary flag the way patch-absence heuristics
# would). Echoes "[]" when nothing can be resolved (fail closed: the caller treats
# an empty file list as "not unreviewable").
head_changed_files() {
  local sha="$1" out=""
  if git rev-parse -q --verify "${sha}^{commit}" >/dev/null 2>&1; then
    out=$(git diff-tree --no-commit-id --numstat -r --root "$sha" 2>/dev/null \
      | jq -Rsc 'split("\n") | map(select(length>0) | split("\t"))
                 | map({path: .[2], binary: (.[0]=="-" and .[1]=="-")})')
  fi
  if [ -z "$out" ] || [ "$out" = "null" ] || [ "$out" = "[]" ]; then
    local api
    api=$(gh api "repos/$REPO/commits/$sha" \
            -q '[.files[]? | {path: .filename, binary: false}]' 2>/dev/null)
    [ -n "$api" ] && [ "$api" != "null" ] && out="$api"
  fi
  [ -n "$out" ] && [ "$out" != "null" ] && printf '%s' "$out" || echo '[]'
}

# cr_issue_comments -> JSON [ {author, body}, ... ] of the PR's ISSUE comments
# (the timeline comments, where CodeRabbit posts its rate-limit notice - NOT the
# review threads the GraphQL query already fetched). Lazy: only called from the
# CR-silence branch, so the happy path makes no extra API call (mirrors
# head_changed_files). Echoes "[]" on any failure (fail closed: feeds
# mc_cr_rate_limited, which then reports "not rate-limited" so the gate keeps
# blocking - the safe direction).
cr_issue_comments() {
  local out
  out=$(gh api --paginate "repos/$REPO/issues/$PR_NUM/comments" \
          -q '[.[] | {author: (.user.login // ""), body: (.body // "")}]' 2>/dev/null \
        | jq -sc 'add // []' 2>/dev/null)
  [ -n "$out" ] && [ "$out" != "null" ] && printf '%s' "$out" || echo '[]'
}

# cr_status_description -> the description string on CodeRabbit's NEWEST commit
# status for HEAD (e.g. "Review rate limited"). The CHECKMAP above deliberately
# carries only name+state, because the description is needed for exactly one
# question: is a "failure" state really a rate limit? So this refetches lazily and
# is called ONLY from the failure branch below (mirroring head_changed_files /
# cr_issue_comments - the happy path pays for no extra API call). The statuses
# endpoint returns newest-first, so `first` is the newest CodeRabbit COMMIT STATUS,
# which is what produces the folded state today (CR publishes a commit status, not a
# check-run). Note the asymmetry: state_of folds check-runs AND statuses, while this
# reads statuses only, so if CR ever also emitted a check-run named "CodeRabbit" the
# description could go empty while the state stayed "failure". That direction fails
# CLOSED (the failure keeps blocking), it just makes the hatch stop firing. Echoes "" on any failure (fail closed: an unreadable description feeds
# mc_cr_failure_rate_limited, which then reports "not a rate limit" and the failure
# keeps blocking - the safe direction).
cr_status_description() {
  local out
  out=$(gh api "repos/$REPO/commits/$HEAD/statuses" \
          -q 'first(.[] | select(.context=="CodeRabbit") | (.description // ""))' 2>/dev/null) || out=""
  printf '%s' "$out"
}

# ---- evaluate each dimension -----------------------------------------------

# 1) CI required checks
CI_STATE="success"; CI_DETAIL=""
while IFS= read -r chk; do
  [ -n "$chk" ] || continue
  st=$(state_of "$chk")
  CI_DETAIL="${CI_DETAIL}${chk}=${st} "
  case "$st" in success) ;; failure) CI_STATE="failure" ;; *) [ "$CI_STATE" = success ] && CI_STATE="pending" ;; esac
done < <(printf '%s' "$REQUIRED_CHECKS" | jq -r '.[]')

# 2) CodeRabbit resolution + in-progress
CR_STATUS_STATE=$(state_of "CodeRabbit")          # CR's own commit status context
# Pass the CR commit-status state into both CR helpers. For the verdict, a
# "success" status on HEAD (CR re-evaluated HEAD and is green) waives leftover
# unresolved nitpick threads that would otherwise hard-block a PR CR itself marks
# green (the mutwo-skills#118 wedge); CHANGES_REQUESTED and non-green statuses
# still block. For reviewed-head, a "success" status is proof CR evaluated HEAD
# even when it posted no new review object (clean incremental commit). The status
# API is per-commit, so success here means HEAD, not an inherited ancestor.
CR_VERDICT=$(mc_cr_verdict "$THREADS" "$REVIEWS" "$CR_STATUS_STATE"); CR_RC=$?
# A "success" CodeRabbit status is not self-evidently a review: CR publishes
# state=success with description "Review rate limited" when it never read the code.
# Fetch the description for the success case so reviewed-head can tell the two
# apart. This costs one extra API call on the green path, which the old comment on
# cr_status_description said it was avoiding; correctness wins, because without it
# a rate-limited PR reaches a full CLEAR verdict (mujtaba3B/dev#92).
CR_STATUS_DESC=""
[ "$CR_STATUS_STATE" = "success" ] && CR_STATUS_DESC=$(cr_status_description)
CR_STATUS_RL=$(mc_status_rate_limited "$CR_STATUS_DESC")
CR_REVIEWED_HEAD=$(mc_cr_reviewed_head "$REVIEWS" "$HEAD" "$CR_STATUS_STATE" "$CR_STATUS_DESC")
CR_INPROGRESS=0
[ "$CR_STATUS_STATE" = "pending" ] && CR_INPROGRESS=1

# Auto-satisfy for the "CR has not reviewed HEAD" gap: only computed when that gap
# is actually present (CR posted no status and no review on HEAD), so the common
# path pays for no extra git/gh calls. The incremental HEAD->parent diff being
# entirely CR-unreviewable (git-binary OR matching CR_UNREVIEWABLE_GLOBS) means CR
# legitimately had nothing to review here; its silence is then not a review gap.
# This relaxes ONLY the reviewed-head dimension - the separate "CR clear" verdict
# (unresolved threads / changes-requested) still blocks regardless.
CR_HEAD_UNREVIEWABLE=no
CR_RATE_LIMITED=no
CR_FAILURE_RATE_LIMITED=no
if [ "$CR_STATUS_STATE" != "pending" ] && [ "$CR_REVIEWED_HEAD" = "no" ] \
   && { [ "$CR_STATUS_STATE" = "missing" ] || [ "$CR_STATUS_RL" = "yes" ]; }; then
  CR_HEAD_UNREVIEWABLE=$(mc_head_cr_unreviewable "$(head_changed_files "$HEAD")" "$CR_UNREVIEWABLE_GLOBS")
  # Second auto-satisfy path for the same "CR silent on HEAD" gap: CodeRabbit
  # itself posted its rate-limit notice (mc_cr_rate_limited finds the stable
  # "rate limited by coderabbit.ai" marker), so its silence is "couldn't start",
  # not "nothing to review". UNLIKE the *.pen path, this one is NOT safe on its
  # own - there IS reviewable code, CR just didn't see it - so it only relaxes
  # the gate when a CURRENT local /eng:cr review backstops it (CR_RL_BACKSTOPPED,
  # computed in the verdict section once REVIEW_STATE is known). Detection here is
  # independent of that interlock; the gating combines the two. Skip the extra API
  # call when the *.pen path already auto-satisfied.
  if [ "$CR_HEAD_UNREVIEWABLE" != "yes" ]; then
    if [ "$CR_STATUS_STATE" = "success" ]; then
      # Shape 4: green status, rate-limited description. The description is the
      # primary proof (mc_cr_success_rate_limited), because CR edits its marker
      # comment in place and the marker can vanish mid-PR. Pass the comments only
      # as the secondary proof, and only when the description did not settle it,
      # so the common path still costs no extra API call.
      # Call the SAME function twice, as the failure branch does at its own site.
      # Passing the description here keeps mc_cr_success_rate_limited's primary arm
      # live in production rather than exercised only by tests; the second call
      # supplies the comments as the secondary proof, and only when the first did
      # not settle it, so the green path still costs no extra API call.
      CR_RATE_LIMITED=$(mc_cr_success_rate_limited "$CR_STATUS_STATE" "$CR_STATUS_DESC" '[]')
      [ "$CR_RATE_LIMITED" = "yes" ] \
        || CR_RATE_LIMITED=$(mc_cr_success_rate_limited "$CR_STATUS_STATE" "" "$(cr_issue_comments)")
    else
      CR_RATE_LIMITED=$(mc_cr_rate_limited "$(cr_issue_comments)")
    fi
  fi
elif [ "$CR_STATUS_STATE" = "pending" ] && [ "$CR_REVIEWED_HEAD" = "no" ]; then
  # Stuck-pending rate-limit: CodeRabbit posts a "pending" commit status the moment
  # it STARTS a review, then can hit the limit mid-flight and post its rate-limit
  # notice, leaving the status stuck "pending" forever. That reads as "review in
  # progress, wait" and wedges the PR. We treat it as rate-limited ONLY when the
  # notice is CR's LATEST comment (mc_cr_rate_limited_latest) - a genuine in-flight
  # review posts a newer "Currently processing ..." comment, which keeps this "no"
  # and the in-progress wait intact. Like the missing path, this RELAXES the gate
  # only when a current local /eng:cr review backstops it (CR_RL_BACKSTOPPED, in the
  # verdict section); no notice or no backstop still blocks. The *.pen auto-satisfy
  # is deliberately NOT offered here: a pending status means CR did start, so there
  # was reviewable content - silence is "couldn't finish", never "nothing to review".
  CR_RATE_LIMITED=$(mc_cr_rate_limited_latest "$(cr_issue_comments)")
elif [ "$CR_STATUS_STATE" = "failure" ]; then
  # Third rate-limit shape: CR RESOLVED its per-commit status to failure with a
  # rate-limit description ("Review rate limited"). This is what an incremental pass
  # that burns the limit looks like - CR may have fully reviewed the PR already
  # (reviewed-head can be "yes" here, unlike the two branches above), then tripped
  # the limit on a trailing commit. In this flavour CR often posts NO marker comment,
  # so the description is the primary signal and the marker the secondary one; both
  # live in mc_cr_failure_rate_limited. Deliberately NOT conditioned on
  # CR_REVIEWED_HEAD: the failure status blocks on its own (see the verdict section),
  # independently of whether CR reviewed HEAD. Like the other two shapes this only
  # RELAXES the gate together with a current local /eng:cr review (CR_RL_BACKSTOPPED).
  # Two-step so the marker proof stays LAZY: the description alone settles the
  # common case, and only an inconclusive description pays for the paginated
  # comments fetch. (Passing both as arguments would expand each $(...) up front,
  # so the comments call would always run.)
  CR_FAILURE_RATE_LIMITED=$(mc_cr_failure_rate_limited "$CR_STATUS_STATE" "$(cr_status_description)" '[]')
  [ "$CR_FAILURE_RATE_LIMITED" = "yes" ] \
    || CR_FAILURE_RATE_LIMITED=$(mc_cr_failure_rate_limited "$CR_STATUS_STATE" "" "$(cr_issue_comments)")
  CR_RATE_LIMITED="$CR_FAILURE_RATE_LIMITED"
fi

# 3) local /review stamp (best-effort; keyed to the local checkout's git dir)
REVIEW_STATE="n/a"
GITDIR=$(git rev-parse --absolute-git-dir 2>/dev/null || true)
if [ -n "$GITDIR" ]; then
  RSTAMP=$(cat "$GITDIR/review-skill-head" 2>/dev/null || echo "")
  if [ "$RSTAMP" = "$HEAD" ]; then REVIEW_STATE="current"; elif [ -n "$RSTAMP" ]; then REVIEW_STATE="stale"; else REVIEW_STATE="missing"; fi
fi

# 4) QA checklist in the PR body - classified by mc_qa_state (extracted into
#    merge-clearance-lib.sh, unit tested in merge-clearance-lib.bats). Captures the
#    "## QA" section (deeper ### Development/Production QA subheadings stay inside),
#    skips fenced code, and returns complete / incomplete / missing / n/a. With the
#    repo's marker carrying require_qa_plan, a PR with no Dev QA checklist is
#    "missing" (a soft blocker) instead of "n/a"; default keeps prior behavior.
QA_STATE=$(mc_qa_state "$BODY" "$REQUIRE_QA_PLAN")

# ---- verdict ----------------------------------------------------------------
# Hard blockers: CI not green, CR not clear, CR mid-review, CR hasn't seen HEAD,
# CR status failure (unless rate-limited + backstopped, or operator-overridden).
# Soft blockers (block unless --skip-*): /review missing-or-stale, QA incomplete.

# CR rate-limit escape hatch (gated): when CodeRabbit signalled rate-limit on this
# HEAD (never started, stuck mid-flight, or a failure-status limit on an incremental
# pass - the last of which can happen on a HEAD CR DID review), fall back to the
# local /eng:cr review IFF that review is current for this HEAD. Never lose both reviewers - CR down + no local review
# still blocks. Computed here because it needs REVIEW_STATE (section 3).
CR_RL_BACKSTOPPED=no
[ "$CR_RATE_LIMITED" = "yes" ] && [ "$REVIEW_STATE" = "current" ] && CR_RL_BACKSTOPPED=yes

# Operator override for a GENUINE CodeRabbit failure (one with no rate-limit
# evidence). This is the human-judgment counterpart to the machine-detectable
# rate-limit auto-satisfy above, and it exists so a legitimate override never
# requires moving the repo's .merge-clearance.json marker aside or reaching for
# `gh pr merge --admin`. Two invariants keep it honest:
#   - it is NEVER the default: nothing sets OVERRIDE_CR_FAILURE but the explicit
#     --override-cr-failure flag (the bookkeeping fast lane does not touch it);
#   - it still requires a CURRENT local /eng:cr review on this exact head, so the
#     "never both reviewers down" rule holds here too. --skip-review does NOT
#     satisfy it: REVIEW_STATE is read independently of that hatch.
# It is recorded in the checklist, the JSON verdict, the stamp evidence and the
# posted GitHub status description, so an override is always greppable after the fact.
#
# The decision itself lives in mc_cr_failure_disposition (merge-clearance-lib.sh),
# not in `&&` chains here, because it is the one place a wrong edit turns the flag
# into a bare merge bypass. As a pure function every row of its truth table is a
# bats case; as inline shell it could only ever be verified by hand.
CR_FAILURE_DISPOSITION=$(mc_cr_failure_disposition \
  "$CR_STATUS_STATE" "$CR_FAILURE_RATE_LIMITED" "$OVERRIDE_CR_FAILURE" "$REVIEW_STATE")
CR_FAILURE_OVERRIDDEN=no
[ "$CR_FAILURE_DISPOSITION" = "cleared-override" ] && CR_FAILURE_OVERRIDDEN=yes
# Deriving the flag FROM the disposition (rather than recomputing it) is what keeps
# the audit trail honest when both escapes apply at once: the disposition checks the
# rate limit first, so passing the flag defensively on a rate-limited failure records
# "rate-limited", not a human override that was never needed. A later grep for real
# operator overrides then has no false positives.
[ "$CR_FAILURE_DISPOSITION" = "override-inert" ] \
  && err "merge-clearance: --override-cr-failure ignored (CodeRabbit status is ${CR_STATUS_STATE}, not failure)"

# ---- machine-local CodeRabbit opt-out ---------------------------------------
# merge-clearance treats CodeRabbit as a machine-HARD dimension: no auto-satisfy
# beyond the rate-limit and unreviewable-globs escapes. That is correct where CR is
# installed, and a permanent deadlock where it is not (probed 2026-09-02: the
# Unbound-Clinicians org has no CR on any recent PR). Under gate inheritance every
# such repo would otherwise become unmergeable with no override.
#
# So the opt-out is explicit, machine-local (~/dev/.gates/local.json, git-ignored,
# never committed) and keyed by repo IDENTITY, so one "owner/*" entry covers every
# repo, clone and worktree in an org. Deleting the entry re-arms the dimension with
# no other change.
#
# It NEUTRALIZES the CR inputs rather than suppressing the blockers, so there is
# exactly one place the skip takes effect, and the dimension is still RENDERED, as
# SKIPPED plus its reason. A bypass that does not appear in the output is precisely
# the class of bug this whole change exists to remove, so it must never go silent.
CR_SKIPPED=no
CR_SKIP_REASON=""
if [ -n "$TOPLEVEL" ] && command -v gp_skip_dimension >/dev/null 2>&1; then
  _mc_id=$(gp_repo_identity "$TOPLEVEL" 2>/dev/null || true)
  if [ -n "$_mc_id" ] && gp_skip_dimension "$_mc_id" coderabbit; then
    CR_SKIPPED=yes
    CR_SKIP_REASON=$(gp_skip_reason "$_mc_id" 2>/dev/null || echo "no reason recorded")
    CR_RC=0
    CR_VERDICT="skipped"
    CR_INPROGRESS=0
    CR_REVIEWED_HEAD="skipped"
    CR_FAILURE_DISPOSITION="n/a"
    err "merge-clearance: CodeRabbit dimension SKIPPED for ${_mc_id} - ${CR_SKIP_REASON}"
  fi
fi

BLOCKERS=()
# CR_BLOCKED is set alongside EVERY CodeRabbit-dimension blocker below, and is the
# ONLY input to the CodeRabbit checklist mark. The mark used to re-derive the same
# conditions in a second dialect, which is exactly how #58 happened: the expression
# omitted the failure status, so the one dimension actually blocking rendered as a
# green tick. Reading the blockers instead of mirroring them makes
# "mark is green iff nothing is blocking" true by construction.
CR_BLOCKED=0
[ "$CI_STATE" = "success" ] || BLOCKERS+=("CI is ${CI_STATE} (${CI_DETAIL})")
if [ "$CR_RC" -ne 0 ]; then BLOCKERS+=("CodeRabbit ${CR_VERDICT}"); CR_BLOCKED=1; fi
# CodeRabbit in-progress (pending commit status). A genuine pending is "review
# running, wait". But a pending that is really CR stuck after posting its rate-limit
# notice (CR_RATE_LIMITED, set above only when that notice is CR's latest comment) is
# NOT a running review: relax it when a current local /eng:cr review backstops it,
# else tell the operator exactly how to clear it rather than the misleading
# "in progress".
if [ "$CR_INPROGRESS" -eq 1 ]; then
  if [ "$CR_RATE_LIMITED" = "yes" ]; then
    [ "$CR_RL_BACKSTOPPED" = "yes" ] || { BLOCKERS+=("CodeRabbit is rate-limited (status stuck pending) and no current local review backstops it (run /eng:cr on this head, then land)"); CR_BLOCKED=1; }
  else
    BLOCKERS+=("CodeRabbit review in progress on this head"); CR_BLOCKED=1
  fi
fi
# A CodeRabbit commit status of "failure" (state_of folds error/timed_out/
# cancelled/action_required into "failure") is CR actively signaling a problem, not
# silence, so it blocks - it is NOT relaxed by the CR-unreviewable auto-satisfy
# below, which only covers the "CR posted nothing" (missing) case. The reviewed-head
# blocker then handles only the missing case. Two, and only two, things clear a
# failure, and BOTH require a current local /eng:cr review on this head:
#   - the failure is really a RATE LIMIT (CR_FAILURE_RATE_LIMITED, detected from the
#     status description and/or CR's marker comment). Machine-detectable, so it
#     auto-satisfies with the backstop and needs no flag - the same deal the missing
#     and stuck-pending rate-limit shapes already get.
#   - the operator explicitly passed --override-cr-failure for a GENUINE failure.
#     Human judgment, so it is never inferred.
case "$CR_FAILURE_DISPOSITION" in
  cleared-rate-limited|cleared-override|n/a|override-inert) ;;
  block-rate-limited-unbackstopped)
    BLOCKERS+=("CodeRabbit is rate-limited (status failure on this head) and no current local review backstops it (run /eng:cr on this head, then land)")
    CR_BLOCKED=1 ;;
  block-override-needs-review)
    BLOCKERS+=("--override-cr-failure passed but the local /review is ${REVIEW_STATE} for this head; the override still requires a current /eng:cr review (run it, then retry)")
    CR_BLOCKED=1 ;;
  *)
    # Default deny: block-genuine, and any token a future lib change might add.
    BLOCKERS+=("CodeRabbit status is failure on this head (genuine CR failure: fix it, or pass --override-cr-failure with a current /eng:cr review)")
    CR_BLOCKED=1 ;;
esac
if [ "$CR_STATUS_STATE" != "pending" ] && [ "$CR_REVIEWED_HEAD" = "no" ] \
   && { [ "$CR_STATUS_STATE" = "missing" ] || [ "$CR_STATUS_RL" = "yes" ]; } \
   && [ "$CR_HEAD_UNREVIEWABLE" != "yes" ] && [ "$CR_RL_BACKSTOPPED" != "yes" ]; then
  if [ "$CR_RATE_LIMITED" = "yes" ]; then
    # Rate-limited but no current local review to backstop it: tell the operator
    # exactly how to clear it rather than emitting the generic "not reviewed" line.
    BLOCKERS+=("CodeRabbit is rate-limited and no current local review backstops it (run /eng:cr on this head, then land)")
  else
    BLOCKERS+=("CodeRabbit has not reviewed the current head yet")
  fi
  CR_BLOCKED=1
fi
if [ "$SKIP_REVIEW" -eq 0 ] && { [ "$REVIEW_STATE" = "missing" ] || [ "$REVIEW_STATE" = "stale" ]; }; then
  BLOCKERS+=("local /review ${REVIEW_STATE} for this head (run /review, or pass --skip-review)")
fi
if [ "$SKIP_QA" -eq 0 ] && [ "$QA_STATE" = "incomplete" ]; then
  BLOCKERS+=("PR body QA checklist has unchecked boxes (complete them, or pass --skip-qa)")
fi
if [ "$SKIP_QA" -eq 0 ] && [ "$QA_STATE" = "missing" ]; then
  BLOCKERS+=("PR body has no QA plan and this repo requires one (run /qa:plan, or pass --skip-qa)")
fi
[ "$IS_DRAFT" = "true" ] && BLOCKERS+=("PR is a draft")
[ "$STATE" = "OPEN" ] || BLOCKERS+=("PR state is ${STATE}, not OPEN")

CLEAR=0; [ "${#BLOCKERS[@]}" -eq 0 ] && CLEAR=1

# ---- render checklist -------------------------------------------------------
mark() { case "$1" in ok) printf '✅';; warn) printf '⚠️ ';; bad) printf '❌';; esac; }

ci_mark=bad;     [ "$CI_STATE" = success ] && ci_mark=ok
# CodeRabbit mark: green iff nothing in the CodeRabbit family is blocking. It reads
# CR_BLOCKED (set beside every CR blocker above) rather than re-deriving those
# conditions, so the mark cannot disagree with the verdict. An operator override
# renders ⚠️ (warn), matching how --skip-review / --skip-qa surface: cleared, but
# visibly not on the strength of the machine check.
cr_mark=bad
[ "$CR_BLOCKED" -eq 0 ] && cr_mark=ok
[ "$CR_FAILURE_OVERRIDDEN" = "yes" ] && [ "$CR_BLOCKED" -eq 0 ] && cr_mark=warn
rev_mark=bad;    case "$REVIEW_STATE" in current) rev_mark=ok;; n/a) rev_mark=warn;; esac
                 [ "$SKIP_REVIEW" -eq 1 ] && rev_mark=warn
qa_mark=bad;     case "$QA_STATE" in complete) qa_mark=ok;; n/a) qa_mark=warn;; esac
                 [ "$SKIP_QA" -eq 1 ] && qa_mark=warn

{
  echo "### Merge clearance - $REPO#$PR_NUM"
  echo "_${PR_TITLE}_"
  echo "head \`${HEAD:0:12}\` → \`$BASE\`"
  echo
  echo "- [$([ $ci_mark = ok ] && echo x || echo ' ')] **CI** - $(mark $ci_mark) ${CI_DETAIL:-no required checks}"
  cr_head_note="reviewed-head=${CR_REVIEWED_HEAD}"
  [ "$CR_HEAD_UNREVIEWABLE" = "yes" ] && cr_head_note="reviewed-head=${CR_REVIEWED_HEAD} (auto-satisfied: HEAD diff is CR-unreviewable, e.g. *.pen)"
  # Only claim the reviewed-head dimension was AUTO-SATISFIED when it actually needed
  # rescuing. In the failure-status rate-limit shape CR has often already reviewed
  # HEAD (reviewed-head=yes) and only the status is rate-limited, so attaching the
  # note there would credit the backstop for something CR did on its own.
  [ "$CR_RL_BACKSTOPPED" = "yes" ] && [ "$CR_REVIEWED_HEAD" = "no" ] \
    && cr_head_note="reviewed-head=${CR_REVIEWED_HEAD} (auto-satisfied: CR rate-limited, current local /eng:cr review backstops)"
  cr_verdict_note="verdict=${CR_VERDICT}"
  [ "$CR_VERDICT" = "unresolved-waived" ] && cr_verdict_note="verdict=${CR_VERDICT} (only OUTDATED CR threads left unresolved; CR status green on HEAD; current threads would still block)"
  # The status cell states WHICH of the two failure escapes applied, so a cleared
  # failure is never indistinguishable from a green one in the rendered checklist.
  cr_status_note="status=${CR_STATUS_STATE}"
  [ "$CR_STATUS_RL" = "yes" ] && cr_status_note="status=success but RATE LIMITED (CR published green without reviewing)"
  case "$CR_FAILURE_DISPOSITION" in
    cleared-rate-limited) cr_status_note="status=failure (auto-satisfied: rate-limited, current local /eng:cr review backstops)" ;;
    cleared-override)     cr_status_note="status=failure (OPERATOR OVERRIDE --override-cr-failure; current local /eng:cr review backstops)" ;;
  esac
  if [ "$CR_SKIPPED" = "yes" ]; then
    # Rendered, never omitted: an invisible bypass is the bug, not the feature.
    echo "- [x] **CodeRabbit** - $(mark warn) SKIPPED (machine-local opt-out: ${CR_SKIP_REASON})"
  else
    echo "- [$([ $cr_mark = ok ] && echo x || echo ' ')] **CodeRabbit** - $(mark $cr_mark) ${cr_verdict_note}, ${cr_status_note}, ${cr_head_note}"
  fi
  echo "- [$([ $rev_mark = ok ] && echo x || echo ' ')] **Local /review** - $(mark $rev_mark) ${REVIEW_STATE}$([ $SKIP_REVIEW = 1 ] && echo ' (skipped)')"
  echo "- [$([ $qa_mark = ok ] && echo x || echo ' ')] **QA checklist** - $(mark $qa_mark) ${QA_STATE}$([ $SKIP_QA = 1 ] && echo ' (skipped)')"
  [ "$IS_BOOKKEEPING" = "yes" ] && echo "- ⚡ **Bookkeeping fast-lane** - diff is docs/inventory only; /review + QA auto-waived (CI + CodeRabbit still enforced)"
  # Local merge-gate readiness (informational; NOT a clearance dimension, so it
  # never blocks `clear`). The land-deploy sentinel is what makes /land-and-deploy
  # the single CLI merge path; showing its state lets `status` explain why a bare
  # `gh pr merge` would be blocked even when clearance is green.
  if [ -n "$GITDIR" ]; then
    ld_sentinel=$(cat "$GITDIR/land-deploy-clearance" 2>/dev/null || echo "")
    ld_repo=$(git remote get-url origin 2>/dev/null | sed -E 's#^[^:]+://[^/]+/##; s#^[^@]+@[^:]+:##; s#\.git$##')
    ld_verdict=$(ld_sentinel_valid "$ld_sentinel" "$(date +%s)" 1800 "$HEAD" "$ld_repo" "$PR_NUM")
    ld_mark=warn; [ "$ld_verdict" = valid ] && ld_mark=ok
    echo "- [$([ $ld_mark = ok ] && echo x || echo ' ')] **land-deploy sentinel** - $(mark $ld_mark) ${ld_verdict} (required for \`gh pr merge\`; minted only by /land-and-deploy, not by a bare clear)"
  fi
  echo
  if [ "$CLEAR" -eq 1 ]; then
    echo "**Verdict: CLEAR.** Safe to clear and merge."
  else
    echo "**Verdict: NOT CLEAR.**"
    for b in "${BLOCKERS[@]}"; do echo "  - $b"; done
  fi
}

if [ "$WANT_JSON" -eq 1 ]; then
  jq -nc \
    --arg repo "$REPO" --argjson pr "$PR_NUM" --arg head "$HEAD" --arg base "$BASE" \
    --arg ci "$CI_STATE" --arg cr "$CR_VERDICT" --arg crstatus "$CR_STATUS_STATE" \
    --arg review "$REVIEW_STATE" --arg qa "$QA_STATE" --argjson clear "$CLEAR" \
    --arg crhead "$CR_REVIEWED_HEAD" --arg crheadauto "$CR_HEAD_UNREVIEWABLE" \
    --arg crratelimited "$CR_RATE_LIMITED" --arg crrlbackstop "$CR_RL_BACKSTOPPED" \
    --arg crfailrl "$CR_FAILURE_RATE_LIMITED" --arg crfailoverride "$CR_FAILURE_OVERRIDDEN" \
    --arg crfaildisp "$CR_FAILURE_DISPOSITION" \
    --argjson bk "$([ "$IS_BOOKKEEPING" = "yes" ] && echo true || echo false)" \
    --argjson blockers "$(printf '%s\n' "${BLOCKERS[@]:-}" | jq -R . | jq -sc 'map(select(length>0))')" \
    '{repo:$repo, pr:$pr, head:$head, base:$base, ci:$ci, coderabbit:$cr, coderabbit_status:$crstatus,
      coderabbit_reviewed_head:$crhead, coderabbit_head_auto_satisfied:($crheadauto=="yes"),
      coderabbit_rate_limited:($crratelimited=="yes"), coderabbit_rate_limit_backstopped:($crrlbackstop=="yes"),
      coderabbit_failure_rate_limited:($crfailrl=="yes"), coderabbit_failure_overridden:($crfailoverride=="yes"),
      coderabbit_failure_disposition:$crfaildisp,
      review:$review, qa:$qa, bookkeeping_fast_lane:$bk, clear:($clear==1), blockers:$blockers}'
fi

# ---- check: exit reflects the verdict --------------------------------------
if [ "$VERB" = "check" ] || [ "$VERB" = "status" ]; then
  [ "$CLEAR" -eq 1 ] && exit 0 || exit 1
fi

# ---- clear: only on a clean verdict, write stamp + post status -------------
if [ "$CLEAR" -ne 1 ]; then
  err "merge-clearance: refusing to clear $REPO#$PR_NUM - not clear (see checklist above)."
  exit 1
fi

NOW=$(date +%s)
ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
case "$TTL" in ''|*[!0-9]*) TTL="$DEFAULT_TTL" ;; esac

# Audit trail: when the reviewed-head dimension was auto-satisfied (CR silent on
# a CR-unreviewable-only HEAD), record it in the stamp evidence and the posted
# status description so the bypass is greppable later, never silent.
CR_HEAD_EVIDENCE="reviewed-head=${CR_REVIEWED_HEAD}"
[ "$CR_HEAD_UNREVIEWABLE" = "yes" ] && CR_HEAD_EVIDENCE="auto-satisfied: CR-unreviewable-only HEAD"
[ "$CR_RL_BACKSTOPPED" = "yes" ] && [ "$CR_REVIEWED_HEAD" = "no" ] \
  && CR_HEAD_EVIDENCE="auto-satisfied: CR rate-limited, local review backstops"

# Same for the CR commit status: when a "failure" was cleared, the evidence records
# WHICH escape did it, so an audit of the stamp never has to guess.
CR_STATUS_EVIDENCE="$CR_STATUS_STATE"
case "$CR_FAILURE_DISPOSITION" in
  cleared-rate-limited) CR_STATUS_EVIDENCE="failure auto-satisfied: rate-limited, local /eng:cr review backstops" ;;
  cleared-override)     CR_STATUS_EVIDENCE="failure OVERRIDDEN by operator --override-cr-failure (local /eng:cr review backstops)" ;;
esac

STAMP_JSON=$(jq -nc \
  --argjson pr "$PR_NUM" --arg head "$HEAD" --arg base "$BASE" \
  --arg iso "$ISO" --argjson epoch "$NOW" --argjson ttl "$TTL" \
  --arg ci "$CI_STATE" --arg cr "$CR_VERDICT" --arg review "$REVIEW_STATE" --arg qa "$QA_STATE" \
  --arg crhead "$CR_HEAD_EVIDENCE" --arg crstatus "$CR_STATUS_EVIDENCE" \
  --argjson override "$([ "$CR_FAILURE_OVERRIDDEN" = "yes" ] && echo true || echo false)" \
  --argjson bk "$([ "$IS_BOOKKEEPING" = "yes" ] && echo true || echo false)" \
  '{pr:$pr, head:$head, base:$base, checked_at:$iso, checked_at_epoch:$epoch,
    ttl_seconds:$ttl, tool:"land-and-deploy",
    evidence:{ci:$ci, coderabbit:$cr, coderabbit_head:$crhead,
              coderabbit_status:$crstatus, coderabbit_failure_overridden:$override,
              review:$review, qa:$qa, bookkeeping_fast_lane:$bk}}')

# GitHub commit status - the hard authority the branch ruleset requires. The
# description carries the auto-satisfy note when it applied, so the audit trail
# is visible on the commit status itself (descriptions cap ~140 chars).
# Built by ACCUMULATING every applicable note, not by a run of last-wins overwrites.
# Overwrites silently dropped information: a docs-only PR whose CR status failed on a
# rate limit posted only the bookkeeping note, so the most security-relevant fact
# (a hard CR failure was auto-satisfied) vanished from the most durable audit
# surface, while the local stamp still recorded it. The two disagreeing is the exact
# failure this file exists to prevent. Order is by importance, and the join is
# truncated to GitHub's ~140-char description cap, so the leading (most important)
# note always survives.
DESC_NOTES=()
[ "$CR_FAILURE_OVERRIDDEN" = "yes" ] && DESC_NOTES+=("OPERATOR OVERRIDE --override-cr-failure on a genuine CR failure, local review backstops")
[ "$CR_FAILURE_DISPOSITION" = "cleared-rate-limited" ] && DESC_NOTES+=("CR status failure = rate limit, local review backstops")
[ "$CR_RL_BACKSTOPPED" = "yes" ] && [ "$CR_REVIEWED_HEAD" = "no" ] && DESC_NOTES+=("CR rate-limited, local review backstops")
[ "$CR_HEAD_UNREVIEWABLE" = "yes" ] && DESC_NOTES+=("CR-head auto-satisfied: unreviewable-only HEAD")
[ "$CR_VERDICT" = "unresolved-waived" ] && DESC_NOTES+=("CR green on HEAD, only OUTDATED CR threads waived")
[ "$IS_BOOKKEEPING" = "yes" ] && DESC_NOTES+=("bookkeeping fast-lane: docs/inventory only, review+QA waived")
STATUS_DESC="Cleared by merge-clearance ($ISO)"
if [ "${#DESC_NOTES[@]}" -gt 0 ]; then
  # printf reuses the format once per argument; strip the leading separator.
  # (IFS + ${arr[*]} would join on only the FIRST character of IFS, not "; ".)
  DESC_JOINED=$(printf '; %s' "${DESC_NOTES[@]}"); DESC_JOINED=${DESC_JOINED#'; '}
  STATUS_DESC="Cleared ($ISO); ${DESC_JOINED}"
  STATUS_DESC="${STATUS_DESC:0:140}"
fi
if gh api -X POST "repos/$REPO/statuses/$HEAD" \
     -f state=success \
     -f context="$CLEARANCE_CONTEXT" \
     -f description="$STATUS_DESC" >/dev/null 2>&1; then
  err "merge-clearance: posted $CLEARANCE_CONTEXT=success on ${HEAD:0:12}"
  # Local stamp (consumed by pr-merge-gate.sh) is written only AFTER the
  # authoritative GitHub status posted, so a failed POST never leaves a valid
  # local stamp behind for the TTL window. Only meaningful inside a checkout.
  if [ -n "$GITDIR" ]; then
    printf '%s\n' "$STAMP_JSON" > "$GITDIR/merge-clearance-head" \
      && err "merge-clearance: wrote local stamp $GITDIR/merge-clearance-head (ttl ${TTL}s)" \
      || err "merge-clearance: WARNING could not write local stamp ($GITDIR/merge-clearance-head)"
  else
    err "merge-clearance: not in a checkout - skipping local stamp (GitHub status still posted)"
  fi
else
  err "merge-clearance: ERROR failed to post $CLEARANCE_CONTEXT status (check gh auth / repo perms)"
  exit 1
fi

err "merge-clearance: CLEARED $REPO#$PR_NUM - ok to merge within ${TTL}s."
exit 0
