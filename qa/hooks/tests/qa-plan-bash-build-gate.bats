#!/usr/bin/env bats
# Tests for gate 1b, the QA-plan BUILD gate's Bash path (qa-plan-bash-build-gate.sh
# plus its pure decision functions in qa-plan-gate-lib.sh).
#
# The defect under test: gate 1 is registered on Edit|MultiEdit|Write only, so
# source written through Bash bypassed it entirely. Observed 2026-09-04 in
# ~/dev/tooling/local-bin, where three tracked source files were written with
# `python3 - <<'PY'` heredocs and nothing fired.
#
# TWO THINGS THIS SUITE IS CAREFUL ABOUT, both scars this repo already carries:
#   1. No bare `[[ ]]`. Under bats-core 1.13 a failing `[[ ]]` in any position
#      other than the last line of a test body does NOT fail the test. Use
#      assert_contains / assert_missing, or `[ ]`.
#   2. Assert the REASON, not just a non-zero-ness. This gate has four
#      dispositions and several allow paths; an outcome-only assertion passes for
#      the wrong reason. Every allow case below pins WHICH allow it was, via the
#      snapshot side effects the different paths leave behind.

setup() {
  # Hermetic: pin the gate-policy lookup at a path that cannot exist, so these
  # tests exercise the policy contract deterministically instead of inheriting
  # whatever ~/dev/gate-policy.json this machine happens to carry.
  export GATE_POLICY_TEST=1
  export GATE_POLICY_FILE="$BATS_TEST_TMPDIR/no-such-gate-policy.json"
  export GATE_LOCAL_FILE="$BATS_TEST_TMPDIR/no-such-gate-local.json"
  LIB="$BATS_TEST_DIRNAME/../scripts/qa-plan-gate-lib.sh"
  GATE="$BATS_TEST_DIRNAME/../scripts/qa-plan-bash-build-gate.sh"
  # shellcheck source=/dev/null
  . "$LIB"
  mkdir -p "$HOME/dev"
  REPO=$(mktemp -d "$HOME/dev/.qpbtest.XXXXXX")
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Test User"
  git -C "$REPO" config user.email "t@example.com"
  mkdir -p "$REPO/src" "$REPO/docs" "$REPO/tests"
  printf 'print(1)\n'  > "$REPO/src/app.py"
  printf 'hello\n'     > "$REPO/docs/guide.md"
  printf 'x\n'         > "$REPO/tests/test_app.py"
  printf 'build/\n'    > "$REPO/.gitignore"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m init
  git -C "$REPO" branch -M main
  git -C "$REPO" checkout -q -b feat/thing
  GITDIR=$(git -C "$REPO" rev-parse --absolute-git-dir)
  SNAP="$GITDIR/qa-plan-bash-snapshot"
}

teardown() { rm -rf "$REPO"; }

# ---- substring assertions (see the header note about bare `[[ ]]`) ----------
assert_contains() {  # <haystack> <needle>
  case "$1" in *"$2"*) return 0 ;; esac
  echo "assert_contains failed" >&2
  echo "  wanted substring: $2" >&2
  echo "  actual:           $1" >&2
  return 1
}
assert_missing() {  # <haystack> <needle-that-must-not-appear>
  case "$1" in *"$2"*)
    echo "assert_missing failed" >&2
    echo "  unwanted substring: $2" >&2
    echo "  actual:             $1" >&2
    return 1 ;;
  esac
  return 0
}

# ---- helpers ---------------------------------------------------------------
gp_write_policy() {  # <gate> <config-json>
  mkdir -p "$(dirname "$GATE_POLICY_FILE")"
  jq -nc --arg g "$1" --argjson c "$2" --arg root "$HOME/dev" \
    '{scope:{root:$root, exclude_path_prefixes:[], exclude_nested:false},
      defaults:{($g): $c}, overrides:{}}' > "$GATE_POLICY_FILE"
}
# NOT `"${1:-{\"base_branches\":[\"main\"]}}"`. That form (copied around this
# repo) breaks the moment an argument IS passed: the first `}` inside the default
# closes the parameter expansion, so the trailing `}` is concatenated onto
# whatever $1 was, producing invalid JSON and a jq --argjson failure.
opt_in() {
  local cfg="${1:-}"
  [ -n "$cfg" ] || cfg='{"base_branches":["main"]}'
  gp_write_policy qa-plan "$cfg"
}

# An ATTESTED stamp, the shape qa-plan-stamp.sh writes after a real human
# approval: approval_source is the proof field, criteria_digest keeps it from
# being time-bounded.
stamp_for() {
  printf '{"branch":"%s","approved_at":"x","approved_at_epoch":1,"head_at_approval":"y","criteria_digest":"d","approver":"a","approval_source":"AskUserQuestion","approval_nonce":"n","tool":"qa-plan"}' \
    "$1" > "$GITDIR/qa-plan-approved"
}

payload() {  # <command> [cwd]
  jq -nc --arg c "$1" --arg cwd "${2:-$REPO}" \
    '{hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:$c}, cwd:$cwd}'
}
fire() { payload "$1" "${2:-$REPO}" | bash "$GATE"; }

# Establish the branch baseline the way the first Bash call of a session does.
baseline() { fire "ls" >/dev/null 2>&1 || true; }

# ============================================================================
# Pure: qpg_bash_build_disposition <verdict> <baseline> <delta>
# The whole allow/block decision. Full truth table; this is the function a
# mutation must make go red.
# ============================================================================

@test "disposition: a valid stamp allows, whatever else is true" {
  run qpg_bash_build_disposition "valid" "have" "abc src/app.py"
  [ "$output" = "allow-stamped" ]; [ "$status" -eq 1 ]
}

@test "disposition: no stamp + no baseline yet -> allow (this call is the baseline)" {
  run qpg_bash_build_disposition "no-stamp" "none" "abc src/app.py"
  [ "$output" = "allow-baseline" ]; [ "$status" -eq 1 ]
}

@test "disposition: no stamp + baseline + empty delta -> allow (nothing changed)" {
  run qpg_bash_build_disposition "no-stamp" "have" ""
  [ "$output" = "allow-no-delta" ]; [ "$status" -eq 1 ]
}

@test "disposition: no stamp + baseline + a delta -> BLOCK" {
  run qpg_bash_build_disposition "no-stamp" "have" "abc src/app.py"
  [ "$output" = "block" ]; [ "$status" -eq 0 ]
}

@test "disposition: every non-valid verdict blocks on a delta, not just no-stamp" {
  for v in no-stamp wrong-branch malformed unattested approval-expired plan-changed; do
    run qpg_bash_build_disposition "$v" "have" "abc src/app.py"
    [ "$output" = "block" ]
  done
}

@test "disposition: 'valid' is matched exactly, not as a prefix or substring" {
  run qpg_bash_build_disposition "invalid" "have" "abc src/app.py"
  [ "$output" = "block" ]
  run qpg_bash_build_disposition "validish" "have" "abc src/app.py"
  [ "$output" = "block" ]
}

@test "disposition: baseline is matched exactly ('have'), so an unknown state is treated as no baseline" {
  run qpg_bash_build_disposition "no-stamp" "haveish" "abc src/app.py"
  [ "$output" = "allow-baseline" ]
}

# ============================================================================
# Pure: qpg_status_source_paths <porcelain-text>
# ============================================================================

@test "status paths: a modified source file is source" {
  run qpg_status_source_paths " M src/app.py"
  [ "$output" = "src/app.py" ]
}

@test "status paths: docs, config and tests are carved out" {
  run qpg_status_source_paths " M docs/guide.md
 M config/settings.json
 M tests/test_app.py
 M src/app.test.js"
  [ "$output" = "" ]
}

@test "status paths: an untracked new source file is source" {
  run qpg_status_source_paths "?? src/new.py"
  [ "$output" = "src/new.py" ]
}

@test "status paths: a deleted source file is source (a deletion is a mutation)" {
  run qpg_status_source_paths " D src/app.py"
  [ "$output" = "src/app.py" ]
}

@test "status paths: a rename reports the DESTINATION, not the 'orig -> dest' blob" {
  run qpg_status_source_paths "R  src/old.py -> src/new.py"
  [ "$output" = "src/new.py" ]
}

@test "status paths: ' -> ' inside an ordinary filename is not truncated" {
  # Not a rename status, so the arrow is part of the name and must survive.
  run qpg_status_source_paths " M src/a -> b.py"
  [ "$output" = "src/a -> b.py" ]
}

@test "status paths: an ignored (!!) entry is never source" {
  run qpg_status_source_paths "!! build/out.js"
  [ "$output" = "" ]
}

@test "status paths: a .git/ path is carved out" {
  run qpg_status_source_paths " M .git/config.py"
  [ "$output" = "" ]
}

@test "status paths: a quoted path is unquoted before classification" {
  run qpg_status_source_paths " M \"src/a\\\"b.py\""
  [ "$output" = 'src/a"b.py' ]
}

@test "status paths: short or empty lines are skipped without error" {
  run qpg_status_source_paths "
 M
xy"
  [ "$output" = "" ]; [ "$status" -eq 0 ]
}

@test "status paths: mixed input returns only the source entries, in order" {
  run qpg_status_source_paths " M docs/a.md
 M src/one.py
?? src/two.sh
 M package.json"
  [ "$output" = "src/one.py
src/two.sh" ]
}

# ============================================================================
# Pure: qpg_unquote_path
# ============================================================================

@test "unquote: an unquoted token is returned unchanged" {
  run qpg_unquote_path "src/app.py"
  [ "$output" = "src/app.py" ]
}

@test "unquote: escaped backslashes survive an adjacent escaped quote" {
  # The porcelain token for a file literally named  a\  is  "a\\"  . Unescaping
  # quotes BEFORE backslashes would read the `\\"` as an escaped quote, swallow
  # the closing delimiter and lose the backslash.
  run qpg_unquote_path '"a\\"'
  [ "$output" = 'a\' ]
}

@test "unquote: an escaped quote inside a name is restored" {
  run qpg_unquote_path '"a\"b.py"'
  [ "$output" = 'a"b.py' ]
}

# ============================================================================
# Pure: qpg_snapshot_delta
# ============================================================================

@test "delta: a newly dirty path is a delta" {
  run qpg_snapshot_delta "" "aaa src/app.py"
  [ "$output" = "aaa src/app.py" ]
}

@test "delta: an unchanged entry is not a delta" {
  run qpg_snapshot_delta "aaa src/app.py" "aaa src/app.py"
  [ "$output" = "" ]
}

@test "delta: a CHANGED digest on an already-dirty path is a delta" {
  # This is why snapshot lines carry a content digest rather than a bare path: an
  # agent iterating on one file would otherwise go unreported after the first.
  run qpg_snapshot_delta "aaa src/app.py" "bbb src/app.py"
  [ "$output" = "bbb src/app.py" ]
}

@test "delta: a path that went back to clean is NOT reported as a change" {
  run qpg_snapshot_delta "aaa src/app.py" ""
  [ "$output" = "" ]
}

@test "delta: only the new entries are reported when others are unchanged" {
  run qpg_snapshot_delta "aaa src/one.py
bbb src/two.py" "aaa src/one.py
ccc src/three.py"
  [ "$output" = "ccc src/three.py" ]
}

# ============================================================================
# End to end: the hook, against a real repo
# ============================================================================

@test "e2e REPRO: a python heredoc writing tracked source BLOCKS and names the file" {
  opt_in
  baseline
  # The exact 2026-09-04 mechanism: the write lives inside the interpreter's
  # source text, which no shell-shape matcher can see.
  cd "$REPO" && python3 - <<'PY'
open("src/app.py", "w").write("print(2)\n")
PY
  run fire "python3 - <<'PY'
open(\"src/app.py\", \"w\").write(\"print(2)\")
PY"
  [ "$status" -eq 0 ]
  assert_contains "$output" '"decision":"block"'
  assert_contains "$output" "src/app.py"
  assert_contains "$output" "QA-plan gate (Bash path)"
}

@test "e2e: an in-place stream editor is caught, with no matcher for it anywhere" {
  # `perl -pi -e`, not `sed -i ''`: the empty-argument form of in-place sed is
  # BSD-only and fails on the Linux runner CI uses. Which editor it is makes no
  # difference to this gate (that is the whole point), and CI asserts perl.
  opt_in
  baseline
  perl -pi -e 's/print\(1\)/print(3)/' "$REPO/src/app.py"
  run fire "perl -pi -e s/x/y/ src/app.py"
  assert_contains "$output" '"decision":"block"'
  assert_contains "$output" "src/app.py"
}

@test "e2e: a brand-new untracked source file BLOCKS" {
  opt_in
  baseline
  printf 'x\n' > "$REPO/src/brand-new.sh"
  run fire "cat > src/brand-new.sh"
  assert_contains "$output" '"decision":"block"'
  assert_contains "$output" "src/brand-new.sh"
}

@test "e2e: deleting a tracked source file BLOCKS" {
  opt_in
  baseline
  rm "$REPO/src/app.py"
  run fire "rm src/app.py"
  assert_contains "$output" '"decision":"block"'
  assert_contains "$output" "src/app.py"
}

@test "e2e: the FIRST call on a branch only baselines, it never blocks" {
  opt_in
  printf 'print(9)\n' > "$REPO/src/app.py"   # already dirty before any call
  run fire "ls"
  [ "$output" = "" ]
  [ -f "$SNAP" ]                              # baseline was recorded
}

@test "e2e REGRESSION: a CLEAN branch still records a baseline (header-only)" {
  # The bug this pins: the snapshot writer's `[ -n "$CURR" ]` guard was the last
  # command in its group, so on a clean tree the group exited 1, the mv was
  # skipped and the temp file was removed. No baseline meant the NEXT call saw
  # BASELINE="none" and allowed, so the first source write on any clean branch
  # walked straight through. The test above did not catch it because it dirtied
  # the tree before the first call, which is exactly the case that DOES write.
  opt_in
  run fire "ls"                      # clean tree
  [ "$output" = "" ]
  [ -f "$SNAP" ]
  run cat "$SNAP"
  assert_contains "$output" "#branch feat/thing"
}

@test "e2e REGRESSION: the first source write on a clean branch BLOCKS" {
  # The user-visible consequence of the bug above, asserted end to end.
  opt_in
  fire "ls" >/dev/null 2>&1 || true   # clean-tree baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  assert_contains "$output" '"decision":"block"'
  assert_contains "$output" "src/app.py"
}

@test "e2e: pre-existing dirt does not block later calls (no block storm)" {
  opt_in
  printf 'print(9)\n' > "$REPO/src/app.py"
  baseline
  run fire "git status"
  [ "$output" = "" ]
  run fire "ls -la"
  [ "$output" = "" ]
  run fire "grep -rn foo src/"
  [ "$output" = "" ]
}

@test "e2e: a read-only command changes nothing and so cannot fire" {
  opt_in
  baseline
  run fire "cat src/app.py"
  [ "$output" = "" ]
}

@test "e2e: writing docs, config and tests does not block" {
  opt_in
  baseline
  printf 'more\n'  >> "$REPO/docs/guide.md"
  printf '{}\n'     > "$REPO/settings.json"
  printf 'y\n'     >> "$REPO/tests/test_app.py"
  run fire "tee docs/guide.md settings.json tests/test_app.py"
  [ "$output" = "" ]
}

@test "e2e: writing outside the repo (/tmp) does not block" {
  opt_in
  baseline
  printf 'x\n' > "$BATS_TEST_TMPDIR/scratch.py"
  run fire "cat > $BATS_TEST_TMPDIR/scratch.py"
  [ "$output" = "" ]
}

@test "e2e: writing a gitignored path does not block" {
  opt_in
  baseline
  mkdir -p "$REPO/build"
  printf 'x\n' > "$REPO/build/out.js"
  run fire "cat > build/out.js"
  [ "$output" = "" ]
}

@test "e2e: a second call after the same single change does not re-block" {
  opt_in
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  assert_contains "$output" '"decision":"block"'
  # The snapshot was updated on the block path, so the same delta is not replayed.
  run fire "ls"
  [ "$output" = "" ]
}

@test "e2e: a FURTHER edit to an already-dirty file blocks again" {
  opt_in
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  assert_contains "$output" '"decision":"block"'
  printf 'print(3)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  assert_contains "$output" '"decision":"block"'
}

@test "e2e: a validly stamped branch allows, and short-circuits before snapshotting" {
  opt_in
  stamp_for "feat/thing"
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  [ "$output" = "" ]
  # Pins WHICH allow this was: allow-stamped exits before the snapshot step, so
  # no snapshot file exists. An outcome-only assertion would pass for any allow.
  [ ! -f "$SNAP" ]
}

@test "e2e: on the base branch there is no feature work to gate" {
  opt_in
  git -C "$REPO" checkout -q main
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  [ "$output" = "" ]
}

@test "e2e: a spike/ branch bypasses, exactly as it does for gate 1" {
  opt_in
  git -C "$REPO" checkout -q -b spike/poke
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  [ "$output" = "" ]
}

@test "e2e: an un-governed repo (no policy) allows" {
  # No opt_in: nothing is governed, so the gate must not fire.
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  [ "$output" = "" ]
}

@test "e2e: a repo with the build gate disabled allows" {
  opt_in '{"base_branches":["main"],"gates":["pr"]}'
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  [ "$output" = "" ]
}

@test "e2e: a detached HEAD allows" {
  opt_in
  git -C "$REPO" checkout -q --detach
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  [ "$output" = "" ]
}

@test "e2e: a non-Bash tool is ignored" {
  opt_in
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run bash -c 'jq -nc --arg cwd "$1" "{hook_event_name:\"PostToolUse\", tool_name:\"Edit\", tool_input:{command:\"x\"}, cwd:\$cwd}" | bash "$2"' _ "$REPO" "$GATE"
  [ "$output" = "" ]
}

@test "e2e: a branch switch is not read as a delta" {
  opt_in
  baseline
  git -C "$REPO" checkout -q -b feat/other
  # The snapshot header records the branch it was taken on, so the other
  # branch starts from its own baseline rather than inheriting this one.
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  [ "$output" = "" ]
}

@test "e2e: the block reason states that nothing was reverted and names both exits" {
  opt_in
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  assert_contains "$output" "NOTHING HAS BEEN REVERTED"
  assert_contains "$output" "/qa:plan"
  assert_contains "$output" "spike/"
}

@test "e2e: the block reason is honest that it fired AFTER the write" {
  # The one thing this message must never imply is that it stopped anything. It
  # cannot: PostToolUse runs after the tool. Asserted positively, on the sentence
  # that carries the admission, rather than by banning phrases (a ban on "was
  # prevented" fails against the honest sentence "nothing was prevented").
  opt_in
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  assert_contains "$output" "this fires AFTER the write, so nothing was prevented"
  assert_contains "$output" "NOTHING HAS BEEN REVERTED"
}
