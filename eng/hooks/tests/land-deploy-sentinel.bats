#!/usr/bin/env bats
# Tests for land-deploy-sentinel.sh: the writer that mints the
# <gitdir>/land-deploy-clearance sentinel when /land-and-deploy is invoked. Drives
# the real hook with synthetic Skill / UserPromptSubmit payloads and asserts the
# sentinel file is (or is not) written, and that it is target-bound (head_sha).
# Temp repos live under ~/dev because the hook scopes to that tree.

setup() {
  # Hermetic: pin the gate-policy lookup at a path that cannot exist, so these
  # tests exercise the MARKER-FALLBACK contract (a machine with no gate policy)
  # deterministically, instead of inheriting whatever ~/dev/gate-policy.json this
  # machine happens to carry. Inheritance-by-default is covered end-to-end in
  # gate-inheritance.bats.
  export GATE_POLICY_FILE="$BATS_TEST_TMPDIR/no-such-gate-policy.json"
  export GATE_LOCAL_FILE="$BATS_TEST_TMPDIR/no-such-gate-local.json"
  WRITER="$BATS_TEST_DIRNAME/../scripts/land-deploy-sentinel.sh"
  mkdir -p "$HOME/dev"
  REPO=$(mktemp -d "$HOME/dev/.ldtest.XXXXXX")
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Test User"
  git -C "$REPO" config user.email "t@example.com"
  git -C "$REPO" remote add origin "https://github.com/owner/name.git"
  git -C "$REPO" commit -q --allow-empty -m init
  HEAD=$(git -C "$REPO" rev-parse HEAD)
  GITDIR=$(git -C "$REPO" rev-parse --absolute-git-dir)
  SENTINEL="$GITDIR/land-deploy-clearance"
}

teardown() {
  rm -rf "$REPO"
  rm -f "${TMPDIR:-/tmp}"/gstack-land-armed-ldtest-* 2>/dev/null || true
}

skill_payload()  { printf '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"%s"},"cwd":"%s"}' "$1" "$REPO"; }
prompt_payload() { printf '{"hook_event_name":"UserPromptSubmit","prompt":"%s","cwd":"%s"}' "$1" "$REPO"; }

@test "writes a sentinel on a Skill invocation of land-and-deploy" {
  printf '%s' "$(skill_payload "land-and-deploy")" | bash "$WRITER"
  [ -f "$SENTINEL" ]
  [ "$(jq -r .head_sha "$SENTINEL")" = "$HEAD" ]
  [ "$(jq -r .repo "$SENTINEL")" = "owner/name" ]
  [ "$(jq -r .source "$SENTINEL")" = "skill" ]
}

@test "writes a sentinel on a namespaced skill id (eng:land-and-deploy)" {
  printf '%s' "$(skill_payload "eng:land-and-deploy")" | bash "$WRITER"
  [ -f "$SENTINEL" ]
  [ "$(jq -r .head_sha "$SENTINEL")" = "$HEAD" ]
}

@test "writes a sentinel on a prompt starting with /land-and-deploy" {
  printf '%s' "$(prompt_payload "/land-and-deploy")" | bash "$WRITER"
  [ -f "$SENTINEL" ]
  [ "$(jq -r .source "$SENTINEL")" = "prompt" ]
}

@test "captures the PR number from the prompt args (#123)" {
  printf '%s' "$(prompt_payload "/land-and-deploy #123 https://x.test")" | bash "$WRITER"
  [ -f "$SENTINEL" ]
  [ "$(jq -r .pr_number "$SENTINEL")" = "123" ]
}

@test "does NOT capture stray digits from prose args (only a #-prefixed token)" {
  printf '%s' "$(prompt_payload "/land-and-deploy v2 ship it now")" | bash "$WRITER"
  [ -f "$SENTINEL" ]
  [ "$(jq -r .pr_number "$SENTINEL")" = "" ]
}

@test "does NOT capture path digits from a bare URL arg" {
  printf '%s' "$(prompt_payload "/land-and-deploy https://github.com/owner/name/pull/77")" | bash "$WRITER"
  [ -f "$SENTINEL" ]
  [ "$(jq -r .pr_number "$SENTINEL")" = "" ]
}

@test "does NOT write for a different skill" {
  printf '%s' "$(skill_payload "ship")" | bash "$WRITER"
  [ ! -f "$SENTINEL" ]
}

@test "does NOT write when the prompt only mentions the command mid-sentence" {
  printf '%s' "$(prompt_payload "should I use /land-and-deploy here?")" | bash "$WRITER"
  [ ! -f "$SENTINEL" ]
}

@test "does NOT write for /land-and-deployer (whole-token match)" {
  printf '%s' "$(prompt_payload "/land-and-deployer")" | bash "$WRITER"
  [ ! -f "$SENTINEL" ]
}

@test "does NOT write for a repo outside ~/dev" {
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/ldout.XXXXXX")
  git -C "$OUT" init -q
  git -C "$OUT" commit -q --allow-empty -m init
  payload=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"land-and-deploy"},"cwd":"%s"}' "$OUT")
  printf '%s' "$payload" | bash "$WRITER"
  outgit=$(git -C "$OUT" rev-parse --absolute-git-dir)
  [ ! -f "$outgit/land-deploy-clearance" ]
  rm -rf "$OUT"
}

@test "sentinel always exits 0 and never emits stdout (it is the gate's input, not a gate)" {
  run bash -c "printf '%s' '$(skill_payload "land-and-deploy")' | bash '$WRITER'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- ARMED Bash target-mint path (the cwd-vs-target fix) ---------------------

armed_skill_payload()   { printf '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"%s"},"cwd":"%s","session_id":"%s"}' "$1" "$2" "$3"; }
sentinel_bash_payload() { printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s","session_id":"%s"}' "$1" "$2" "$3"; }

@test "armed mint: /land-and-deploy from a cwd OUTSIDE the target repo, then cd into it, mints target-bound sentinel (the bug repro)" {
  SID="ldtest-$BATS_TEST_NUMBER"
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/ldout.XXXXXX")   # session cwd, not a ~/dev repo
  bash -c "printf '%s' '$(armed_skill_payload "land-and-deploy" "$OUT" "$SID")' | bash '$WRITER'"
  [ ! -f "$SENTINEL" ]   # cwd was not the target repo -> nothing minted yet
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $REPO && gh pr merge 45 --squash" "$OUT" "$SID")' | bash '$WRITER'"
  [ -f "$SENTINEL" ]
  [ "$(jq -r .head_sha "$SENTINEL")" = "$HEAD" ]      # bound to the TARGET checkout's HEAD
  [ "$(jq -r .repo "$SENTINEL")" = "owner/name" ]     # repo read from the TARGET origin
  [ "$(jq -r .pr_number "$SENTINEL")" = "45" ]        # PR parsed from the merge command
  [ "$(jq -r .source "$SENTINEL")" = "land-bash" ]
  rm -rf "$OUT"
}

@test "armed mint: UNARMED bash cd+merge mints nothing (accident-guard intact)" {
  SID="ldtest-$BATS_TEST_NUMBER"
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $REPO && gh pr merge 45" "$HOME" "$SID")' | bash '$WRITER'"
  [ ! -f "$SENTINEL" ]
}

@test "armed mint: a non-land skill does NOT arm the merge path" {
  SID="ldtest-$BATS_TEST_NUMBER"
  bash -c "printf '%s' '$(armed_skill_payload "ship" "$HOME" "$SID")' | bash '$WRITER'"
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $REPO && gh pr merge 45" "$HOME" "$SID")' | bash '$WRITER'"
  [ ! -f "$SENTINEL" ]
}

@test "armed mint: armed cd into a NON-dev repo mints nothing (scope held)" {
  SID="ldtest-$BATS_TEST_NUMBER"
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/ldout.XXXXXX")
  git -C "$OUT" init -q
  git -C "$OUT" config user.name "Test User"
  git -C "$OUT" config user.email "t@example.com"
  git -C "$OUT" commit -q --allow-empty -m init
  outgit=$(git -C "$OUT" rev-parse --absolute-git-dir)
  bash -c "printf '%s' '$(armed_skill_payload "land-and-deploy" "$HOME" "$SID")' | bash '$WRITER'"
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $OUT && gh pr merge 45" "$HOME" "$SID")' | bash '$WRITER'"
  [ ! -f "$outgit/land-deploy-clearance" ]
  rm -rf "$OUT"
}

@test "armed mint: an EXPIRED arm marker does not mint (stale /land-and-deploy window closed)" {
  # Prove this tests EXPIRY, not an absent marker: a FRESH marker at the same path
  # DOES mint, then aging it past ARM_TTL (1800s) stops the mint.
  SID="ldtest-$BATS_TEST_NUMBER"
  ARM="${TMPDIR:-/tmp}/gstack-land-armed-$SID"
  NOWS=$(date +%s)
  printf '%s\n' "$NOWS" > "$ARM"                        # fresh -> mints
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $REPO && gh pr merge 45" "$HOME" "$SID")' | bash '$WRITER'"
  [ -f "$SENTINEL" ]
  rm -f "$SENTINEL"
  printf '%s\n' "$((NOWS-4000))" > "$ARM"               # same path, now expired -> no mint
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $REPO && gh pr merge 45" "$HOME" "$SID")' | bash '$WRITER'"
  [ ! -f "$SENTINEL" ]
  rm -f "$ARM"
}

# ---- sliding arm window (mirrors the ship-gate long-run fix) ----------------

@test "armed mint: an armed Bash command SLIDES the land arm window forward (long /land-and-deploy stays armed past ARM_TTL)" {
  # Same long-run fix as ship-gate-sentinel.sh: the arm marker used to be written
  # once at invocation and never refreshed, so ARM_TTL(1800s) later the Bash-mint
  # went inert and the head_sha-bound sentinel froze - a /land-and-deploy longer than
  # the window found it stale at merge time. Now every armed Bash command that mints
  # into the target repo re-arms the session. Assert the slide directly.
  SID="ldtest-$BATS_TEST_NUMBER"
  ARM="${TMPDIR:-/tmp}/gstack-land-armed-$SID"
  NOWS=$(date +%s)
  printf '%s\n' "$((NOWS-1700))" > "$ARM"     # armed 1700s ago: still fresh (<1800), near lapsing
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $REPO && git status" "$HOME" "$SID")' | bash '$WRITER'"
  [ -f "$SENTINEL" ]                          # minted into the target repo
  [ "$(head -1 "$ARM")" -ge "$((NOWS-10))" ]  # land arm window slid forward to ~now (was T-1700)
  rm -f "$ARM"
}

@test "armed mint: an EXPIRED land arm marker neither mints nor self-arms (slide only extends a live window)" {
  # The slide must not resurrect a dead merge window: under an expired arm marker a
  # Bash command must not mint AND must not re-arm, so an abandoned /land-and-deploy
  # cannot keep authorizing merges.
  SID="ldtest-$BATS_TEST_NUMBER"
  ARM="${TMPDIR:-/tmp}/gstack-land-armed-$SID"
  NOWS=$(date +%s)
  printf '%s\n' "$((NOWS-4000))" > "$ARM"     # expired (age 4000 > ARM_TTL 1800)
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $REPO && git status" "$HOME" "$SID")' | bash '$WRITER'"
  [ ! -f "$SENTINEL" ]                         # did not mint
  [ "$(head -1 "$ARM")" = "$((NOWS-4000))" ]   # arm marker unchanged: no self-arm
  rm -f "$ARM"
}

@test "armed mint: an armed Bash command OUT of ~/dev scope does NOT slide the land arm window (the return-1 guard)" {
  # Pins the mint `return 0`->`return 1` flip: an armed, still-fresh session running a
  # Bash command that resolves OUTSIDE ~/dev must NOT re-arm, so the window stays
  # bound to genuine target-repo activity. Arm at a distinctly OLDER time so a
  # wrongful slide (to ~now) is detectable; a regression to `return 0` would silently
  # re-arm off any out-of-scope Bash activity and this test would catch it.
  SID="ldtest-$BATS_TEST_NUMBER"
  ARM="${TMPDIR:-/tmp}/gstack-land-armed-$SID"
  NOWS=$(date +%s)
  OUT=$(mktemp -d "/tmp/.ldtestout.XXXXXX")
  git -C "$OUT" init -q; git -C "$OUT" commit -q --allow-empty -m init
  OUTGIT=$(git -C "$OUT" rev-parse --absolute-git-dir)
  printf '%s\n' "$((NOWS-1700))" > "$ARM"     # armed, fresh, near-lapse
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $OUT && git status" "$HOME" "$SID")' | bash '$WRITER'"
  [ ! -f "$OUTGIT/land-deploy-clearance" ]     # out of scope -> not minted
  [ "$(head -1 "$ARM")" = "$((NOWS-1700))" ]   # arm marker UNCHANGED: no slide out of scope
  rm -rf "$OUT"; rm -f "$ARM"
}
