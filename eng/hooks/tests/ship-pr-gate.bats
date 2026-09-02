#!/usr/bin/env bats
# Tests for the ship-PR gate: the pure validator (sg_sentinel_valid), the gate
# hook (ship-pr-gate.sh), and the sentinel writer (ship-gate-sentinel.sh).
# Temp repos live under ~/dev because the gate is scoped to that tree; removed in
# teardown.

setup() {
  # Hermetic: pin the gate-policy lookup at a path that cannot exist, so these
  # tests exercise the MARKER-FALLBACK contract (a machine with no gate policy)
  # deterministically, instead of inheriting whatever ~/dev/gate-policy.json this
  # machine happens to carry. Inheritance-by-default is covered end-to-end in
  # gate-inheritance.bats.
  export GATE_POLICY_FILE="$BATS_TEST_TMPDIR/no-such-gate-policy.json"
  export GATE_LOCAL_FILE="$BATS_TEST_TMPDIR/no-such-gate-local.json"
  LIB="$BATS_TEST_DIRNAME/../scripts/ship-pr-gate-lib.sh"
  GATE="$BATS_TEST_DIRNAME/../scripts/ship-pr-gate.sh"
  SENTINEL_HOOK="$BATS_TEST_DIRNAME/../scripts/ship-gate-sentinel.sh"
  # shellcheck source=/dev/null
  . "$LIB"
  REPO=$(mktemp -d "$HOME/dev/.sgtest.XXXXXX")
  git -C "$REPO" init -q
  git -C "$REPO" commit -q --allow-empty -m init
  GITDIR=$(git -C "$REPO" rev-parse --absolute-git-dir)
  NOW=$(date +%s)
  TTL=1200
}

teardown() {
  rm -rf "$REPO" "${REPO2:-/nonexistent}"
  rm -f "${TMPDIR:-/tmp}"/gstack-ship-armed-sgtest-* 2>/dev/null || true
}

# ---- helpers ----------------------------------------------------------------

sentinel() {
  # sentinel <epoch> [ttl] [trigger]
  local e="$1" t="${2:-1200}" tr="${3:-skill}"
  printf '{"set_at_epoch":%s,"ttl_seconds":%s,"trigger":"%s"}' "$e" "$t" "$tr"
}
write_sentinel() { sentinel "$@" > "$GITDIR/ship-pr-clearance"; }
bash_payload()   { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

# Arming is now a POLICY write, not a marker file. Markers were dropped entirely on
# 2026-09-02: a machine-local, git-ignored file that arms enforcement is what
# produced the worktree hole. `opt_in` keeps its meaning (this repo is governed);
# only the mechanism changed, so every test below reads the same.
# With no policy written, nothing is governed, which preserves the "allow" cases.
gp_write_policy() {  # <gate> <config-json>
  mkdir -p "$(dirname "$GATE_POLICY_FILE")"
  jq -nc --arg g "$1" --argjson c "$2" --arg root "$HOME/dev" \
    '{scope:{root:$root, exclude_path_prefixes:[], exclude_nested:false},
      defaults:{($g): $c}, overrides:{}}' > "$GATE_POLICY_FILE"
}
opt_in()         { gp_write_policy ship '{"base_branches":["main"]}'; }

# ========================================================================
# Pure validator: sg_sentinel_valid <json> <now> <default_ttl>
# ========================================================================

@test "validator: fresh sentinel within default ttl -> valid" {
  run sg_sentinel_valid "$(sentinel $((NOW-60)))" "$NOW" "$TTL"
  [ "$output" = "valid" ]; [ "$status" -eq 0 ]
}

@test "validator: empty sentinel -> no-sentinel" {
  run sg_sentinel_valid "" "$NOW" "$TTL"
  [ "$output" = "no-sentinel" ]; [ "$status" -eq 1 ]
}

@test "validator: corrupt json -> malformed" {
  run sg_sentinel_valid '{not json' "$NOW" "$TTL"
  [ "$output" = "malformed" ]; [ "$status" -eq 1 ]
}

@test "validator: non-numeric epoch -> malformed" {
  run sg_sentinel_valid '{"set_at_epoch":"soon","ttl_seconds":1200}' "$NOW" "$TTL"
  [ "$output" = "malformed" ]; [ "$status" -eq 1 ]
}

@test "validator: aged past ttl -> expired (slow /ship run that overran)" {
  run sg_sentinel_valid "$(sentinel $((NOW-1300)) 1200)" "$NOW" "$TTL"
  [ "$output" = "expired" ]; [ "$status" -eq 1 ]
}

@test "validator: sentinel's own ttl wins over default (longer window honored)" {
  # default ttl would expire it; the sentinel's larger ttl keeps it valid.
  run sg_sentinel_valid "$(sentinel $((NOW-400)) 1800)" "$NOW" 300
  [ "$output" = "valid" ]; [ "$status" -eq 0 ]
}

@test "validator: future-dated sentinel (negative age) -> expired" {
  run sg_sentinel_valid "$(sentinel $((NOW+5000)))" "$NOW" "$TTL"
  [ "$output" = "expired" ]; [ "$status" -eq 1 ]
}

@test "validator: sentinel with NO ttl_seconds uses the default_ttl (fresh -> valid)" {
  # The writer can emit a sentinel whose ttl came from a malformed marker (absent);
  # freshness then rides entirely on the caller default. Exercise that fallback.
  run sg_sentinel_valid "{\"set_at_epoch\":$((NOW-100))}" "$NOW" "$TTL"
  [ "$output" = "valid" ]; [ "$status" -eq 0 ]
}

@test "validator: sentinel with NO ttl_seconds, aged past default_ttl -> expired" {
  run sg_sentinel_valid "{\"set_at_epoch\":$((NOW-1300))}" "$NOW" "$TTL"
  [ "$output" = "expired" ]; [ "$status" -eq 1 ]
}

@test "validator: non-positive ttl_seconds (0) falls back to default_ttl" {
  run sg_sentinel_valid "$(sentinel $((NOW-100)) 0)" "$NOW" "$TTL"
  [ "$output" = "valid" ]; [ "$status" -eq 0 ]
}

# ========================================================================
# Gate hook: ship-pr-gate.sh
# ========================================================================

@test "gate allow: non-create command is ignored" {
  run bash -c "printf '%s' '$(bash_payload "git status")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "gate allow: gh pr create in a non-dev repo (out of scope)" {
  run bash -c "printf '%s' '$(bash_payload "cd /tmp && gh pr create --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "gate allow: ~/dev repo not covered by any gate policy" {
  run bash -c "printf '%s' '$(bash_payload "cd $REPO && gh pr create --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "gate block: opted-in repo with no sentinel" {
  opt_in
  run bash -c "printf '%s' '$(bash_payload "cd $REPO && gh pr create --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "gate allow: opted-in repo with a fresh sentinel" {
  opt_in; write_sentinel "$NOW"
  run bash -c "printf '%s' '$(bash_payload "cd $REPO && gh pr create --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "gate block: opted-in repo with an expired sentinel" {
  opt_in; write_sentinel "$((NOW-1300))" 1200
  run bash -c "printf '%s' '$(bash_payload "cd $REPO && gh pr create --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "gate block: bare gh pr create with NO --base gates (load-bearing default)" {
  # The most security-load-bearing branch: a create with no base cannot be
  # scope-checked, so it must gate, not allow.
  opt_in
  run bash -c "printf '%s' '$(bash_payload "cd $REPO && gh pr create")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "gate allow: an unparseable gate policy fails OPEN and is logged" {
  # Contract change (2026-09-02): config moved from a per-repo marker to ONE tracked
  # policy file. A corrupt marker could fail closed because it only affected that
  # repo; a corrupt policy affects every repo at once, so failing closed would wedge
  # all work everywhere. It fails open and the session-start drift check announces it.
  opt_in
  printf '{ this is not valid json' > "$GATE_POLICY_FILE"
  export GATE_POLICY_LOG="$BATS_TEST_TMPDIR/policy.log"
  run bash -c "printf '%s' '$(bash_payload "cd $REPO && gh pr create --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  grep -q "FAIL-OPEN policy file unparseable" "$GATE_POLICY_LOG"
}

@test "gate allow: trigger phrase inside a quoted string is not command position" {
  opt_in
  run bash -c "printf '%s' '$(bash_payload "cd $REPO; echo run gh pr create later")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "gate block: env-var prefix before gh is still caught" {
  opt_in
  run bash -c "printf '%s' '$(bash_payload "cd $REPO && GH_TOKEN=x gh pr create --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "gate block: absolute path to gh is still caught" {
  opt_in
  run bash -c "printf '%s' '$(bash_payload "cd $REPO && /opt/homebrew/bin/gh pr create --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "gate allow: base branch out of scope (marker restricts to main, create targets dev)" {
  echo '{"base_branches":["main"]}' > "$REPO/.ship-gate.json"
  run bash -c "printf '%s' '$(bash_payload "cd $REPO && gh pr create --base dev")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "gate: cd into a DIFFERENT opted-in repo is evaluated against THAT repo (Codex case)" {
  # The sentinel lives in REPO, but the command cd's into REPO2. The gate must
  # resolve REPO2 and find no sentinel there -> block (not silently pass on REPO's).
  opt_in; write_sentinel "$NOW"
  REPO2=$(mktemp -d "$HOME/dev/.sgtest2.XXXXXX")
  git -C "$REPO2" init -q; git -C "$REPO2" commit -q --allow-empty -m init
  echo '{"base_branches":["main"]}' > "$REPO2/.ship-gate.json"
  run bash -c "printf '%s' '$(bash_payload "cd $REPO2 && gh pr create --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "gate block: --repo targeting another repo with no sentinel still blocks (defense in depth)" {
  # The cross-repo guard's gh-resolve path needs a real remote (skipped offline in
  # a bare temp repo), but a --repo create with no local sentinel must block anyway
  # via the no-sentinel path: a bare cross-repo create is never silently allowed.
  opt_in
  run bash -c "printf '%s' '$(bash_payload "cd $REPO && gh pr create --repo other/repo --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "gate: linked worktree sentinel does not bleed from the main checkout (Codex case)" {
  # A sentinel in the main repo's git dir must NOT clear a create run from a
  # linked worktree (separate absolute-git-dir).
  opt_in; write_sentinel "$NOW"
  WT=$(mktemp -d "$HOME/dev/.sgtestwt.XXXXXX"); rm -rf "$WT"
  git -C "$REPO" worktree add -q "$WT" -b wt-branch
  echo '{"base_branches":["main"]}' > "$WT/.ship-gate.json"
  run bash -c "printf '%s' '$(bash_payload "cd $WT && gh pr create --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
  git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
}

@test "gate fail-open: malformed payload (no command) is allowed silently" {
  run bash -c "printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{}}' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

# ========================================================================
# Sentinel writer: ship-gate-sentinel.sh
# ========================================================================

skill_payload()  { printf '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"%s"},"cwd":"%s"}' "$1" "$2"; }
prompt_payload() { printf '{"hook_event_name":"UserPromptSubmit","prompt":"%s","cwd":"%s"}' "$1" "$2"; }

@test "writer: Skill PreToolUse for ship writes a fresh valid sentinel" {
  run bash -c "printf '%s' '$(skill_payload "ship" "$REPO")' | bash '$SENTINEL_HOOK'"
  [ "$status" -eq 0 ]
  [ -f "$GITDIR/ship-pr-clearance" ]
  run sg_sentinel_valid "$(cat "$GITDIR/ship-pr-clearance")" "$(date +%s)" "$TTL"
  [ "$output" = "valid" ]
}

@test "writer: Skill PreToolUse for a non-ship skill writes nothing" {
  run bash -c "printf '%s' '$(skill_payload "review" "$REPO")' | bash '$SENTINEL_HOOK'"
  [ "$status" -eq 0 ]
  [ ! -f "$GITDIR/ship-pr-clearance" ]
}

@test "writer: namespaced skill form plugin:ship writes a sentinel" {
  # The harness skill key format is version-dependent; the glob ship|*:ship|*/ship
  # must accept the namespaced/path forms or it would false-block every real /ship.
  run bash -c "printf '%s' '$(skill_payload "gstack:ship" "$REPO")' | bash '$SENTINEL_HOOK'"
  [ "$status" -eq 0 ]
  [ -f "$GITDIR/ship-pr-clearance" ]
}

@test "writer: look-alike skill (shipment / ownership) writes nothing" {
  run bash -c "printf '%s' '$(skill_payload "shipment" "$REPO")' | bash '$SENTINEL_HOOK'"
  [ "$status" -eq 0 ]
  [ ! -f "$GITDIR/ship-pr-clearance" ]
}

@test "writer: prompt starting with /ship writes a sentinel" {
  run bash -c "printf '%s' '$(prompt_payload "/ship it" "$REPO")' | bash '$SENTINEL_HOOK'"
  [ "$status" -eq 0 ]
  [ -f "$GITDIR/ship-pr-clearance" ]
}

@test "writer: prompt merely MENTIONING /ship mid-sentence writes nothing" {
  run bash -c "printf '%s' '$(prompt_payload "should I use /ship here?" "$REPO")' | bash '$SENTINEL_HOOK'"
  [ "$status" -eq 0 ]
  [ ! -f "$GITDIR/ship-pr-clearance" ]
}

@test "writer: ship invoked outside ~/dev writes nothing" {
  OUT=$(mktemp -d "/tmp/.sgtestout.XXXXXX")
  git -C "$OUT" init -q; git -C "$OUT" commit -q --allow-empty -m init
  OUTGIT=$(git -C "$OUT" rev-parse --absolute-git-dir)
  run bash -c "printf '%s' '$(skill_payload "ship" "$OUT")' | bash '$SENTINEL_HOOK'"
  [ "$status" -eq 0 ]
  [ ! -f "$OUTGIT/ship-pr-clearance" ]
  rm -rf "$OUT"
}

@test "writer + gate end to end: ship invocation then create is allowed" {
  opt_in
  bash -c "printf '%s' '$(skill_payload "ship" "$REPO")' | bash '$SENTINEL_HOOK'"
  run bash -c "printf '%s' '$(bash_payload "cd $REPO && gh pr create --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

# ========================================================================
# Sentinel writer: ARMED Bash target-mint path (the cwd-vs-target fix)
# ========================================================================

armed_skill_payload()   { printf '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"%s"},"cwd":"%s","session_id":"%s"}' "$1" "$2" "$3"; }
sentinel_bash_payload() { printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s","session_id":"%s"}' "$1" "$2" "$3"; }

@test "armed mint: /ship from a cwd OUTSIDE the target repo, then cd into it, mints + gate allows (the bug repro)" {
  # THE bug: session cwd is not the target repo (here: a non-~/dev tmp dir). The
  # Skill event arms the session but cannot direct-mint (cwd is not a dev repo);
  # the later armed `cd $REPO && gh pr create` mints into $REPO's git dir.
  opt_in
  SID="sgtest-$BATS_TEST_NUMBER"
  OUT=$(mktemp -d "/tmp/.sgtestout.XXXXXX")
  bash -c "printf '%s' '$(armed_skill_payload "ship" "$OUT" "$SID")' | bash '$SENTINEL_HOOK'"
  [ ! -f "$GITDIR/ship-pr-clearance" ]   # cwd was not the target repo -> not minted yet
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $REPO && gh pr create --base main" "$OUT" "$SID")' | bash '$SENTINEL_HOOK'"
  [ -f "$GITDIR/ship-pr-clearance" ]      # armed Bash cd into target minted it
  run bash -c "printf '%s' '$(bash_payload "cd $REPO && gh pr create --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  rm -rf "$OUT"
}

@test "armed mint: UNARMED bash cd+create mints nothing (accident-guard intact)" {
  # No prior /ship in this session -> the Bash path must not mint, so the gate
  # blocks an improvised create.
  opt_in
  SID="sgtest-$BATS_TEST_NUMBER"
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $REPO && gh pr create --base main" "$HOME" "$SID")' | bash '$SENTINEL_HOOK'"
  [ ! -f "$GITDIR/ship-pr-clearance" ]
  run bash -c "printf '%s' '$(bash_payload "cd $REPO && gh pr create --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "armed mint: a non-ship skill does NOT arm the session" {
  # Only /ship arms. A different skill (review) must leave the Bash path inert.
  opt_in
  SID="sgtest-$BATS_TEST_NUMBER"
  bash -c "printf '%s' '$(armed_skill_payload "review" "$HOME" "$SID")' | bash '$SENTINEL_HOOK'"
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $REPO && gh pr create --base main" "$HOME" "$SID")' | bash '$SENTINEL_HOOK'"
  [ ! -f "$GITDIR/ship-pr-clearance" ]
}

@test "armed mint: armed cd into a NON-dev repo mints nothing (scope held)" {
  SID="sgtest-$BATS_TEST_NUMBER"
  OUT=$(mktemp -d "/tmp/.sgtestout.XXXXXX")
  git -C "$OUT" init -q; git -C "$OUT" commit -q --allow-empty -m init
  OUTGIT=$(git -C "$OUT" rev-parse --absolute-git-dir)
  bash -c "printf '%s' '$(armed_skill_payload "ship" "$HOME" "$SID")' | bash '$SENTINEL_HOOK'"
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $OUT && gh pr create --base main" "$HOME" "$SID")' | bash '$SENTINEL_HOOK'"
  [ ! -f "$OUTGIT/ship-pr-clearance" ]
  rm -rf "$OUT"
}

@test "armed mint: an EXPIRED arm marker does not mint (stale /ship window closed)" {
  # The ARM_TTL freshness branch in session_armed_fresh: a /ship from long ago must
  # not keep authorizing the Bash mint path. To prove this tests EXPIRY (not merely
  # an absent marker), first show a FRESH marker at the same path DOES mint, then
  # that aging it past ARM_TTL (1200s) stops the mint.
  opt_in
  SID="sgtest-$BATS_TEST_NUMBER"
  ARM="${TMPDIR:-/tmp}/gstack-ship-armed-$SID"
  NOWS=$(date +%s)
  printf '%s\n' "$NOWS" > "$ARM"                         # fresh -> mints
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $REPO && gh pr create --base main" "$HOME" "$SID")' | bash '$SENTINEL_HOOK'"
  [ -f "$GITDIR/ship-pr-clearance" ]
  rm -f "$GITDIR/ship-pr-clearance"
  printf '%s\n' "$((NOWS-3000))" > "$ARM"                # same path, now expired -> no mint
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $REPO && gh pr create --base main" "$HOME" "$SID")' | bash '$SENTINEL_HOOK'"
  [ ! -f "$GITDIR/ship-pr-clearance" ]
  rm -f "$ARM"
}

@test "armed mint: empty session_id disables the Bash path (no shared arm file collision)" {
  # arm_file must refuse an empty/sanitized-to-blank session id, so a session with
  # no id cannot mint off another session's arm (or a shared 'gstack-ship-armed-_').
  opt_in
  SID="sgtest-$BATS_TEST_NUMBER"
  bash -c "printf '%s' '$(armed_skill_payload "ship" "$HOME" "$SID")' | bash '$SENTINEL_HOOK'"
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $REPO && gh pr create --base main" "$HOME" "")' | bash '$SENTINEL_HOOK'"
  [ ! -f "$GITDIR/ship-pr-clearance" ]
}

@test "armed mint: armed Bash with NO cd mints for the session cwd when it is the target repo" {
  # /ship armed; a bare `gh pr create` (no cd) falls back to the payload cwd, which
  # here IS the target repo -> mint there.
  opt_in
  SID="sgtest-$BATS_TEST_NUMBER"
  bash -c "printf '%s' '$(armed_skill_payload "ship" "$REPO" "$SID")' | bash '$SENTINEL_HOOK'"
  rm -f "$GITDIR/ship-pr-clearance"   # drop the Skill-event direct mint to isolate the Bash path
  bash -c "printf '%s' '$(sentinel_bash_payload "gh pr create --base main" "$REPO" "$SID")' | bash '$SENTINEL_HOOK'"
  [ -f "$GITDIR/ship-pr-clearance" ]
}

# ---- sliding arm window (the long-ship fix) --------------------------------

@test "armed mint: an armed Bash command SLIDES the arm window forward (long /ship stays armed past the initial ARM_TTL)" {
  # THE long-ship fix. The arm marker used to be written once at /ship invocation and
  # never refreshed, so ARM_TTL(1200s) later the Bash-mint went inert, the sentinel
  # froze at its last mint, and any /ship whose invocation->create span exceeded the
  # TTL found it expired (the 2026-07-21 mutwo-skills incident). Now every armed Bash
  # command that mints into the target repo re-arms the session, so an actively-
  # working /ship keeps itself armed. Assert the slide directly: an arm marker near
  # expiry is advanced to ~now by a mint.
  opt_in
  SID="sgtest-$BATS_TEST_NUMBER"
  ARM="${TMPDIR:-/tmp}/gstack-ship-armed-$SID"
  NOWS=$(date +%s)
  printf '%s\n' "$((NOWS-1100))" > "$ARM"     # armed 1100s ago: still fresh (<1200), 100s from lapsing
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $REPO && git status" "$HOME" "$SID")' | bash '$SENTINEL_HOOK'"
  [ -f "$GITDIR/ship-pr-clearance" ]          # minted into the target repo
  [ "$(head -1 "$ARM")" -ge "$((NOWS-10))" ]  # arm window slid forward to ~now (was T-1100)
  rm -f "$ARM"
}

@test "armed mint + gate: a stale sentinel from early in a long run is refreshed by a later armed Bash command -> create allowed (incident repro)" {
  # Reproduces the incident end to end: the FIRST mint has since expired, yet the
  # session is still armed and running repo commands. A later armed Bash command must
  # re-mint a fresh sentinel so the eventual `gh pr create` PASSES instead of the
  # blocking [sentinel: expired] observed in the field.
  opt_in
  SID="sgtest-$BATS_TEST_NUMBER"
  ARM="${TMPDIR:-/tmp}/gstack-ship-armed-$SID"
  NOWS=$(date +%s)
  write_sentinel "$((NOWS-3000))" 1200        # an early mint, now long expired
  run bash -c "printf '%s' '$(bash_payload "cd $REPO && gh pr create --base main")' | bash '$GATE'"
  echo "$output" | grep -q '"decision":"block"'   # stale sentinel blocks: the bug's symptom
  printf '%s\n' "$NOWS" > "$ARM"              # session still armed (slid by ongoing repo work)
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $REPO && git status" "$HOME" "$SID")' | bash '$SENTINEL_HOOK'"
  run bash -c "printf '%s' '$(bash_payload "cd $REPO && gh pr create --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]       # refreshed sentinel -> allowed
  rm -f "$ARM"
}

@test "armed mint: an EXPIRED arm marker neither mints nor self-arms (slide only extends a live window)" {
  # The slide must not resurrect a dead window: under an expired arm marker a Bash
  # command must not mint AND must not re-arm, so an abandoned /ship (idle > ARM_TTL)
  # cannot keep authorizing creates. This is the accident-guard backstop for sliding.
  opt_in
  SID="sgtest-$BATS_TEST_NUMBER"
  ARM="${TMPDIR:-/tmp}/gstack-ship-armed-$SID"
  NOWS=$(date +%s)
  printf '%s\n' "$((NOWS-3000))" > "$ARM"     # expired (age 3000 > ARM_TTL 1200)
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $REPO && git status" "$HOME" "$SID")' | bash '$SENTINEL_HOOK'"
  [ ! -f "$GITDIR/ship-pr-clearance" ]         # did not mint
  [ "$(head -1 "$ARM")" = "$((NOWS-3000))" ]   # arm marker unchanged: no self-arm
  rm -f "$ARM"
}

@test "armed mint: an armed Bash command OUT of ~/dev scope does NOT slide the arm window (the return-1 guard)" {
  # Pins the mint_for_dir `return 0`->`return 1` flip, the whole mechanism gating the
  # slide: an armed, still-fresh session running a Bash command that resolves OUTSIDE
  # ~/dev must NOT re-arm, so the window stays bound to genuine target-repo activity.
  # Arm at a distinctly OLDER time so a wrongful slide (to ~now) is detectable; a
  # regression to `return 0` would silently re-arm off any out-of-scope Bash activity
  # and this test would catch it (the "non-dev repo mints nothing" test cannot: it
  # arms at ~now, so a bad slide to ~now is invisible).
  SID="sgtest-$BATS_TEST_NUMBER"
  ARM="${TMPDIR:-/tmp}/gstack-ship-armed-$SID"
  NOWS=$(date +%s)
  OUT=$(mktemp -d "/tmp/.sgtestout.XXXXXX")
  git -C "$OUT" init -q; git -C "$OUT" commit -q --allow-empty -m init
  OUTGIT=$(git -C "$OUT" rev-parse --absolute-git-dir)
  printf '%s\n' "$((NOWS-1100))" > "$ARM"     # armed, fresh, near-lapse
  bash -c "printf '%s' '$(sentinel_bash_payload "cd $OUT && git status" "$HOME" "$SID")' | bash '$SENTINEL_HOOK'"
  [ ! -f "$OUTGIT/ship-pr-clearance" ]         # out of scope -> not minted
  [ "$(head -1 "$ARM")" = "$((NOWS-1100))" ]   # arm marker UNCHANGED: no slide out of scope
  rm -rf "$OUT"; rm -f "$ARM"
}

# ========================================================================
# Out-of-~/dev binding: a `gh pr create --repo <gated-repo>` run from a cwd
# OUTSIDE ~/dev (e.g. a session anchored in a Google Drive folder) must still be
# gated for the repo it names. Helpers live in ship-gate-repo-lib.sh.
# ========================================================================

@test "repo-lib: sg_norm_repo normalizes URL / scp / host-prefixed / case / trailing-slash to owner/name" {
  . "$BATS_TEST_DIRNAME/../scripts/ship-gate-repo-lib.sh"
  [ "$(sg_norm_repo "https://github.com/Owner/Name.git")" = "owner/name" ]
  [ "$(sg_norm_repo "git@github.com:Owner/Name.git")" = "owner/name" ]
  [ "$(sg_norm_repo "ssh://git@github.com/Owner/Name.git")" = "owner/name" ]
  [ "$(sg_norm_repo "Owner/Name")" = "owner/name" ]
  # regressions the review found: trailing slash after .git, uppercase scheme, host-prefixed form
  [ "$(sg_norm_repo "https://github.com/o/n.git/")" = "o/n" ]
  [ "$(sg_norm_repo "HTTPS://github.com/O/N.git")" = "o/n" ]
  [ "$(sg_norm_repo "github.com/owner/name")" = "owner/name" ]
  # a repo name containing a dot must survive (only a trailing .git is stripped)
  [ "$(sg_norm_repo "owner/repo.js")" = "owner/repo.js" ]
}

@test "repo-lib: sg_repo_from_flags reads --repo / --repo= / -R / -RX / GH_REPO=, last wins, else 1" {
  . "$BATS_TEST_DIRNAME/../scripts/ship-gate-repo-lib.sh"
  [ "$(sg_repo_from_flags "gh pr create --repo owner/name --base main")" = "owner/name" ]
  [ "$(sg_repo_from_flags "gh pr create --repo=owner/name")" = "owner/name" ]
  [ "$(sg_repo_from_flags "gh pr create -R owner/name")" = "owner/name" ]
  [ "$(sg_repo_from_flags "gh pr create -Rowner/name")" = "owner/name" ]
  [ "$(sg_repo_from_flags "GH_REPO=owner/name gh pr create --base main")" = "owner/name" ]
  # last --repo wins, mirroring gh (an earlier decoy must not shadow the real target)
  [ "$(sg_repo_from_flags "gh pr create --repo owner/decoy --repo owner/real")" = "owner/real" ]
  run sg_repo_from_flags "gh pr create --base main"
  [ "$status" -eq 1 ]; [ -z "$output" ]
}

@test "gate block: --repo names a gated ~/dev repo, create run from OUTSIDE ~/dev, no sentinel -> block" {
  opt_in
  git -C "$REPO" remote add origin "https://github.com/sgtest-owner/sgtest-repo.git"
  run bash -c "cd /tmp && printf '%s' '$(bash_payload "gh pr create --repo sgtest-owner/sgtest-repo --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "gate block: compact -Rowner/repo (no space) from OUTSIDE ~/dev binds and blocks" {
  opt_in
  git -C "$REPO" remote add origin "https://github.com/sgtest-owner/sgtest-repo.git"
  run bash -c "cd /tmp && printf '%s' '$(bash_payload "gh pr create -Rsgtest-owner/sgtest-repo --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "gate block: host-prefixed --repo github.com/owner/repo from OUTSIDE ~/dev binds and blocks" {
  opt_in
  git -C "$REPO" remote add origin "https://github.com/sgtest-owner/sgtest-repo.git"
  run bash -c "cd /tmp && printf '%s' '$(bash_payload "gh pr create --repo github.com/sgtest-owner/sgtest-repo --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}

@test "gate allow: --repo names a gated ~/dev repo from OUTSIDE ~/dev WITH a fresh sentinel" {
  opt_in
  git -C "$REPO" remote add origin "https://github.com/sgtest-owner/sgtest-repo.git"
  write_sentinel "$NOW"
  run bash -c "cd /tmp && printf '%s' '$(bash_payload "gh pr create --repo sgtest-owner/sgtest-repo --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "gate allow: --repo names a repo with NO gated ~/dev checkout -> out of scope" {
  run bash -c "cd /tmp && printf '%s' '$(bash_payload "gh pr create --repo nobody/nowhere-sgtest --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "gate allow: bare create (no --repo) from OUTSIDE ~/dev stays out of scope" {
  run bash -c "cd /tmp && printf '%s' '$(bash_payload "gh pr create --base main")' | bash '$GATE'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "block: an EMPTY env-var prefix before gh pr create is still caught" {
  # Regression, paired with the same case in pr-merge-gate.bats. The shared
  # command-position prefix required a non-empty assignment value, so
  # `FOO= gh pr create` matched neither the env-prefixed branch nor the bare one
  # and sailed past every gate carrying that matcher. Each consumer gets its own
  # case so copy drift cannot reopen the bypass in only one of them.
  opt_in
  run bash -c "printf '%s' '$(bash_payload "cd $REPO && FOO= gh pr create")' | bash '$GATE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
}
