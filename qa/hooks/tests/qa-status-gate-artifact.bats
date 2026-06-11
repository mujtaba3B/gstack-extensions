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

@test "gate block: real prod_verified outside a fence still blocks despite a fenced example" {
  msg=$(printf 'Example:\n```\nsome code\n```\nDeployed. QA_STATUS: prod_verified EVIDENCE: docker run %s only' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}
