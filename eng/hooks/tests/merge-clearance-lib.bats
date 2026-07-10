#!/usr/bin/env bats
# Unit tests for the pure decision functions behind the merge-clearance gate.
# These run with no network, no git repo, no PR - every input is a literal.

setup() {
  load_lib="$BATS_TEST_DIRNAME/../scripts/merge-clearance-lib.sh"
  # shellcheck source=/dev/null
  . "$load_lib"
  HEAD="abc123def456"
  NOW=1700000000
  TTL=900
}

# ---- mc_stamp_valid ---------------------------------------------------------

stamp() {
  # stamp <head> <epoch> [ttl]
  local h="$1" e="$2" t="${3:-}"
  if [ -n "$t" ]; then
    printf '{"head":"%s","checked_at_epoch":%s,"ttl_seconds":%s,"tool":"land-and-deploy"}' "$h" "$e" "$t"
  else
    printf '{"head":"%s","checked_at_epoch":%s,"tool":"land-and-deploy"}' "$h" "$e"
  fi
}

@test "stamp valid: matching head, fresh, default ttl" {
  run mc_stamp_valid "$(stamp "$HEAD" $((NOW-60)))" "$HEAD" "$NOW" "$TTL"
  [ "$output" = "valid" ]
  [ "$status" -eq 0 ]
}

@test "stamp invalid: empty stamp -> no-stamp" {
  run mc_stamp_valid "" "$HEAD" "$NOW" "$TTL"
  [ "$output" = "no-stamp" ]
  [ "$status" -eq 1 ]
}

@test "stamp invalid: head mismatch -> stale-head" {
  run mc_stamp_valid "$(stamp "deadbeef" $((NOW-60)))" "$HEAD" "$NOW" "$TTL"
  [ "$output" = "stale-head" ]
  [ "$status" -eq 1 ]
}

@test "stamp invalid: older than default ttl -> expired" {
  run mc_stamp_valid "$(stamp "$HEAD" $((NOW-901)))" "$HEAD" "$NOW" "$TTL"
  [ "$output" = "expired" ]
}

@test "stamp valid: exactly at ttl boundary still valid" {
  run mc_stamp_valid "$(stamp "$HEAD" $((NOW-900)))" "$HEAD" "$NOW" "$TTL"
  [ "$output" = "valid" ]
}

@test "stamp ttl: stamp's own ttl_seconds overrides the default (shorter)" {
  # default 900 would pass, but stamp says 120 and age is 200 -> expired
  run mc_stamp_valid "$(stamp "$HEAD" $((NOW-200)) 120)" "$HEAD" "$NOW" "$TTL"
  [ "$output" = "expired" ]
}

@test "stamp ttl: stamp's own ttl_seconds overrides the default (longer)" {
  # default 900 would expire at age 1000, but stamp says 3600 -> valid
  run mc_stamp_valid "$(stamp "$HEAD" $((NOW-1000)) 3600)" "$HEAD" "$NOW" "$TTL"
  [ "$output" = "valid" ]
}

@test "stamp invalid: future-dated stamp (clock skew) -> expired" {
  run mc_stamp_valid "$(stamp "$HEAD" $((NOW+500)))" "$HEAD" "$NOW" "$TTL"
  [ "$output" = "expired" ]
}

@test "stamp invalid: not JSON -> malformed" {
  run mc_stamp_valid "this is not json" "$HEAD" "$NOW" "$TTL"
  [ "$output" = "malformed" ]
}

@test "stamp invalid: missing head field -> malformed" {
  run mc_stamp_valid '{"checked_at_epoch":1700000000}' "$HEAD" "$NOW" "$TTL"
  [ "$output" = "malformed" ]
}

@test "stamp invalid: non-numeric epoch -> malformed" {
  run mc_stamp_valid '{"head":"abc123def456","checked_at_epoch":"soon"}' "$HEAD" "$NOW" "$TTL"
  [ "$output" = "malformed" ]
}

# ---- mc_cr_verdict ----------------------------------------------------------

@test "cr clear: no threads, no reviews" {
  run mc_cr_verdict "[]" "[]"
  [ "$output" = "clear" ]
  [ "$status" -eq 0 ]
}

@test "cr fail-closed: null threads (degraded GraphQL) -> unknown, not clear" {
  run mc_cr_verdict "null" "[]"
  [ "$output" = "unknown" ]
  [ "$status" -eq 1 ]
}

@test "cr fail-closed: null reviews -> unknown" {
  run mc_cr_verdict "[]" "null"
  [ "$output" = "unknown" ]
  [ "$status" -eq 1 ]
}

@test "cr fail-closed: empty-string input -> unknown" {
  run mc_cr_verdict "" "[]"
  [ "$output" = "unknown" ]
}

@test "cr fail-closed: non-array (object) input -> unknown" {
  run mc_cr_verdict '{"nodes":[]}' "[]"
  [ "$output" = "unknown" ]
}

@test "cr fail-closed: malformed JSON -> unknown" {
  run mc_cr_verdict "not json" "[]"
  [ "$output" = "unknown" ]
}

@test "cr unresolved: an unresolved coderabbit thread blocks" {
  threads='[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"coderabbitai[bot]"}}]}}]'
  run mc_cr_verdict "$threads" "[]"
  [ "$output" = "unresolved" ]
  [ "$status" -eq 1 ]
}

@test "cr clear: a RESOLVED coderabbit thread does not block" {
  threads='[{"isResolved":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]'
  run mc_cr_verdict "$threads" "[]"
  [ "$output" = "clear" ]
}

@test "cr clear: an unresolved thread from a HUMAN (not coderabbit) does not block" {
  threads='[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"mujtaba3B"}}]}}]'
  run mc_cr_verdict "$threads" "[]"
  [ "$output" = "clear" ]
}

@test "cr changes_requested: latest coderabbit review requests changes" {
  reviews='[{"author":{"login":"coderabbitai[bot]"},"state":"CHANGES_REQUESTED","commit":{"oid":"x"}}]'
  run mc_cr_verdict "[]" "$reviews"
  [ "$output" = "changes_requested" ]
  [ "$status" -eq 1 ]
}

@test "cr clear: latest coderabbit review is COMMENTED (non-blocking state)" {
  reviews='[{"author":{"login":"coderabbitai[bot]"},"state":"COMMENTED","commit":{"oid":"x"}}]'
  run mc_cr_verdict "[]" "$reviews"
  [ "$output" = "clear" ]
}

@test "cr clear: a later APPROVED review supersedes an earlier CHANGES_REQUESTED" {
  reviews='[{"author":{"login":"coderabbitai"},"state":"CHANGES_REQUESTED","commit":{"oid":"x"}},{"author":{"login":"coderabbitai"},"state":"APPROVED","commit":{"oid":"y"}}]'
  run mc_cr_verdict "[]" "$reviews"
  [ "$output" = "clear" ]
}

@test "cr unresolved wins over changes_requested when both present" {
  threads='[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]'
  reviews='[{"author":{"login":"coderabbitai"},"state":"CHANGES_REQUESTED","commit":{"oid":"x"}}]'
  run mc_cr_verdict "$threads" "$reviews"
  [ "$output" = "unresolved" ]
}

# --- green HEAD waives only STALE (outdated) CR threads, never current ones ----
# The real wedge (mutwo-skills#118): CodeRabbit left a Minor, isOutdated=true
# nitpick thread unresolved on an earlier commit, then posted a `success` commit
# status on every commit incl. HEAD. mc_cr_verdict counted the stale thread as a
# HARD block, so a PR CR itself marks green could not clear (it had to be merged
# by bypassing the gate). CRITICAL SAFETY FACT: CR's `success` status means CR
# FINISHED reviewing HEAD, not that it approved it - CR posts success alongside
# actionable COMMENTED feedback. So the waiver applies ONLY to OUTDATED threads
# (the anchored code changed and CR re-reviewed HEAD green without re-flagging).
# A CURRENT (isOutdated!=true) unresolved CR thread is CR asking for changes on the
# code as it stands and ALWAYS blocks. 3rd arg = resolved CR commit-status state.

@test "cr verdict: success + an OUTDATED unresolved CR nitpick is waived (the #118 case)" {
  threads='[{"isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"coderabbitai[bot]"}}]}}]'
  run mc_cr_verdict "$threads" "[]" "success"
  [ "$output" = "unresolved-waived" ]
  [ "$status" -eq 0 ]
}

@test "cr verdict: success + a CURRENT (non-outdated) unresolved CR thread STILL BLOCKS" {
  # CR asking for changes on the code as it stands - the green status must NOT waive it
  threads='[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]'
  run mc_cr_verdict "$threads" "[]" "success"
  [ "$output" = "unresolved" ]
  [ "$status" -eq 1 ]
}

@test "cr verdict: success + mixed outdated+current unresolved threads BLOCKS (a current one exists)" {
  threads='[{"isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}},{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]'
  run mc_cr_verdict "$threads" "[]" "success"
  [ "$output" = "unresolved" ]
  [ "$status" -eq 1 ]
}

@test "cr verdict: an unresolved thread with NO isOutdated field defaults to current -> blocks under success" {
  # fail-closed: unknown freshness must not be waived
  threads='[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]'
  run mc_cr_verdict "$threads" "[]" "success"
  [ "$output" = "unresolved" ]
  [ "$status" -eq 1 ]
}

@test "cr verdict: success + outdated thread + CHANGES_REQUESTED review still BLOCKS (not waived)" {
  threads='[{"isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]'
  reviews='[{"author":{"login":"coderabbitai"},"state":"CHANGES_REQUESTED","commit":{"oid":"x"}}]'
  run mc_cr_verdict "$threads" "$reviews" "success"
  [ "$status" -eq 1 ]
  [ "$output" != "unresolved-waived" ]
}

@test "cr verdict: pending status does NOT waive even an outdated thread (review in flight blocks)" {
  threads='[{"isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]'
  run mc_cr_verdict "$threads" "[]" "pending"
  [ "$output" = "unresolved" ]
  [ "$status" -eq 1 ]
}

@test "cr verdict: failure status does NOT waive an outdated thread (blocks)" {
  threads='[{"isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]'
  run mc_cr_verdict "$threads" "[]" "failure"
  [ "$output" = "unresolved" ]
  [ "$status" -eq 1 ]
}

@test "cr verdict: missing status does NOT waive an outdated thread (blocks)" {
  threads='[{"isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]'
  run mc_cr_verdict "$threads" "[]" "missing"
  [ "$output" = "unresolved" ]
  [ "$status" -eq 1 ]
}

@test "cr verdict: two-arg call (no status) still hard-blocks an outdated unresolved thread (backward compat)" {
  threads='[{"isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]'
  run mc_cr_verdict "$threads" "[]"
  [ "$output" = "unresolved" ]
  [ "$status" -eq 1 ]
}

@test "cr verdict: success status with NO unresolved threads is plain clear (unchanged)" {
  run mc_cr_verdict "[]" "[]" "success"
  [ "$output" = "clear" ]
  [ "$status" -eq 0 ]
}

@test "cr verdict: success status still fails CLOSED on degraded thread data" {
  run mc_cr_verdict "null" "[]" "success"
  [ "$output" = "unknown" ]
  [ "$status" -eq 1 ]
}

# ---- mc_cr_reviewed_head ----------------------------------------------------

@test "cr reviewed head: yes when a coderabbit review is on HEAD" {
  reviews='[{"author":{"login":"coderabbitai"},"state":"COMMENTED","commit":{"oid":"abc123def456"}}]'
  run mc_cr_reviewed_head "$reviews" "$HEAD"
  [ "$output" = "yes" ]
}

@test "cr reviewed head: no when coderabbit only reviewed an older commit" {
  reviews='[{"author":{"login":"coderabbitai"},"state":"COMMENTED","commit":{"oid":"older000"}}]'
  run mc_cr_reviewed_head "$reviews" "$HEAD"
  [ "$output" = "no" ]
}

@test "cr reviewed head: no when only a human reviewed HEAD" {
  reviews='[{"author":{"login":"mujtaba3B"},"state":"APPROVED","commit":{"oid":"abc123def456"}}]'
  run mc_cr_reviewed_head "$reviews" "$HEAD"
  [ "$output" = "no" ]
}

# --- green-but-quiet CodeRabbit: success commit status on HEAD proves review ---
# The bug: on a clean incremental commit CodeRabbit flips its per-commit STATUS to
# success and posts NO new review object. The review-object-only check reported
# reviewed-head=no and wedged a fully clean PR. A success CR commit status on the
# exact HEAD sha (per-commit statuses API) is proof CR evaluated HEAD.

@test "cr reviewed head: yes when CR commit status is success on HEAD (no review object)" {
  # review object is on an ANCESTOR only, but CR's status on HEAD is success
  reviews='[{"author":{"login":"coderabbitai"},"state":"COMMENTED","commit":{"oid":"older000"}}]'
  run mc_cr_reviewed_head "$reviews" "$HEAD" "success"
  [ "$output" = "yes" ]
  [ "$status" -eq 0 ]
}

@test "cr reviewed head: yes on success status even with an empty reviews array" {
  run mc_cr_reviewed_head "[]" "$HEAD" "success"
  [ "$output" = "yes" ]
}

@test "cr reviewed head: pending CR status does NOT satisfy reviewed-head (review in flight)" {
  reviews='[{"author":{"login":"coderabbitai"},"state":"COMMENTED","commit":{"oid":"older000"}}]'
  run mc_cr_reviewed_head "$reviews" "$HEAD" "pending"
  [ "$output" = "no" ]
}

@test "cr reviewed head: failure CR status does NOT satisfy reviewed-head" {
  run mc_cr_reviewed_head "[]" "$HEAD" "failure"
  [ "$output" = "no" ]
}

@test "cr reviewed head: missing CR status falls through to the review-object proof" {
  reviews='[{"author":{"login":"coderabbitai"},"state":"COMMENTED","commit":{"oid":"abc123def456"}}]'
  run mc_cr_reviewed_head "$reviews" "$HEAD" "missing"
  [ "$output" = "yes" ]
}

@test "cr reviewed head: guard - a success status does not override an unresolved-thread block" {
  # reviewed-head is satisfied by the success status, but the SEPARATE verdict
  # (mc_cr_verdict) still blocks on an unresolved CodeRabbit thread. This pins that
  # the green-but-quiet relaxation only touches reviewed-head, never the verdict.
  run mc_cr_reviewed_head "[]" "$HEAD" "success"
  [ "$output" = "yes" ]
  threads='[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"coderabbitai[bot]"}}]}}]'
  run mc_cr_verdict "$threads" "[]"
  [ "$output" = "unresolved" ]
  [ "$status" -eq 1 ]
}

# ---- mc_qa_state (the b5 require-a-QA-plan dimension) -----------------------

@test "qa state: complete when all boxes checked" {
  body=$'## QA\n### Development QA\n- [x] criterion via /qa, expect ok'
  run mc_qa_state "$body" 0
  [ "$output" = "complete" ]
}

@test "qa state: incomplete when a box is unchecked" {
  body=$'## QA\n### Development QA\n- [x] one\n- [ ] two'
  run mc_qa_state "$body" 0
  [ "$output" = "incomplete" ]
}

@test "qa state: n/a when no checklist and require_qa_plan off (legacy behavior)" {
  body=$'## QA\nQA_STATUS: dev_verified\nEVIDENCE: ran it'
  run mc_qa_state "$body" 0
  [ "$output" = "n/a" ]
}

@test "qa state: missing when no checklist and require_qa_plan on (b5 gate)" {
  body=$'## QA\nQA_STATUS: dev_verified\nEVIDENCE: ran it'
  run mc_qa_state "$body" 1
  [ "$output" = "missing" ]
}

@test "qa state: production-QA plain bullets do not count as boxes" {
  body=$'## QA\n### Development QA\n- [x] dev one\n### Production QA\n- prod check via /canary'
  run mc_qa_state "$body" 1
  [ "$output" = "complete" ]
}

@test "qa state: fenced code block with boxes is not parsed" {
  body=$'## QA\n```\n- [ ] not a real box, just docs\n```\nQA_STATUS: dev_verified'
  run mc_qa_state "$body" 0
  [ "$output" = "n/a" ]
}

@test "qa state: a sibling heading closes the QA section" {
  body=$'## QA\n### Development QA\n- [x] dev done\n## Notes\n- [ ] unrelated box outside QA'
  run mc_qa_state "$body" 0
  [ "$output" = "complete" ]
}

# ---- mc_qa_state: Template B table format (DEV boxes live in table cells) ----

@test "qa state (Template B): an unchecked DEV table row -> incomplete" {
  body=$'## QA\n| Phase | Status | Tester | Flow | Expect |\n|---|---|---|---|---|\n| DEV | [ ] | claude | run bats | green |'
  run mc_qa_state "$body" 0
  [ "$output" = "incomplete" ]
}

@test "qa state (Template B): all DEV rows checked + DoD boxes checked -> complete" {
  body=$'## QA\n| Phase | Status | Tester | Flow | Expect |\n|---|---|---|---|---|\n| DEV | [x] | claude | run bats | green |\n| DEV | [x] | claude | lint | clean |\n\n**Definition of Done:**\n- [x] Tests written and green\n- [x] Review clear'
  run mc_qa_state "$body" 0
  [ "$output" = "complete" ]
}

@test "qa state (Template B): a PROD row with a hyphen status does not count as a box" {
  body=$'## QA\n| Phase | Status | Tester | Flow | Expect |\n|---|---|---|---|---|\n| DEV | [x] | claude | run bats | green |\n| PROD | - | mutwo | live smoke | 200 |'
  run mc_qa_state "$body" 1
  [ "$output" = "complete" ]
}

@test "qa state (Template B): a PROD hyphen row alone (no DEV box) never blocks by itself" {
  body=$'## QA\n| Phase | Status | Tester | Flow | Expect |\n|---|---|---|---|---|\n| PROD | - | mutwo | live smoke | 200 |\nQA_STATUS: dev_verified'
  run mc_qa_state "$body" 0
  [ "$output" = "n/a" ]
}

@test "qa state (Template B): a PROD hyphen row alone with require=1 -> missing" {
  body=$'## QA\n| Phase | Status | Tester | Flow | Expect |\n|---|---|---|---|---|\n| PROD | - | mutwo | live smoke | 200 |\nQA_STATUS: dev_verified'
  run mc_qa_state "$body" 1
  [ "$output" = "missing" ]
}

@test "qa state (Template B): an unchecked DoD box with all DEV rows checked -> incomplete" {
  body=$'## QA\n| Phase | Status | Tester | Flow | Expect |\n|---|---|---|---|---|\n| DEV | [x] | claude | run bats | green |\n\n**Definition of Done:**\n- [ ] Tests written and green'
  run mc_qa_state "$body" 0
  [ "$output" = "incomplete" ]
}

# ---- mc_head_cr_unreviewable (the CR-unreviewable-only HEAD auto-satisfy) ----
# This is the fix for the .pen-only HEAD permanently blocking the merge-clearance
# gate (email-hero#31). "yes" means the reviewed-head gate may be auto-satisfied.

@test "cr-unreviewable: a .pen-only HEAD (nested path, default *.pen glob) -> yes" {
  files='[{"path":"spec/wireframes/gmail-overlay.pen","binary":false}]'
  run mc_head_cr_unreviewable "$files" '["*.pen"]'
  [ "$output" = "yes" ]
  [ "$status" -eq 0 ]
}

@test "cr-unreviewable: a code-bearing HEAD still requires CR -> no" {
  files='[{"path":"userscript/inject.user.js","binary":false}]'
  run mc_head_cr_unreviewable "$files" '["*.pen"]'
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "cr-unreviewable: a mixed code+.pen HEAD still requires CR -> no" {
  # the safety property: one non-.pen, non-binary file is enough to demand a review
  files='[{"path":"spec/x.pen","binary":false},{"path":"userscript/inject.user.js","binary":false}]'
  run mc_head_cr_unreviewable "$files" '["*.pen"]'
  [ "$output" = "no" ]
}

@test "cr-unreviewable: git-binary blob clears with NO glob configured -> yes" {
  files='[{"path":"design/mock.png","binary":true}]'
  run mc_head_cr_unreviewable "$files" '[]'
  [ "$output" = "yes" ]
}

@test "cr-unreviewable: a .pen text file with NO glob (empty list) -> no" {
  # binary detection alone misses .pen (it is plaintext JSON); without the glob it blocks
  files='[{"path":"a.pen","binary":false}]'
  run mc_head_cr_unreviewable "$files" '[]'
  [ "$output" = "no" ]
}

@test "cr-unreviewable: binary + .pen together (glob *.pen) -> yes" {
  files='[{"path":"x.png","binary":true},{"path":"y.pen","binary":false}]'
  run mc_head_cr_unreviewable "$files" '["*.pen"]'
  [ "$output" = "yes" ]
}

@test "cr-unreviewable: a slash-bearing dir glob anchors to the full path" {
  files='[{"path":"spec/wireframes/x.pen","binary":false}]'
  run mc_head_cr_unreviewable "$files" '["spec/wireframes/**"]'
  [ "$output" = "yes" ]
}

@test "cr-unreviewable: a file outside the dir glob -> no" {
  files='[{"path":"src/app.ts","binary":false}]'
  run mc_head_cr_unreviewable "$files" '["spec/wireframes/**"]'
  [ "$output" = "no" ]
}

@test "cr-unreviewable: single * does not cross a slash" {
  files='[{"path":"spec/deep/x.pen","binary":false}]'
  run mc_head_cr_unreviewable "$files" '["spec/*"]'
  [ "$output" = "no" ]
}

@test "cr-unreviewable: fail-closed on an empty file list -> no" {
  run mc_head_cr_unreviewable "[]" '["*.pen"]'
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "cr-unreviewable: fail-closed on null files -> no" {
  run mc_head_cr_unreviewable "null" '["*.pen"]'
  [ "$output" = "no" ]
}

@test "cr-unreviewable: fail-closed on a non-array (object) files input -> no" {
  run mc_head_cr_unreviewable '{"nodes":[]}' '["*.pen"]'
  [ "$output" = "no" ]
}

@test "cr-unreviewable: fail-closed on malformed files JSON -> no" {
  run mc_head_cr_unreviewable "not json" '["*.pen"]'
  [ "$output" = "no" ]
}

@test "cr-unreviewable: malformed globs degrade to [] (binary still clears)" {
  run mc_head_cr_unreviewable '[{"path":"a.png","binary":true}]' "not json"
  [ "$output" = "yes" ]
}

@test "cr-unreviewable: malformed globs degrade to [] (non-binary text blocks)" {
  run mc_head_cr_unreviewable '[{"path":"a.pen","binary":false}]' "not json"
  [ "$output" = "no" ]
}

# --- safety-invariant hardening: a code file must NEVER auto-clear -----------

@test "cr-unreviewable: *.pen is an anchored extension, not a substring (penpal.ts -> no)" {
  # guards the ^...$ anchoring: a code file whose name merely contains "pen" must block
  run mc_head_cr_unreviewable '[{"path":"src/penpal.ts","binary":false}]' '["*.pen"]'
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "cr-unreviewable: a .pen.bak decoy does not match *.pen -> no" {
  run mc_head_cr_unreviewable '[{"path":"spec/x.pen.bak","binary":false}]' '["*.pen"]'
  [ "$output" = "no" ]
}

@test "cr-unreviewable: code-only with assorted extensions and depth -> no" {
  files='[{"path":"a.ts","binary":false},{"path":"pkg/b.py","binary":false},{"path":"cmd/c/main.go","binary":false}]'
  run mc_head_cr_unreviewable "$files" '["*.pen"]'
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "cr-unreviewable: regex metachars in a glob stay literal, code still blocks -> no" {
  # "build(generated)/**" must not let app/(routes)/x.ts through via a live "(" group
  files='[{"path":"app/(routes)/x.ts","binary":false}]'
  run mc_head_cr_unreviewable "$files" '["build(generated)/**"]'
  [ "$output" = "no" ]
}

@test "cr-unreviewable: a string \"true\" binary value is NOT treated as binary -> no" {
  # pins the producer/consumer contract: binary must be a real boolean, not "true"
  run mc_head_cr_unreviewable '[{"path":"x.bin","binary":"true"}]' '[]'
  [ "$output" = "no" ]
}

@test "cr-unreviewable: a degenerate null-path entry fails closed -> no" {
  run mc_head_cr_unreviewable '[{"path":null,"binary":true}]' '["*.pen"]'
  [ "$output" = "no" ]
}

@test "cr-unreviewable: a misconfigured bare [\"*\"] glob matches any basename (documented)" {
  # NOT a safety hole introduced here: "*" is an operator-authored marker choice.
  # Pinned so the behavior is a decision, not an accident.
  run mc_head_cr_unreviewable '[{"path":"app.ts","binary":false}]' '["*"]'
  [ "$output" = "yes" ]
}

@test "cr-unreviewable: bare [\"*\"] matches any basename at any depth (match-all footgun)" {
  # a no-slash glob matches the basename, which never has a slash, so "*" matches
  # EVERY file regardless of depth. This is why "*" is an operator-error config,
  # documented; pinned so the match-all behavior is a decision, not an accident.
  run mc_head_cr_unreviewable '[{"path":"src/deep/app.ts","binary":false}]' '["*"]'
  [ "$output" = "yes" ]
}

@test "cr-unreviewable: ? glob matches exactly one non-slash char" {
  run mc_head_cr_unreviewable '[{"path":"a.pen","binary":false}]' '["?.pen"]'
  [ "$output" = "yes" ]
  run mc_head_cr_unreviewable '[{"path":"ab.pen","binary":false}]' '["?.pen"]'
  [ "$output" = "no" ]
}

@test "cr-unreviewable: a binary file cannot cover a sibling code file (per-file OR) -> no" {
  files='[{"path":"weird.bin","binary":true},{"path":"src/app.ts","binary":false}]'
  run mc_head_cr_unreviewable "$files" '["*.pen"]'
  [ "$output" = "no" ]
}

# ---- ld_sentinel_valid ------------------------------------------------------
# Signature: ld_sentinel_valid <json> <now> <default_ttl> <target_head> [<repo>] [<pr>]

sentinel() {
  # sentinel <epoch> <head> [repo] [pr] [ttl]
  local e="$1" h="$2" repo="${3:-owner/name}" pr="${4:-}" t="${5:-1800}"
  printf '{"set_at_epoch":%s,"ttl_seconds":%s,"repo":"%s","head_sha":"%s","pr_number":"%s","source":"skill"}' \
    "$e" "$t" "$repo" "$h" "$pr"
}

@test "sentinel valid: fresh, matching head + repo + pr" {
  run ld_sentinel_valid "$(sentinel $((NOW-60)) "$HEAD" "owner/name" "55")" "$NOW" "$TTL" "$HEAD" "owner/name" "55"
  [ "$output" = "valid" ]
  [ "$status" -eq 0 ]
}

@test "sentinel valid: head matches, repo/pr omitted on target side -> head-only match" {
  run ld_sentinel_valid "$(sentinel $((NOW-60)) "$HEAD")" "$NOW" "$TTL" "$HEAD" "" ""
  [ "$output" = "valid" ]
}

@test "sentinel invalid: empty -> no-sentinel" {
  run ld_sentinel_valid "" "$NOW" "$TTL" "$HEAD" "owner/name" "55"
  [ "$output" = "no-sentinel" ]
  [ "$status" -eq 1 ]
}

@test "sentinel invalid: corrupt json -> malformed" {
  run ld_sentinel_valid '{not json' "$NOW" "$TTL" "$HEAD" "" ""
  [ "$output" = "malformed" ]
}

@test "sentinel invalid: missing head_sha -> malformed" {
  run ld_sentinel_valid '{"set_at_epoch":1700000000,"ttl_seconds":1800,"repo":"owner/name"}' "$NOW" "$TTL" "$HEAD" "" ""
  [ "$output" = "malformed" ]
}

@test "sentinel invalid: older than its own ttl -> expired" {
  run ld_sentinel_valid "$(sentinel $((NOW-1801)) "$HEAD" "owner/name" "55" 1800)" "$NOW" "$TTL" "$HEAD" "owner/name" "55"
  [ "$output" = "expired" ]
}

@test "sentinel valid: exactly at ttl boundary still valid" {
  run ld_sentinel_valid "$(sentinel $((NOW-1800)) "$HEAD" "owner/name" "55" 1800)" "$NOW" "$TTL" "$HEAD" "owner/name" "55"
  [ "$output" = "valid" ]
}

@test "sentinel invalid: head mismatch (newer pushed commit) -> mismatch" {
  run ld_sentinel_valid "$(sentinel $((NOW-60)) "oldcommit" "owner/name" "55")" "$NOW" "$TTL" "$HEAD" "owner/name" "55"
  [ "$output" = "mismatch" ]
}

@test "sentinel invalid: repo mismatch -> mismatch" {
  run ld_sentinel_valid "$(sentinel $((NOW-60)) "$HEAD" "owner/other" "55")" "$NOW" "$TTL" "$HEAD" "owner/name" "55"
  [ "$output" = "mismatch" ]
}

@test "sentinel invalid: pr mismatch when both sides carry one -> mismatch" {
  run ld_sentinel_valid "$(sentinel $((NOW-60)) "$HEAD" "owner/name" "99")" "$NOW" "$TTL" "$HEAD" "owner/name" "55"
  [ "$output" = "mismatch" ]
}

@test "sentinel valid: pr enforced only when both sides have one (sentinel pr empty -> ignored)" {
  run ld_sentinel_valid "$(sentinel $((NOW-60)) "$HEAD" "owner/name" "")" "$NOW" "$TTL" "$HEAD" "owner/name" "55"
  [ "$output" = "valid" ]
}

@test "sentinel ttl: sentinel's own ttl overrides the default (shorter -> expired)" {
  # default 1800 would pass, but sentinel says 120 and age is 200 -> expired
  run ld_sentinel_valid "$(sentinel $((NOW-200)) "$HEAD" "owner/name" "55" 120)" "$NOW" 1800 "$HEAD" "owner/name" "55"
  [ "$output" = "expired" ]
}

# ---- mc_is_bookkeeping ------------------------------------------------------
# Twin of qpg_is_bookkeeping in the qa plugin; the two allowlists are kept in
# lockstep. A PR whose every path is docs / the cross-host inventory rides the
# bookkeeping fast lane (review + QA waived; CI + CR stay hard).

@test "bookkeeping: all docs -> yes" {
  run mc_is_bookkeeping "$(printf 'README.md\ndocs/x.md')"
  [ "$output" = "yes" ]
  [ "$status" -eq 0 ]
}

@test "bookkeeping: docs + cross-host inventory -> yes" {
  run mc_is_bookkeeping "$(printf 'CHANGELOG.md\nwhere-things-run.json')"
  [ "$output" = "yes" ]
  [ "$status" -eq 0 ]
}

@test "bookkeeping: where-things-run.json matches at any depth, by basename" {
  run mc_is_bookkeeping "sub/dir/where-things-run.json"
  [ "$output" = "yes" ]
  [ "$status" -eq 0 ]
}

@test "bookkeeping: any code file makes the set no (fails closed)" {
  run mc_is_bookkeeping "$(printf 'README.md\nlib/x.sh')"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "bookkeeping: arbitrary json is not bookkeeping" {
  run mc_is_bookkeeping "settings.json"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "bookkeeping: app yaml config is not bookkeeping (buckets.yaml stays gated)" {
  run mc_is_bookkeeping "automations/triage/buckets.yaml"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "bookkeeping: empty changeset -> no" {
  run mc_is_bookkeeping ""
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "bookkeeping: SKILL.md/CLAUDE.md/AGENTS.md are behavior, excluded despite .md" {
  run mc_is_bookkeeping "SKILL.md"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
  run mc_is_bookkeeping "CLAUDE.md"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
  run mc_is_bookkeeping "AGENTS.md"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
  run mc_is_bookkeeping "$(printf 'README.md\nx/SKILL.md')"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "bookkeeping: vcs/meta dotfiles + placeholders are inert -> yes" {
  run mc_is_bookkeeping "$(printf '.gitignore\n.gitattributes\n.editorconfig\n.dockerignore\n.npmignore\n.prettierignore\n.eslintignore\n.gcloudignore\ndata/.keep\nassets/.gitkeep')"
  [ "$output" = "yes" ]
  [ "$status" -eq 0 ]
}

@test "bookkeeping: a .gitignore-only changeset rides the fast lane" {
  run mc_is_bookkeeping "sub/dir/.gitignore"
  [ "$output" = "yes" ]
  [ "$status" -eq 0 ]
}

@test "bookkeeping: legal/governance files are inert -> yes" {
  run mc_is_bookkeeping "$(printf 'LICENSE\nLICENSE.txt\nLICENCE\nCOPYING\nNOTICE\nAUTHORS\nCONTRIBUTORS\nCODEOWNERS')"
  [ "$output" = "yes" ]
  [ "$status" -eq 0 ]
}

@test "bookkeeping: requirements/runtime/constraints .txt are manifests, excluded" {
  run mc_is_bookkeeping "requirements.txt"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
  run mc_is_bookkeeping "requirements-dev.txt"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
  # reverse-order naming must also be caught by the *requirements*.txt glob
  run mc_is_bookkeeping "dev-requirements.txt"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
  run mc_is_bookkeeping "runtime.txt"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
  run mc_is_bookkeeping "constraints.txt"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
  run mc_is_bookkeeping "$(printf 'README.md\nrequirements.txt')"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "bookkeeping: LICENSE.txt still rides via the *.txt doc arm (no LICENSE.* glob)" {
  run mc_is_bookkeeping "LICENSE.txt"
  [ "$output" = "yes" ]
  [ "$status" -eq 0 ]
}

@test "bookkeeping: .coderabbit.yaml + version pins stay gated" {
  run mc_is_bookkeeping ".coderabbit.yaml"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
  run mc_is_bookkeeping ".python-version"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
  run mc_is_bookkeeping "Gemfile.lock"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "merge-clearance GraphQL files connection respects GitHub's first<=100 cap" {
  # GitHub rejects files(first:>100) with EXCESSIVE_PAGINATION, which made the
  # whole clearance query die. Pin the cap so a future bump past 100 fails here.
  script="$BATS_TEST_DIRNAME/../scripts/merge-clearance.sh"
  run grep -oE 'files\(first:[0-9]+\)' "$script"
  [ "$status" -eq 0 ]
  n=$(printf '%s' "$output" | grep -oE '[0-9]+' | head -1)
  [ "$n" -le 100 ]
}

# ---- mc_cr_rate_limited -----------------------------------------------------
# CodeRabbit's rate-limit notice carries a stable auto-generated marker string
# ("rate limited by coderabbit.ai"). These tests pin detection vs the in-progress
# notice (which must NOT match) and the fail-closed behaviour on bad input.

rlmarker="<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->"

@test "cr rate-limited: 'reached your PR review rate limit' flavour detected" {
  body="$rlmarker"$'\n'"\`@mujtaba3B\`, we couldn't start this review because you've reached your PR review rate limit."
  run mc_cr_rate_limited "$(jq -nc --arg b "$body" '[{author:"coderabbitai[bot]", body:$b}]')"
  [ "$output" = "yes" ]
  [ "$status" -eq 0 ]
}

@test "cr rate-limited: 'Rate limit exceeded ... please wait' flavour detected" {
  body="$rlmarker"$'\n'"## Rate limit exceeded
\`@mujtaba3B\` has exceeded the limit for the number of commits that can be reviewed per hour. Please wait 4 minutes and 29 seconds before requesting another review."
  run mc_cr_rate_limited "$(jq -nc --arg b "$body" '[{author:"coderabbitai[bot]", body:$b}]')"
  [ "$output" = "yes" ]
  [ "$status" -eq 0 ]
}

@test "cr rate-limited: in-progress 'Currently processing' notice is NOT rate-limit" {
  body="Currently processing new changes in this PR. This may take a few minutes, please wait..."
  run mc_cr_rate_limited "$(jq -nc --arg b "$body" '[{author:"coderabbitai[bot]", body:$b}]')"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "cr rate-limited: marker from a NON-coderabbit author does not count" {
  body="$rlmarker someone quoting the rate limited by coderabbit.ai marker"
  run mc_cr_rate_limited "$(jq -nc --arg b "$body" '[{author:"mujtaba3B", body:$b}]')"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "cr rate-limited: no CR comments at all -> no" {
  run mc_cr_rate_limited "$(jq -nc '[{author:"mujtaba3B", body:"lgtm"}]')"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "cr rate-limited: empty array -> no" {
  run mc_cr_rate_limited "[]"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "cr rate-limited: non-array input fails closed -> no" {
  run mc_cr_rate_limited '{"not":"an array"}'
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
  run mc_cr_rate_limited "garbage"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "cr rate-limited: marker among many comments is found (mixed authors)" {
  json=$(jq -nc --arg m "$rlmarker" '[
    {author:"mujtaba3B", body:"first pass looks good"},
    {author:"coderabbitai[bot]", body:($m + "\nyou have reached your PR review rate limit")},
    {author:"some-other-bot", body:"ci passed"}
  ]')
  run mc_cr_rate_limited "$json"
  [ "$output" = "yes" ]
  [ "$status" -eq 0 ]
}

# ---- mc_cr_rate_limited_latest (the STUCK-PENDING freshness guard) -----------
# CodeRabbit posts a "pending" commit status the moment it starts, then can hit
# the limit mid-flight and post its notice, leaving the status stuck "pending".
# This stricter variant fires ONLY when the rate-limit notice is CR's LATEST
# comment, so a genuine in-flight review (which posts a newer "Currently
# processing ..." comment) keeps blocking. The caller gates the pending escape
# hatch on this AND a current local /eng:cr review backstop.

@test "cr rate-limited (latest): notice is CR's most recent comment -> yes" {
  json=$(jq -nc --arg m "$rlmarker" '[
    {author:"coderabbitai[bot]", body:"Currently processing new changes ... please wait"},
    {author:"mujtaba3B", body:"ping"},
    {author:"coderabbitai[bot]", body:($m + "\nyou have reached your PR review rate limit")}
  ]')
  run mc_cr_rate_limited_latest "$json"
  [ "$output" = "yes" ]
  [ "$status" -eq 0 ]
}

@test "cr rate-limited (latest): a later 'Currently processing' supersedes a stale notice -> no" {
  # freshness guard: CR was rate-limited earlier, then resumed and is reviewing now
  json=$(jq -nc --arg m "$rlmarker" '[
    {author:"coderabbitai[bot]", body:($m + "\nyou have reached your PR review rate limit")},
    {author:"coderabbitai[bot]", body:"Currently processing new changes ... please wait"}
  ]')
  run mc_cr_rate_limited_latest "$json"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "cr rate-limited (latest): a HUMAN comment after the notice does not unset it (CR's latest still the notice) -> yes" {
  json=$(jq -nc --arg m "$rlmarker" '[
    {author:"coderabbitai[bot]", body:($m + "\nRate limit exceeded")},
    {author:"mujtaba3B", body:"acknowledged, running local review"}
  ]')
  run mc_cr_rate_limited_latest "$json"
  [ "$output" = "yes" ]
  [ "$status" -eq 0 ]
}

@test "cr rate-limited (latest): no rate-limit notice at all -> no" {
  json=$(jq -nc '[{author:"coderabbitai[bot]", body:"Currently processing new changes ... please wait"}]')
  run mc_cr_rate_limited_latest "$json"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "cr rate-limited (latest): no CR comments at all -> no" {
  run mc_cr_rate_limited_latest "$(jq -nc '[{author:"mujtaba3B", body:"lgtm"}]')"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "cr rate-limited (latest): empty array -> no" {
  run mc_cr_rate_limited_latest "[]"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}

@test "cr rate-limited (latest): non-array / garbage input fails closed -> no" {
  run mc_cr_rate_limited_latest '{"not":"an array"}'
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
  run mc_cr_rate_limited_latest "garbage"
  [ "$output" = "no" ]
  [ "$status" -eq 1 ]
}
