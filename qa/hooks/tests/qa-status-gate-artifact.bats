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

@test "extract prod artifact: a bare label with bulleted artifacts underneath captures the bullets" {
  body=$(printf '### Production\n\n**Production artifacts:**\n- per-agent image `%s` on mac-mini\n- exercised by a live agent run\n\n**Definition of Done:**\n- [ ] Tests' "$PERAGENT")
  run qa_extract_prod_artifact "$body"
  case "$output" in *"$PERAGENT"*) ;; *) echo "got: $output"; false ;; esac
  case "$output" in *"Definition of Done"*|*"Tests"*) echo "overran: $output"; false ;; *) ;; esac
}

@test "extract prod artifact: the field ends at a blank line even before plain prose" {
  body=$(printf '**Production artifacts:**\n- `%s` on mac-mini\n\nNotes: the old ghcr.io/x/other:v9 is retired.' "$PERAGENT")
  run qa_extract_prod_artifact "$body"
  case "$output" in *"other:v9"*) echo "overran: $output"; false ;; *) ;; esac
  case "$output" in *"$PERAGENT"*) ;; *) echo "got: $output"; false ;; esac
}

@test "extract prod artifact: real template shapes keep their bullets" {
  for fmt in \
    '**Production artifacts:**\n- **Image:** `%s` on mac-mini\n- **Exercised by:** a live agent run' \
    '**Production artifacts:**\n\n- `%s` on mac-mini' \
    '**Production artifacts:** the exact things production runs, per Prod row.\n\n- `%s` on mac-mini' \
    '**Production artifacts:**\n- host: mac-mini\n\n- `%s` (loose list)' \
    '**Production artifacts:**\n  **Image:** `%s`\n  **Host:** mini' \
    '**Production artifacts:**\nThe per-agent image `%s` on mac-mini'; do
    body=$(printf "$fmt" "$PERAGENT")
    run qa_extract_prod_artifact "$body"
    case "$output" in *"$PERAGENT"*) ;; *) echo "lost in: $fmt -> $output"; false ;; esac
  done
}

@test "extract prod artifact: the field ends at a heading, a table or a top-level bold label with no blank line" {
  for stop in '**Definition of Done:**' '### Next' '| a | b |'; do
    body=$(printf '**Production artifacts:**\n- `%s`\n%s\n- ghcr.io/x/other:v9' "$PERAGENT" "$stop")
    run qa_extract_prod_artifact "$body"
    case "$output" in *"other:v9"*) echo "overran past: $stop"; false ;; *) ;; esac
    case "$output" in *"$PERAGENT"*) ;; *) echo "got: $output"; false ;; esac
  done
}

@test "bulleted field after a blank line: a base-only awaiting_human handoff still blocks" {
  field=$(qa_extract_prod_artifact "$(printf '**Production artifacts:** per Prod row.\n\n- `ghcr.io/acme/agent-alpha:7f3c2a1` on the mini')")
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran ghcr.io/acme/agent-base:latest')" "$field"
  [ "$output" = "block-uncited" ]
}

@test "bulleted field: a base-only awaiting_human handoff and a base-family prod_verified both block" {
  body=$(printf '**Production artifacts:**\n- per-agent image `%s` on mac-mini' "$PERAGENT")
  field=$(qa_extract_prod_artifact "$body")
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran nanoclaw-agent-base:latest')" "$field"
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: prod_verified\nEVIDENCE: docker run %s' "$BASE")" "$field"
  [ "$output" = "block" ]
}

@test "awaiting missing refs: lists only the uncited digests" {
  run qa_awaiting_missing_refs "EVIDENCE: pulled sha256:1111aaaa2222bbbb3333" "img digest sha256:1111aaaa2222bbbb3333 and sha256:9999eeee8888dddd7777"
  [ "$output" = "sha256:9999eeee8888dddd7777" ]
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

@test "engages yes: PHASE: dev, but prose later pairs PHASE with prod (fail closed)" {
  run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\nPHASE: dev\nAfter merge we move to PHASE: prod.')"
  [ "$output" = "yes" ]
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

@test "engages yes: the posture, DRIVER and PHASE: prod on one line, plus a dev recap bullet (adversarial shape)" {
  run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human DRIVER: mujtaba PHASE: prod\n- PHASE: dev QA passed on the preview earlier')"
  [ "$output" = "yes" ]
}

@test "engages yes: prod in tables, dash separators, backticked keys or after e.g. (adversarial shapes)" {
  for extra in '| PHASE | prod |' 'PHASE - prod' '`PHASE`: prod' 'DRIVER: x | CHECK: y | PHASE: prod' 'e.g. the PHASE: prod check remains'; do
    run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\nPHASE: dev\n%s' "$extra")"
    [ "$output" = "yes" ] || { echo "did not engage on: $extra"; return 1; }
  done
}

@test "engages yes: preprod spelled as one word counts as prod" {
  run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\nPHASE: dev (preprod)')"
  [ "$output" = "yes" ]
}

@test "engages yes: a bold or backticked awaiting_human posture engages too" {
  for posture in 'QA_STATUS: **awaiting_human**' 'QA_STATUS: `awaiting_human`'; do
    run qa_artifact_engages "$(printf '%s\nPHASE: prod' "$posture")"
    [ "$output" = "yes" ] || { echo "did not engage on: $posture"; return 1; }
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

# ---- qa_artifact_engage_reason (what the block message names) --------------

@test "engage reason: names a prod_verified posture" {
  run qa_artifact_engage_reason "Deployed. QA_STATUS: prod_verified EVIDENCE: x"
  [ "$output" = "QA_STATUS: prod_verified" ]
}

@test "engage reason: names the span that pairs PHASE with prod" {
  run qa_artifact_engage_reason "$(printf 'QA_STATUS: awaiting_human\nPHASE: dev (Production QA runs after land)')"
  [ "$output" = "PHASE: dev (Production " ]
}

@test "engage reason: names a Phase table header token (a fail-closed false engage)" {
  run qa_artifact_engage_reason "$(printf 'QA_STATUS: awaiting_human\nPHASE: dev\n| Phase | Check | Result |\n|---|---|---|\n| Dev | x | ok |')"
  [ "$output" = "Phase | Check" ]
}

@test "engage reason: a missing PHASE gets a neutral note, not an instruction" {
  run qa_artifact_engage_reason "$(printf 'QA_STATUS: awaiting_human\nCHECK: x')"
  [ "$output" = "awaiting_human with no PHASE stated (treated as prod)" ]
}

@test "engage reason: a long line keeps the PHASE-to-prod span, capped at 80" {
  pad=$(printf 'x%.0s' $(seq 1 90))
  run qa_artifact_engage_reason "$(printf 'QA_STATUS: awaiting_human\n| %s | PHASE: prod | ok |' "$pad")"
  [ "${#output}" -le 80 ]
  case "$output" in "PHASE: prod"*) ;; *) echo "got: $output"; false ;; esac
}

@test "engage reason: PHASE and prod far apart fall back to the line, still capped at 80" {
  pad=$(printf 'x%.0s' $(seq 1 90))
  run qa_artifact_engage_reason "$(printf 'QA_STATUS: awaiting_human\nPHASE: dev, notes %s then prod' "$pad")"
  [ "${#output}" -le 80 ]
  case "$output" in "PHASE: dev, notes x"*) ;; *) echo "got: $output"; false ;; esac
}

@test "engage reason agrees with engages: every engaged awaiting_human message names a cause" {
  for m in 'PHASE: post-deploy' 'PHASE=staging' 'PHASE: dev and prod' '| Phase | Check |' 'PHASE: dev, then PHASE: prod'; do
    msg=$(printf 'QA_STATUS: awaiting_human\n%s' "$m")
    [ "$(qa_artifact_engages "$msg")" = "yes" ]
    why=$(qa_artifact_engage_reason "$msg")
    [ -n "$why" ]
    [ "$why" != "awaiting_human with no PHASE stated (treated as prod)" ]
    case "$why" in *[Pp][Hh][Aa][Ss][Ee]*) ;; *) echo "no cause for: $m -> $why"; false ;; esac
  done
}

@test "engages yes: awaiting-human and awaiting human (reworded posture) with PHASE: prod" {
  run qa_artifact_engages "$(printf 'QA_STATUS: awaiting-human\nPHASE: prod')"
  [ "$output" = "yes" ]
  run qa_artifact_engages "$(printf 'QA_STATUS: awaiting human\nPHASE: prod')"
  [ "$output" = "yes" ]
}

@test "engages yes: an unspaced PHASE-dev is not read as dev (fail closed)" {
  run qa_artifact_engages "$(printf 'QA_STATUS: awaiting_human\nPHASE-dev')"
  [ "$output" = "yes" ]
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

@test "awaiting gate block-uncited: PHASE: prod handoff with NO EVIDENCE line when the plan names an artifact" {
  msg=$(printf 'QA_STATUS: awaiting_human\nDRIVER: mujtaba\nCHECK: run /mu:pause from the desktop app\nPHASE: prod')
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block-uncited" ]
}

@test "awaiting gate block-uncited: no PHASE and no EVIDENCE (template shape, fail closed)" {
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nDRIVER: mujtaba\nCHECK: x')" "$FIELD"
  [ "$output" = "block-uncited" ]
}

@test "awaiting gate block-uncited: a placeholder EVIDENCE line does not cite the artifact" {
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: n/a, only the human row remains')" "$FIELD"
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE:')" "$FIELD"
  [ "$output" = "block-uncited" ]
}

@test "awaiting gate block-uncited: prose containing evidence: does not cite the artifact" {
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nThere is no new evidence: the human check is pending.')" "$FIELD"
  [ "$output" = "block-uncited" ]
}

@test "awaiting gate allow: a bold or dashed label that cites the exact ref" {
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\n**EVIDENCE**: ran %s' "$PERAGENT")" "$FIELD"
  [ "$output" = "allow" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\n- Evidence - ran %s' "$PERAGENT")" "$FIELD"
  [ "$output" = "allow" ]
}

@test "awaiting gate block-uncited: the only citation is inside a code fence" {
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\n```\nEVIDENCE: ran %s\n```' "$PERAGENT")" "$FIELD"
  [ "$output" = "block-uncited" ]
}

@test "awaiting gate allow: a host:port or clock time in the field is not a citation requirement" {
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: Heroku release v87 of sms-hero, health 200')" "Heroku release v87 of app sms-hero (slug abc1234), served at sms-hero.example.com:443 since 14:05"
  [ "$output" = "allow" ]
}

@test "awaiting gate allow: a sentence-ending period on the field's ref does not turn a citation into a mismatch" {
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran ghcr.io/mutwo/emily-agent:v1.4.2 on mini')" "**Production artifacts:** ghcr.io/mutwo/emily-agent:v1.4.2."
  [ "$output" = "allow" ]
}

@test "awaiting gate: a digest-only plan still requires the citation" {
  d="Production artifact: sha256:0123456789abcdef0123 on the mini"
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: n/a')" "$d"
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: pulled sha256:0123456789abcdef0123')" "$d"
  [ "$output" = "allow" ]
}

@test "citable refs truth table: image refs and image-or-host tokens in, times and plain hosts out" {
  run qa_citable_refs 'emily-agent:v2 ghcr.io/org/app:v1 api:4718203 ghcr.io/acme/x:1234 mutwo:2026.10.13 agent-web:1234 mac-mini:8080 app:latest mu:pause agent:42 mini:22'
  [ "$output" = "$(printf 'emily-agent:v2\nghcr.io/org/app:v1\napi:4718203\nghcr.io/acme/x:1234\nmutwo:2026.10.13\nagent-web:1234\nmac-mini:8080\napp:latest\nmu:pause\nagent:42\nmini:22')" ]
  run qa_citable_refs 'sms-hero.example.com:443 localhost:8080 14:05 2026-10-13T14:05Z 14:05pm'
  [ -z "$output" ]
}

@test "awaiting gate block-uncited: a weak host:port beside a real image never satisfies the citation" {
  f="ghcr.io/acme/agent-web:v42, health via mac-mini:8080"
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: Health on mac-mini:8080 is green')" "$f"
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: Deployed 2026-10-13T14:05Z, please check')" "ghcr.io/acme/agent-web:v42 (deployed 2026-10-13T14:05Z)"
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran ghcr.io/acme/agent-web:v42')" "ghcr.io/acme/agent-web:v42, health via mac-mini:8080"
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran ghcr.io/acme/agent-web:v42, health via mac-mini:8080')" "ghcr.io/acme/agent-web:v42, health via mac-mini:8080"
  [ "$output" = "allow" ]
}

# Value: protects=a short bare image name with a numeric tag must be cited;
#   fails_when=qa_citable_refs drops short names again (a base-only handoff then passes); why_new=red team, cycle 14; seam=none
@test "awaiting gate block-uncited: a short bare image name with a number tag still needs citing, inline or bulleted" {
  for f in "**Production artifacts:** agent:42 on the mac mini" "$(printf '**Production artifacts:**\n- web:7 (per-agent image) on the mac mini')"; do
    run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran base:42 and base:7 via docker run')" "$(qa_extract_prod_artifact "$f")"
    [ "$output" = "block-uncited" ]
  done
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran agent:42 on the mac mini')" "$(qa_extract_prod_artifact "**Production artifacts:** agent:42 on the mac mini")"
  [ "$output" = "allow" ]
}

@test "awaiting gate block: citing a different build that extends the planned tag is a mismatch" {
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran agent-web:12345')" "Production artifact: agent-web:1234 on the mini"
  [ "$output" = "block" ]
}

@test "awaiting gate: a short-named image with a long build tag still needs citing; a full digest cites a short one" {
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: n/a')" "Production artifact: api:4718203"
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: pulled sha256:0123456789abcdef0123456789abcdef')" "Production artifact: sha256:0123456789abcdef0123"
  [ "$output" = "allow" ]
}

@test "awaiting gate block-uncited: numeric-tag and slash-less image refs still need the citation" {
  for f in "ghcr.io/acme/agent-web:4718203" "agent-web:1234" "mutwo:2026.10.13" "agentmu:v3.1.0"; do
    run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: n/a')" "Production artifact: $f on the mini"
    [ "$output" = "block-uncited" ]
    run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran %s' "$f")" "Production artifact: $f on the mini"
    [ "$output" = "allow" ]
  done
}

@test "awaiting gate block-uncited: naming only the field's host:port or time is not a citation" {
  f="ghcr.io/acme/agent-web:v1.2.3 on host mini:22, health at localhost:8080, rolled out 14:05"
  for e in 'Health on mini:22 fine' 'Deployed at 14:05' 'localhost:8080 returns 200'; do
    run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: %s' "$e")" "$f"
    [ "$output" = "block-uncited" ]
  done
}

@test "awaiting gate: a field naming the derived image AND its base cannot be satisfied by the base alone" {
  f="per-agent image nanoclaw-agent-v2-83c915c8:ag-1-main on the mac mini (rebuilt FROM the shared base nanoclaw-base:2026.10.13)"
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: docker run nanoclaw-base:2026.10.13 smoke passed')" "$f"
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran nanoclaw-agent-v2-83c915c8:base')" "nanoclaw-agent-v2-83c915c8:ag-1-main (FROM nanoclaw-agent-v2-83c915c8:base)"
  [ "$output" = "block" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran nanoclaw-agent-v2-83c915c8:ag-1-main and nanoclaw-base:2026.10.13')" "$f"
  [ "$output" = "allow" ]
}

@test "prod_verified: a sentence-ending period on the field's ref no longer turns an exact citation into a mismatch" {
  run qa_artifact_gate "$(printf 'QA_STATUS: prod_verified\nEVIDENCE: ran ghcr.io/mutwo/emily-agent:v1.4.2 on mini')" "**Production artifacts:** ghcr.io/mutwo/emily-agent:v1.4.2."
  [ "$output" = "allow" ]
}

@test "awaiting gate: an image plus its digest; the digest alone, the image alone, or both satisfy it" {
  f="ghcr.io/acme/app:v1 digest sha256:0123456789abcdef0123"
  for e in 'pulled sha256:0123456789abcdef0123' 'ran ghcr.io/acme/app:v1' 'ran ghcr.io/acme/app:v1 sha256:0123456789abcdef0123'; do
    run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: %s' "$e")" "$f"
    [ "$output" = "allow" ]
  done
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: n/a')" "$f"
  [ "$output" = "block-uncited" ]
}

@test "awaiting gate block: a weak host:port cannot stand in for a weak image beside it (base-only handoff)" {
  f='`agent-web:4412` on mac-mini:8080, exercised by curl'
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: smoke against agent-web-base:4400 on mac-mini:8080 passed')" "$f"
  [ "$output" = "block" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: curl via mac-mini:8080 against agent-web:4412 ok')" "$f"
  [ "$output" = "allow" ]
}

@test "awaiting gate: a base digest listed beside the image digest cannot stand in for it" {
  f="ghcr.io/acme/agent-web:2026.10.13 (sha256:1111aaaa2222bbbb3333) built from ghcr.io/acme/agent-base:3.2 (sha256:9999eeee8888dddd7777)"
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: agent rows green against sha256:9999eeee8888dddd7777')" "$f"
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: green against ghcr.io/acme/agent-web:2026.10.13 and ghcr.io/acme/agent-base:3.2')" "$f"
  [ "$output" = "allow" ]
}

@test "awaiting gate block-uncited: a skill name in the field cannot push a weak-tagged image out of the required set" {
  f=$(printf -- '- `agent-web:417` on host `mutwos-mac-mini`\n- Exercised by invoking `/mu:pause` from the desktop app')
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: run /mu:pause from the desktop app\nPHASE: prod\nEVIDENCE: docker run agent-base:417 smoke passed')" "$f"
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: run /mu:pause from the desktop app\nPHASE: prod\nEVIDENCE: ran agent-web:417 on the mini')" "$f"
  [ "$output" = "allow" ]
}

@test "awaiting gate: two images, one pinned by digest and one by ref, are each checked on their own line" {
  d=sha256:aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000
  f=$(printf -- '- agent-a digest: `%s` on mac-mini\n- agent-b: `ghcr.io/acme/agent-b:v1.4.2` on mac-mini' "$d")
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: agent-b ghcr.io/acme/agent-b:v1.4.2 ; agent-a checked on ghcr.io/acme/agent-base:v1.4.2')" "$f"
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: %s ; agent-b checked on ghcr.io/acme/agent-base:v1.4.2' "$d")" "$f"
  [ "$output" = "block" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: %s and ghcr.io/acme/agent-b:v1.4.2' "$d")" "$f"
  [ "$output" = "allow" ]
}

@test "awaiting gate: one line naming two images and one digest cannot be satisfied by that digest" {
  m=$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran sha256:aaaaaaaaaaaa1111 (agent-api) and in ghcr.io/acme/agent-worker-base:v1.4.2')
  run qa_artifact_gate "$m" '**Production artifacts:** `ghcr.io/acme/agent-api:v1.4.2@sha256:aaaaaaaaaaaa1111` and `ghcr.io/acme/agent-worker:v1.4.2`'
  [ "$output" = "block" ]
  run qa_artifact_gate "$m" '- `agent-api:v1.4.2` (`sha256:aaaaaaaaaaaa1111`) and `agent-worker:v1.4.2`'
  [ "$output" = "block" ]
}

@test "awaiting gate: a strong-image line cannot hide a weak-tagged image on another line" {
  f=$(printf -- '- agent-a: `ghcr.io/acme/agent-a:v1.4.2`\n- agent-b: `agent-web:4412`')
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran ghcr.io/acme/agent-a:v1.4.2 ; agent-b on agent-web-base:4400')" "$f"
  [ "$output" = "block" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran ghcr.io/acme/agent-a:v1.4.2 and agent-web:4412')" "$f"
  [ "$output" = "allow" ]
}

@test "awaiting gate allow: a host-only field is not checked, even when EVIDENCE names the host" {
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: curl sms-hero.example.com/health 200')" "Production artifacts: sms-hero.example.com:443 (the live site)"
  [ "$output" = "allow" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: prod_verified\nEVIDENCE: curl sms-hero.example.com/health 200')" "Production artifacts: sms-hero.example.com:443 (the live site)"
  [ "$output" = "block" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nQA_STATUS: prod_verified\nEVIDENCE: curl sms-hero.example.com/health 200')" "Production artifacts: sms-hero.example.com:443 (the live site)"
  [ "$output" = "block" ]
}

@test "awaiting gate: a letter-tagged image beside a strong-tagged one on the same line still needs citing" {
  f='**Production artifacts:** `nanoclaw-agent-ag1:main` and `nanoclaw-agent-ag2:ag-2-main` on mac-mini'
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: nanoclaw-agent-ag2:ag-2-main green; nanoclaw-base:main green')" "$f"
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: nanoclaw-agent-ag2:ag-2-main and nanoclaw-agent-ag1:main green')" "$f"
  [ "$output" = "allow" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran agent-base:latest via deploy/build.sh:44')" '- Image: `agent-web:latest` on mac-mini (rebuilt by deploy/build.sh:44)'
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: run /mu:pause from the desktop app\nPHASE: prod\nEVIDENCE: ran ghcr.io/acme/agent-web:v42')" '- `ghcr.io/acme/agent-web:v42` exercised by /mu:pause'
  [ "$output" = "allow" ]
}

@test "awaiting gate block-uncited: a strong ref on the line never lowers the bar for a second image" {
  m=$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: nanoclaw-orch:v2.1.55 healthy; ran nanoclaw-agent-base:1532 in docker run')
  run qa_artifact_gate "$m" '**Production artifacts:** the orchestrator `nanoclaw-orch:v2.1.55` and the per-agent image `nanoclaw-agent-mutwo:1532` on mutwos-mac-mini'
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ghcr.io/mujtaba3b/orch:v2.1.55 ok; nanoclaw-base:latest ok')" '- `ghcr.io/mujtaba3b/orch:v2.1.55` and `nanoclaw:latest`'
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: pulled sha256:0123456789ab')" '- `nanoclaw-agent-ag1:v1.4.2` @ sha256:0123456789ab plus `nanoclaw-agent-ag2:1532`'
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: nanoclaw-orch:v2.1.55 and nanoclaw-agent-mutwo:1532 healthy')" '**Production artifacts:** the orchestrator `nanoclaw-orch:v2.1.55` and the per-agent image `nanoclaw-agent-mutwo:1532` on mutwos-mac-mini'
  [ "$output" = "allow" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ghcr.io/mujtaba3b/orch:v2.1.55 and nanoclaw:latest ok')" '- `ghcr.io/mujtaba3b/orch:v2.1.55` and `nanoclaw:latest`'
  [ "$output" = "allow" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran nanoclaw-agent-ag1:v1.4.2 and nanoclaw-agent-ag2:1532')" '- `nanoclaw-agent-ag1:v1.4.2` @ sha256:0123456789ab plus `nanoclaw-agent-ag2:1532`'
  [ "$output" = "allow" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: pulled sha256:0123456789ab and ran nanoclaw-agent-ag2:1532')" '- `nanoclaw-agent-ag1:v1.4.2` @ sha256:0123456789ab plus `nanoclaw-agent-ag2:1532`'
  [ "$output" = "block-uncited" ]
}

@test "awaiting gate: a one-character image tag still needs citing" {
  for f in '**Production artifacts:** ghcr.io/org/agent-web:7 on the mini' '**Production artifacts:** org/app:1 on the mini'; do
    run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran ghcr.io/org/agent-base:7')" "$f"
    [ "$output" = "block-uncited" ]
  done
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran ghcr.io/org/agent-web:7')" '**Production artifacts:** ghcr.io/org/agent-web:7 on the mini'
  [ "$output" = "allow" ]
}

# The loose numbered row is the one that needs the numbered-item rule: a first
# item after a gap is read as the first paragraph anyway, a later one is not.
@test "extract prod artifact: a numbered list or a first paragraph after a blank line stays in the field" {
  for fmt in '**Production artifacts:**\n\n1. `%s` on mac-mini\n2. exercised by a live run' '**Production artifacts:**\n\nThe per-agent image `%s` on mac-mini.' '**Production artifacts:**\n1. host is the mini\n\n2. `%s` (loose numbered list)'; do
    body=$(printf "$fmt" "$PERAGENT")
    run qa_extract_prod_artifact "$body"
    case "$output" in *"$PERAGENT"*) ;; *) echo "lost in: $fmt -> $output"; false ;; esac
  done
}

# Value: protects=only the FIRST paragraph after a gap joins the field, a second one ends it;
#   fails_when=the plain-line branch stops setting got, so later prose is captured;
#   why_new=the blank-line stop rows all capture a bullet first; seam=none; no_claim=none beyond protects
@test "extract prod artifact: a second paragraph after another blank line ends the field" {
  body=$(printf '**Production artifacts:**\n\nThe per-agent image `%s` on mac-mini.\n\nNotes: the old ghcr.io/x/other:v9 is retired.' "$PERAGENT")
  run qa_extract_prod_artifact "$body"
  case "$output" in *"$PERAGENT"*) ;; *) echo "got: $output"; false ;; esac
  case "$output" in *"other:v9"*) echo "overran: $output"; false ;; *) ;; esac
}

# Value: protects=a label line that already names an artifact ends the field at a blank line before prose;
#   fails_when=the first-paragraph-after-gap rule ignores what the label line captured (it does at 7c593f9);
#   why_new=only bullet-first fields pin the blank-line stop; seam=none; no_claim=PR bodies with this shape exist (unit, literal body)
# Regression (7c593f9): before it, this shape yielded only the label line and a
# handoff citing the one planned image was allowed; now the trailing note's ref
# is required too, so a correct awaiting_human handoff is blocked.
@test "extract prod artifact: an inline artifact on the label line still ends the field at a blank line before prose" {
  body=$(printf '**Production artifacts:** `ghcr.io/acme/agent-alpha:7f3c2a1` on the mini\n\nNotes: the old ghcr.io/x/other:v9 is retired.')
  run qa_extract_prod_artifact "$body"
  case "$output" in *"other:v9"*) echo "overran: $output"; false ;; *) ;; esac
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran ghcr.io/acme/agent-alpha:7f3c2a1')" "$(qa_extract_prod_artifact "$body")"
  [ "$output" = "allow" ]
}

# Value: protects=a label line naming only a time or other uncitable token still reads the next paragraph;
#   fails_when=the label-line capture test drifts from qa_citable_refs (a loose name:tag shape counted 14:05); why_new=maintainability, cycle 14; seam=none
@test "extract prod artifact: a label line naming only a time still reads the paragraph after a blank line" {
  body=$(printf 'Production artifacts: deployed at 14:05 UTC\n\nghcr.io/acme/agent-web:v2 on the mini')
  run qa_extract_prod_artifact "$body"
  case "$output" in *"agent-web:v2"*) ;; *) echo "dropped: $output"; false ;; esac
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran ghcr.io/acme/agent-base:v2')" "$(qa_extract_prod_artifact "$body")"
  [ "$output" = "block-uncited" ]
}

# Value: protects=a label line naming only a sha256 digest ends the field at a blank line before prose,
#   and a second field is judged on its own label line; fails_when=the digest half of the label-line
#   capture is dropped, or the flag is taken from the first label only; why_new=specialists, cycle 14 pass 2; seam=none
@test "extract prod artifact: a digest-only label line ends the field, and each label line is judged on its own" {
  body=$(printf '**Production artifacts:** sha256:0123456789abcdef0123 on the mini\n\nNotes: the old ghcr.io/x/other:v9 is retired.')
  run qa_extract_prod_artifact "$body"
  case "$output" in *"other:v9"*) echo "overran: $output"; false ;; *) ;; esac
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: pulled sha256:0123456789abcdef0123')" "$(qa_extract_prod_artifact "$body")"
  [ "$output" = "allow" ]
  body=$(printf -- '- Production artifact: agent-x:v2 (summary)\n\n**Production artifacts:**\n\nghcr.io/acme/agent-y:v3 on the mini')
  run qa_extract_prod_artifact "$body"
  case "$output" in *"agent-y:v3"*) ;; *) echo "dropped: $output"; false ;; esac
}

# Value: protects=label-line capture flags are read at each label's own index, in either order;
#   fails_when=the flag is read from the last (or a fixed) label; why_new=testing + coverage, cycle 14 pass 3; seam=none
@test "extract prod artifact: label lines judged on their own in the reverse order too" {
  body=$(printf '**Production artifacts:** deployed 14:05\n\nghcr.io/acme/a:v1 here\n\n- Production artifact: ghcr.io/acme/b:v2\n\nNotes: ghcr.io/x/other:v9 retired')
  run qa_extract_prod_artifact "$body"
  case "$output" in *"acme/a:v1"*) ;; *) echo "dropped: $output"; false ;; esac
  case "$output" in *"other:v9"*) echo "overran: $output"; false ;; *) ;; esac
}

# Value: protects=a bare host named beside its uncited host:port gets the missing-citation verdict, not the stale-image one;
#   fails_when=any bare mention of a numeric-tagged family counts as a base substitution; why_new=red team, cycle 14 pass 3; seam=none
@test "awaiting gate block-uncited: the bare host beside an uncited host:port is a missing citation, not a stale image" {
  f='- ghcr.io/acme/agent-web:v1.4.2 on mac-mini:8080'
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran ghcr.io/acme/agent-web:v1.4.2, dashboard served from mac-mini')" "$f"
  [ "$output" = "block-uncited" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran ghcr.io/acme/agent-web:v1.4.2 on mac-mini:8080')" "$f"
  [ "$output" = "allow" ]
}

# Value: protects=a path, digest or bare-registry mention of a numeric-tagged family gets the substitution verdict;
#   fails_when=the family/, family@ or image-shaped (slash) arm is dropped; why_new=coverage + testing, run 15; seam=none;
#   no_claim=message wording only, both verdicts block
@test "awaiting gate block: a numeric-tagged family named by path, digest or bare registry ref is a substitution" {
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: checked mac-mini/healthz')" "- svc on mac-mini:8080"
  [ "$output" = "block" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran agent-web@sha256:abc123')" "- agent-web:42 on the mini"
  [ "$output" = "block" ]
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran ghcr.io/acme/app latest build')" "- ghcr.io/acme/app:42 on the mini"
  [ "$output" = "block" ]
}

@test "awaiting missing refs: lists exactly the uncited required refs" {
  run qa_awaiting_missing_refs "EVIDENCE: ran nanoclaw-agent-v2-83c915c8:ag-1-main" "nanoclaw-agent-v2-83c915c8:ag-1-main (FROM nanoclaw-base:2026.10.13)"
  [ "$output" = "nanoclaw-base:2026.10.13" ]
  run qa_awaiting_missing_refs "EVIDENCE: ran ghcr.io/acme/app:v1" "ghcr.io/acme/app:v1"
  [ -z "$output" ]
}

@test "awaiting gate allow: the plan names no machine-matchable token (nothing to cite)" {
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod')" "Production artifact: release v1.4 of the desktop app"
  [ "$output" = "allow" ]
}

@test "awaiting gate allow: PHASE: dev handoff with no EVIDENCE line" {
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nDRIVER: mujtaba\nCHECK: x\nPHASE: dev')" "$FIELD"
  [ "$output" = "allow" ]
}

@test "awaiting gate allow: PHASE: prod with no EVIDENCE and no Production artifacts field" {
  run qa_artifact_gate "$(printf 'QA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod')" ""
  [ "$output" = "allow" ]
}

@test "prod_verified with no EVIDENCE line still allows (pre-existing; follow-up gate change)" {
  run qa_artifact_gate "Deployed. QA_STATUS: prod_verified" "$FIELD"
  [ "$output" = "allow" ]
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
  msg=$(printf 'QA_STATUS: awaiting_human\nPHASE: dev\nEVIDENCE: smoke-tested %s\nI will record QA_STATUS: prod_verified once you confirm.' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}

@test "awaiting gate block: task-box prod_verified line (red-team shape)" {
  msg=$(printf 'QA_STATUS: awaiting_human\nPHASE: dev\n- [x] QA_STATUS: prod_verified\nEVIDENCE: docker run %s' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}

@test "awaiting gate block: HTML tag before the token (red-team shape)" {
  msg=$(printf 'QA_STATUS: awaiting_human\nPHASE: dev\n<strong>QA_STATUS: prod_verified</strong>\nEVIDENCE: docker run %s' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}

@test "awaiting gate block: HTML entity before the token (red-team shape)" {
  msg=$(printf 'QA_STATUS: awaiting_human\nPHASE: dev\n&nbsp;QA_STATUS: prod_verified\nEVIDENCE: docker run %s' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}

@test "awaiting gate block: indented or mismatched tilde fences do not hide the claim" {
  msg=$(printf 'QA_STATUS: awaiting_human\nPHASE: dev\n    ~~~\nQA_STATUS: prod_verified\nEVIDENCE: docker run %s' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
  msg=$(printf 'QA_STATUS: awaiting_human\nPHASE: dev\n~~~~\n~~~\n~~~~\nQA_STATUS: prod_verified\nEVIDENCE: docker run %s' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}

@test "awaiting gate block: both postures stated, base-only evidence" {
  msg=$(printf 'QA_STATUS: awaiting_human\nPHASE: dev\nQA_STATUS: prod_verified\nEVIDENCE: ran docker run %s' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}

@test "gate block: real prod_verified outside a fence still blocks despite a fenced example" {
  msg=$(printf 'Example:\n```\nsome code\n```\nDeployed. QA_STATUS: prod_verified EVIDENCE: docker run %s only' "$BASE")
  run qa_artifact_gate "$msg" "$FIELD"
  [ "$output" = "block" ]
}
