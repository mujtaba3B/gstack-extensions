#!/usr/bin/env bats
# Integration tests for the deploy-gate.sh PreToolUse hook. Drives the real hook
# with sample payloads and asserts allow (silent, exit 0) vs block (decision JSON
# on stdout), plus the two ARM events. Temp repos must live under ~/dev because
# the gate is scoped to that tree; they are removed in teardown.
#
# The load-bearing case is "blocks the 2026-07-24 command": the hand-rolled ssh
# deploy that skipped the upgrade-marker stamp and crash-looped the mini for
# 16h46m. If that test ever goes green-by-allowing, the gate has lost its point.

setup() {
  # Hermetic: pin the gate-policy lookup at a path that cannot exist, so these
  # tests exercise the MARKER-FALLBACK contract (a machine with no gate policy)
  # deterministically, instead of inheriting whatever ~/dev/gate-policy.json this
  # machine happens to carry. Inheritance-by-default is covered end-to-end in
  # gate-inheritance.bats.
  export GATE_POLICY_FILE="$BATS_TEST_TMPDIR/no-such-gate-policy.json"
  export GATE_LOCAL_FILE="$BATS_TEST_TMPDIR/no-such-gate-local.json"
  GATE="$BATS_TEST_DIRNAME/../scripts/deploy-gate.sh"
  mkdir -p "$HOME/dev"   # hermetic on clean runners: the gate scopes to ~/dev
  REPO=$(mktemp -d "$HOME/dev/.dgtest.XXXXXX")
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Test User"
  git -C "$REPO" config user.email "t@example.com"
  git -C "$REPO" commit -q --allow-empty -m init
  SESSION="dgtest-$$-${BATS_TEST_NUMBER:-0}"
  ARMFILE="${TMPDIR:-/tmp}/gstack-deploy-armed-${SESSION}"
  LANDARM="${TMPDIR:-/tmp}/gstack-land-armed-${SESSION}"
  PFILE="$REPO/.payload.json"
}

teardown() {
  rm -rf "$REPO"
  rm -f "$ARMFILE" "$LANDARM" 2>/dev/null || true
}

# --- payload builders -------------------------------------------------------
# Built with jq, not printf: the commands under test carry single quotes, nested
# quotes, and `&&`, which a hand-rolled printf template mangles into a payload
# that no longer represents the command (an early version of this file silently
# tested backslash-mangled strings and "passed" the ssh cases by allowing them).
bash_payload() {
  jq -nc --arg cmd "$1" --arg cwd "${2:-$REPO}" --arg sid "$SESSION" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd,session_id:$sid}'
}
skill_payload() {
  jq -nc --arg s "$1" --arg cwd "$REPO" --arg sid "$SESSION" \
    '{hook_event_name:"PreToolUse",tool_name:"Skill",tool_input:{skill:$s},cwd:$cwd,session_id:$sid}'
}
prompt_payload() {
  jq -nc --arg p "$1" --arg cwd "$REPO" --arg sid "$SESSION" \
    '{hook_event_name:"UserPromptSubmit",prompt:$p,cwd:$cwd,session_id:$sid}'
}

# --- fixtures ---------------------------------------------------------------

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
opt_in()        { gp_write_policy deploy '{"hosts":["mutwos-mac-mini","mini"]}'; }
opt_in_nohost() { gp_write_policy deploy '{"hosts":[]}'; }
deploy_json()   { printf '{"deploy":{"command":"scripts/deploy.sh"}}' > "$REPO/deploy.json"; }

# Pipe from a file so no shell quoting layer sits between the payload and the hook.
feed()     { printf '%s' "$1" > "$PFILE"; run bash -c "bash '$2' < '$PFILE'"; }
run_gate() { feed "$1" "$GATE"; }
assert_allow() { [ "$status" -eq 0 ]; [ -z "$output" ]; }
assert_block() { [ "$status" -eq 0 ]; echo "$output" | grep -q '"decision":"block"'; }

# =========================== allow: out of scope =============================

@test "allow: a non-deploy command is ignored" {
  opt_in; deploy_json
  run_gate "$(bash_payload "git status")"
  assert_allow
}

@test "allow: deploy command in a non-dev repo (out of scope)" {
  run_gate "$(bash_payload "cd /tmp && scripts/deploy.sh" "/tmp")"
  assert_allow
}

@test "allow: ~/dev repo not covered by any gate policy (fails open)" {
  deploy_json
  run_gate "$(bash_payload "scripts/deploy.sh")"
  assert_allow
}

# =========================== block: tier 1, entrypoint =======================

@test "block: opted-in repo, bare scripts/deploy.sh, unarmed" {
  opt_in; deploy_json
  run_gate "$(bash_payload "scripts/deploy.sh")"
  assert_block
}

@test "block: ./scripts/deploy.sh with flags, unarmed" {
  opt_in; deploy_json
  run_gate "$(bash_payload "./scripts/deploy.sh --rebuild-base --rederive-all")"
  assert_block
}

@test "block: deploy-mini.sh invoked directly, unarmed" {
  opt_in; deploy_json
  run_gate "$(bash_payload "bash scripts/deploy-mini.sh")"
  assert_block
}

@test "block: entrypoint after a leading cd into the repo" {
  opt_in; deploy_json
  run_gate "$(bash_payload "cd $REPO && scripts/deploy.sh" "/tmp")"
  assert_block
}

# =========================== allow: read-only entrypoint =====================

@test "allow: scripts/deploy.sh check, even unarmed" {
  opt_in; deploy_json
  run_gate "$(bash_payload "scripts/deploy.sh check")"
  assert_allow
}

@test "allow: scripts/deploy.sh --status, even unarmed" {
  opt_in; deploy_json
  run_gate "$(bash_payload "scripts/deploy.sh --status")"
  assert_allow
}

@test "allow: a read-only flag later in the same invocation" {
  opt_in; deploy_json
  run_gate "$(bash_payload "scripts/deploy.sh --force --dry-run")"
  assert_allow
}

# --- regressions: the read-only escape must not be a bypass ------------------
# Caught in review. The escape originally tested for the bare word `check`
# ANYWHERE in the command, so chaining a real deploy to a check read as
# read-only and deployed straight past the gate.

@test "block: a real deploy chained to a check is NOT read-only" {
  opt_in; deploy_json
  run_gate "$(bash_payload "scripts/deploy.sh && devops check")"
  assert_block
}

@test "block: a real deploy followed by a check after a semicolon" {
  opt_in; deploy_json
  run_gate "$(bash_payload "scripts/deploy.sh; devops check")"
  assert_block
}

@test "block: the word check in a trailing comment is not read-only" {
  opt_in; deploy_json
  run_gate "$(bash_payload "scripts/deploy.sh --force # check the mini after")"
  assert_block
}

# --- regressions: the trailing boundary must accept shell separators ---------
# Also caught in review. With a whitespace-or-end-only boundary, a deploy
# immediately followed by a separator was not recognized as a deploy at all.

@test "block: entrypoint immediately followed by a semicolon" {
  opt_in; deploy_json
  run_gate "$(bash_payload "scripts/deploy.sh;echo done")"
  assert_block
}

@test "block: entrypoint immediately followed by && (no space)" {
  opt_in; deploy_json
  run_gate "$(bash_payload "scripts/deploy.sh&&echo done")"
  assert_block
}

@test "block: entrypoint inside a subshell" {
  opt_in; deploy_json
  run_gate "$(bash_payload "(scripts/deploy.sh)")"
  assert_block
}

# =========================== degraded inputs still gate ======================
# The gate fails OPEN on missing dependencies, but a malformed or thin config is
# not a missing dependency: it must still gate, or a corrupt marker would
# silently disarm the repo.

@test "block: a repo with only scripts/deploy.sh and no deploy.json still gates" {
  # Applicability is derived. A repo that deploys WITHOUT a deploy.json is exactly
  # the ungated-deployer shape of the 2026-07-24 incident, so the conventional
  # script name counts on its own.
  opt_in
  rm -f "$REPO/deploy.json"
  mkdir -p "$REPO/scripts" && : > "$REPO/scripts/deploy.sh"
  feed "$(bash_payload 'scripts/deploy.sh')" "$GATE"
  printf '%s' "$output" | grep -q '"block"'
}

@test "block: no deploy.json still gates (falls back to scripts/deploy.sh)" {
  opt_in
  run_gate "$(bash_payload "scripts/deploy.sh")"
  assert_block
}

@test "gates a custom entrypoint declared in deploy.json, and only that one" {
  opt_in
  printf '{"deploy":{"command":"bin/ship-it"}}' > "$REPO/deploy.json"
  run_gate "$(bash_payload "bin/ship-it --now")"
  assert_block
  # A repo that declares bin/ship-it should not also gate an unrelated
  # scripts/deploy.sh it does not use.
  run_gate "$(bash_payload "scripts/deploy.sh")"
  assert_allow
}

@test "the allow path writes nothing to stdout (hook protocol)" {
  # Any stray stdout would be parsed as a hook decision. This fires on every
  # Bash call in every ~/dev repo, so a single stray byte is a fleet-wide bug.
  #
  # Assert on FILE SIZE, not on captured output: bats strips trailing newlines
  # from $output, so a lone stray "\n" would read as empty. Piping through `od`
  # is also wrong here, GNU od prints an offset line for empty input while BSD od
  # prints nothing, which passed on macOS and failed in CI.
  opt_in; deploy_json
  printf '%s' "$(bash_payload "git status")" > "$PFILE"
  bash "$GATE" < "$PFILE" > "$REPO/.stdout" 2>/dev/null
  [ ! -s "$REPO/.stdout" ]
}

# =========================== block: tier 2, the hand-roll ====================

@test "block: the 2026-07-24 hand-rolled ssh deploy" {
  opt_in; deploy_json
  run_gate "$(bash_payload "ssh mutwos-mac-mini 'cd ~/nanoclaw && git pull --ff-only && pnpm run build'")"
  assert_block
}

@test "block: ssh + launchctl kickstart" {
  opt_in; deploy_json
  run_gate "$(bash_payload "ssh mini 'launchctl kickstart -k gui/501/com.nanoclaw'")"
  assert_block
}

@test "block: ssh + systemctl --user restart" {
  opt_in; deploy_json
  run_gate "$(bash_payload "ssh mutwos-mac-mini 'systemctl --user restart nanoclaw'")"
  assert_block
}

# =========================== allow: read-only ssh ============================

@test "allow: ssh + launchctl list (read-only verb)" {
  opt_in; deploy_json
  run_gate "$(bash_payload "ssh mutwos-mac-mini 'launchctl list | grep com.nanoclaw'")"
  assert_allow
}

@test "allow: ssh + tail logs (read-only verb)" {
  opt_in; deploy_json
  run_gate "$(bash_payload "ssh mutwos-mac-mini 'tail -50 ~/nanoclaw/logs/nanoclaw.log'")"
  assert_allow
}

@test "allow: a local build with no ssh is not a deploy" {
  opt_in; deploy_json
  run_gate "$(bash_payload "pnpm run build")"
  assert_allow
}

@test "allow: ssh to a host the marker does not list" {
  opt_in; deploy_json
  run_gate "$(bash_payload "ssh some-other-box 'cd ~/app && git pull && pnpm run build'")"
  assert_allow
}

@test "allow: tier 2 disabled when hosts is empty (entrypoint still gated)" {
  opt_in_nohost; deploy_json
  run_gate "$(bash_payload "ssh mutwos-mac-mini 'cd ~/nanoclaw && git pull && pnpm run build'")"
  assert_allow
  run_gate "$(bash_payload "scripts/deploy.sh")"
  assert_block
}

# --- regressions from the CodeRabbit review on #64 ---------------------------
# All three were verified failing against the real mutwo checkout before the fix.
# Note CodeRabbit marked the first two "addressed" on commit activity alone while
# they were still live, so each of these asserts the behavior, not the label.

@test "block: an override string embedded in a quoted payload is NOT a bypass" {
  # The gate defeat: as a bare substring search, the literal text
  # DEPLOY_GATE_OVERRIDE=x anywhere in the command authorized the bypass with no
  # variable ever being set, including inside the exact hand-rolled ssh this gate
  # exists to block.
  opt_in; deploy_json
  run_gate "$(bash_payload "ssh mutwos-mac-mini \"git commit -m 'DEPLOY_GATE_OVERRIDE=oops' && git pull && pnpm run build\"")"
  assert_block
}

@test "block: a real deploy chained after a read-only one" {
  # Judged per invocation. A single regex over the whole command read this as
  # read-only on the strength of the FIRST invocation's flag.
  opt_in; deploy_json
  run_gate "$(bash_payload "scripts/deploy.sh --dry-run && scripts/deploy.sh --force")"
  assert_block
}

@test "allow: a verb-prefixed word is not a mutating verb" {
  # `pnpm run builder` / `git pull-request` are not `pnpm run build` / `git pull`.
  opt_in; deploy_json
  run_gate "$(bash_payload "ssh mutwos-mac-mini 'pnpm run builder'")"
  assert_allow
  run_gate "$(bash_payload "ssh mutwos-mac-mini 'echo git pull-request'")"
  assert_allow
}

@test "allow: a local command chained after a read-only ssh" {
  # The mutating verb must run ON THE HOST. Here `git pull` is local, and the ssh
  # payload is read-only, so this is not a hand-rolled deploy.
  opt_in; deploy_json
  run_gate "$(bash_payload "ssh mutwos-mac-mini 'tail -50 log' ; git pull")"
  assert_allow
}

@test "block: the quoted ssh payload survives segment splitting" {
  # The separators inside the quotes are part of the REMOTE command. A
  # quote-blind splitter cut there and lost the mutating verb.
  opt_in; deploy_json
  run_gate "$(bash_payload "ssh mutwos-mac-mini 'cd ~/nanoclaw && git pull --ff-only && pnpm run build'")"
  assert_block
}

@test "block: ssh flags before the host still resolve the host" {
  opt_in; deploy_json
  run_gate "$(bash_payload "ssh -p 22 mutwos-mac-mini 'git pull'")"
  assert_block
}

@test "allow: a listed host name appearing outside the ssh target" {
  # The host is read from the ssh invocation's own target token, not searched for
  # across the whole command.
  opt_in; deploy_json
  run_gate "$(bash_payload "ssh some-other-box 'cd /srv/mutwos-mac-mini && git pull && pnpm run build'")"
  assert_allow
}

# =========================== arming ==========================================

@test "arm: a Skill invocation of land-and-deploy allows the entrypoint" {
  opt_in; deploy_json
  printf '%s' "$(skill_payload "land-and-deploy")" | bash "$GATE"
  [ -f "$ARMFILE" ]
  run_gate "$(bash_payload "scripts/deploy.sh")"
  assert_allow
}

@test "arm: a Skill invocation of eng:deploy allows the hand-rolled shape" {
  opt_in; deploy_json
  printf '%s' "$(skill_payload "eng:deploy")" | bash "$GATE"
  [ -f "$ARMFILE" ]
  run_gate "$(bash_payload "ssh mutwos-mac-mini 'cd ~/nanoclaw && git pull && pnpm run build'")"
  assert_allow
}

@test "arm: a typed /eng:deploy prompt arms the session" {
  opt_in; deploy_json
  printf '%s' "$(prompt_payload "/eng:deploy")" | bash "$GATE"
  [ -f "$ARMFILE" ]
  run_gate "$(bash_payload "scripts/deploy.sh")"
  assert_allow
}

@test "arm: prose mentioning the skill does NOT arm" {
  opt_in; deploy_json
  printf '%s' "$(prompt_payload "should I /eng:deploy this?")" | bash "$GATE"
  [ ! -f "$ARMFILE" ]
  run_gate "$(bash_payload "scripts/deploy.sh")"
  assert_block
}

@test "arm: an unrelated skill does NOT arm" {
  opt_in; deploy_json
  printf '%s' "$(skill_payload "eng:cr")" | bash "$GATE"
  [ ! -f "$ARMFILE" ]
  run_gate "$(bash_payload "scripts/deploy.sh")"
  assert_block
}

@test "arm: a stale arm marker does not authorize a deploy" {
  opt_in; deploy_json
  printf '%s\n' "$(( $(date +%s) - 99999 ))" > "$ARMFILE"
  run_gate "$(bash_payload "scripts/deploy.sh")"
  assert_block
}

# =========================== break-glass =====================================

@test "allow: DEPLOY_GATE_OVERRIDE with a reason" {
  opt_in; deploy_json
  run_gate "$(bash_payload "DEPLOY_GATE_OVERRIDE='host wedged, emergency' scripts/deploy.sh")"
  assert_allow
}

@test "block: DEPLOY_GATE_OVERRIDE with an empty reason is not an override" {
  opt_in; deploy_json
  run_gate "$(bash_payload "DEPLOY_GATE_OVERRIDE= scripts/deploy.sh")"
  assert_block
}

# =========================== no merge-authority leak =========================

@test "the deploy arm mints no merge clearance (no authority leak)" {
  # The whole reason deploy-gate arms its OWN kind: a deploy-only ceremony must
  # never be able to authorize `gh pr merge`. The merge gate keys on the
  # land-deploy-clearance sentinel, which land-deploy-sentinel.sh mints on a Bash
  # `gh pr merge` ONLY while a "land" arm is fresh. So the precise assertion is:
  # after /eng:deploy, the deploy arm exists, the land arm does not, and driving
  # the real sentinel with a merge command mints nothing.
  #
  # Asserting on the sentinel rather than on pr-merge-gate's verdict is
  # deliberate: that gate fails OPEN when it cannot resolve a PR, so against a
  # fixture repo with no remote it would return "allow" for reasons unrelated to
  # arming, and the test would prove nothing.
  SENTINEL_WRITER="$BATS_TEST_DIRNAME/../scripts/land-deploy-sentinel.sh"
  GITDIR=$(git -C "$REPO" rev-parse --absolute-git-dir)

  printf '%s' "$(skill_payload "eng:deploy")" | bash "$GATE"
  [ -f "$ARMFILE" ]
  [ ! -f "$LANDARM" ]

  feed "$(bash_payload "cd $REPO && gh pr merge")" "$SENTINEL_WRITER"
  [ "$status" -eq 0 ]
  [ ! -f "$GITDIR/land-deploy-clearance" ]
}

@test "a land-and-deploy skill arms BOTH kinds (it does deploy)" {
  # The converse: /land-and-deploy legitimately deploys, so it must arm the
  # deploy kind too, or the gate would block the ceremony's own deploy step.
  printf '%s' "$(skill_payload "land-and-deploy")" | bash "$GATE"
  printf '%s' "$(skill_payload "land-and-deploy")" | bash "$BATS_TEST_DIRNAME/../scripts/land-deploy-sentinel.sh"
  [ -f "$ARMFILE" ]
  [ -f "$LANDARM" ]
}
