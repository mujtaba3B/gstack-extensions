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
  # Hermetic, and NOT rooted at ~/dev. Fixtures used to be real git repos created
  # under the maintainer's actual governed root, which leaked when a run aborted
  # (two abandoned `.qpbtest.*` repos were found sitting in ~/dev) and put test
  # repos inside the very tree these gates police. Nothing needs the real path:
  # scope.root is a policy field, so point it at the bats tmpdir instead.
  export GATE_POLICY_TEST=1
  export GATE_POLICY_FILE="$BATS_TEST_TMPDIR/gate-policy.json"
  export GATE_LOCAL_FILE="$BATS_TEST_TMPDIR/gate-local.json"
  # Isolates the audit log too, so a run never appends to the maintainer's real
  # ~/.claude/qa-plan-gate.log and the log assertions below can read it back.
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  GATELOG="$CLAUDE_CONFIG_DIR/qa-plan-gate.log"

  LIB="$BATS_TEST_DIRNAME/../scripts/qa-plan-gate-lib.sh"
  GATE="$BATS_TEST_DIRNAME/../scripts/qa-plan-bash-build-gate.sh"
  # shellcheck source=/dev/null
  . "$LIB"

  ROOT="$BATS_TEST_TMPDIR/root"
  REPO="$ROOT/repo"
  mkdir -p "$REPO"
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
  SESSION="s1"
  SNAP="$GITDIR/qa-plan-bash-snapshot-$SESSION"
}

teardown() { rm -rf "$ROOT"; }

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
  jq -nc --arg g "$1" --argjson c "$2" --arg root "$ROOT" \
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

payload() {  # <command> [cwd] [event] [session]
  jq -nc --arg c "$1" --arg cwd "${2:-$REPO}" --arg ev "${3:-PostToolUse}" \
         --arg sid "${4:-$SESSION}" \
    '{hook_event_name:$ev, tool_name:"Bash", tool_input:{command:$c}, cwd:$cwd, session_id:$sid}'
}
fire() { payload "$1" "${2:-$REPO}" "${3:-PostToolUse}" "${4:-$SESSION}" | bash "$GATE"; }

# Establish this session's baseline the way its first Bash call does.
baseline() { fire "ls" >/dev/null 2>&1 || true; }

# assert_allowed <output> <snapshot-expectation>
#   Every allow path produces empty stdout, so `[ "$output" = "" ]` alone passes
#   for the WRONG allow. Mutation-proved: deleting the detached-HEAD guard left
#   its test green, because the fall-through landed on allow-baseline, which is
#   also silent. So each allow is pinned by a snapshot side effect that
#   distinguishes WHICH arm ran:
#     snap-absent  -> exited before the snapshot step (out of scope, stamped,
#                     base branch, spike, detached, non-Bash)
#     snap-present -> reached the observe/record step and chose to allow
assert_allowed() {
  case "$1" in *'"decision":"block"'*)
    echo "assert_allowed failed: got a block" >&2; echo "  actual: $1" >&2; return 1 ;;
  esac
  case "$2" in
    snap-absent)  [ ! -f "$SNAP" ] || { echo "expected NO snapshot at $SNAP" >&2; return 1 ;} ;;
    snap-present) [ -f "$SNAP" ]   || { echo "expected a snapshot at $SNAP" >&2; return 1 ;} ;;
    *) echo "assert_allowed: bad expectation '$2'" >&2; return 1 ;;
  esac
  return 0
}

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

@test "status paths: a rename reports BOTH sides, never the 'orig -> dest' blob" {
  # Both, because a rename OUT of the source tree removes application source.
  # Taking only the destination made `git mv src/engine.py tests/helper.py`
  # vanish, since the destination is a test carve-out.
  run qpg_status_source_paths "R  src/old.py -> src/new.py"
  [ "$output" = "src/old.py
src/new.py" ]
}

@test "status paths: a rename whose destination is carved out still reports the source" {
  run qpg_status_source_paths "R  src/engine.py -> tests/engine_helper.py"
  [ "$output" = "src/engine.py" ]
}

@test "status paths: a COPY reports only the destination (the original is untouched)" {
  run qpg_status_source_paths "C  src/old.py -> src/new.py"
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

@test "status paths: a DIRECTORY entry (nested repo) is never source" {
  # `-uall` descends ordinary untracked dirs, so a trailing slash can only be a
  # nested repository the VCS refused to descend into: a linked worktree, a
  # submodule, or a parked clone. Its basename is EMPTY, which matches no
  # carve-out, so before the guard this fell through to "source" and the main
  # checkout blocked on a directory as soon as a worktree existed.
  run qpg_status_source_paths "?? .claude/worktrees/my-branch/"
  [ "$output" = "" ]
  run qpg_status_source_paths "?? vendor/some-clone/"
  [ "$output" = "" ]
}

@test "status paths: a directory entry does not mask real source on other lines" {
  run qpg_status_source_paths "?? .claude/worktrees/wt1/
 M src/real.py"
  [ "$output" = "src/real.py" ]
}

@test "status paths: unmerged conflict codes still count as source" {
  # A conflicted source file is genuinely modified; UU/AA/DD must not slip past.
  run qpg_status_source_paths "UU src/app.py"
  [ "$output" = "src/app.py" ]
  run qpg_status_source_paths "AA src/two.py"
  [ "$output" = "src/two.py" ]
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

@test "e2e: a read-only command with nothing changed does not fire" {
  # NOTE the careful name. The gate CANNOT guarantee "a read-only command never
  # fires": it reports any source change since the previous call, whoever made
  # it, so a `cat` is perfectly capable of surfacing an editor's write. The
  # earlier name claimed that guarantee and this test never checked it.
  opt_in
  baseline
  run fire "cat src/app.py"
  assert_allowed "$output" snap-present
}

@test "e2e: a read-only command DOES surface an out-of-band change (documented behavior)" {
  opt_in
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"   # as if the human's editor did it
  run fire "cat src/app.py"
  assert_contains "$output" '"decision":"block"'
  # ...and the wording must not blame the command that merely observed it.
  assert_missing "$output" "a Bash command just modified"
  assert_contains "$output" "changed since this session's previous Bash call"
}

@test "e2e: writing docs, config and tests does not block" {
  opt_in
  baseline
  printf 'more\n'  >> "$REPO/docs/guide.md"
  printf '{}\n'     > "$REPO/settings.json"
  printf 'y\n'     >> "$REPO/tests/test_app.py"
  run fire "tee docs/guide.md settings.json tests/test_app.py"
  assert_allowed "$output" snap-present
}

@test "e2e: data and build artifacts do not block" {
  # The false-positive class most likely to get the gate deleted: a repo whose
  # job is writing CSVs, a QA screenshot, a tee'd build log. Measured against the
  # real ~/dev, one repo had 15 dirty paths that were all scraped html/csv.
  opt_in
  baseline
  printf 'a,b\n1,2\n' > "$REPO/out.csv"
  printf 'PNG\n'      > "$REPO/shot.png"
  printf 'log\n'      > "$REPO/run.log"
  printf 'x\n'        > "$REPO/app.db"
  run fire "python3 report.py > out.csv; screencapture shot.png; make | tee run.log"
  assert_allowed "$output" snap-present
}

@test "e2e: writing outside the repo (/tmp) does not block" {
  opt_in
  baseline
  printf 'x\n' > "$BATS_TEST_TMPDIR/scratch.py"
  run fire "cat > $BATS_TEST_TMPDIR/scratch.py"
  assert_allowed "$output" snap-present
}

@test "e2e: a dirty submodule gitlink is skipped, not recorded as an unhashable path" {
  # The superproject reports a dirty submodule as ONE path with no trailing
  # slash, so the classifier's nested-repo rule misses it. Recording it stored
  # `- <path>` (a directory cannot be hashed), and every later edit inside the
  # already-dirty submodule produced a byte-identical line that never fired
  # again. Skipping it matches the documented rule: nested repos are governed by
  # their own hook.
  opt_in
  SUB="$ROOT/sub"
  mkdir -p "$SUB"
  git -C "$SUB" init -q
  git -C "$SUB" config user.name T
  git -C "$SUB" config user.email t@e.com
  printf 'x\n' > "$SUB/lib.py"
  git -C "$SUB" add -A
  git -C "$SUB" commit -q -m init
  git -C "$REPO" -c protocol.file.allow=always submodule add -q "$SUB" vendor/sub 2>/dev/null
  git -C "$REPO" commit -q -m "add submodule" 2>/dev/null
  baseline
  printf 'y\n' > "$REPO/vendor/sub/lib.py"    # dirty the submodule's contents
  run fire "cat > vendor/sub/lib.py"
  assert_missing "$output" '"decision":"block"'
  run cat "$SNAP"
  assert_missing "$output" "vendor/sub"
}

@test "e2e: creating a linked worktree inside the repo does not block" {
  # The real-world shape of the directory-entry bug: a worktree under
  # .claude/worktrees/ makes the MAIN checkout report one collapsed untracked
  # directory. Before the guard, the next Bash call here blocked on it.
  opt_in
  baseline
  mkdir -p "$REPO/.claude/worktrees"
  git -C "$REPO" worktree add -q -b wt-probe "$REPO/.claude/worktrees/wt-probe" >/dev/null 2>&1
  run fire "git worktree add .claude/worktrees/wt-probe"
  [ "$output" = "" ]
  git -C "$REPO" worktree remove --force "$REPO/.claude/worktrees/wt-probe" >/dev/null 2>&1 || true
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

@test "e2e: a validly stamped branch allows, but still refreshes the snapshot" {
  # It used to exit BEFORE the snapshot step as a cost saving. That left the
  # snapshot stale for the whole approved window, so the moment the stamp lapsed
  # (every human-override stamp is TTL-bounded, and approval-expired is a real
  # verdict) the next command, even a bare `ls`, blocked naming every file the
  # human had already approved, advising them to undo it. Refreshing here costs
  # one write and removes that entirely.
  opt_in
  stamp_for "feat/thing"
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  assert_allowed "$output" snap-present
  run cat "$SNAP"
  assert_contains "$output" "src/app.py"
}

@test "e2e REGRESSION: a lapsed stamp does not dump the approved window as a block" {
  opt_in
  stamp_for "feat/thing"
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  printf 'x\n'        > "$REPO/src/b.py"
  fire "cat > src/app.py" >/dev/null 2>&1 || true   # allowed, and recorded
  rm -f "$GITDIR/qa-plan-approved"                   # the stamp lapses
  run fire "ls"                                      # a read-only command
  assert_allowed "$output" snap-present
}

@test "e2e: on the base branch there is no feature work to gate" {
  opt_in
  git -C "$REPO" checkout -q main
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  assert_allowed "$output" snap-absent
}

@test "e2e: a spike/ branch bypasses, exactly as it does for gate 1" {
  opt_in
  git -C "$REPO" checkout -q -b spike/poke
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  assert_allowed "$output" snap-absent
}

@test "e2e: an un-governed repo (no policy) allows" {
  # No opt_in: nothing is governed, so the gate must not fire.
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  assert_allowed "$output" snap-absent
}

@test "e2e: a repo with the build gate disabled allows" {
  opt_in '{"base_branches":["main"],"gates":["pr"]}'
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  assert_allowed "$output" snap-absent
}

@test "e2e: a detached HEAD allows, and exits before snapshotting" {
  # Proved by mutation: deleting the detached guard left this test green, because
  # the fall-through landed on allow-baseline, which is equally silent. The
  # snapshot discriminator is what makes the assertion real.
  opt_in
  git -C "$REPO" checkout -q --detach
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  assert_allowed "$output" snap-absent
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

@test "e2e: a new source file inside a NEW untracked directory BLOCKS" {
  # Pins `-uall`. Dropping it collapses the new directory to one `src/newmod/`
  # entry, which the trailing-slash guard then drops, so the whole directory is
  # SILENTLY ALLOWED. Creating a new module through a heredoc is the most common
  # build shape this gate exists for, and the mutation was previously uncaught.
  opt_in
  baseline
  mkdir -p "$REPO/src/newmod"
  printf 'x\n' > "$REPO/src/newmod/thing.py"
  run fire "mkdir -p src/newmod && cat > src/newmod/thing.py"
  assert_contains "$output" '"decision":"block"'
  assert_contains "$output" "src/newmod/thing.py"
}

@test "e2e: the block payload is VALID JSON on stdout alone" {
  # Every other block test greps a merged stdout+stderr stream, so a stray stdout
  # line left all 54 green while the runtime saw unparseable JSON and the block
  # silently became a no-op. Parse it the way the harness does.
  opt_in
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run bash -c 'payload=$(jq -nc --arg c "cat > src/app.py" --arg cwd "$1" --arg sid "$2" \
      "{hook_event_name:\"PostToolUse\", tool_name:\"Bash\", tool_input:{command:\$c}, cwd:\$cwd, session_id:\$sid}"); \
      printf "%s" "$payload" | bash "$3" 2>/dev/null | jq -er ".decision"' \
    _ "$REPO" "$SESSION" "$GATE"
  [ "$status" -eq 0 ]
  [ "$output" = "block" ]
}

@test "e2e: PostToolUseFailure is honored, so a write-then-fail cannot escape" {
  # PostToolUse fires only for a SUCCESSFUL call, so `sed -i src/app.py && npm
  # test` with a failing test wrote source and the gate never ran. Verified
  # against CLI 2.1.261 that PostToolUseFailure fires for a non-zero Bash call.
  opt_in
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "sed -i '' s/x/y/ src/app.py && npm test" "$REPO" "PostToolUseFailure"
  assert_contains "$output" '"decision":"block"'
  assert_contains "$output" "src/app.py"
}

@test "e2e: an unknown hook event is ignored" {
  opt_in
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py" "$REPO" "SomeOtherEvent"
  [ "$output" = "" ]
}

# Cross the >200 dirty-source-path threshold, which is the reachable way to force
# the degraded comparison mode. (Hiding shasum via PATH also hides git, so the
# gate exits long before the degrade and the test proves nothing: that mistake
# made the first version of these two tests pass for the wrong reason.)
make_many_source_files() {  # <n>
  local i
  mkdir -p "$REPO/src/bulk"
  for ((i = 0; i < $1; i++)); do printf 'x\n' > "$REPO/src/bulk/f$i.py"; done
}

@test "e2e REGRESSION: a degrade-mode flip re-baselines instead of blocking on everything" {
  # Degraded lines are `- <path>` and normal lines are `<digest> <path>`, so when
  # the mode flips EVERY line differs verbatim and the delta reported every dirty
  # path at once. Reproduced: a bare `ls` blocked naming 200 files. The mode now
  # lives in the snapshot header, so a flip reads as "no baseline".
  opt_in
  printf 'print(2)\n' > "$REPO/src/app.py"
  baseline                                   # digest-mode snapshot
  run cat "$SNAP"
  assert_contains "$output" "mode=digest"
  make_many_source_files 205                 # crosses the cap -> paths mode
  run fire "ls"                              # a READ-ONLY command
  assert_missing "$output" '"decision":"block"'
  run cat "$SNAP"
  assert_contains "$output" "mode=paths"
}

@test "e2e: the degrade is LOGGED, never silent" {
  # The PR's whole answer to "we never no-op silently" had zero coverage: the
  # logging could be deleted outright and the suite stayed green.
  opt_in
  make_many_source_files 205
  run fire "ls"
  run cat "$GATELOG"
  assert_contains "$output" "delta-degraded"
  assert_contains "$output" "too-many-paths=20"
}

@test "e2e: a failing git status is logged rather than silently ungating" {
  # `status` exits non-zero on a corrupt index or a safe.directory refusal, and
  # the refusal is PERSISTENT, so the gate would be permanently and invisibly off
  # while the docs claim coverage.
  opt_in
  baseline
  printf 'corrupt' > "$GITDIR/index"
  run fire "cat > src/app.py"
  [ "$output" = "" ]
  run cat "$GATELOG"
  assert_contains "$output" "FAIL-OPEN(status-failed)"
}

@test "e2e REGRESSION: an unwritable git dir does not cause a block storm" {
  # Reproduced before the fix: call 1 blocked correctly and EVERY later call,
  # `ls` included, reblocked forever with no explanation. That is the exact
  # failure the unconditional snapshot write exists to prevent.
  opt_in
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  chmod a-w "$GITDIR"
  run fire "cat > src/app.py"
  chmod u+w "$GITDIR"
  assert_contains "$output" '"decision":"block"'
  # The block must say WHY it will repeat, instead of leaving it inexplicable.
  assert_contains "$output" "could not record state"
  run cat "$GATELOG"
  assert_contains "$output" "snapshot-write-failed"
}

@test "e2e: two sessions in one checkout do not consume each other's delta" {
  # The inversion this keying fixes: with one shared snapshot, whichever hook
  # fired first ate the delta, so the INNOCENT session was blocked for the
  # other's write and the WRITING session was never blocked at all.
  opt_in
  fire "ls" "$REPO" "PostToolUse" "sessA" >/dev/null 2>&1 || true
  fire "ls" "$REPO" "PostToolUse" "sessB" >/dev/null 2>&1 || true
  printf 'print(2)\n' > "$REPO/src/app.py"      # session A writes
  run fire "cat > src/app.py" "$REPO" "PostToolUse" "sessA"
  assert_contains "$output" '"decision":"block"'   # A is told, correctly
  run fire "ls" "$REPO" "PostToolUse" "sessB"
  assert_contains "$output" '"decision":"block"'   # B sees it too, once
  run fire "ls" "$REPO" "PostToolUse" "sessB"
  assert_missing "$output" '"decision":"block"'    # and not again
}

@test "e2e: a cd inside a heredoc body does not redirect repo resolution" {
  # The extraction ran per-line over the whole command, so a `cd` on ANY line
  # won. A heredoc writing a shell script whose body contains `cd /tmp`
  # retargeted the gate to /tmp, where rev-parse fails and the call exits
  # ungated. Writing shell scripts through heredocs is this gate's own use case.
  opt_in
  baseline
  printf 'cd /tmp\n' > "$REPO/src/deploy.sh"
  run fire "cat > src/deploy.sh <<'EOF'
cd /tmp
EOF"
  assert_contains "$output" '"decision":"block"'
  assert_contains "$output" "src/deploy.sh"
}

@test "e2e: a non-default verdict reaches the message (not only no-stamp)" {
  opt_in
  stamp_for "feat/some-other-branch"
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "cat > src/app.py"
  assert_contains "$output" '"decision":"block"'
  assert_contains "$output" "wrong-branch"
}

@test "e2e: git mv of source into a test path still blocks" {
  # Only the rename DESTINATION used to be classified, and a test path is a
  # carve-out, so removing application source vanished entirely.
  opt_in
  baseline
  git -C "$REPO" mv src/app.py tests/app_helper.py
  run fire "git mv src/app.py tests/app_helper.py"
  assert_contains "$output" '"decision":"block"'
  assert_contains "$output" "src/app.py"
}

@test "e2e: staging a file does not by itself produce a block" {
  # `git add` changes the porcelain XY columns but not the path or the digest,
  # so it must be a no-op here. Pins that the status columns stay out of the
  # snapshot line.
  opt_in
  printf 'print(2)\n' > "$REPO/src/app.py"
  baseline
  git -C "$REPO" add src/app.py
  run fire "git add src/app.py"
  assert_allowed "$output" snap-present
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
  assert_contains "$output" "it fires AFTER the write, so nothing was prevented"
  assert_contains "$output" "NOTHING HAS BEEN REVERTED"
}

@test "e2e: the block reason warns that a git tree operation may be a false alarm" {
  # The old remediation said "undo it yourself" unconditionally. After a stash
  # pop, merge, rebase or apply, following that destroys work, and those are
  # exactly the operations that produce a large sudden delta.
  opt_in
  baseline
  printf 'print(2)\n' > "$REPO/src/app.py"
  run fire "git stash pop"
  assert_contains "$output" "stash pop, merge, rebase"
  assert_contains "$output" "should NOT undo anything"
}

# ============================================================================
# Classifier: data / build artifacts (shared with gate 1)
# ============================================================================

@test "path: data and build artifacts are carved out" {
  for f in out.csv data.tsv db.sqlite3 shot.png logo.svg run.log bundle.tar.gz .DS_Store; do
    run qpg_path_needs_plan "some/dir/$f"
    [ "$output" = "carveout" ]
  done
}

@test "path: real source is still source after the artifact carve-out" {
  for f in main.py app.ts server.go lib.rs Makefile deploy.sh; do
    run qpg_path_needs_plan "src/$f"
    [ "$output" = "source" ]
  done
}
