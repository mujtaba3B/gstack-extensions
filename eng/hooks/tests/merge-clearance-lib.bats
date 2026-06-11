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
