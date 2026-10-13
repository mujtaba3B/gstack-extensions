#!/bin/bash
# Pure decision logic for the QA-status Stop gate, extracted so it can be unit
# tested without a live transcript or git repo. No side effects, no I/O beyond
# the args it is handed.
#
# qa_gate_decision <last_assistant_message> <shippable:0|1>
#   echoes "block" or "allow".
#
# Policy: make QA a first-class, stated posture at the moment work is declared
# done. If the message already carries a QA_STATUS line, the posture is stated,
# so allow. Otherwise, only gate when there is shippable work AND the message
# makes a (non-negated) completion claim. Everything else allows: this gate
# fails OPEN by design, so a miss is caught by the PR CI backstop rather than
# the gate nagging on a chat turn.
#
# Accepted postures (any one stated -> allow). The full contract for each, the
# QA-driver roster rules, and the CI asymmetry live in ONE home:
# docs/qa-status-postures.md. Keyword summary only here:
#   dev_verified                + EVIDENCE:   (alias: verified)
#   deploy_branch_for_manual_qa + DRIVER: <roster-id> + DEPLOYED:
#   prod_verified               + EVIDENCE:   (post-deploy only)
#   awaiting_human              + DRIVER: + CHECK: + PHASE: dev|prod
#   blocked                     + REASON:
#   skip_requested              + REASON:  (then a signed skip in the PR)
#   skip_approved               (the recorded human sign-off)
#   no_tracked_change           (docs/memory/ops-only turn; nothing to QA)
# This function only checks that SOME posture is stated, not that it is
# well-formed, on purpose: it is a "did you decide?" gate, not a linter. Keeping
# it shape-agnostic means a newly documented posture is accepted with no regex to
# keep in sync; docs/qa-status-postures.md carries the contract the agent reads
# (the block message names the keywords and points there).
#
# False-positive guards (the reason this is not a bare grep):
#   - Fenced code blocks are stripped before matching, so quoting or discussing
#     a trigger word (common in this very repo) does not block.
#   - The completion match is negation-aware ("not done", "isn't ready",
#     "don't merge yet" do NOT block), via fixed-width perl lookbehinds.

qa_gate_decision() {
  local msg="$1" shippable="$2"

  # Strip fenced code blocks FIRST, for BOTH checks: trigger words inside
  # ``` ... ``` (examples, quoted logs, the gate discussing itself) do not
  # count as a claim, and a QA_STATUS: token inside a fence is a quotation,
  # not a stated posture, so it must not satisfy the gate either.
  local clean
  clean=$(printf '%s\n' "$msg" | awk 'BEGIN{f=0} /^[[:space:]]*```/{f=!f; next} !f{print}')

  # Posture already stated (outside fences) -> allow regardless of anything else.
  if printf '%s' "$clean" | grep -qiE 'QA_STATUS:'; then
    echo allow
    return 0
  fi

  # No shippable work in the tree -> nothing to QA, allow.
  if [ "$shippable" != "1" ]; then
    echo allow
    return 0
  fi

  # Negation-aware completion claim. perl gives fixed-width negative lookbehinds
  # so "not done" / "isn't ready" / "never shipped" do not match. If perl is
  # missing or errors, the `if` sees a non-zero exit and we fall through to
  # allow (fail open).
  if printf '%s' "$clean" | /usr/bin/perl -0777 -ne '
      exit 0 if /(?<!not )(?<!n.t )(?<!never )\b(done|shipped|landed|opened (?:a |the )?pr|pr is up|ready to (?:merge|ship)|ready for merge|good to merge|all green)\b/i;
      exit 1;
  '; then
    echo block
    return 0
  fi

  echo allow
}

# ---------------------------------------------------------------------------
# Artifact-evidence check (incident hardening).
#
# Motivation: a change in a shared Docker BASE image was "prod_verified" by
# running the BASE image directly with `docker run`, but production runs
# PER-AGENT images derived FROM that base (e.g.
# nanoclaw-agent-v2-83c915c8:ag-...-main), which had silently gone stale. The
# QA plan had NAMED the correct production check; the executor substituted a
# weaker proxy at execution time and the gate accepted prod_verified on it. The
# bug was caught only by a later manual in-container smoke.
#
# These functions let the gate reject a Production-QA EVIDENCE line
# (prod_verified, or an awaiting_human production handoff) that names only an
# upstream / base / proxy artifact instead of the exact production artifact the
# approved plan named in its `Production artifacts:` field. They are PURE (no
# I/O): qa-status-gate.sh fetches the PR body, extracts the field, and passes
# it in.
#
# Conservative by construction (this gate fails OPEN and has fleet-wide blast
# radius). The only verdict that blocks is `mismatch`, returned ONLY when the
# evidence references the SAME image family as a named plan artifact but NOT the
# exact production ref -- the precise shape of a base/proxy substitution.
# Evidence that does not reference the family at all, a plan field with no
# machine-matchable token, or an absent field all return a non-blocking verdict.
# Enforcement engages only when a `Production artifacts:` field is actually
# present, so PRs without it behave exactly as before this change.

# qa_extract_evidence <message>
#   Echo every `EVIDENCE:` line found in the message (the substring from
#   `EVIDENCE:` to end of line). The downstream verdict does substring matching,
#   so the leading `EVIDENCE:` token is harmless and is left in place.
qa_extract_evidence() {
  printf '%s\n' "$1" | grep -oiE 'EVIDENCE:.*'
}

# qa_extract_prod_artifact <pr_body>
#   Echo each structured Production-artifact(s) field value from a PR body. The
#   /qa:plan template writes this field as `**Production artifacts:**` (bold,
#   plural); older plans wrote a plain `Production artifact:` line or a
#   `- Production artifact:` bullet. The match tolerates all of these: optional
#   leading indentation, list bullets, and `**` bold markers, in any order, with
#   the noun singular or plural. It stays ANCHORED to the start of a line so PROSE
#   that merely MENTIONS the words "Production artifact(s):" mid-sentence (e.g. a
#   PR summary describing the field, like this very repo's PRs) is NOT mistaken
#   for a declared artifact. Pure, so the hook's one impure step (the gh fetch) is
#   the only untested line.
#
#   History: the anchor once required the singular `Production artifact:` with at
#   most one bullet char, so it never matched the template's bold plural label and
#   the artifact-evidence gate below sat DORMANT (fail-open on every PR). The
#   character class `[-*[:space:]]*` now absorbs `**`, bullets, and indent alike.
qa_extract_prod_artifact() {
  printf '%s\n' "$1" | grep -oiE '^[[:space:]]*[-*[:space:]]*Production artifacts?:.*'
}

# qa_evidence_artifact_verdict <evidence_text> <prod_artifact_field>
#   Echo one of:
#     ok       -> evidence names the exact production artifact the plan named.
#     mismatch -> evidence references that artifact's image FAMILY (the base
#                 before the tag) but NOT the exact ref -> a base/proxy
#                 substitution. THE ONLY BLOCKING VERDICT.
#     n/a      -> enforcement does not apply / cannot be decided -> fail open:
#                 no field, no machine-matchable token in the field, or the
#                 evidence does not reference the family at all.
#   Matchable tokens are container image refs (`image:tag`) and sha256 digests,
#   the shapes that carry the base-vs-derived staleness risk. Non-image
#   artifacts (a release version, a bundle id with no `:`) yield no token and
#   return n/a; for those the plan prose carries the discipline, not this gate.
qa_evidence_artifact_verdict() {
  local evidence="$1" field="$2"

  # Backward compat: no Production artifacts field -> enforcement disabled.
  [ -n "$(printf '%s' "$field" | tr -d '[:space:]')" ] || { echo "n/a"; return 0; }

  # Strip URLs first so a "how it is exercised" URL like https://host:443/path
  # is not mistaken for an image:tag ref.
  local fclean
  fclean=$(printf '%s' "$field" | sed -E 's#https?://[^[:space:]]*##g')

  # Distinctive production refs the plan named: image:tag (excluding sha256:...,
  # handled separately as a digest) and sha256 digests.
  local refs digests tok
  refs=$(printf '%s\n' "$fclean" | grep -oE '[A-Za-z0-9][A-Za-z0-9._/-]*:[A-Za-z0-9][A-Za-z0-9._-]+' | grep -viE '^sha256:' || true)
  digests=$(printf '%s\n' "$fclean" | grep -oiE 'sha256:[0-9a-f]{12,}' || true)

  # 1) Evidence names the exact production artifact (full ref or digest) -> ok.
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    case "$evidence" in *"$tok"*) echo "ok"; return 0 ;; esac
  done <<EOF
$refs
$digests
EOF

  # 2) Evidence references a ref's image FAMILY (base before the tag) but not the
  #    exact ref -> base/proxy substitution -> mismatch. Only a DISTINCTIVE base
  #    (length >= 6 AND containing '-' or '/') counts, so generic word:word prose
  #    cannot trigger a block.
  local base
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    base="${tok%:*}"
    if [ "${#base}" -ge 6 ] && printf '%s' "$base" | grep -qE '[/-]'; then
      case "$evidence" in *"$base"*) echo "mismatch"; return 0 ;; esac
    fi
  done <<EOF
$refs
EOF

  # 3) Evidence does not reference the family at all -> cannot decide -> fail open.
  echo "n/a"
  return 0
}

# qa_strip_fences <message>  -> message without ``` fenced blocks  (PURE)
#   The one fence stripper the artifact check uses, so the hook's network
#   prefilter and qa_artifact_gate decide on exactly the same text.
qa_strip_fences() {
  printf '%s\n' "$1" | awk 'BEGIN{f=0} /^[[:space:]]*```/{f=!f; next} !f{print}'
}

# The patterns qa_artifact_engages decides with and qa_artifact_engage_reason
# explains with. Shared so the explanation cannot drift from the decision.
# Plain (not readonly) so re-sourcing the lib, as bats does per test, is safe.
QA_PROD_VERIFIED_RE='QA_STATUS:[[:space:]]*prod_verified'
QA_PHASE_TOKEN_RE='PHASE[*`_[:space:]]*[:=|-][^[:alnum:]]*[[:alnum:]][[:alnum:]-]*'
QA_PHASE_DEV_RE='[^[:alnum:]-](dev|development)$'
QA_PROD_WORD_RE='(^|[^[:alnum:]])(pre-?)?prod(uction)?([^[:alnum:]]|$)'

# qa_artifact_engages <fence_stripped_message>  -> yes|no  (PURE)
#   Whether a message makes a Production-QA evidence claim the artifact check
#   must inspect. A `QA_STATUS: prod_verified` posture engages. So does an
#   `awaiting_human` posture (bold or backticked too), UNLESS it is plainly dev:
#   every `PHASE <separator> <value>` token in the message (separator `:`, `=`,
#   `|` or a spaced ` - `, markup tolerated; an unspaced "PHASE-dev" is not
#   read as dev and engages) has the value `dev` or `development`, at
#   least one such token exists, and NO line pairs `PHASE` with the word prod
#   (`prod`, `production`, `pre-prod`, `preprod`; not "product" or "reproduce")
#   anywhere after it. So "PHASE: post-deploy" engages as surely as "prod".
#   An awaiting_human production handoff's EVIDENCE closes the agent-runnable
#   Production rows before the human's check, so a base / proxy artifact there
#   is the same stale-image risk.
#   Both tests match anywhere in the text rather than parsing "PHASE lines":
#   every line-parsing rule tried here was beaten by formatting (a one-line
#   posture, recap bullets, tables, list markers, "e.g."). Once a message has a
#   non-dev PHASE token or a PHASE/prod pairing, no added text can cancel it;
#   the only way out is a message whose every PHASE token is dev. Everything
#   ambiguous engages (fail closed): no PHASE at all, "devops", "dev and prod",
#   the "dev|prod" menu, prose such as "next we move to PHASE: prod". Engaging
#   only means evidence gets checked; a missing `Production artifacts:` field
#   (no PR on the current branch, e.g. a deploy run from main) still fails open
#   downstream. Known residual: an agent that never pairs PHASE with prod, and
#   declares PHASE: dev on what is really a post-deploy handoff, is not checked.
#   The block message must never coach that relabel.
qa_artifact_engages() {
  local msg="$1" values
  if printf '%s' "$msg" | grep -qiE "$QA_PROD_VERIFIED_RE"; then
    echo yes; return 0
  fi
  if printf '%s' "$msg" | grep -qiE 'QA_STATUS:[*`_[:space:]]*awaiting_human'; then
    values=$(printf '%s\n' "$msg" | grep -oiE "$QA_PHASE_TOKEN_RE")
    if [ -n "$values" ] \
       && ! printf '%s\n' "$values" | grep -viqE "$QA_PHASE_DEV_RE" \
       && ! printf '%s\n' "$msg" | grep -qiE "PHASE.*${QA_PROD_WORD_RE}"; then
      echo no; return 0
    fi
    echo yes; return 0
  fi
  echo no
}

# qa_artifact_engage_reason <fence_stripped_message>  -> one line  (PURE)
#   Why qa_artifact_engages said yes, for the block message, so an agent whose
#   honest dev handoff was engaged by a stray mention (a "Phase" table header,
#   a "PHASE: prod" remark) can see the exact text and reword it. Echoes the
#   prod_verified posture if stated, else the span from PHASE to prod on the
#   first line pairing them, else the first non-dev PHASE token, else a
#   neutral "treated as prod" note (worded so it never reads as "add PHASE:
#   dev"). Every branch is cut to 80 chars. It reads the same
#   QA_*_RE patterns as qa_artifact_engages, so the two cannot drift; it never
#   changes the decision, it only explains it.
qa_artifact_engage_reason() {
  local msg="$1" why line
  if printf '%s' "$msg" | grep -qiE "$QA_PROD_VERIFIED_RE"; then
    echo "QA_STATUS: prod_verified"; return 0
  fi
  line=$(printf '%s\n' "$msg" | grep -iE "PHASE.*${QA_PROD_WORD_RE}" | head -n 1)
  if [ -n "$line" ]; then
    # The span, so a trigger past column 80 of a wide row still shows.
    why=$(printf '%s\n' "$line" | grep -oiE "PHASE.{0,60}${QA_PROD_WORD_RE}" | head -n 1)
    [ -n "$why" ] || why=$(printf '%s\n' "$line" | grep -oiE 'PHASE.*' | head -n 1)
  else
    why=$(printf '%s\n' "$msg" | grep -oiE "$QA_PHASE_TOKEN_RE" \
          | grep -viE "$QA_PHASE_DEV_RE" | head -n 1)
  fi
  [ -n "$why" ] || why="awaiting_human with no plain PHASE: dev (treated as prod)"
  printf '%s\n' "$why" | cut -c1-80
}

# qa_artifact_gate <message> <prod_artifact_field>  -> block|allow  (PURE)
#   The composable gate decision used by the Stop hook AND the bats tests. Blocks
#   ONLY when the message makes a Production-QA evidence claim
#   (qa_artifact_engages decides: prod_verified, or an awaiting_human that is
#   not plainly PHASE: dev) AND
#   its EVIDENCE names a base/proxy artifact instead of the production artifact
#   the plan named. Any other posture, missing evidence, or a non-blocking
#   verdict -> allow.
qa_artifact_gate() {
  local msg="$1" field="$2"

  # Strip fenced code blocks so a message that quotes or discusses the posture
  # inside ``` ... ``` does not engage enforcement (same guard as the posture gate).
  local clean
  clean=$(qa_strip_fences "$msg")

  # Scope: Production-QA claims only, as qa_artifact_engages decides. dev_verified and an
  # awaiting_human PHASE: dev handoff are exercised against a dev / preview
  # artifact by design; enforcing them would be a category error and could
  # false-block correct dev QA.
  [ "$(qa_artifact_engages "$clean")" = "yes" ] || { echo allow; return 0; }

  local evidence
  evidence=$(qa_extract_evidence "$clean")
  [ -n "$evidence" ] || { echo allow; return 0; }   # no evidence to evaluate -> fail open

  if [ "$(qa_evidence_artifact_verdict "$evidence" "$field")" = "mismatch" ]; then
    echo block
    return 0
  fi
  echo allow
}
