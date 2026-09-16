#!/usr/bin/env bats
# Tests for apply-merge-clearance-protection.sh's review-preservation contract.
#
# Why this file exists: a PUT replaces branch protection wholesale, so the script
# used to hardcode `required_pull_request_reviews: null` and thereby DELETE
# whatever review rule a branch had, silently. That is a destructive default in
# the one script whose job is to arm protection, so the behavior is pinned here.
#
# Everything runs through --dry-run, which prints the payload and exits before
# the PUT, so no test can touch a real repo's protection. `gh` is stubbed on PATH
# and serves a canned protection document; `jq` stays real because the script's
# payload construction is the thing under test.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/apply-merge-clearance-protection.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  # The canned response the stub serves for the protection GET. A test writes
  # the file it wants; an absent file makes the stub exit non-zero, which is how
  # a branch with no protection at all (404) is represented.
  export STUB_PROTECTION="$BATS_TEST_TMPDIR/protection.json"
  cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal gh stub: only the calls --dry-run reaches.
if [ "$1" = "api" ]; then
  # `gh api <path> --jq <filter>`
  [ -f "$STUB_PROTECTION" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
  filter="."
  for ((i=1;i<=$#;i++)); do
    if [ "${!i}" = "--jq" ]; then j=$((i+1)); filter="${!j}"; fi
  done
  jq -r "$filter" < "$STUB_PROTECTION"
  exit 0
fi
if [ "$1" = "repo" ]; then echo "main"; exit 0; fi
exit 0
STUB
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH"
}

# Pull the pretty-printed payload (after the "Protection payload:" banner) and
# read one field out of it. Anchoring on the banner matters: the preserve path
# also echoes a JSON object in its stderr notice, so a naive "first {" would
# sometimes read the wrong object.
payload_field() {  # <output> <jq-filter>
  # Take ONLY the pretty-printed payload: from the banner to the first line that
  # is a bare closing brace. Two things would otherwise leak in and make jq fail
  # for a reason that has nothing to do with the assertion: bats merges stderr
  # into $output, so the preserve notice and the deadlock warning sit in the
  # same stream, and the script prints "(dry-run: no change applied)" after the
  # payload. A helper that dies on unrelated text turns every real failure into
  # a parse error, which is how a broken assertion hides as a broken harness.
  printf '%s' "$1" \
    | sed -n '/^Protection payload:/,$p' | tail -n +2 \
    | sed -n '1,/^}$/p' \
    | jq -c "$2"
}

@test "preserves an existing code-owner review requirement instead of clearing it" {
  cat > "$STUB_PROTECTION" <<'JSON'
{"required_pull_request_reviews":{"dismiss_stale_reviews":true,"require_code_owner_reviews":true,"required_approving_review_count":0,"require_last_push_approval":false}}
JSON
  run bash "$SCRIPT" owner/repo main --dry-run
  [ "$status" -eq 0 ]
  [ "$(payload_field "$output" '.required_pull_request_reviews.require_code_owner_reviews')" = "true" ]
  [ "$(payload_field "$output" '.required_pull_request_reviews.dismiss_stale_reviews')" = "true" ]
  [ "$(payload_field "$output" '.required_pull_request_reviews.required_approving_review_count')" = "0" ]
}

@test "invents no review rule when the branch has none" {
  echo '{"required_pull_request_reviews":null}' > "$STUB_PROTECTION"
  run bash "$SCRIPT" owner/repo main --dry-run
  [ "$status" -eq 0 ]
  [ "$(payload_field "$output" '.required_pull_request_reviews')" = "null" ]
}

@test "invents no review rule when the branch has no protection at all" {
  rm -f "$STUB_PROTECTION"   # stub exits non-zero, as a 404 would
  run bash "$SCRIPT" owner/repo main --dry-run
  [ "$status" -eq 0 ]
  [ "$(payload_field "$output" '.required_pull_request_reviews')" = "null" ]
}

@test "warns that code-owner review plus enforce_admins can deadlock a sole owner" {
  cat > "$STUB_PROTECTION" <<'JSON'
{"required_pull_request_reviews":{"require_code_owner_reviews":true,"required_approving_review_count":0}}
JSON
  run bash "$SCRIPT" owner/repo main --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot merge their own change to an owned path"* ]]
}

@test "does not warn about deadlock under --soft, which keeps the admin bypass" {
  cat > "$STUB_PROTECTION" <<'JSON'
{"required_pull_request_reviews":{"require_code_owner_reviews":true,"required_approving_review_count":0}}
JSON
  run bash "$SCRIPT" owner/repo main --dry-run --soft
  [ "$status" -eq 0 ]
  [[ "$output" != *"cannot merge their own change to an owned path"* ]]
  # the rule itself is still preserved; only the admin binding changed
  [ "$(payload_field "$output" '.required_pull_request_reviews.require_code_owner_reviews')" = "true" ]
  [ "$(payload_field "$output" '.enforce_admins')" = "false" ]
}
