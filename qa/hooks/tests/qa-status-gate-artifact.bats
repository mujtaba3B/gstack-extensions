#!/usr/bin/env bats
# Unit tests for the artifact-evidence functions behind the QA-status Stop gate.
# These run with no network, no gh, no PR, no git repo - every input is a literal,
# which is the whole point: the matching logic is pure so the gate's real
# behavior is exercised directly (the exact bug class this hardening fixes was a
# weaker PROXY being substituted for the real check).
#
# Incident under test: a shared Docker BASE image change was "prod_verified" by
# running the BASE image, but production runs PER-AGENT images derived from it,
# which had gone stale. The gate must reject EVIDENCE that names only the base
# when the approved plan named the per-agent image.

setup() {
  load_lib="$BATS_TEST_DIRNAME/../scripts/qa-status-gate-lib.sh"
  # shellcheck source=/dev/null
  . "$load_lib"

  BASE="nanoclaw-agent-v2-83c915c8"
  PERAGENT="nanoclaw-agent-v2-83c915c8:ag-1776991598924-main"
  FIELD="Production artifact: \`${PERAGENT}\` on mac-mini, container ag-1776991598924, exercised by a live agent run on the host"
}

# ---- qa_extract_evidence ----------------------------------------------------

@test "extract evidence: pulls the EVIDENCE line (inline form)" {
  run qa_extract_evidence "All set. QA_STATUS: prod_verified EVIDENCE: ran docker run $BASE"
  [[ "$output" == *"ran docker run $BASE"* ]]
}

@test "extract evidence: empty when no EVIDENCE line" {
  run qa_extract_evidence "QA_STATUS: prod_verified but I forgot the evidence"
  [ -z "$output" ]
}

# ---- qa_extract_prod_artifact (PR-body field parsing, anchored) -------------

@test "extract prod artifact: a structured bulleted field line is extracted" {
  body=$'### Production QA\n- check via /canary\n  - Production artifact: `'"$PERAGENT"'` on mac-mini'
  run qa_extract_prod_artifact "$body"
  [[ "$output" == *"$PERAGENT"* ]]
}

@test "extract prod artifact: a bare (non-bulleted) field line is extracted" {
  run qa_extract_prod_artifact "Production artifact: $PERAGENT on the host"
  [[ "$output" == *"$PERAGENT"* ]]
}

@test "extract prod artifact: PROSE mentioning the words mid-sentence is NOT extracted" {
  # The PR summary of this very change describes the \`Production artifact:\` field;
  # an anchored match must not treat that as a declared artifact.
  body='The gate reads the `Production artifact:` field via gh and blocks a mismatch.'
  run qa_extract_prod_artifact "$body"
  [ -z "$output" ]
}

# ---- broadened label matching (the arming fix) ------------------------------
# The /qa:plan template writes the field as `**Production artifacts:**` (bold,
# plural). The extractor once required a singular, unbolded `Production artifact:`
# with at most one bullet char, so it never matched the template and the whole
# artifact-evidence gate sat DORMANT. These lock the broadened match: bold,
# plural, indented, bulleted -- while keeping the mid-sentence-prose guard.

@test "extract prod artifact: bold PLURAL label (the /qa:plan template form) is extracted" {
  body=$'### Production\n\n**Production artifacts:** `'"$PERAGENT"'` on mac-mini, exercised by a live agent run.'
  run qa_extract_prod_artifact "$body"
  [[ "$output" == *"$PERAGENT"* ]]
}

@test "extract prod artifact: bold SINGULAR label is extracted" {
  run qa_extract_prod_artifact "**Production artifact:** $PERAGENT on the host"
  [[ "$output" == *"$PERAGENT"* ]]
}

@test "extract prod artifact: indented bold-plural bullet is extracted" {
  body=$'  - **Production artifacts:** `'"$PERAGENT"'` on mac-mini'
  run qa_extract_prod_artifact "$body"
  [[ "$output" == *"$PERAGENT"* ]]
}

@test "extract prod artifact: bold-plural PROSE mention mid-sentence is NOT extracted" {
  body='The gate reads the **Production artifacts:** field via gh and blocks a mismatch.'
  run qa_extract_prod_artifact "$body"
  [ -z "$output" ]
}

# ---- end-to-end through the real template label (the incident, armed) -------
# Extract from a PR body written the way /qa:plan really writes it, then feed the
# extracted field to the gate. Before the fix the field came back empty and the
# gate ALWAYS allowed; these prove it now blocks the exact base/proxy substitution
# and still allows an honest exact-ref claim.

@test "arming: bold-plural field extracted, then BLOCK base-only prod_verified evidence" {
  body=$'### Production\n\n**Production artifacts:** `'"$PERAGENT"'` on mac-mini, exercised by a live agent run on the host.'
  field=$(qa_extract_prod_artifact "$body")
  run qa_artifact_gate "Deployed. QA_STATUS: prod_verified EVIDENCE: ran docker run $BASE" "$field"
  [ "$output" = "block" ]
}

@test "arming: bold-plural field extracted, then ALLOW exact-ref prod_verified evidence" {
  body=$'### Production\n\n**Production artifacts:** `'"$PERAGENT"'` on mac-mini, exercised by a live agent run on the host.'
  field=$(qa_extract_prod_artifact "$body")
  run qa_artifact_gate "Deployed. QA_STATUS: prod_verified EVIDENCE: live agent run on $PERAGENT" "$field"
  [ "$output" = "allow" ]
}

@test "arming: no artifacts field in the body -> extraction empty -> gate fails OPEN" {
  body=$'### Production\n\n| Tester | Check | Expect | Notes |\n| claude | smoke | 200 | none |'
  # grep exits 1 on no match (that IS the "no field" case); mask it like the hook,
  # which pipes through `head`. The point is the empty field, not the exit code.
  field=$(qa_extract_prod_artifact "$body" || true)
  [ -z "$field" ]
  run qa_artifact_gate "Deployed. QA_STATUS: prod_verified EVIDENCE: ran docker run $BASE" "$field"
  [ "$output" = "allow" ]
}

# ---- qa_evidence_artifact_verdict -------------------------------------------

@test "verdict mismatch: evidence names ONLY the base image (the incident)" {
  run qa_evidence_artifact_verdict "EVIDENCE: tested with docker run $BASE, output looked right" "$FIELD"
  [ "$output" = "mismatch" ]
}

@test "verdict ok: evidence names the exact per-agent image tag the plan named" {
  run qa_evidence_artifact_verdict "EVIDENCE: live agent run on $PERAGENT, logs show the new path" "$FIELD"
  [ "$output" = "ok" ]
}

@test "verdict n/a: no Production artifact field -> enforcement disabled (backward compat)" {
  run qa_evidence_artifact_verdict "EVIDENCE: ran docker run $BASE" ""
  [ "$output" = "n/a" ]
}

@test "verdict n/a: whitespace-only field -> enforcement disabled" {
  run qa_evidence_artifact_verdict "EVIDENCE: ran docker run $BASE" "   "
  [ "$output" = "n/a" ]
}

@test "verdict n/a: evidence references neither the ref nor its family" {
  run qa_evidence_artifact_verdict "EVIDENCE: hit https://canary.example.com and saw 200" "$FIELD"
  [ "$output" = "n/a" ]
}

@test "verdict ok: digest match (sha256 named in plan, cited in evidence)" {
  local field="Production artifact: image sha256:deadbeefcafe1234 deployed to prod"
  run qa_evidence_artifact_verdict "EVIDENCE: pulled sha256:deadbeefcafe1234 and ran it" "$field"
  [ "$output" = "ok" ]
}

@test "verdict n/a: non-image artifact (release version, no image:tag) -> no token, fail open" {
  local field="Production artifact: sms-hero release v1.4.2 on Heroku, exercised by hitting the SMS webhook"
  run qa_evidence_artifact_verdict "EVIDENCE: sent a test SMS, got the reply" "$field"
  [ "$output" = "n/a" ]
}

@test "verdict n/a: a URL with a port in the field is not mistaken for image:tag" {
  local field="Production artifact: deployed worker, exercised by https://api.example.com:8443/health"
  # evidence mentions the host but there is no real image family to match
  run qa_evidence_artifact_verdict "EVIDENCE: curled https://api.example.com:8443/health -> 200" "$field"
  [ "$output" = "n/a" ]
}

@test "verdict ok: family base appears AND the exact ref appears -> ok wins" {
  run qa_evidence_artifact_verdict "EVIDENCE: built $BASE then ran $PERAGENT live" "$FIELD"
  [ "$output" = "ok" ]
}

@test "verdict n/a: generic word:word prose does not become a family signal" {
  # 'note:done' has a short, hyphen/slash-free base -> not distinctive -> no block
  local field="Production artifact: note:done"
  run qa_evidence_artifact_verdict "EVIDENCE: note something else entirely" "$field"
  [ "$output" = "n/a" ]
}

# ---- qa_artifact_gate (the composable gate decision) ------------------------

@test "gate block: prod_verified + base-only evidence + plan named per-agent image" {
  run qa_artifact_gate "Deployed. QA_STATUS: prod_verified EVIDENCE: ran docker run $BASE" "$FIELD"
  [ "$output" = "block" ]
}

@test "gate allow: prod_verified + evidence names the exact per-agent image" {
  run qa_artifact_gate "Deployed. QA_STATUS: prod_verified EVIDENCE: live agent run on $PERAGENT" "$FIELD"
  [ "$output" = "allow" ]
}

@test "gate allow: dev_verified is OUT OF SCOPE (dev runs a preview artifact by design)" {
  run qa_artifact_gate "QA_STATUS: dev_verified EVIDENCE: ran docker run $BASE in preview" "$FIELD"
  [ "$output" = "allow" ]
}

@test "gate allow: posture other than prod_verified (blocked) never engages the check" {
  run qa_artifact_gate "QA_STATUS: blocked REASON: cannot reach the host" "$FIELD"
  [ "$output" = "allow" ]
}

@test "gate allow: prod_verified but no EVIDENCE line -> fail open" {
  run qa_artifact_gate "QA_STATUS: prod_verified, it all looked fine" "$FIELD"
  [ "$output" = "allow" ]
}

@test "gate allow: no Production artifact field -> behaves as before (backward compat)" {
  run qa_artifact_gate "QA_STATUS: prod_verified EVIDENCE: ran docker run $BASE" ""
  [ "$output" = "allow" ]
}

@test "gate allow: prod_verified mentioned only inside a fenced code block does not engage" {
  msg=$(printf 'Here is the contract:\n```\nQA_STATUS: prod_verified EVIDENCE: ran docker run %s\n```\nStill verifying.' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "allow" ]
}

# ---- qa_artifact_engages (which messages make a Production-QA claim) --------

@test "engages yes: prod_verified posture" {
  run qa_artifact_engages "Deployed. QA_STATUS: prod_verified EVIDENCE: x"
  [ "$output" = "yes" ]
}

@test "engages yes: awaiting_human with PHASE: prod" {
  run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\nPHASE: prod')"
  [ "$output" = "yes" ]
}

@test "engages yes: awaiting_human with PHASE: production (broad on purpose)" {
  run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\nPHASE: production QA, row 2')"
  [ "$output" = "yes" ]
}

@test "engages no: awaiting_human with PHASE: dev (preview artifact by design)" {
  run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\nPHASE: dev')"
  [ "$output" = "no" ]
}

@test "engages yes: the hook message's 'PHASE: dev|prod' menu on a PHASE line is ambiguous (fail closed)" {
  run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\nPHASE: dev|prod')"
  [ "$output" = "yes" ]
}

@test "engages yes: awaiting_human with PHASE omitted (fail closed)" {
  run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\nCHECK: run the live agent')"
  [ "$output" = "yes" ]
}

@test "engages yes: awaiting_human with unusual PHASE formats (fail closed)" {
  for phase in 'PHASE=prod' 'PHASE prod' '**PHASE**: prod' 'PHASE: post-deploy' 'PHASE: 2 (prod)'; do
    run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\n%s' "$phase")"
    [ "$output" = "yes" ] || { echo "did not engage on: $phase"; return 1; }
  done
}

@test "engages no: PHASE: dev, later prose mentions PHASE: prod mid-sentence" {
  run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\nPHASE: dev\nAfter merge we move to PHASE: prod.')"
  [ "$output" = "no" ]
}

@test "engages yes: one PHASE line prod, another says dev (not every line is dev)" {
  run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\nPHASE: prod\nPHASE: dev was last week')"
  [ "$output" = "yes" ]
}

@test "engages yes: a dev recap bullet before the real PHASE: prod (red-team shape)" {
  run qa_artifact_engages "$(printf -- '- Phase: dev QA passed on the preview build\nQA_STATUS: awaiting_human\nPHASE: prod')"
  [ "$output" = "yes" ]
}

@test "engages yes: an earlier dev_verified block, then an awaiting_human PHASE: prod (red-team shape)" {
  run qa_artifact_engages "$(printf 'QA_STATUS: dev_verified\nPHASE: dev (done)\nQA_STATUS: awaiting_human\nPHASE: prod')"
  [ "$output" = "yes" ]
}

@test "engages no: bold or equals-sign dev PHASE still reads as dev" {
  run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\n- **PHASE:** dev')"
  [ "$output" = "no" ]
  run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\nPHASE=dev')"
  [ "$output" = "no" ]
}

@test "engages yes: a prod PHASE line that mentions dev later (red-team shape)" {
  for line in 'PHASE: prod (was PHASE: dev)' 'PHASE: prod, not PHASE: dev' 'PHASE: post-deploy; earlier phase=dev'; do
    run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\n%s' "$line")"
    [ "$output" = "yes" ] || { echo "did not engage on: $line"; return 1; }
  done
}

@test "engages yes: mixed or prefix-only dev values (red-team shape)" {
  for line in 'PHASE: dev and prod' 'PHASE: dev, then prod' 'PHASE: dev-ready-for-prod' 'PHASE: devops'; do
    run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\n%s' "$line")"
    [ "$output" = "yes" ] || { echo "did not engage on: $line"; return 1; }
  done
}

@test "engages yes: a prod PHASE line behind a markdown prefix next to a dev one (red-team shape)" {
  for line in '1. PHASE: prod' '> PHASE: prod' '## PHASE: prod' '+ PHASE: prod' '`PHASE: prod`' 'a) PHASE: prod'; do
    run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\nPHASE: dev\n%s' "$line")"
    [ "$output" = "yes" ] || { echo "did not engage on: $line"; return 1; }
  done
}

@test "engages no: a plainly dev PHASE in any markdown shape (no false block)" {
  for line in 'PHASE: development' '`PHASE: dev`' '1. PHASE: dev' '> PHASE: dev' 'PHASE: DEV' 'PHASE: dev (preview)'; do
    run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\n%s' "$line")"
    [ "$output" = "no" ] || { echo "engaged on a dev handoff: $line"; return 1; }
  done
}

@test "engages no: a dev PHASE whose words merely contain 'prod' (no false block)" {
  for line in 'PHASE: dev (needs the product owner to eyeball the copy)' 'PHASE: dev (cannot reproduce headlessly; needs a real phone)'; do
    run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\n%s' "$line")"
    [ "$output" = "no" ] || { echo "engaged on a dev handoff: $line"; return 1; }
  done
}

@test "engages yes: prod as a word inside a dev PHASE line still counts" {
  for line in 'PHASE: dev, then pre-prod' 'PHASE: dev/prod' 'PHASE: dev, production next'; do
    run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\n%s' "$line")"
    [ "$output" = "yes" ] || { echo "did not engage on: $line"; return 1; }
  done
}

@test "engages no: dev_verified with PHASE: prod (only awaiting_human is widened)" {
  run qa_artifact_engages "$(printf 'QA_STATUS: dev_verified\nPHASE: prod')"
  [ "$output" = "no" ]
}

@test "engages no: dev_verified" {
  run qa_artifact_engages "QA_STATUS: dev_verified EVIDENCE: preview"
  [ "$output" = "no" ]
}

# ---- awaiting_human next to the artifact check (fail closed) ----------------
# An awaiting_human PHASE: prod handoff makes a Production-QA evidence claim
# (the agent-runnable Prod rows it closed), so its EVIDENCE is checked like
# prod_verified. PHASE: dev is out of scope, and a missing Production
# artifacts field still fails open. A per-line "which posture is stated"
# carve-out was tried and lost three red-team rounds to markdown and HTML
# shapes, each failing OPEN, so the check is never narrowed by formatting.

@test "awaiting gate block: PHASE: prod handoff with base-only EVIDENCE (evidence laundering)" {
  msg=$(printf 'QA_STATUS: awaiting_human\nDRIVER: mujtaba\nCHECK: run the live agent\nPHASE: prod\nEVIDENCE: smoke-tested %s\nI will mark it verified once you confirm.' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}

@test "awaiting gate allow: PHASE: prod handoff whose EVIDENCE names the exact production ref" {
  msg=$(printf 'QA_STATUS: awaiting_human\nCHECK: run the live agent\nPHASE: prod\nEVIDENCE: live run on %s' "$PERAGENT")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "allow" ]
}

@test "awaiting gate block: a fenced PHASE: dev example above the real PHASE: prod handoff" {
  msg=$(printf 'Template:\n```\nPHASE: dev\n```\nQA_STATUS: awaiting_human\nPHASE: prod\nEVIDENCE: smoke-tested %s' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}

@test "awaiting gate block: the only PHASE line is inside a fence (counts as missing: fail closed)" {
  msg=$(printf 'QA_STATUS: awaiting_human\n```\nPHASE: dev\n```\nEVIDENCE: smoke-tested %s' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}

@test "awaiting gate allow: PHASE: dev handoff is out of scope (preview artifact)" {
  msg=$(printf 'QA_STATUS: awaiting_human\nCHECK: open the local build\nPHASE: dev\nEVIDENCE: docker run %s in preview' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "allow" ]
}

@test "awaiting gate allow: PHASE: prod handoff with no Production artifacts field fails open" {
  msg=$(printf 'QA_STATUS: awaiting_human\nPHASE: prod\nEVIDENCE: docker run %s' "$BASE")
  run qa_artifact_gate "$msg" ""
  [ "$output" = "allow" ]
}

@test "awaiting gate block: the literal token in prose still engages the check" {
  msg=$(printf 'QA_STATUS: awaiting_human\nEVIDENCE: smoke-tested %s\nI will record QA_STATUS: prod_verified once you confirm.' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}

@test "awaiting gate block: task-box prod_verified line (red-team shape)" {
  msg=$(printf 'QA_STATUS: awaiting_human\n- [x] QA_STATUS: prod_verified\nEVIDENCE: docker run %s' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}

@test "awaiting gate block: HTML tag before the token (red-team shape)" {
  msg=$(printf 'QA_STATUS: awaiting_human\n<strong>QA_STATUS: prod_verified</strong>\nEVIDENCE: docker run %s' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}

@test "awaiting gate block: HTML entity before the token (red-team shape)" {
  msg=$(printf 'QA_STATUS: awaiting_human\n&nbsp;QA_STATUS: prod_verified\nEVIDENCE: docker run %s' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}

@test "awaiting gate block: indented or mismatched tilde fences do not hide the claim" {
  msg=$(printf 'QA_STATUS: awaiting_human\n    ~~~\nQA_STATUS: prod_verified\nEVIDENCE: docker run %s' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
  msg=$(printf 'QA_STATUS: awaiting_human\n~~~~\n~~~\n~~~~\nQA_STATUS: prod_verified\nEVIDENCE: docker run %s' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}

@test "awaiting gate block: both postures stated, base-only evidence" {
  msg=$(printf 'QA_STATUS: awaiting_human\nQA_STATUS: prod_verified\nEVIDENCE: ran docker run %s' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}

@test "gate block: real prod_verified outside a fence still blocks despite a fenced example" {
  msg=$(printf 'Example:\n```\nsome code\n```\nDeployed. QA_STATUS: prod_verified EVIDENCE: docker run %s only' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}
