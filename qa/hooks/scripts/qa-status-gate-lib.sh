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

  # Posture already stated -> allow regardless of anything else.
  if printf '%s' "$msg" | grep -qiE 'QA_STATUS:'; then
    echo allow
    return 0
  fi

  # No shippable work in the tree -> nothing to QA, allow.
  if [ "$shippable" != "1" ]; then
    echo allow
    return 0
  fi

  # Strip fenced code blocks so trigger words inside ``` ... ``` (examples,
  # quoted logs, the gate discussing itself) do not count as a claim.
  local clean
  clean=$(printf '%s\n' "$msg" | awk 'BEGIN{f=0} /^[[:space:]]*```/{f=!f; next} !f{print}')

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
# These functions let the gate reject a prod_verified EVIDENCE line that names
# only an upstream / base / proxy artifact instead of the exact production
# artifact the approved plan named in its `Production artifact:` field. They are
# PURE (no I/O): qa-status-gate.sh fetches the PR body, extracts the field, and
# passes it in.
#
# Conservative by construction (this gate fails OPEN and has fleet-wide blast
# radius). The only verdict that blocks is `mismatch`, returned ONLY when the
# evidence references the SAME image family as a named plan artifact but NOT the
# exact production ref -- the precise shape of a base/proxy substitution.
# Evidence that does not reference the family at all, a plan field with no
# machine-matchable token, or an absent field all return a non-blocking verdict.
# Enforcement engages only when a `Production artifact:` field is actually
# present, so PRs without it behave exactly as before this change.

# qa_extract_evidence <message>
#   Echo every `EVIDENCE:` line found in the message (the substring from
#   `EVIDENCE:` to end of line). The downstream verdict does substring matching,
#   so the leading `EVIDENCE:` token is harmless and is left in place.
qa_extract_evidence() {
  printf '%s\n' "$1" | grep -oiE 'EVIDENCE:.*'
}

# qa_extract_prod_artifact <pr_body>
#   Echo each structured `Production artifact:` field value from a PR body (the
#   shape /qa:plan writes: a plan list item, or a bare line). Anchored to the
#   start of a line (after optional leading whitespace and an optional list
#   bullet) so PROSE that merely MENTIONS the words "Production artifact:"
#   mid-sentence (e.g. a PR summary describing the field, like this very repo's
#   PRs) is NOT mistaken for a declared artifact. Pure, so the hook's one impure
#   step (the gh fetch) is the only untested line.
qa_extract_prod_artifact() {
  printf '%s\n' "$1" | grep -oiE '^[[:space:]]*[-*]?[[:space:]]*Production artifact:.*'
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

  # Backward compat: no Production artifact field -> enforcement disabled.
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

# qa_artifact_gate <message> <prod_artifact_field>  -> block|allow  (PURE)
#   The composable gate decision used by the Stop hook AND the bats tests. Blocks
#   ONLY when the message states a prod_verified posture AND its EVIDENCE names a
#   base/proxy artifact instead of the production artifact the plan named. Any
#   other posture, missing evidence, or a non-blocking verdict -> allow.
qa_artifact_gate() {
  local msg="$1" field="$2"

  # Strip fenced code blocks so a message that quotes or discusses the posture
  # inside ``` ... ``` does not engage enforcement (same guard as the posture gate).
  local clean
  clean=$(printf '%s\n' "$msg" | awk 'BEGIN{f=0} /^[[:space:]]*```/{f=!f; next} !f{print}')

  # Scope: prod_verified only. dev_verified is exercised against a dev / preview
  # artifact by design and has no Production-artifact field to match against;
  # enforcing it would be a category error and could false-block correct dev QA.
  printf '%s' "$clean" | grep -qiE 'QA_STATUS:[[:space:]]*prod_verified' || { echo allow; return 0; }

  local evidence
  evidence=$(qa_extract_evidence "$clean")
  [ -n "$evidence" ] || { echo allow; return 0; }   # no evidence to evaluate -> fail open

  if [ "$(qa_evidence_artifact_verdict "$evidence" "$field")" = "mismatch" ]; then
    echo block
    return 0
  fi
  echo allow
}
