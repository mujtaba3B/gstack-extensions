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

# qpg_stamp_valid <stamp_json> <branch> [current_digest] [now_epoch]
#   Decide whether an approval stamp authorizes building / PRing on <branch>.
#   Echoes "valid" on success, else a single-word reason (no-stamp | malformed |
#   wrong-branch | plan-changed | unattested | approval-expired). Return code
#   mirrors the verdict (0 valid, 1 otherwise). Every verdict has a matching row
#   in qpg_block_advice, so a gate never has to invent remedy text.
#
#   <now_epoch> is only consulted for an override stamp's expiry, and defaults to
#   the wall clock when empty. Tests pass it explicitly so the expiry truth table
#   is deterministic.
#
#   A stamp is a JSON object written by `qa-plan-stamp.sh write`:
#     { "branch": "<name>", "approved_at": "<iso8601>",
#       "approved_at_epoch": <int>, "head_at_approval": "<sha>",
#       "criteria_digest": "<hex>", "approver": "<who>",
#       "approval_source": "AskUserQuestion", "approval_nonce": "<hex>",
#       "tool": "qa-plan" }
#   A human-override stamp carries `approval_source` of "human-prompt-override" or
#   "human-tty-override" plus an `expires_at_epoch` (see QPG_OVERRIDE_TTL).
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
  local stamp="$1" branch="$2" current_digest="${3:-}" now="${4:-}"

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

  # The source must be one of the EXACT literals a trusted writer emits, not
  # merely non-empty. Accepting any truthy string gave a forged stamp a free
  # choice of value and cost nothing to tighten (CodeRabbit, PR #76). This does
  # not make a written file unforgeable, which is impossible for any agent with
  # shell access and is documented honestly in qa-plan-token-lib.sh; it removes a
  # degree of freedom. The allowlist lives in qpg_source_trusted so adding an
  # override channel cannot silently widen it to "anything non-empty" again.
  local s_source
  s_source=$(printf '%s' "$stamp" | jq -r '.approval_source // empty' 2>/dev/null) || s_source=""
  [ "$(qpg_source_trusted "$s_source")" = "trusted" ] || { echo "unattested"; return 1; }

  # AN APPROVAL THAT CANNOT BE RE-VERIFIED MUST EXPIRE. The test is the DIGEST,
  # not the source, and that correction came from an adversarial review of this
  # change: the first cut keyed the expiry on "is this an override", which left a
  # real hole. A modal click whose question carried no `<qa-plan-digest:...>`
  # marker produces a stamp with criteria_digest "none", which falls through the
  # drift check above (nothing to compare) AND, under the source-keyed rule, got
  # no expiry either. That is a standing, drift-immune approval reachable through
  # the ORDINARY path: approve once with a digest-less question, then rewrite the
  # `## QA` section freely. It is exactly the "scoped approval carried forward as
  # a standing one" shape of the 2026-09-02 incident, arrived at from the other
  # direction.
  #
  # So: a stamp carrying a real digest stands for the branch's life, because the
  # drift check re-verifies it against whatever is being shipped. A stamp with no
  # digest (every override, plus any digest-less click) is bounded by time,
  # because time is the only bound it has left.
  #
  # A missing or non-numeric expiry on such a stamp is EXPIRED, not unbounded:
  # the writers always set one, so its absence means the stamp predates this rule
  # or was not written by them. Fail-closed; the cure is one re-approval.
  local s_digest_e
  s_digest_e=$(printf '%s' "$stamp" | jq -r '.criteria_digest // empty' 2>/dev/null) || s_digest_e=""
  if [ -z "$s_digest_e" ] || [ "$s_digest_e" = "none" ]; then
    local s_exp
    s_exp=$(printf '%s' "$stamp" | jq -r '.expires_at_epoch // empty' 2>/dev/null) || s_exp=""
    case "$s_exp" in ''|*[!0-9]*) echo "approval-expired"; return 1 ;; esac
    [ -n "$now" ] || now=$(date +%s)
    case "$now" in ''|*[!0-9]*) echo "approval-expired"; return 1 ;; esac
    [ "$now" -le "$s_exp" ] || { echo "approval-expired"; return 1; }
  fi

  echo "valid"; return 0
}

# QPG_OVERRIDE_TTL - how long a human override authorizes a branch, in seconds.
#
# Eight hours: one working day, so a single override covers the session it was
# given for without becoming a permanent grant. Re-giving it costs one typed line
# (or one terminal command), and by the time it lapses the ordinary click path is
# almost always available again, since the usual cause of needing an override is a
# hook that a restart has since registered.
# shellcheck disable=SC2034  # consumed by qa-plan-stamp.sh, which sources this file
QPG_OVERRIDE_TTL=28800

# qpg_source_trusted <approval_source>
#   Is this `approval_source` one a trusted writer emits? Echoes "trusted" / "no";
#   return code 0 for trusted. Fails CLOSED on anything unrecognized, INCLUDING
#   the empty string, which is the pre-#71 stamp shape.
#
#   The three trusted values, and the human act behind each:
#     AskUserQuestion        the human clicked Approve on the "QA plan" modal.
#     human-prompt-override  the human typed the override phrase as a whole prompt.
#     human-tty-override     the human confirmed at a real controlling terminal.
#   Every one of them requires something the harness fills in or the kernel
#   provides. None is reachable from an agent's own output.
qpg_source_trusted() {
  case "$1" in
    AskUserQuestion|human-prompt-override|human-tty-override) echo "trusted"; return 0 ;;
    *) echo "no"; return 1 ;;
  esac
}

# qpg_source_is_override <approval_source>
#   Is this stamp a human OVERRIDE rather than a modal approval? Echoes
#   "override" / "no"; return code 0 for override. Kept separate from
#   qpg_source_trusted because the two questions have different answers for the
#   same input and collapsing them is how an override would quietly inherit the
#   click path's unlimited lifetime.
qpg_source_is_override() {
  case "$1" in
    human-prompt-override|human-tty-override) echo "override"; return 0 ;;
    *) echo "no"; return 1 ;;
  esac
}

# qpg_block_advice <verdict>
#   The remedy for one stamp verdict, in one sentence or two. Echoes the advice.
#
#   WHY THIS IS A FUNCTION AND NOT A STRING IN THE GATE. Both gates previously
#   emitted ONE remedy for every verdict: "Run /qa:plan now". For `no-stamp` that
#   is right. For `unattested` it is actively wrong, and on 2026-09-03 it cost a
#   session: the operator HAD run /qa:plan and approved, an old cached writer had
#   left a pre-token stamp on the branch, and running /qa:plan again could never
#   clear it because a stale stamp is not what /qa:plan removes. The advice the
#   block needed was "clear the stamp first", which nothing on screen said. A
#   verdict-keyed truth table cannot drift back into one-size-fits-all advice, and
#   its rows are enumerated in bats.
qpg_block_advice() {
  case "$1" in
    no-stamp)
      echo "No approval stamp exists for this branch. Run /qa:plan: it pulls the success criteria, writes the two-phase plan, presents it, and your Approve click is what mints the stamp." ;;
    wrong-branch)
      echo "A stamp exists but it was approved for a DIFFERENT branch, so it does not cover this one. Run /qa:plan on this branch; do not copy or edit the existing stamp." ;;
    plan-changed)
      echo "The QA plan changed after it was approved, so the approval no longer covers what is being shipped. Re-run /qa:plan and get the current plan approved." ;;
    unattested)
      echo "A stamp exists but carries no proof a human approved it (no trusted approval_source). Running /qa:plan again will NOT fix this on its own, because the stale stamp stays on disk. Run 'qa-plan-stamp.sh doctor' to see where it came from (usually an older cached copy of the stamp writer, which predates the approval-token guard), then 'qa-plan-stamp.sh clear', then /qa:plan." ;;
    approval-expired)
      echo "This branch's approval carries no plan digest, so nothing can re-verify it against what is being shipped and it is bounded by time instead, and that window has closed. Every human override is in this category, and so is a modal approval whose question carried no <qa-plan-digest:...> marker. Get the plan approved through /qa:plan, which embeds the digest and produces an approval that does not expire, or have the human give a fresh override." ;;
    malformed)
      echo "The stamp file is not valid JSON, so nothing can be read from it. Run 'qa-plan-stamp.sh clear' and then /qa:plan." ;;
    *)
      echo "Run /qa:plan to obtain an approved-plan stamp for this branch, and 'qa-plan-stamp.sh doctor' if it is not obvious why this branch has none." ;;
  esac
}

# qpg_stale_writer_warning <space-separated-version-list>
#   The warning shown when cached plugin copies whose stamp writer predates the
#   approval-token guard are still on disk. Echoes the warning, or nothing when
#   the list is empty.
#
#   WHY IT APPEARS IN A BLOCK MESSAGE AND NOT ONLY IN `doctor`. doctor is a
#   command someone runs after they are already stuck. The bypass happens
#   earlier, at exactly this moment: an agent is blocked, the guarded writer has
#   just refused it, and the most obvious next move is to look for another copy
#   of the writer. On 2026-09-03 an agent did precisely that, found the cached
#   3.8.0 copy, and it stamped without complaint; the agent was not evading
#   anything, it took the next obvious step. So the warning belongs where that
#   step gets taken. Reported from a consumer repo by the session it happened to.
qpg_stale_writer_warning() {
  local versions="$1"
  [ -n "$versions" ] || { printf ''; return 1; }
  echo "WARNING: older cached copies of qa-plan-stamp.sh are on this machine ($versions) and they predate the approval-token guard, so they will write a stamp with no human approval and exit 0. Do NOT reach for one: the stamp it writes is graded 'unattested' by this gate and blocks anyway, and it records the human's name against an approval they did not give. Run bin/install to prune them."
  return 0
}

# qpg_override_hint
#   The pointer to the two human override routes, appended to a block so the
#   human reading over the agent's shoulder knows a route exists that does not
#   require a restart. Addressed TO THE HUMAN.
#
#   It used to end "Claude cannot do either of these for you, which is the point."
#   That was half false and the half that was false mattered. The typed phrase is
#   genuinely beyond an agent: nothing it does produces a UserPromptSubmit event.
#   The terminal route is only beyond an ORDINARY tool call; a process can spawn
#   itself a pty, which was verified by running the exploit. So the hint now says
#   which is which, and tells the agent plainly that taking the second route is
#   forging a human approval rather than solving a problem. An instruction it can
#   disobey is all that is available there, and pretending otherwise in the one
#   message an agent is guaranteed to read would be the worst place to be wrong.
qpg_override_hint() {
  echo "If you are the human and you have already approved this plan, you can override without a restart: send \"qa-plan: I approve this plan\" as a message on its own (nothing Claude does can produce that event), or run 'qa-plan-stamp.sh override' yourself in a real terminal tab. CLAUDE: do not attempt either. The second refuses for any ordinary tool call because it needs a controlling terminal; spawning one to get around that is forging a record that a human approved this, and the stamp records the parent process that did it."
}

# qpg_unattested_disposition <gate>
#   What a gate does with an "unattested" stamp: one carrying no proof a human
#   approved it. Echoes "block" for everything. Kept as a function rather than
#   inlined so the truth table stays enumerated in bats and a future carve-out
#   has one obvious place to be argued for.
#
#   It used to allow such a stamp inside a migration window bounded by the stamp
#   FILE'S MTIME. CodeRabbit killed that on PR #76 and was right: mtime is
#   mutable by the same shell that writes the file, so `touch -t` past the cutoff
#   defeated it in one extra command. The window existed only because a pre-fix
#   branch could not obtain a token at all (the minting hook was unregistered,
#   and blocking those stamps caused a machine-wide outage mid-build). With the
#   hook shipping here, the remedy is one /qa:plan approval, so the carve-out
#   costs a forgeable bypass to save a click.
qpg_unattested_disposition() {
  case "$1" in
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
#
#   A markdown THEMATIC BREAK (`---` alone on a line) also terminates it. gstack
#   /ship appends its attribution footer after a bare `---` with no heading of its
#   own, so without this arm the footer is absorbed into the section, changes the
#   plan's digest, and produces a FALSE "the QA plan changed after it was
#   approved" block on a body whose plan is byte-identical to the approved one.
#   Caught on this feature's own PR (#76), which is the shape every future ship
#   would have hit. Safe to stop on: plan tables use `|---|` separators, which are
#   not bare, and a thematic break genuinely ends a section.
qpg_extract_qa_section() {
  printf '%s' "$1" | awk '
    /^##[[:space:]]+QA[[:space:]]*$/ { inq=1; print; next }
    inq && /^##[[:space:]]/ && !/^###/ { inq=0 }
    inq && /^-{3,}[[:space:]]*$/ { inq=0 }
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
#   Tokenized with awk, and QUOTED REGIONS ARE BLANKED FIRST. Both parts are
#   needed, and the second was learned the hard way twice.
#
#   The regex version took the LAST match (its leading `.*` was greedy), so a
#   trailing `gh api ... -F key=val` won. Switching to first-match fixed that and
#   opened the mirror-image bug: awk has no notion of shell quoting, so
#   `--body "see -F notes.md for context"` tokenizes to `--body`, `"see`, `-F`,
#   `notes.md`, ... and the bare `-F` matched FIRST, ahead of the real
#   `--body-file`. That is not a harmless skip: if `notes.md` exists and carries
#   an older `## QA` section, the digest is computed from the WRONG document and
#   a perfectly correct create is BLOCKED with "the QA plan changed after it was
#   approved", which is a lie. Blanking quoted spans first makes the parse
#   independent of which flag happens to come first.
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
    function seg_has_create(t) { return (t ~ /gh[ \t]+pr[ \t]+create/) }
    {
      # 1. Quoting JOINS words. Inside a quoted span, spaces become \001 and the
      #    quote marks are dropped, so `--body "see -F notes.md"` becomes ONE
      #    token that can never equal "-F", while `"$PR_BODY_FILE"` survives
      #    intact as a value we can still report. Blanking the contents instead
      #    (a first attempt) also destroyed --body-file="path" and the
      #    unexpanded-variable form the PR gate needs in order to log honestly.
      out = ""; q = ""; n = length($0)
      for (k = 1; k <= n; k++) {
        c = substr($0, k, 1)
        if (q == "") {
          if (c == "\"" || c == "\047") q = c
          else out = out c
        } else if (c == q) q = ""
        else out = out (c == " " || c == "\t" ? "\001" : c)
      }
      # 2. Only look at the shell segment that actually carries `gh pr create`.
      #    Otherwise a neighbouring `gh api ... -F key=val` in the same line wins
      #    or loses on position alone, which is a coin flip either way.
      nseg = split(out, seg, /&&|\|\||;/)
      pick = out
      for (s = 1; s <= nseg; s++) if (seg_has_create(seg[s])) { pick = seg[s]; break }
      m = split(pick, tok, /[ \t]+/)
      for (i = 1; i <= m; i++) {
        v = ""
        if ((tok[i] == "--body-file" || tok[i] == "-F") && i < m) v = tok[i+1]
        else if (index(tok[i], "--body-file=") == 1) v = substr(tok[i], 13)
        if (v != "") { gsub(/\001/, " ", v); print v; exit }
      }
    }'
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
