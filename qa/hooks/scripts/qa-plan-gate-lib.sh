#!/bin/bash
# Pure, side-effect-free decision logic for the QA-plan approval gates, extracted
# so it can be unit tested (tests/qa-plan-gate.bats) without a live repo, a
# transcript, or any hook plumbing. Every function takes everything it needs as
# arguments and writes only to stdout.
#
# Policy (BUILD-PROCEDURE.md non-negotiable #4): the two-phase QA plan must be
# PRESENTED to and APPROVED by the human BEFORE building, BEFORE the PR goes up,
# and verified-passed BEFORE deploy. /qa:plan ends with an AskUserQuestion
# approval gate that writes an approval stamp; these helpers are what the three
# gates use to read it.
#
# Consumers:
#   scripts/qa-plan-build-gate.sh - PreToolUse Edit|Write: block source edits
#                                   until the branch has an approval stamp.
#   scripts/qa-plan-pr-gate.sh    - PreToolUse Bash: block `gh pr create` until
#                                   the branch has an approval stamp.
#   scripts/qa-plan-stamp.sh      - writes the stamp in the canonical shape.
#   scripts/merge-clearance.sh    - reads the marker to require QA-passed at merge.
#
# Requires jq for the JSON helpers. Every gate fails OPEN (allowing the action)
# before sourcing this when jq is absent, so a jq-less host never reaches here.

# qpg_stamp_valid <stamp_json> <branch>
#   Decide whether an approval stamp authorizes building / PRing on <branch>.
#   Echoes "valid" on success, else a single-word reason (no-stamp | malformed |
#   wrong-branch). Return code mirrors the verdict (0 valid, 1 otherwise).
#
#   A stamp is a JSON object written by `qa-plan-stamp.sh write`:
#     { "branch": "<name>", "approved_at": "<iso8601>",
#       "approved_at_epoch": <int>, "head_at_approval": "<sha>",
#       "criteria_digest": "<hex>", "approver": "<who>", "tool": "qa-plan" }
#   Validity is keyed on BRANCH, not HEAD: an approved plan stays approved as the
#   branch's commits accumulate during the build. (HEAD-keyed re-verification is
#   the deploy gate's job, via the QA-passed checklist at merge time.) There is
#   deliberately no TTL: a plan approved for a line of work does not "expire"
#   mid-build; abandoning the branch is what ends it.
qpg_stamp_valid() {
  local stamp="$1" branch="$2"

  if [ -z "$stamp" ]; then echo "no-stamp"; return 1; fi

  local s_branch
  s_branch=$(printf '%s' "$stamp" | jq -r '.branch // empty' 2>/dev/null) \
    || { echo "malformed"; return 1; }
  [ -n "$s_branch" ] || { echo "malformed"; return 1; }

  [ "$s_branch" = "$branch" ] || { echo "wrong-branch"; return 1; }

  echo "valid"; return 0
}

# qpg_is_spike <branch>
#   The escape hatch for genuine spikes / exploration: a branch whose name starts
#   with "spike/" is exempt from the build gate (you cannot write a meaningful QA
#   plan for code you are still discovering). Echoes "spike" / "no"; return code
#   0 when it IS a spike. Only the "spike/" prefix counts, so "spike-fix" or a
#   feature branch that merely contains the word does not accidentally bypass.
qpg_is_spike() {
  local branch="$1"
  case "$branch" in
    spike/*) echo "spike"; return 0 ;;
    *) echo "no"; return 1 ;;
  esac
}

# qpg_path_needs_plan <path>
#   Classify an Edit/Write target as application SOURCE (needs an approved plan)
#   or a carved-out non-source file (always allowed). Echoes "source" / "carveout";
#   return code 0 when it needs a plan (is source). The classifier is an
#   allowlist of carve-outs; anything not matched is treated as source, so the
#   gate errs toward gating (the strict posture the human chose).
#
#   Carve-outs (allowed without a plan):
#     - docs:    *.md *.mdx *.markdown *.txt *.rst *.adoc
#     - config:  *.json *.jsonl *.yaml *.yml *.toml *.ini *.cfg *.conf *.env *.lock
#                *.properties, dotfiles like .gitignore / .editorconfig
#     - tests:   any path segment test/ tests/ spec/ __tests__/ __mocks__/, or a
#                basename test_* / *_test.* / *.test.* / *.spec.* / *_spec.*
#     - vcs/meta: anything under a .git/ segment, plus the gate's own marker/stamp
qpg_path_needs_plan() {
  local path="$1"
  local base="${path##*/}"

  # vcs / gate internals - never gated
  case "/$path" in
    */.git/*) echo "carveout"; return 1 ;;
  esac
  case "$base" in
    .qa-plan-gate.json|qa-plan-approved) echo "carveout"; return 1 ;;
  esac

  # test locations (path segment) and test-named files (basename)
  case "/$path/" in
    */test/*|*/tests/*|*/spec/*|*/specs/*|*/__tests__/*|*/__mocks__/*|*/testdata/*|*/fixtures/*)
      echo "carveout"; return 1 ;;
  esac
  case "$base" in
    test_*|*_test.*|*.test.*|*.spec.*|*_spec.*|conftest.py)
      echo "carveout"; return 1 ;;
  esac

  # docs + config by extension; dotfiles that are config
  case "$base" in
    *.md|*.mdx|*.markdown|*.txt|*.rst|*.adoc) echo "carveout"; return 1 ;;
    *.json|*.jsonl|*.yaml|*.yml|*.toml|*.ini|*.cfg|*.conf|*.env|*.lock|*.properties)
      echo "carveout"; return 1 ;;
    .gitignore|.gitattributes|.editorconfig|.dockerignore|.npmignore|.prettierignore)
      echo "carveout"; return 1 ;;
  esac

  echo "source"; return 0
}

# qpg_is_bookkeeping <newline-separated-paths>
#   Echo "yes" iff the changeset is NON-EMPTY and EVERY path is a "bookkeeping"
#   file: documentation or the cross-host service inventory. These are zero-risk,
#   non-code changes that should not pay the full ship-time ceremony (the /qa:plan
#   approval modal, the /eng:cr stamp, the CodeRabbit re-stamp cycle). Echoes "no"
#   and returns 1 otherwise. Fails CLOSED: an empty list, OR a single path outside
#   the allowlist, yields "no", so a code change can never ride the fast lane by
#   being bundled with docs.
#
#   Allowlist (matched on the basename):
#     - docs:      *.md *.mdx *.markdown *.txt *.rst
#     - inventory: where-things-run.json  (the cross-host service inventory ONLY;
#                  NOT *.json broadly - app config like buckets.yaml stays gated)
#   Excluded even though they end in .md: SKILL.md / CLAUDE.md / AGENTS.md are
#   agent-instruction files - executable contracts that change runtime behavior
#   when edited, NOT inert prose. A PR that rewrites one is a behavior change and
#   must get the full review, so it is forced off the fast lane (checked before
#   the *.md arm so it wins).
#   Deliberately TIGHTER than qpg_path_needs_plan's build-gate carve-out, which is
#   lenient on all *.json/*.yaml because an edit is cheap to undo before it ships.
#   A ship gate must be narrow: merging is the act that reaches production.
#   Twin of mc_is_bookkeeping in the eng plugin's merge-clearance-lib.sh; keep the
#   two allowlists in lockstep (each plugin is self-contained and binds its own).
qpg_is_bookkeeping() {
  local paths="$1" p base any=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    any=1
    base="${p##*/}"
    case "$base" in
      SKILL.md|CLAUDE.md|AGENTS.md) echo "no"; return 1 ;;
      *.md|*.mdx|*.markdown|*.txt|*.rst) ;;
      where-things-run.json) ;;
      *) echo "no"; return 1 ;;
    esac
  done <<EOF
$paths
EOF
  [ "$any" -eq 1 ] && { echo "yes"; return 0; }
  echo "no"; return 1
}

# qpg_marker_gates <marker_json>
#   Which gates this repo's .qa-plan-gate.json marker turns on. Echoes a
#   space-separated subset of "build pr deploy". A marker that omits "gates"
#   (or whose value is not a non-empty array) enables ALL THREE - presence of the
#   marker means "opt this repo into the full policy" unless it explicitly narrows.
qpg_marker_gates() {
  local marker="$1"
  local gates
  gates=$(printf '%s' "$marker" | jq -r '
    if (.gates | type) == "array" and (.gates | length) > 0
    then (.gates | join(" "))
    else "build pr deploy" end
  ' 2>/dev/null) || gates="build pr deploy"
  [ -n "$gates" ] || gates="build pr deploy"
  echo "$gates"
}

# qpg_gate_enabled <marker_json> <gate>
#   Return 0 if <gate> (build|pr|deploy) is enabled by the marker. Convenience
#   wrapper over qpg_marker_gates for callers that just want a boolean.
qpg_gate_enabled() {
  local marker="$1" gate="$2" g
  for g in $(qpg_marker_gates "$marker"); do
    [ "$g" = "$gate" ] && return 0
  done
  return 1
}

# qpg_base_in_scope <marker_json> <base_branch>
#   Does the marker scope enforcement to <base_branch>? Mirrors the merge/ship
#   gates: default ["main"] when the marker is silent. Echoes "in" / "out";
#   return code 0 when in scope. An empty <base_branch> (could not resolve) is
#   treated as in-scope (fail toward gating on the scope check; the rest of each
#   gate still fails open on its own errors).
qpg_base_in_scope() {
  local marker="$1" base="$2"
  [ -z "$base" ] && { echo "in"; return 0; }
  local bases
  bases=$(printf '%s' "$marker" | jq -r '(.base_branches // ["main"]) | .[]' 2>/dev/null) \
    || { echo "in"; return 0; }
  if printf '%s\n' "$bases" | grep -qxF "$base"; then echo "in"; return 0; fi
  echo "out"; return 1
}
