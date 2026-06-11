#!/bin/bash
# merge-clearance - the sanctioned pre-merge gauntlet for an opted-in ~/dev repo.
#
# This is the workhorse behind the "make /land-and-deploy the only merge path"
# design. It answers one question for a PR: is this genuinely clear to land?
# "Clear" means, on the PR's CURRENT head commit:
#   - CI required checks are green
#   - CodeRabbit has finished reviewing and left nothing unresolved
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

set -uo pipefail

LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/merge-clearance-lib.sh"
# shellcheck source=/dev/null
. "$LIB"

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
BASE_ARG=""; CHECKS_ARG=""; APPLY_PROTECTION=0
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
    --json) WANT_JSON=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

need gh; need jq; need git

# ---- enable: scaffold a repo's opt-in marker (and optionally protection) -----
# Porting the gate to a new repo is just dropping a .merge-clearance.json marker
# at its root and (for the GitHub-enforced half) flipping branch protection. This
# subcommand does both, auto-detecting the CI check context names so the marker is
# correct without hand-editing.
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

  MARKERFILE="$TOP/.merge-clearance.json"
  jq -nc --arg base "$BASE" --argjson checks "$CHECKS" \
    '{_comment:"Opt-in marker for the merge-clearance gate. Presence activates the eng plugin pr-merge-gate hook on the listed base branches and tells apply-merge-clearance-protection.sh which CI checks to require. Cleared via /land-and-deploy.",
      base_branches:[$base], required_checks:$checks}' \
    | jq . > "$MARKERFILE"
  err "merge-clearance enable: wrote $MARKERFILE"

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
  1. Commit .merge-clearance.json on a branch and open a PR (it must reach $BASE).
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
        reviewThreads(first:100){ nodes { isResolved comments(first:1){ nodes { author{ login } } } } }
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

# ---- required CI checks from the repo's opt-in marker -----------------------
# The marker lists which check contexts must be green. We deliberately do NOT
# include the clearance context itself (that would be circular: this script is
# what produces it). Default to ["ci"] when the marker is silent.
REQUIRED_CHECKS='["ci"]'
REQUIRE_QA_PLAN=0
# Globs whose files CodeRabbit does not review (gitignore / minimatch style).
# When a HEAD's only change is files matching these (or git-binary blobs), CR
# legitimately posts no review and the "CR reviewed HEAD" gate is auto-satisfied
# (see the CR-reviewed-head block below). Defaults to ["*.pen"] - encrypted-
# looking Pencil wireframes are plaintext JSON git treats as text, yet CR skips
# them - so the common case needs no per-repo config. A marker may override the
# list (extend it, or set [] to require CR on every file type).
CR_UNREVIEWABLE_GLOBS='["*.pen"]'
MARKER=""
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$TOPLEVEL" ] && [ -f "$TOPLEVEL/.merge-clearance.json" ] && MARKER="$TOPLEVEL/.merge-clearance.json"
if [ -n "$MARKER" ]; then
  mk=$(jq -c '.required_checks // empty' "$MARKER" 2>/dev/null || true)
  [ -n "$mk" ] && REQUIRED_CHECKS="$mk"
  # Opt-in: when require_qa_plan is true, a PR with no Dev QA checklist blocks
  # (run /qa:plan). Default false preserves prior behavior (no checklist -> n/a).
  case "$(jq -r '.require_qa_plan // false' "$MARKER" 2>/dev/null)" in true|1) REQUIRE_QA_PLAN=1 ;; esac
  # An explicit array (incl. []) wins over the default; an absent OR null key
  # leaves the default in place. "// empty" yields no output for both absent and
  # null (so $ug stays empty and the default holds), but emits [] for an explicit
  # empty array (so a marker can disable the default by setting []).
  ug=$(jq -c '.cr_unreviewable_globs // empty' "$MARKER" 2>/dev/null || true)
  [ -n "$ug" ] && CR_UNREVIEWABLE_GLOBS="$ug"
fi

# Gate 3 of the QA-plan approval policy (BUILD-PROCEDURE.md non-negotiable #4):
# a repo carrying a `.qa-plan-gate.json` marker with the "deploy" gate enabled
# requires QA to have PASSED before deploy. Folding it into REQUIRE_QA_PLAN reuses
# the mc_qa_state classifier: with it on, a PR whose Dev QA boxes are unchecked
# ("incomplete") or whose plan is absent ("missing") blocks, so only an all-boxes-
# checked ("complete") plan clears the merge. The build/PR halves of the same
# policy live in qa-plan-build-gate.sh / qa-plan-pr-gate.sh.
QPG_MARKER_FILE=""
[ -n "$TOPLEVEL" ] && [ -f "$TOPLEVEL/.qa-plan-gate.json" ] && QPG_MARKER_FILE="$TOPLEVEL/.qa-plan-gate.json"
if [ -n "$QPG_MARKER_FILE" ]; then
  QPG_LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa-plan-gate-lib.sh"
  if [ -f "$QPG_LIB" ]; then
    # shellcheck source=/dev/null
    . "$QPG_LIB"
    # Only enforce when the deploy gate is on AND this PR's base is in the
    # marker's scope (default ["main"]), mirroring qa-plan-build/pr-gate.sh.
    QPG_MARKER_JSON="$(cat "$QPG_MARKER_FILE" 2>/dev/null)"
    if qpg_gate_enabled "$QPG_MARKER_JSON" deploy \
       && [ "$(qpg_base_in_scope "$QPG_MARKER_JSON" "$BASE")" = "in" ]; then
      REQUIRE_QA_PLAN=1
    fi
  fi
fi

# ---- gather check / status state for HEAD ----------------------------------
# Merge check-runs (Actions) and commit statuses (CodeRabbit et al.) into one
# name->state map. Statuses come newest-first; keep only the first per context.
CHECKRUNS=$(gh api --paginate "repos/$REPO/commits/$HEAD/check-runs" \
              -q '.check_runs[] | {name:.name, state:(.conclusion // .status)}' 2>/dev/null \
            | jq -sc '.' || echo '[]')
STATUSES=$(gh api "repos/$REPO/commits/$HEAD/statuses" \
              -q '.[] | {name:.context, state:.state}' 2>/dev/null \
            | jq -sc 'reduce .[] as $s ({}; if has($s.name) then . else . + {($s.name):$s.state} end)
                      | to_entries | map({name:.key, state:.value})' || echo '[]')
CHECKMAP=$(jq -cn --argjson a "$CHECKRUNS" --argjson b "$STATUSES" '$a + $b')

# state_of <context-name> -> success|failure|pending|missing (success conclusions
# from check-runs are "success"; a completed status is "success"; everything not
# yet conclusive is "pending"; absent is "missing").
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
CR_VERDICT=$(mc_cr_verdict "$THREADS" "$REVIEWS"); CR_RC=$?
CR_STATUS_STATE=$(state_of "CodeRabbit")          # CR's own commit status context
CR_REVIEWED_HEAD=$(mc_cr_reviewed_head "$REVIEWS" "$HEAD")
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
if [ "$CR_STATUS_STATE" != "pending" ] && [ "$CR_REVIEWED_HEAD" = "no" ] && [ "$CR_STATUS_STATE" = "missing" ]; then
  CR_HEAD_UNREVIEWABLE=$(mc_head_cr_unreviewable "$(head_changed_files "$HEAD")" "$CR_UNREVIEWABLE_GLOBS")
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
# Hard blockers: CI not green, CR not clear, CR mid-review, CR hasn't seen HEAD.
# Soft blockers (block unless --skip-*): /review missing-or-stale, QA incomplete.
BLOCKERS=()
[ "$CI_STATE" = "success" ] || BLOCKERS+=("CI is ${CI_STATE} (${CI_DETAIL})")
if [ "$CR_RC" -ne 0 ]; then BLOCKERS+=("CodeRabbit ${CR_VERDICT}"); fi
[ "$CR_INPROGRESS" -eq 0 ] || BLOCKERS+=("CodeRabbit review in progress on this head")
# A CodeRabbit commit status of "failure" (state_of folds error/timed_out/
# cancelled/action_required into "failure") is CR actively signaling a problem,
# not silence, so it blocks unconditionally - it is NOT relaxed by the
# CR-unreviewable auto-satisfy below, which only covers the "CR posted nothing"
# (missing) case. The reviewed-head blocker then handles only the missing case.
[ "$CR_STATUS_STATE" != "failure" ] || BLOCKERS+=("CodeRabbit status is failure on this head")
if [ "$CR_STATUS_STATE" != "pending" ] && [ "$CR_REVIEWED_HEAD" = "no" ] && [ "$CR_STATUS_STATE" = "missing" ] \
   && [ "$CR_HEAD_UNREVIEWABLE" != "yes" ]; then
  BLOCKERS+=("CodeRabbit has not reviewed the current head yet")
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
cr_mark=bad;     [ "$CR_RC" -eq 0 ] && [ "$CR_INPROGRESS" -eq 0 ] && cr_mark=ok
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
  echo "- [$([ $cr_mark = ok ] && echo x || echo ' ')] **CodeRabbit** - $(mark $cr_mark) verdict=${CR_VERDICT}, status=${CR_STATUS_STATE}, ${cr_head_note}"
  echo "- [$([ $rev_mark = ok ] && echo x || echo ' ')] **Local /review** - $(mark $rev_mark) ${REVIEW_STATE}$([ $SKIP_REVIEW = 1 ] && echo ' (skipped)')"
  echo "- [$([ $qa_mark = ok ] && echo x || echo ' ')] **QA checklist** - $(mark $qa_mark) ${QA_STATE}$([ $SKIP_QA = 1 ] && echo ' (skipped)')"
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
    --argjson blockers "$(printf '%s\n' "${BLOCKERS[@]:-}" | jq -R . | jq -sc 'map(select(length>0))')" \
    '{repo:$repo, pr:$pr, head:$head, base:$base, ci:$ci, coderabbit:$cr, coderabbit_status:$crstatus,
      coderabbit_reviewed_head:$crhead, coderabbit_head_auto_satisfied:($crheadauto=="yes"),
      review:$review, qa:$qa, clear:($clear==1), blockers:$blockers}'
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

STAMP_JSON=$(jq -nc \
  --argjson pr "$PR_NUM" --arg head "$HEAD" --arg base "$BASE" \
  --arg iso "$ISO" --argjson epoch "$NOW" --argjson ttl "$TTL" \
  --arg ci "$CI_STATE" --arg cr "$CR_VERDICT" --arg review "$REVIEW_STATE" --arg qa "$QA_STATE" \
  --arg crhead "$CR_HEAD_EVIDENCE" \
  '{pr:$pr, head:$head, base:$base, checked_at:$iso, checked_at_epoch:$epoch,
    ttl_seconds:$ttl, tool:"land-and-deploy",
    evidence:{ci:$ci, coderabbit:$cr, coderabbit_head:$crhead, review:$review, qa:$qa}}')

# Local stamp (consumed by pr-merge-gate.sh). Only meaningful inside a checkout.
if [ -n "$GITDIR" ]; then
  printf '%s\n' "$STAMP_JSON" > "$GITDIR/merge-clearance-head" \
    && err "merge-clearance: wrote local stamp $GITDIR/merge-clearance-head (ttl ${TTL}s)" \
    || err "merge-clearance: WARNING could not write local stamp ($GITDIR/merge-clearance-head)"
else
  err "merge-clearance: not in a checkout - skipping local stamp (GitHub status still posted)"
fi

# GitHub commit status - the hard authority the branch ruleset requires. The
# description carries the auto-satisfy note when it applied, so the audit trail
# is visible on the commit status itself (descriptions cap ~140 chars).
STATUS_DESC="Cleared by merge-clearance ($ISO)"
[ "$CR_HEAD_UNREVIEWABLE" = "yes" ] && STATUS_DESC="Cleared ($ISO); CR-head auto-satisfied: unreviewable-only HEAD"
if gh api -X POST "repos/$REPO/statuses/$HEAD" \
     -f state=success \
     -f context="$CLEARANCE_CONTEXT" \
     -f description="$STATUS_DESC" >/dev/null 2>&1; then
  err "merge-clearance: posted $CLEARANCE_CONTEXT=success on ${HEAD:0:12}"
else
  err "merge-clearance: ERROR failed to post $CLEARANCE_CONTEXT status (check gh auth / repo perms)"
  exit 1
fi

err "merge-clearance: CLEARED $REPO#$PR_NUM - ok to merge within ${TTL}s."
exit 0
