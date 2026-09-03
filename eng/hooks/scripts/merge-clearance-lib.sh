#!/bin/bash
# Pure, side-effect-free decision logic for the merge-clearance gate, extracted so
# it can be unit tested (tests/merge-clearance-lib.bats) without a live repo, a PR,
# or the network. Every function takes everything it needs as arguments (including
# "now", so time-based checks are deterministic) and writes only to stdout.
#
# Consumers:
#   scripts/pr-merge-gate.sh  - sources mc_stamp_valid to decide whether to block
#                               a `gh pr merge`.
#   scripts/merge-clearance   - sources mc_cr_verdict / mc_cr_reviewed_head to turn
#                               GitHub GraphQL output into a CodeRabbit verdict.
#
# Requires jq for the JSON-parsing helpers. Callers that cannot guarantee jq must
# check for it first; these functions assume it is present (the gate fails OPEN
# before ever sourcing this, so a jq-less host never reaches here).

# mc_stamp_valid <stamp_json> <head_sha> <now_epoch> <default_ttl_seconds>
#   Decide whether a merge-clearance stamp authorizes merging <head_sha> right now.
#   Echoes "valid" on success; otherwise a single-word reason
#   (no-stamp | malformed | stale-head | expired). Return code mirrors the verdict
#   (0 valid, 1 otherwise) so callers can branch on either.
#
#   A stamp is a JSON object written by `merge-clearance clear`:
#     { "pr": N, "head": "<sha>", "base": "main", "checked_at": "<iso8601>",
#       "checked_at_epoch": <int>, "tool": "land-and-deploy",
#       "ttl_seconds": <int>, "evidence": { ... } }
#   The stamp's own ttl_seconds wins when present (so the writer controls the
#   window); <default_ttl_seconds> is the fallback for older stamps.
mc_stamp_valid() {
  local stamp="$1" head="$2" now="$3" default_ttl="$4"

  if [ -z "$stamp" ]; then echo "no-stamp"; return 1; fi

  # One jq pass pulls every field; a parse failure (truncated/corrupt stamp) or a
  # missing required field surfaces as "malformed" rather than a false "valid".
  local parsed
  parsed=$(printf '%s' "$stamp" | jq -r '
    [ (.head // "") , (.checked_at_epoch // "") , (.ttl_seconds // "") ] | @tsv
  ' 2>/dev/null) || { echo "malformed"; return 1; }

  local s_head s_epoch s_ttl
  IFS=$'\t' read -r s_head s_epoch s_ttl <<<"$parsed"

  [ -n "$s_head" ] || { echo "malformed"; return 1; }
  case "$s_epoch" in ''|*[!0-9]*) echo "malformed"; return 1 ;; esac

  [ "$s_head" = "$head" ] || { echo "stale-head"; return 1; }

  # ttl: stamp's own value if it is a positive integer, else the caller default.
  local ttl="$default_ttl"
  case "$s_ttl" in ''|*[!0-9]*) : ;; *) [ "$s_ttl" -gt 0 ] && ttl="$s_ttl" ;; esac
  case "$now" in ''|*[!0-9]*) echo "malformed"; return 1 ;; esac

  local age=$(( now - s_epoch ))
  if [ "$age" -lt 0 ] || [ "$age" -gt "$ttl" ]; then echo "expired"; return 1; fi

  echo "valid"; return 0
}

# ld_sentinel_valid <sentinel_json> <now_epoch> <default_ttl> <target_head> [<target_repo>] [<target_pr>]
#   Decide whether a land-deploy sentinel authorizes merging <target_head> right
#   now. Echoes "valid" on success; otherwise a single-word reason
#   (no-sentinel | malformed | expired | mismatch). Return code mirrors the
#   verdict (0 valid, 1 otherwise).
#
#   The sentinel is a JSON object written by land-deploy-sentinel.sh when the
#   /land-and-deploy skill is invoked (the agent calls the Skill tool with skill
#   "land-and-deploy", or the user types "/land-and-deploy" at the prompt):
#     { "set_at_epoch": <int>, "ttl_seconds": <int>, "repo": "owner/name",
#       "head_sha": "<sha>", "pr_number": "<int|empty>", "source": "skill|prompt" }
#   It is stored in <gitdir>/land-deploy-clearance, so repo + worktree binding is
#   already implied by location; head_sha is the strong extra binding (it prevents
#   a stale sentinel from authorizing a NEWER pushed commit). repo and pr_number
#   are matched defensively only when BOTH sides carry a non-empty value, so an
#   unresolvable repo/pr in the gate never false-blocks a legitimate merge.
#
#   This is the half that makes /land-and-deploy the single CLI merge path: the
#   sentinel can ONLY be minted by invoking /land-and-deploy, never by a bare
#   `merge-clearance clear`. The sentinel's own ttl_seconds wins when positive;
#   <default_ttl> is the fallback. A generous TTL is safe here because the binding
#   is to a specific head_sha, not just freshness: the window only ever authorizes
#   merging the exact commit land-and-deploy was invoked on.
ld_sentinel_valid() {
  local sentinel="$1" now="$2" default_ttl="$3" t_head="$4" t_repo="${5:-}" t_pr="${6:-}"

  if [ -z "$sentinel" ]; then echo "no-sentinel"; return 1; fi

  # Join with "|" (a non-whitespace delimiter), NOT @tsv: tab is an IFS-whitespace
  # character, so `read` would collapse consecutive empty fields and shift the
  # columns (a missing head_sha would silently borrow the repo value). None of the
  # five fields (epochs, ttl, sha, owner/name, pr digits) can contain "|".
  local parsed
  parsed=$(printf '%s' "$sentinel" | jq -r '
    [ (.set_at_epoch // "") , (.ttl_seconds // "") , (.head_sha // "") , (.repo // "") , (.pr_number // "") ] | join("|")
  ' 2>/dev/null) || { echo "malformed"; return 1; }

  local s_epoch s_ttl s_head s_repo s_pr
  IFS='|' read -r s_epoch s_ttl s_head s_repo s_pr <<<"$parsed"

  case "$s_epoch" in ''|*[!0-9]*) echo "malformed"; return 1 ;; esac
  case "$now"     in ''|*[!0-9]*) echo "malformed"; return 1 ;; esac
  [ -n "$s_head" ] || { echo "malformed"; return 1; }

  # ttl: sentinel's own value if it is a positive integer, else the caller default.
  local ttl="$default_ttl"
  case "$s_ttl" in ''|*[!0-9]*) : ;; *) [ "$s_ttl" -gt 0 ] && ttl="$s_ttl" ;; esac
  case "$ttl" in ''|*[!0-9]*) echo "malformed"; return 1 ;; esac

  local age=$(( now - s_epoch ))
  if [ "$age" -lt 0 ] || [ "$age" -gt "$ttl" ]; then echo "expired"; return 1; fi

  # head_sha is the strong binding; it must match when a target head is supplied.
  if [ -n "$t_head" ] && [ "$s_head" != "$t_head" ]; then echo "mismatch"; return 1; fi
  # repo + pr are belt-and-suspenders: enforce only when BOTH sides are non-empty,
  # so an unresolvable target repo/pr in the gate degrades to head-only matching
  # rather than false-blocking.
  if [ -n "$t_repo" ] && [ -n "$s_repo" ] && [ "$s_repo" != "$t_repo" ]; then echo "mismatch"; return 1; fi
  if [ -n "$t_pr" ] && [ -n "$s_pr" ] && [ "$s_pr" != "$t_pr" ]; then echo "mismatch"; return 1; fi

  echo "valid"; return 0
}

# mc_is_bookkeeping <newline-separated-paths>
#   Echo "yes" iff the changeset is NON-EMPTY and EVERY path is a "bookkeeping"
#   file: documentation or the cross-host service inventory. These are zero-risk,
#   non-code changes that should not pay the full ship-time ceremony. Echoes "no"
#   and returns 1 otherwise. Fails CLOSED: an empty list, OR a single path outside
#   the allowlist, yields "no", so a code change bundled with docs never rides the
#   fast lane. merge-clearance.sh uses this to internally force --skip-review /
#   --skip-qa for an all-bookkeeping PR while KEEPING CI + CodeRabbit hard.
#
#   Allowlist (matched on the basename), all of which are INERT - editing them
#   cannot change what runs in production:
#     - docs:       *.md *.mdx *.markdown *.txt *.rst
#     - inventory:  where-things-run.json  (the cross-host service inventory ONLY;
#                   NOT *.json broadly - app config stays gated)
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
#   when edited, NOT inert prose. A PR rewriting one is a behavior change and must
#   get the full review, so it is forced off the fast lane (checked before the
#   *.md arm so it wins).
#   Excluded even though they end in .txt: *requirements*.txt / constraints.txt /
#   runtime.txt are dependency / runtime-version manifests - editing them changes
#   what gets installed or which interpreter runs, so they are forced off the fast
#   lane (checked before the *.txt arm so it wins). The *requirements*.txt glob is
#   intentionally broad (catches requirements.txt, requirements-dev.txt,
#   dev-requirements.txt): a docs file that merely matches gets the full gate,
#   which fails safe. Deliberately NOT on the lane:
#   .coderabbit.yaml (tunes the CodeRabbit backstop), .htaccess / CI yaml
#   (executable), version pins (.ruby-version / .python-version / .nvmrc), *.lock.
#   Twin of qpg_is_bookkeeping in the qa plugin's qa-plan-gate-lib.sh; the two
#   allowlists are kept in lockstep (each plugin is self-contained and binds its
#   own copy, per the BASH_SOURCE self-containment rule).
mc_is_bookkeeping() {
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

# mc_cr_verdict <threads_json> <reviews_json> [cr_status_state]
#   Turn GitHub GraphQL output for one PR into a CodeRabbit-resolution verdict.
#   Echoes one of: clear | unresolved | unresolved-waived | changes_requested.
#   Returns 0 for "clear" and "unresolved-waived" (both non-blocking), non-zero
#   otherwise. This is the structural signal (Codex flagged that parsing the review
#   body string "Actionable comments posted: 0" is brittle; that string is fallback
#   evidence only, never the gate).
#
#   threads_json:  the PR's reviewThreads nodes, shape
#     [ { "isResolved": bool, "comments": { "nodes": [ { "author": {"login": "..."} } ] } }, ... ]
#   reviews_json:  the PR's reviews nodes (chronological), shape
#     [ { "author": {"login": "..."}, "state": "...", "submittedAt": "...", "commit": {"oid": "..."} }, ... ]
#   cr_status_state (optional): CodeRabbit's resolved per-commit commit-status on
#     HEAD (state_of "CodeRabbit"): success | failure | pending | missing. Optional
#     so existing two-arg callers/tests keep their meaning ("" is never "success").
#
#   Precedence: an unresolved CodeRabbit thread is the most common actionable
#   blocker, so it wins; then a CHANGES_REQUESTED CodeRabbit review; else clear.
#   "coderabbitai" is matched as a case-insensitive substring of the author login
#   because the bot appears as both "coderabbitai" (GraphQL Bot) and
#   "coderabbitai[bot]" (REST) depending on the surface.
#
#   Stale-thread waiver (the mutwo-skills#118 wedge): CodeRabbit's "success" commit
#   status means it FINISHED reviewing HEAD, NOT that it approved it (state_of folds
#   any completed status into "success"; CR routinely posts success alongside
#   actionable COMMENTED feedback). So "success" alone must NOT waive open CR
#   objections. The ONLY unresolved threads waived here are ones GitHub marks
#   isOutdated=true: the code the thread was anchored to has since changed, and CR
#   re-reviewed HEAD (its status IS on HEAD, per-commit) without re-flagging it, so
#   the stale thread is addressed-or-moot. A CURRENT (isOutdated != true) unresolved
#   CR thread is CodeRabbit asking for changes on the code AS IT STANDS: it ALWAYS
#   blocks, regardless of status. The waiver fires only when (a) CR is green on
#   HEAD (cr_status == "success"), AND (b) every unresolved CR thread is outdated,
#   AND (c) CR's latest review is not CHANGES_REQUESTED -> "unresolved-waived"
#   (rc 0). Non-green status (pending / failure / missing) never waives. The waiver
#   is CodeRabbit-only; a human's unresolved thread was never counted here.
#   Threads missing the isOutdated field default to CURRENT (fail-closed: an
#   unknown-freshness thread blocks rather than being waived).
mc_cr_verdict() {
  local threads="$1" reviews="$2" cr_status="${3:-}"

  # Fail CLOSED on degraded GitHub data. A GraphQL timeout / partial response (gh
  # exits 0 with .data present but null nodes) would otherwise reach here as
  # "null" or "", and a permissive default would emit a FALSE clear - the most
  # dangerous direction for this gate. null / empty / non-array inputs, and any
  # jq parse failure, all resolve to "unknown" (a blocker), never "clear".
  local t
  for t in "$threads" "$reviews"; do
    case "$t" in ''|null) echo "unknown"; return 1 ;; esac
  done
  printf '%s' "$threads" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "unknown"; return 1; }
  printf '%s' "$reviews" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "unknown"; return 1; }

  # Total unresolved CodeRabbit threads, and the subset that are CURRENT (not
  # outdated). A thread with no isOutdated field counts as current (fail closed).
  local unresolved unresolved_current
  unresolved=$(printf '%s' "$threads" | jq '
    [ .[]
      | select(.isResolved != true)
      | select( any(.comments.nodes[]?; (.author.login // "") | ascii_downcase | contains("coderabbitai")) )
    ] | length
  ' 2>/dev/null) || { echo "unknown"; return 1; }
  unresolved_current=$(printf '%s' "$threads" | jq '
    [ .[]
      | select(.isResolved != true)
      | select(.isOutdated != true)
      | select( any(.comments.nodes[]?; (.author.login // "") | ascii_downcase | contains("coderabbitai")) )
    ] | length
  ' 2>/dev/null) || { echo "unknown"; return 1; }

  # Latest CodeRabbit review state (last by array order, which the query returns
  # chronologically). COMMENTED / APPROVED do not block; CHANGES_REQUESTED does.
  local latest_state
  latest_state=$(printf '%s' "$reviews" | jq -r '
    [ .[] | select( (.author.login // "") | ascii_downcase | contains("coderabbitai") ) ]
    | (last // {}) | (.state // "")
  ' 2>/dev/null) || { echo "unknown"; return 1; }

  if [ "${unresolved:-0}" -gt 0 ] 2>/dev/null; then
    # Waive ONLY when CR is green on HEAD, EVERY unresolved CR thread is outdated
    # (no current one), and CR is not explicitly requesting changes. Anything else
    # with an unresolved thread blocks - including a current thread under a green
    # status (CR asking for changes on the code as it stands).
    if [ "$cr_status" = "success" ] && [ "${unresolved_current:-0}" -eq 0 ] 2>/dev/null \
       && [ "$latest_state" != "CHANGES_REQUESTED" ]; then
      echo "unresolved-waived"; return 0
    fi
    echo "unresolved"; return 1
  fi

  if [ "$latest_state" = "CHANGES_REQUESTED" ]; then echo "changes_requested"; return 1; fi

  echo "clear"; return 0
}

# mc_cr_reviewed_head <reviews_json> <head_sha> [cr_status_state]
#   Has CodeRabbit EVALUATED the current HEAD? Echoes "yes" / "no". Two
#   independent proofs, either of which suffices:
#     1. A CodeRabbit REVIEW object whose commit oid == HEAD. This is the strong
#        proof, but CR only re-posts a formal review object when it has FINDINGS.
#        On a clean incremental commit (a trivial follow-up fix) CR flips its
#        per-commit status to green and stays quiet, posting no new review object,
#        so this proof alone misses the "green but quiet" case.
#     2. CodeRabbit's own per-commit COMMIT STATUS is "success" on HEAD. The
#        GitHub commit-status API is per-commit, so a success status attached to
#        the exact HEAD sha proves CR ran on HEAD and passed it green with nothing
#        to say. The caller passes the already-resolved CR commit-status state
#        (state_of "CodeRabbit", keyed to repos/../commits/HEAD/statuses) as the
#        optional third arg; it is optional so existing two-arg callers/tests keep
#        their meaning ("" is never "success", so they fall through to proof 1).
#   Only "success" counts for proof 2: "pending" (review in flight) and "failure"
#   are NOT evidence HEAD was cleared, and the caller handles those separately.
#   This relaxes ONLY the reviewed-head dimension; the separate "CR clear" verdict
#   (mc_cr_verdict: unresolved threads / changes-requested) still blocks regardless,
#   so a real CodeRabbit objection on a green-status HEAD is unaffected.
#   A "no" is advisory - the live "CodeRabbit" commit-status context is the
#   stronger in-progress signal the CLI also checks.
mc_cr_reviewed_head() {
  local reviews="$1" head="$2" cr_status="${3:-}" cr_desc="${4:-}"
  # Proof 1 first: a review OBJECT on this exact HEAD is unambiguous.
  # Proof 2: green-but-quiet. A success commit status on the exact HEAD sha means
  # CR evaluated HEAD even when it posted no review object (clean incremental
  # commit). state_of already keyed this to the per-commit statuses API for HEAD,
  # so it cannot be inherited or stale from an ancestor commit.
  #
  # EXCEPT when the status says it was rate limited. CodeRabbit publishes
  # state=success with description "Review rate limited" when it never got to the
  # code at all, so accepting the bare state here cleared PRs CR had not read: the
  # gate that exists to be strictly stronger than `gh pr checks` was reproducing
  # that check list'"'"'s exact lie. Observed on mujtaba3B/dev#92, which reached a full
  # CLEAR verdict with zero CR reviews on the head and a rate-limit notice posted.
  # Callers pass the description; empty means "not known to be rate limited", which
  # preserves the old behavior for every non-rate-limited success.
  local hit
  hit=$(printf '%s' "$reviews" | jq -r --arg h "$head" '
    [ .[]
      | select( (.author.login // "") | ascii_downcase | contains("coderabbitai") )
      | select( (.commit.oid // "") == $h )
    ] | length
  ' 2>/dev/null) || hit=0
  if [ "${hit:-0}" -gt 0 ] 2>/dev/null; then echo "yes"; return 0; fi
  if [ "$cr_status" = "success" ] && [ "$(mc_status_rate_limited "$cr_desc")" != "yes" ]; then
    echo "yes"; return 0
  fi
  echo "no"; return 1
}

# mc_status_rate_limited <cr_status_description>
#   "yes" when a CodeRabbit commit-status description reports a rate limit, in any
#   state. Matched case-insensitively on "rate limit" so both the observed
#   "Review rate limited" and any future phrasing around the same words are caught;
#   an empty or unreadable description is "no", which fails toward the previous
#   behavior rather than toward blocking every green PR.
mc_status_rate_limited() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    *"rate limit"*) echo "yes" ;;
    *) echo "no" ;;
  esac
}

# mc_cr_rate_limited <comments_json>
#   Decide whether CodeRabbit has SIGNALLED that it is rate-limited / could not
#   start a review on this PR - as opposed to merely being silent or mid-review.
#   CodeRabbit posts a stable auto-generated marker comment in every rate-limit
#   flavour ("reached your PR review rate limit", "Rate limit exceeded ... please
#   wait N minutes", "used up its prepaid credits", "Reviews paused"); they all
#   carry the literal marker string:
#       rate limited by coderabbit.ai
#   (inside an HTML comment: "<!-- This is an auto-generated comment: rate limited
#   by coderabbit.ai -->"). The in-progress notice ("Currently processing new
#   changes ... please wait") does NOT carry that marker, so this cleanly
#   separates "rate-limited" (CR never started) from "still reviewing" (CR is
#   working). The caller consults this on a "missing" CR commit status (CR never
#   posted a status). For a "pending" status that is stuck (CR posted its pending
#   status, then hit the limit mid-flight and never resolved), the caller uses the
#   stricter mc_cr_rate_limited_latest instead, which also requires the notice to
#   be CR's LATEST comment - so a stale rate-limit comment from an earlier commit
#   cannot relax a HEAD that CR is genuinely reviewing now.
#
#   comments_json: the PR's issue comments, shape [ { "author": "login",
#     "body": "..." }, ... ] (the caller maps gh's user.login -> author).
#   Echoes "yes" iff at least one comment authored by the CodeRabbit bot
#   (login contains "coderabbitai", matching mc_cr_reviewed_head's convention)
#   contains the marker; else "no". A non-array / unparseable input is "no"
#   (fail closed: never auto-satisfy on input we could not read).
mc_cr_rate_limited() {
  local comments="$1"
  printf '%s' "$comments" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "no"; return 1; }
  local hit
  hit=$(printf '%s' "$comments" | jq -r '
    [ .[]
      | select( (.author // "") | ascii_downcase | contains("coderabbitai") )
      | select( (.body // "") | contains("rate limited by coderabbit.ai") )
    ] | length' 2>/dev/null) || { echo "no"; return 1; }
  if [ "${hit:-0}" -gt 0 ] 2>/dev/null; then echo "yes"; return 0; fi
  echo "no"; return 1
}

# mc_cr_success_rate_limited <cr_status_state> <cr_status_description> [comments_json]
#   FOURTH rate-limit shape: status SUCCESS with a rate-limit description.
#     1. status MISSING  + marker comment                  -> mc_cr_rate_limited
#     2. status PENDING (stuck) + marker as LATEST comment -> mc_cr_rate_limited_latest
#     3. status FAILURE  + rate-limit description          -> mc_cr_failure_rate_limited
#     4. status SUCCESS  + rate-limit description          -> THIS function
#
#   Shape 4 is the most dangerous of the four, because CR publishes GREEN: the check
#   reads "pass" while the description reads "Review rate limited", so every surface
#   that trusts the check state alone sees a clean review that never happened.
#
#   Keying only on the marker comment (as shape 1 does) is not enough here, and the
#   failure is intermittent in the worst way: CodeRabbit posts its rate-limit notice
#   and then EDITS THAT SAME COMMENT IN PLACE as the review progresses. Observed on
#   mujtaba3B/friendships#6 (2026-09-02): the marker was present at 01:14 and
#   auto-satisfied the gate, and by 01:38 it had been overwritten by the walkthrough
#   text, leaving a PR the gate KNEW was rate-limited ("status=success but RATE
#   LIMITED") but had no way to clear, with no flag that applied
#   (--override-cr-failure is failure-only). So the description is the primary proof
#   here exactly as in shape 3, and the marker is the secondary one.
#
#   Like shapes 1-3 this only RELAXES the reviewed-head dimension, and only when a
#   current local /eng:cr review backstops it (CR_RL_BACKSTOPPED). It is never a
#   bare bypass: with no local review the gate still blocks.
mc_cr_success_rate_limited() {
  local state="$1" desc="${2:-}" comments="${3:-[]}"
  [ "$state" = "success" ] || { echo "no"; return 1; }
  if [ "$(mc_desc_rate_limited "$desc")" = "yes" ]; then echo "yes"; return 0; fi
  # Secondary proof: the marker anywhere in CR's comments. Deliberately the
  # anywhere variant, not _latest: a success status means CR finished (or gave up),
  # so there is no in-flight review whose newer comment should win.
  if [ "$(mc_cr_rate_limited "$comments")" = "yes" ]; then echo "yes"; return 0; fi
  echo "no"; return 1
}

# mc_cr_rate_limited_latest <comments_json>
#   Stricter sibling of mc_cr_rate_limited, for the STUCK-PENDING case: CodeRabbit
#   posts a "pending" commit status the moment it STARTS a review, then can hit the
#   rate limit mid-flight and post its notice, leaving the status stuck "pending"
#   forever. A plain mc_cr_rate_limited would misfire here whenever a rate-limit
#   comment exists ANYWHERE on the PR - including a stale one from an earlier commit
#   while CR is genuinely reviewing the new HEAD now. So this variant requires the
#   rate-limit marker to be on CR's *latest* comment: when CR resumes and starts
#   actually processing, it posts a newer "Currently processing ..." comment, which
#   becomes the latest and flips this back to "no" (keep waiting). The notice being
#   the last word from CR is the signal that CR is still wedged on the limit.
#
#   comments_json: the PR's issue comments, SAME shape as mc_cr_rate_limited
#     ([ { "author": "login", "body": "..." }, ... ]) and SAME chronological order
#     (GitHub's issue-comments listing is oldest-first, so the last CodeRabbit-
#     authored entry is its most recent comment). Echoes "yes" iff the most recent
#     CodeRabbit-authored comment carries the "rate limited by coderabbit.ai"
#     marker; else "no". A non-array / unparseable input, or no CR comment at all,
#     is "no" (fail closed: never relax a pending review on input we cannot read).
mc_cr_rate_limited_latest() {
  local comments="$1"
  printf '%s' "$comments" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "no"; return 1; }
  local hit
  hit=$(printf '%s' "$comments" | jq -r '
    [ .[] | select( (.author // "") | ascii_downcase | contains("coderabbitai") ) ]
    | (last // {}) | (.body // "")
    | if contains("rate limited by coderabbit.ai") then "yes" else "no" end
  ' 2>/dev/null) || { echo "no"; return 1; }
  if [ "$hit" = "yes" ]; then echo "yes"; return 0; fi
  echo "no"; return 1
}

# mc_cr_failure_rate_limited <cr_status_state> <cr_status_description> [comments_json]
#   Decide whether a CodeRabbit commit status of "failure" on HEAD is really a RATE
#   LIMIT rather than a genuine CodeRabbit objection or CR-side error. This is the
#   third rate-limit shape, and the one the two functions above miss:
#     1. status MISSING  + marker comment  -> mc_cr_rate_limited
#     2. status PENDING (stuck) + marker as CR's LATEST comment
#                                          -> mc_cr_rate_limited_latest
#     3. status FAILURE, description "Review rate limited"  -> THIS function
#   Shape 3 is what CodeRabbit posts when it burns its limit on an INCREMENTAL pass:
#   it has already reviewed the PR (often posting acks on every finding), then the
#   final pass over a trailing commit trips the limit and CR resolves its per-commit
#   status to failure with a rate-limit description. In that flavour CR posts NO
#   marker comment at all, so keying only on "rate limited by coderabbit.ai" (as the
#   two functions above do) leaves the PR wedged behind a hard failure blocker. The
#   marker is therefore the SECONDARY proof here, for the residual case where CR
#   posts both; the description is the primary one.
#
#   cr_status_state:       the already-folded CR commit-status state on HEAD
#     (state_of "CodeRabbit"): success | failure | pending | missing. Only "failure"
#     can be a shape-3 rate limit; every other state echoes "no" (the caller handles
#     missing / pending through the two functions above).
#   cr_status_description: the description string on that CodeRabbit status
#     (e.g. "Review rate limited"). Matched case-insensitively against
#     "rate[ -]?limit", so "Review rate limited", "Rate limit exceeded",
#     "Rate-limited" and "ratelimit" all hit. A plain substring test missed the
#     hyphenated spelling, and that miss would be SILENT: the operator would be
#     told the failure is genuine when it is not.
#     A NEGATED phrasing ("not rate limited", "no rate limit hit") is explicitly
#     excluded, so a description that mentions rate limiting only to deny it
#     cannot buy the escape hatch. This is a prefix-negation guard, NOT a semantic
#     parser: a trailing negation ("rate limit was not the cause") would still
#     classify as a rate limit. Accepted, and bounded: even then the failure only
#     degrades from a hard block to "requires a current local /eng:cr review",
#     which is the same deal the other two shapes get. Widen the guard if CR's
#     wording ever makes that theoretical case real.
#   comments_json (optional): the PR's issue comments, SAME shape as
#     mc_cr_rate_limited. Checked as a SECOND, independent proof, via the STRICT
#     mc_cr_rate_limited_latest: the marker must be CR's LATEST comment. The loose
#     mc_cr_rate_limited would match a marker anywhere in the PR's history, so a
#     stale rate-limit notice from an early commit would let a LATER, genuine CR
#     failure auto-clear while the audit trail called it a rate limit. That is the
#     same stale-evidence trap mc_cr_rate_limited_latest already exists to close
#     for the stuck-pending shape; shape 3 gets the same discipline.
#     Defaults to [] so a description-only caller works.
#
#   Echoes "yes" iff the state is "failure" AND (the description says rate limit,
#   non-negated, OR the marker is CR's latest comment); else "no". Return code
#   mirrors the verdict. Fails CLOSED in every degraded direction: a non-failure
#   state, an unreadable description, and an unparseable comments array all yield
#   "no", so a genuine CR failure is never mistaken for a rate limit. Like the other
#   two shapes this only ever RELAXES the gate in combination with a current local
#   /eng:cr review; mc_cr_failure_disposition owns that interlock.
# mc_desc_rate_limited <cr_status_description>
#   The HARDENED description test: a positive "rate limit" match minus prefix
#   negations. Shared by the failure and success shapes, both of which rely on it
#   as PROOF that CR did not review.
#
#   Not to be confused with mc_status_rate_limited above, which is the LOOSE
#   variant (plain substring, no negation guard). That one only decides whether a
#   green status is worth a second look; this one is what a shape may act on.
mc_desc_rate_limited() {
  local desc="${1:-}"
  # Positive match, minus negations. grep -i keeps the case-insensitivity without
  # a tr round-trip, and -E gives the optional space/hyphen between the words.
  if printf '%s' "$desc" | grep -qiE 'rate[ -]?limit' \
     && ! printf '%s' "$desc" | grep -qiE '(not|no|never|isn.t|wasn.t)[^.]{0,20}rate[ -]?limit'; then
    echo "yes"; return 0
  fi
  echo "no"; return 1
}

mc_cr_failure_rate_limited() {
  local state="$1" desc="${2:-}" comments="${3:-[]}"
  [ "$state" = "failure" ] || { echo "no"; return 1; }
  if [ "$(mc_desc_rate_limited "$desc")" = "yes" ]; then
    echo "yes"; return 0
  fi
  # Second proof: the marker as CR's LATEST comment. mc_cr_rate_limited_latest
  # returns rc 1 on "no", but it is read here as a string in $(...), so only its
  # stdout token is authoritative.
  if [ "$(mc_cr_rate_limited_latest "$comments")" = "yes" ]; then echo "yes"; return 0; fi
  echo "no"; return 1
}

# mc_cr_failure_disposition <cr_status_state> <failure_rate_limited> <override_flag> <review_state>
#   The gate's whole decision about a CodeRabbit FAILURE status on HEAD, as one
#   pure function. This lives here rather than as shell control flow in
#   merge-clearance.sh because it is the single most security-relevant decision the
#   gate makes: it is what stands between "--override-cr-failure" and a bare merge
#   bypass. As inline `&&` chains in the I/O script it could only ever be verified
#   by hand; here every row of its truth table is a bats case.
#
#   Arguments are all already-computed scalars (no network, no git):
#     cr_status_state:       success | failure | pending | missing (state_of "CodeRabbit")
#     failure_rate_limited:  yes | no  (mc_cr_failure_rate_limited)
#     override_flag:         1 | 0     (the --override-cr-failure flag)
#     review_state:          current | stale | missing | n/a  (the /eng:cr stamp vs HEAD)
#
#   Echoes exactly one disposition token; rc 0 for the non-blocking ones, 1 for the
#   blocking ones so callers can branch on either:
#     n/a                             - not a failure status; nothing to decide (rc 0)
#     override-inert                  - flag passed on a non-failure status; it does
#                                       nothing, and the caller should SAY so (rc 0)
#     cleared-rate-limited            - rate limit + current local review (rc 0)
#     cleared-override                - genuine failure + explicit flag + current
#                                       local review (rc 0)
#     block-rate-limited-unbackstopped- rate limit but no current local review (rc 1)
#     block-override-needs-review     - flag passed but no current local review (rc 1)
#     block-genuine                   - genuine CR failure, no flag (rc 1)
#
#   The invariants this function EXISTS to enforce, none of which may be relaxed:
#     1. NOTHING clears a failure without review_state == "current". Not the rate
#        limit, not the operator flag. "Never both reviewers down."
#     2. review_state is read as given. The caller must NOT fold --skip-review or
#        the bookkeeping fast lane into it: those waive the review DIMENSION, they
#        do not conjure a review that can backstop a broken CodeRabbit.
#     3. The rate-limit path is checked BEFORE the override path, so a failure the
#        machine can classify never gets ATTRIBUTED to human judgment. Passing the
#        flag defensively on a rate-limited failure yields cleared-rate-limited, so
#        a later grep for real operator overrides stays free of false positives.
#     4. The default is to block. Any state that is not explicitly cleared above
#        falls through to block-genuine.
mc_cr_failure_disposition() {
  local state="$1" rate_limited="${2:-no}" override="${3:-0}" review="${4:-}"

  if [ "$state" != "failure" ]; then
    [ "$override" = "1" ] && { echo "override-inert"; return 0; }
    echo "n/a"; return 0
  fi

  # Invariant 3: machine-detectable rate limit wins over the human flag.
  if [ "$rate_limited" = "yes" ]; then
    [ "$review" = "current" ] && { echo "cleared-rate-limited"; return 0; }
    echo "block-rate-limited-unbackstopped"; return 1
  fi

  if [ "$override" = "1" ]; then
    [ "$review" = "current" ] && { echo "cleared-override"; return 0; }
    echo "block-override-needs-review"; return 1
  fi

  # Invariant 4: default deny.
  echo "block-genuine"; return 1
}

# mc_head_cr_unreviewable <files_json> <globs_json>
#   Decide whether the INCREMENTAL change at a PR HEAD is something CodeRabbit
#   legitimately cannot (or will not) review. This is the ONLY condition under
#   which "CodeRabbit has not reviewed this HEAD" must NOT block: when there was
#   nothing reviewable at this HEAD to begin with, CR's silence is not a gap.
#
#   Motivating case: a trailing commit whose only change is a Pencil `*.pen`
#   wireframe. Despite the "encrypted" framing, a .pen is plaintext JSON that git
#   treats as TEXT, so binary detection alone misses it; CodeRabbit still posts no
#   review on such a HEAD (its config / heuristics skip those paths). The glob
#   list is what carries that case; the binary flag covers genuinely binary blobs
#   (images, archives) without needing a per-repo glob.
#
#   files_json: the files changed by HEAD vs its parent, shape
#     [ { "path": "spec/x.pen", "binary": true|false }, ... ]   (binary = git
#     treats the blob as binary, i.e. numstat shows "-\t-").
#   globs_json:  patterns from the repo marker's cr_unreviewable_globs (the CLI
#     defaults this to ["*.pen"]), gitignore / minimatch style. A glob with NO
#     slash matches the path BASENAME at any depth (so "*.pen" catches
#     spec/wireframes/gmail-overlay.pen); a glob WITH a slash is anchored against
#     the full path. Tokens: "*" (a run of non-slash chars), "**" (a run incl.
#     slashes), "?" (one non-slash char), literal dots, exact segments. e.g.
#     "*.pen", "spec/wireframes/**", "spec/x.pen". Other regex metacharacters in
#     a glob are out of scope (documented, not escaped).
#
#   Echoes "yes" iff files_json is a NON-EMPTY array AND EVERY entry is either
#   git-binary OR matches at least one glob; else "no". An empty / non-array /
#   unparseable files_json is "no" (fail closed: never auto-satisfy on a diff we
#   could not read). The non-empty requirement means a zero-file HEAD never
#   auto-clears. A non-array globs_json is treated as [] (matches nothing), so a
#   malformed marker degrades to binary-only detection rather than over-clearing.
mc_head_cr_unreviewable() {
  local files="$1" globs="${2:-[]}"
  printf '%s' "$files" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "no"; return 1; }
  printf '%s' "$globs" | jq -e 'type=="array"' >/dev/null 2>&1 || globs='[]'
  local res
  res=$(jq -nc --argjson files "$files" --argjson globs "$globs" '
    # Translate a file glob to an anchored regex. Protect literal dots and **
    # behind private-use sentinels (never seen in a real path), expand * and ?,
    # then restore. Only "." is escaped (the one regex metachar realistic in a
    # path); exotic metachars in a glob are out of scope by design.
    def glob2re($g):
      "^" + ( $g
        | gsub("\\.";    "\uE000")   # protect literal dots
        | gsub("\\*\\*"; "\uE001")   # protect ** (matches across slashes)
        | gsub("\\*";    "[^/]*")     # *  -> run of non-slash chars
        | gsub("\uE001";  ".*")        # ** -> run incl. slashes
        | gsub("\\?";    "[^/]")      # ?  -> one non-slash char
        | gsub("\uE000";  "\\.") )   # restore dots, escaped
        + "$";
    # gitignore / minimatch semantics (what .coderabbit.yaml path_filters use):
    # a glob with NO slash (e.g. "*.pen") matches the basename at ANY depth, so
    # it catches spec/wireframes/gmail-overlay.pen; a glob WITH a slash (e.g.
    # "spec/wireframes/**") is anchored against the full path. Bind the glob to
    # $g BEFORE the "$p |"/"$base |" pipe: inside test(...) the pipe rebinds "."
    # to the path, so glob2re(.) would otherwise build a regex from the path and
    # match it against itself (everything passes). $g keeps the glob.
    def matches($p):
      ($p | split("/") | last) as $base
      | any($globs[]; . as $g
          | if ($g | test("/"))
            then ($p    | test(glob2re($g)))
            else ($base | test(glob2re($g))) end);
    if ($files | length) == 0 then false
    else
      # A null path (e.g. a malformed numstat row with < 3 fields) must NEVER be
      # treated as unreviewable just because .binary is true; require a real path
      # so a degenerate entry fails closed rather than auto-clearing.
      all($files[]; (.path != null) and ((.binary == true) or matches(.path)))
    end' 2>/dev/null) || { echo "no"; return 1; }
  if [ "$res" = "true" ]; then echo "yes"; return 0; fi
  echo "no"; return 1
}
# mc_qa_state <pr_body> <require_qa_plan:0|1>
#   Classify the QA checklist in the PR body's "## QA" section. Echoes one of:
#     complete   - the section has checkbox(es) and all are checked
#     incomplete - the section has at least one unchecked box (Dev QA not done)
#     missing    - require_qa_plan=1 AND the section has no checklist at all
#                  (no /qa:plan run); the b5 "require a QA plan to exist" gate
#     n/a        - no checklist and require_qa_plan=0 (legacy: QA not gated here)
#   Return code: 0 for complete / n/a (non-blocking), 1 for incomplete / missing.
#
#   The section spans the "## QA" heading down to the next heading of the SAME OR
#   HIGHER level, so deeper subheadings (### Development QA / ### Production QA,
#   where the boxes live) stay INSIDE. Fenced code blocks are skipped so a body
#   that documents the gate (```- [ ] ...```) is not parsed as real QA boxes.
#   require_qa_plan is opt-in per repo via .merge-clearance.json; default 0
#   preserves the prior behavior exactly (no checklist -> n/a, non-blocking).
#
#   Checkbox detection reads BOTH shapes: the legacy bullet checkbox (- [ ] / - [x]
#   in the Definition-of-Done list and older PR bodies) AND the Template B DEV-row
#   TABLE CELL checkbox (| [ ] | / | [x] |), which has no leading "- ". It matches
#   any checkbox bracket [ ]/[x]/[X] within the fence-stripped section, so a single
#   unchecked box in either place classifies "incomplete". Template B PROD rows use
#   "-" (a plain hyphen, no bracket) in their Status cell, so they correctly do not
#   count toward the merge gate.
mc_qa_state() {
  local body="$1" require="${2:-0}"
  local section
  section=$(printf '%s\n' "$body" | awk '
    BEGIN{inqa=0; qalevel=0; fence=0}
    {
      line=$0; h=line; sub(/^[[:space:]]*/,"",h)
      if (h ~ /^(```|~~~)/) { fence=!fence; next }
      if (fence) next
      if (h ~ /^#+[[:space:]]/) {
        n=0; while (substr(h,n+1,1)=="#") n++
        rest=substr(h,n+1)
        if (inqa==0) { if (rest ~ /^[[:space:]]+QA([[:space:]]|$|\()/) { inqa=1; qalevel=n; next } }
        else if (n<=qalevel) { inqa=0 }
      }
    }
    inqa{print}
  ')
  if printf '%s' "$section" | grep -qE '\[[ xX]\]'; then
    if printf '%s' "$section" | grep -qE '\[ \]'; then echo "incomplete"; return 1; fi
    echo "complete"; return 0
  fi
  if [ "$require" = "1" ]; then echo "missing"; return 1; fi
  echo "n/a"; return 0
}

# mc_collapse_checkruns <checkruns_json>
#   Collapse raw GitHub check-runs for one commit into a name->state list, keeping
#   ONLY the runs belonging to each name's most recent check SUITE.
#
#   Why this exists. GitHub keeps every historical check-run on a commit, and a
#   re-run creates a NEW check suite rather than replacing the old one. The caller
#   folds a name's states with "any failure wins", so without this collapse a check
#   that failed and was then fixed by a re-run stays failed forever: the old
#   failing run is still on the commit and still wins. The gate could then never
#   clear until the head moved, which cost an empty commit and a re-review every
#   time. Observed on Healthcare-Super-Connector/hesco#92 (head 0babf999b66e):
#   qa-status had failure/failure/success across three suites and merge-clearance
#   reported CI FAIL while every check's current state was green.
#
#   Why not simply "newest run per name". A single check suite can legitimately
#   carry several runs sharing one name, and ALL of them must pass. Taking only the
#   newest would report success while a sibling leg failed, turning a conservative
#   bug into a permissive one. That is strictly worse for a gate whose job is to
#   refuse on doubt. So: pick the newest SUITE per name, then keep EVERY run of
#   that name inside it and let the caller's any-failure-wins fold do its work.
#
#   Recency is the max started_at among that name's runs, with the suite id as a
#   tie-break (suite ids increase over time, so this is stable when started_at is
#   absent or equal). Note GitHub's own filter=latest does NOT do this: it means
#   "latest attempt within each suite", which is why three qa-status runs came back
#   above. Verified against the live API on 2026-09-02.
#
#   checkruns_json: [ { "name": ..., "state": ..., "suite": ..., "started": ... }, ... ]
#   Echoes a compact JSON array of { name, state } for the surviving runs.
#   Unparseable or non-array input echoes [] (fail closed: the caller reads a
#   missing name as "missing", never as a pass).
mc_collapse_checkruns() {
  _mcc_raw="${1:-}"
  # Empty input is its own case: jq on empty stdin exits 0 with NO output, so a
  # bare `|| echo []` never fires and the caller would receive an empty string
  # (and then fail on --argjson). Handle it before jq ever runs.
  if [ -z "$_mcc_raw" ]; then echo '[]'; return 0; fi
  _mcc_out=$(printf '%s' "$_mcc_raw" | jq -c '
    if type != "array" then []
    else
      group_by(.name)
      | map(
          # Fail closed when ANY run of this name lacks a suite id. Collapsing on a
          # null suite would keep only the null-suite runs and DROP real ones, so a
          # dropped failure would read as success. Ambiguity must never become
          # permissiveness in a gate, so an incomplete group is left uncollapsed and
          # the any-failure-wins fold downstream still sees every run.
          if any(.[]; (.suite == null)) then
            map({name: .name, state: .state})
          else
            ( max_by([(.started // ""), .suite]) | .suite ) as $newest
            | map(select(.suite == $newest) | {name: .name, state: .state})
          end
        )
      | add // []
    end
  ' 2>/dev/null) || _mcc_out=''
  [ -n "$_mcc_out" ] || _mcc_out='[]'
  printf '%s\n' "$_mcc_out"
}
