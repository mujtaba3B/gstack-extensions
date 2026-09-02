#!/bin/bash
# Pure, side-effect-free decision logic for the QA-plan approval gates, extracted
# so it can be unit tested (tests/qa-plan-gate.bats) without a live repo, a
# transcript, or any hook plumbing. Every function takes everything it needs as
# arguments and writes only to stdout.
#
# Policy (the two-phase QA-plan approval policy): the two-phase QA plan must be
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
#       "criteria_digest": "<hex>", "approver": "<who>",
#       "approval_source": "AskUserQuestion", "approval_nonce": "<hex>",
#       "tool": "qa-plan" }
#   Validity is keyed on BRANCH, not HEAD: an approved plan stays approved as the
#   branch's commits accumulate during the build. (HEAD-keyed re-verification is
#   the deploy gate's job, via the QA-passed checklist at merge time.) There is
#   deliberately no TTL: a plan approved for a line of work does not "expire"
#   mid-build; abandoning the branch is what ends it.
#
#   TWO CHECKS WERE ADDED FOR gstack-extensions#71:
#
#   1. `approval_source` must be present ("unattested" otherwise). Stamps written
#      before the approval-token fix carry no such field, and there is no way to
#      tell one a human approved from one an agent wrote. They therefore FAIL
#      CLOSED and must be re-approved. This is the deliberate answer to that
#      issue's back-compat question: silently honoring them would carry the exact
#      ambiguity the fix exists to remove, and the cost is one re-approval on any
#      branch still carrying a pre-fix stamp.
#
#   2. An optional <current_digest>. When the caller can see the plan the change
#      is actually shipping (the PR gate reads it out of the `gh pr create` body),
#      it passes the digest and a mismatch is "plan-changed": the plan was edited
#      after the human approved it, so the approval no longer covers what is being
#      shipped and a fresh one is required. This is the check that catches a
#      SCOPED approval being carried forward as a STANDING one, which is how the
#      2026-09-02 incident actually happened: a real approval for one piece of
#      work, extended to later work with a different plan.
#
#      Callers that cannot see the plan (the build gate, which runs before any PR
#      exists) omit it and get branch-scoped validity, exactly as before.
qpg_stamp_valid() {
  local stamp="$1" branch="$2" current_digest="${3:-}"

  if [ -z "$stamp" ]; then echo "no-stamp"; return 1; fi

  local s_branch
  s_branch=$(printf '%s' "$stamp" | jq -r '.branch // empty' 2>/dev/null) \
    || { echo "malformed"; return 1; }
  [ -n "$s_branch" ] || { echo "malformed"; return 1; }

  [ "$s_branch" = "$branch" ] || { echo "wrong-branch"; return 1; }

  # Plan-drift check, evaluated BEFORE the attestation verdict. Order matters and
  # the first cut had it backwards: returning "unattested" first meant the LEAST
  # attested stamps got the FEWEST checks, so a pre-fix stamp was a standing,
  # drift-immune approval and its `## QA` section could be rewritten to anything.
  # That left the exact "scoped approval carried forward as standing" hole open on
  # precisely the branches the migration exists to honor, including the four from
  # the 2026-09-02 incident. Drift now applies to every stamp that carries a
  # digest, attested or not.
  #
  # Only meaningful when BOTH digests are real: a stamp whose criteria_digest is
  # "none" carries nothing to compare, and an empty <current_digest> means the
  # caller could not read the plan. Either way we fall through rather than
  # inventing a mismatch, so this check can only ever add a block, never remove one.
  if [ -n "$current_digest" ]; then
    local s_digest
    s_digest=$(printf '%s' "$stamp" | jq -r '.criteria_digest // empty' 2>/dev/null) || s_digest=""
    if [ -n "$s_digest" ] && [ "$s_digest" != "none" ] && [ "$s_digest" != "$current_digest" ]; then
      echo "plan-changed"; return 1
    fi
  fi

  local s_source
  s_source=$(printf '%s' "$stamp" | jq -r '.approval_source // empty' 2>/dev/null) || s_source=""
  [ -n "$s_source" ] || { echo "unattested"; return 1; }

  echo "valid"; return 0
}

# qpg_unattested_disposition <gate> <in_window>
#   What a gate does with an "unattested" stamp: one written before approval
#   tokens existed, which carries no proof a human ever approved it. <in_window>
#   is "in" when the stamp FILE predates the fix (qpt_unattested_in_window).
#   Echoes "allow" / "block"; return code 0 for allow.
#
#   TWO CONDITIONS, and the second one is the whole point. The first cut keyed the
#   carve-out on SHAPE alone, which made a forged stamp strictly EASIER to produce
#   than a real one: `printf '{"branch":"x"}' > .git/qa-plan-approved` opened both
#   gates, permanently, for anyone, with no token and no click. That is a wider
#   hole than the bug being fixed, and the test suite had pinned it as intended
#   behavior. A migration allowance must never be cheaper than the thing it is
#   migrating from, so it is now bounded by the stamp file's own mtime: only
#   stamps that already existed when this shipped are honored.
#
#   Why the gates still ALLOW rather than block inside that window: blocking was
#   tried this morning and backed out. This gate runs from the working tree the
#   moment a file is saved, while the minting hook needs a session restart to
#   register, so there was a window with no path to any valid stamp and every
#   gated repo lost `gh pr create`. A gate nobody can satisfy reliably produces an
#   override habit that outlives the outage. The forward guarantee is untouched:
#   every NEW stamp needs a human click, because qa-plan-stamp.sh cannot write one
#   without a token.
#
#   Out of the window, or an undatable stamp, blocks. An unknown gate name blocks,
#   so anything added later inherits the strict side.
qpg_unattested_disposition() {
  local gate="$1" in_window="${2:-out}"
  [ "$in_window" = "in" ] || { echo "block"; return 1; }
  case "$gate" in
    build|pr) echo "allow"; return 0 ;;
    *) echo "block"; return 1 ;;
  esac
}

# qpg_normalize_plan <text>
#   Canonicalize QA-plan text so a digest of it is stable across the edits that do
#   NOT constitute a plan change. Echoes the normalized text.
#
#   What is normalized away, and why each one matters:
#     - Tick state: a Dev QA row's box and a Definition-of-Done bullet flip from
#       unticked to ticked AS THE QA IS RUN. That is the plan being executed, not
#       the plan being changed, and treating it as a change would invalidate the
#       human's approval precisely when the driver started doing the work.
#     - Trailing whitespace and CRLF: invisible, and churned by editors.
#     - Leading / trailing blank lines: an artifact of how the section was sliced.
#   Everything else (a reworded check, a new row, a different tester, a changed
#   expectation) DOES change the digest, which is the point.
qpg_normalize_plan() {
  printf '%s' "$1" \
    | tr -d '\r' \
    | sed -e 's/\[[xX]\]/[ ]/g' -e 's/[[:space:]]*$//' \
    | sed -e '/./,$!d' \
    | awk 'BEGIN{n=0} {lines[n++]=$0} END{last=n-1; while(last>=0 && lines[last]=="") last--; for(i=0;i<=last;i++) print lines[i]}'
}

# qpg_plan_digest <text>
#   The canonical digest of a QA plan: sha256 of the normalized text. Echoes the
#   hex digest, or nothing when no sha256 tool is available (callers treat an
#   empty digest as "could not read the plan" and skip the drift check, so a host
#   without shasum degrades to the old branch-scoped behaviour rather than
#   blocking everything).
qpg_plan_digest() {
  local norm; norm=$(qpg_normalize_plan "$1")
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$norm" | shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$norm" | sha256sum | cut -d' ' -f1
  else
    printf ''
  fi
}

# qpg_extract_qa_section <pr_body_text>
#   Pull the `## QA` section out of a PR body: from the `## QA` heading to the
#   next top-level `##` heading, or end of body. Echoes the section (heading
#   included), or nothing when the body has no such section.
#
#   `###` subheadings (the Development / Production tables) stay INSIDE, matching
#   how merge-clearance reads the same section. A body with no `## QA` section
#   yields empty, which callers treat as "could not read the plan".
qpg_extract_qa_section() {
  printf '%s' "$1" | awk '
    /^##[[:space:]]+QA[[:space:]]*$/ { inq=1; print; next }
    inq && /^##[[:space:]]/ && !/^###/ { inq=0 }
    inq { print }
  '
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
#   Allowlist (matched on the basename), all of which are INERT - editing them
#   cannot change what runs in production:
#     - docs:       *.md *.mdx *.markdown *.txt *.rst
#     - inventory:  where-things-run.json  (the cross-host service inventory ONLY;
#                   NOT *.json broadly - app config like buckets.yaml stays gated)
#     - vcs holders: .keep .gitkeep  (empty placeholder files)
#     - vcs/meta:   .gitignore .gitattributes .editorconfig .dockerignore
#                   .npmignore .prettierignore .eslintignore .gcloudignore
#                   (ignore lists + editor hints; never executed)
#     - legal/gov:  LICENSE LICENCE COPYING NOTICE AUTHORS CONTRIBUTORS
#                   CODEOWNERS  (a LICENSE.txt / LICENSE.md rides via the doc
#                   extension arms; no LICENSE.* glob, which would also match an
#                   executable LICENSE.sh)
#   Excluded even though they end in .md: SKILL.md / CLAUDE.md / AGENTS.md are
#   agent-instruction files - executable contracts that change runtime behavior
#   when edited, NOT inert prose. A PR that rewrites one is a behavior change and
#   must get the full review, so it is forced off the fast lane (checked before
#   the *.md arm so it wins).
#   Excluded even though they end in .txt: *requirements*.txt / constraints.txt /
#   runtime.txt are dependency / runtime-version manifests - editing them changes
#   what gets installed or which interpreter runs, so they are forced off the fast
#   lane (checked before the *.txt arm so it wins). The *requirements*.txt glob is
#   intentionally broad (catches requirements.txt, requirements-dev.txt,
#   dev-requirements.txt): a docs file that merely matches gets the full gate,
#   which fails safe. Deliberately NOT on the lane:
#   .coderabbit.yaml (tunes the CodeRabbit backstop), .htaccess / CI yaml
#   (executable), version pins (.ruby-version / .python-version / .nvmrc), *.lock.
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
      # behavior contracts - excluded despite .md
      SKILL.md|CLAUDE.md|AGENTS.md) echo "no"; return 1 ;;
      # dependency / runtime manifests - excluded despite .txt
      *requirements*.txt|constraints.txt|runtime.txt) echo "no"; return 1 ;;
      # docs prose
      *.md|*.mdx|*.markdown|*.txt|*.rst) ;;
      # cross-host service inventory
      where-things-run.json) ;;
      # vcs placeholders
      .keep|.gitkeep) ;;
      # vcs / meta / ignore-list dotfiles (inert)
      .gitignore|.gitattributes|.editorconfig|.dockerignore|.npmignore|.prettierignore|.eslintignore|.gcloudignore) ;;
      # RETIRED gate markers. Gating moved to the tracked ~/dev/gate-policy.json on
      # 2026-09-02 and these files are now read by nothing, so removing a leftover
      # one is as inert as editing .gitignore. Listed so the sweep that deletes the
      # dead copies does not demand a QA plan per repo for a no-op diff. Note this
      # is DELETION-of-dead-config territory: if a future gate ever reads these
      # names again, take them back out of this list first.
      .ship-gate.json|.qa-plan-gate.json|.merge-clearance.json|.deploy-gate.json) ;;
      # legal / governance (LICENSE.txt / LICENSE.md ride the doc-extension arms)
      LICENSE|LICENCE|COPYING|NOTICE|AUTHORS|CONTRIBUTORS|CODEOWNERS) ;;
      *) echo "no"; return 1 ;;
    esac
  done <<EOF
$paths
EOF
  [ "$any" -eq 1 ] && { echo "yes"; return 0; }
  echo "no"; return 1
}

# qpg_body_file_from_cmd <cmd>
#   Echo the path given to the FIRST `--body-file` / `--body-file=` / `-F` in a
#   `gh pr create` command, or nothing. Surrounding quotes are stripped.
#
#   Tokenized with awk rather than matched with a regex. The regex version took
#   the LAST match (its leading `.*` was greedy, so a trailing `gh api ... -F
#   key=val` won and could point the drift check at the wrong document, producing
#   a FALSE BLOCK) and it also matched a `-F` appearing inside an inline
#   `--body "see -F notes"`. Walking argv left to right has neither problem.
#
#   SCOPE, stated honestly: an unexpanded shell variable cannot be resolved from a
#   PreToolUse payload, which sees the RAW command string. gstack /ship emits
#   `--body-file "$PR_BODY_FILE"`, so this returns the literal `$PR_BODY_FILE`,
#   the file is unreadable, and the drift check does not run. That is why the
#   authoritative binding is the token's plan_digest (captured at click time),
#   not this re-derivation: this is a secondary confirmation that the body being
#   shipped matches, and the PR gate LOGS when it cannot run rather than passing
#   silently.
qpg_body_file_from_cmd() {
  printf '%s' "$1" | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "--body-file" || $i == "-F") { if (i < NF) { print $(i+1); exit } }
        else if (index($i, "--body-file=") == 1) { print substr($i, 13); exit }
      }
    }' | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'
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

# qpg_build_procedure_ref <marker_json>
#   Optional per-repo pointer to the user's own build-procedure doc. Echoes the
#   string if the marker sets "build_procedure_ref", else empty. Lets a workspace
#   cite its own procedure in gate messages without the plugin hardcoding a path.
qpg_build_procedure_ref() {
  printf '%s' "$1" | jq -r '.build_procedure_ref // empty' 2>/dev/null
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
