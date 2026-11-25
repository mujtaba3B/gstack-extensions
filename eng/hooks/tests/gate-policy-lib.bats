#!/usr/bin/env bats
# Unit tests for gate-policy-lib.sh: the inheritance model that replaced
# marker-presence-as-the-switch. Every case here is a real hole that shipped.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../scripts/gate-policy-lib.sh"
  ROOT="$(mktemp -d)"
  export GATE_POLICY_TEST=1   # env overrides are honored only in test mode
  export GATE_POLICY_FILE="$ROOT/policy.json"
  export GATE_LOCAL_FILE="$ROOT/local.json"
  export GATE_POLICY_LOG="$ROOT/policy.log"
  cat > "$GATE_POLICY_FILE" <<JSON
{
  "scope": {
    "root": "$ROOT/dev",
    "owners": ["mujtaba3B", "DxAngels"],
    "exclude_path_prefixes": ["legacy/"],
    "exclude_nested": true
  },
  "defaults": {
    "ship": { "base_branches": ["main"], "ttl_seconds": 1200 },
    "qa-plan": { "gates": ["build","pr","deploy"] },
    "deploy": { "hosts": [], "required_checks": [] }
  },
  "overrides": {
    "mujtaba3b/tuned": { "deploy": { "required_checks": ["tests"] } }
  }
}
JSON
  cat > "$GATE_LOCAL_FILE" <<'JSON'
{ "repos": { "DxAngels/*": { "skip_dimensions": ["coderabbit"], "reason": "CR not installed" } } }
JSON
  # shellcheck source=/dev/null
  . "$LIB"
  mkdir -p "$ROOT/dev"
}

teardown() { rm -rf "$ROOT"; }

# mkrepo <relpath> <origin-url>
mkrepo() {
  local d="$ROOT/dev/$1"
  mkdir -p "$d" && git -C "$d" init -q 2>/dev/null
  git -C "$d" remote add origin "$2"
  printf '%s' "$d"
}

@test "identity comes from the origin remote, normalized lowercase" {
  d=$(mkrepo plain https://github.com/mujtaba3B/plain.git)
  run gp_repo_identity "$d"
  [ "$status" -eq 0 ]
  [ "$output" = "mujtaba3b/plain" ]
}

@test "a repo with NO marker is gated (the inheritance inversion)" {
  d=$(mkrepo plain https://github.com/mujtaba3B/plain.git)
  [ ! -f "$d/.ship-gate.json" ]
  run gp_gate_config "$d" ship
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ttl_seconds":1200'
}

@test "an override is matched case-insensitively and beats the default" {
  d=$(mkrepo tuned https://github.com/mujtaba3B/tuned.git)
  run gp_gate_config "$d" deploy
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"required_checks":\["tests"\]'
}

@test "a stray marker file on disk has NO effect (markers are gone)" {
  # Markers were dropped entirely on 2026-09-02. A leftover one from before the
  # migration must not quietly re-acquire authority over the tracked policy.
  d=$(mkrepo tuned https://github.com/mujtaba3B/tuned.git)
  echo '{"required_checks":["from-marker"]}' > "$d/.deploy-gate.json"
  run gp_gate_config "$d" deploy
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"required_checks":\["tests"\]'   # the override, not the file
  ! echo "$output" | grep -q 'from-marker'
}

@test "a foreign owner is out of scope" {
  d=$(mkrepo foreign https://github.com/someoneelse/foreign.git)
  run gp_repo_in_scope "$d"
  [ "$status" -ne 0 ]
  [ "$output" = "foreign-owner" ]
}

@test "an excluded path prefix is out of scope" {
  d=$(mkrepo legacy/old https://github.com/mujtaba3B/old.git)
  run gp_repo_in_scope "$d"
  [ "$output" = "excluded-path" ]
}

@test "a repo nested inside another repo is out of scope" {
  outer=$(mkrepo outer https://github.com/mujtaba3B/outer.git)
  inner=$(mkrepo outer/vendor/inner https://github.com/mujtaba3B/inner.git)
  run gp_repo_in_scope "$inner"
  [ "$output" = "nested" ]
}

@test "the policy ROOT being a git repo does not make everything nested" {
  # ~/dev is itself a repo; testing it before stopping would disarm every gate.
  git -C "$ROOT/dev" init -q
  git -C "$ROOT/dev" remote add origin https://github.com/mujtaba3B/dev.git
  d=$(mkrepo under https://github.com/mujtaba3B/under.git)
  run gp_repo_in_scope "$d"
  [ "$output" = "in" ]
}

@test "the deploy gate arms everywhere in scope, deploy.json or not" {
  # It is command-shaped, so arming it broadly costs nothing and under-arming the
  # one gate whose failure mode is an outage is the dangerous direction.
  d=$(mkrepo nodeploy https://github.com/mujtaba3B/nodeploy.git)
  run gp_gate_config "$d" deploy
  [ "$status" -eq 0 ]
  echo '{}' > "$d/deploy.json"
  run gp_gate_config "$d" deploy
  [ "$status" -eq 0 ]
}

@test "an owner wildcard opt-out skips a dimension and carries its reason" {
  run gp_skip_dimension "dxangels/anything" coderabbit
  [ "$status" -eq 0 ]
  run gp_skip_reason "dxangels/anything"
  [ "$output" = "CR not installed" ]
  run gp_skip_dimension "mujtaba3b/plain" coderabbit
  [ "$status" -ne 0 ]
}

@test "a missing policy file fails OPEN but LOGS it" {
  # One tracked file is the whole configuration surface, so its absence disarms
  # everything. That is announced at session start rather than discovered later.
  d=$(mkrepo plain https://github.com/mujtaba3B/plain.git)
  rm -f "$GATE_POLICY_FILE"
  run gp_gate_config "$d" ship
  [ "$status" -ne 0 ]
  grep -q "FAIL-OPEN policy file missing" "$GATE_POLICY_LOG"
  echo '{"ttl_seconds":99}' > "$d/.ship-gate.json"
  run gp_gate_config "$d" ship
  [ "$status" -ne 0 ]                      # a marker cannot resurrect a gate
}

@test "an unparseable policy fails OPEN but LOGS it" {
  d=$(mkrepo plain https://github.com/mujtaba3B/plain.git)
  echo 'not json {{{' > "$GATE_POLICY_FILE"
  run gp_gate_config "$d" ship
  [ "$status" -ne 0 ]
  grep -q "FAIL-OPEN policy file unparseable" "$GATE_POLICY_LOG"
}

@test "a linked worktree inherits the same config as its main checkout" {
  # The PR #182 hole. Nothing has to be copied into the worktree now, because
  # config no longer lives in the working tree at all.
  d=$(mkrepo tuned https://github.com/mujtaba3B/tuned.git)
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  wt="$ROOT/dev/wt-linked"
  git -C "$d" worktree add -q -b probe "$wt" 2>/dev/null
  run gp_main_worktree "$wt"
  [ "$output" = "$(cd -P "$d" && pwd)" ]   # physical form on both sides
  main_cfg=$(gp_gate_config "$d" deploy)
  run gp_gate_config "$wt" deploy
  [ "$status" -eq 0 ]
  [ "$output" = "$main_cfg" ]
  echo "$output" | grep -q '"required_checks":\["tests"\]'
}

@test "a repo with NO origin remote is gated with defaults, not excluded" {
  # An UNKNOWN owner must never become an ALLOW: a repo whose remote is missing or
  # renamed would otherwise silently lose every gate.
  d="$ROOT/dev/noremote"; mkdir -p "$d"; git -C "$d" init -q
  run gp_repo_in_scope "$d"
  [ "$status" -eq 0 ]
  [ "$output" = "in" ]
  run gp_gate_config "$d" ship
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ttl_seconds":1200'
  grep -q "NO-IDENTITY" "$GATE_POLICY_LOG"
}

@test "a worktree parked OUTSIDE the root is still governed by its main checkout" {
  # Otherwise `git worktree add /tmp/escape` disarms every gate. A worktree of the
  # root repo itself must live outside the root, so this is a normal case, not an
  # exotic one.
  d=$(mkrepo inroot https://github.com/mujtaba3B/inroot.git)
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  outside="$ROOT/outside-wt"
  git -C "$d" worktree add -q -b esc "$outside" 2>/dev/null
  run gp_repo_in_scope "$outside"
  [ "$status" -eq 0 ]
  [ "$output" = "in" ]
  run gp_gate_config "$outside" ship
  [ "$status" -eq 0 ]
}

@test "a repo genuinely outside the root stays outside" {
  d="$ROOT/elsewhere"; mkdir -p "$d"; git -C "$d" init -q
  git -C "$d" remote add origin https://github.com/mujtaba3B/elsewhere.git
  run gp_repo_in_scope "$d"
  [ "$output" = "outside-root" ]
}

@test "a gates_off entry in the local file disarms one gate entirely" {
  # Disarming is the dangerous direction in this design, so both full-OFF paths are
  # pinned. This one is the machine-local file.
  cat > "$GATE_LOCAL_FILE" <<'JSON'
{ "repos": { "mujtaba3b/offrepo": { "gates_off": ["ship"], "reason": "test" } } }
JSON
  d=$(mkrepo offrepo https://github.com/mujtaba3B/offrepo.git)
  run gp_gate_config "$d" ship
  [ "$status" -ne 0 ]
  run gp_gate_config "$d" deploy   # only the named gate is off
  [ "$status" -eq 0 ]
  grep -q "LOCAL-OFF gate=ship" "$GATE_POLICY_LOG"
}

@test "an override of literal false disarms one gate entirely" {
  # The other full-OFF path. It depends on jq evaluating `$o == false` BEFORE the
  # `*` merge, which would collapse false into an object and silently re-arm.
  jq '.overrides["mujtaba3b/offpolicy"] = {"ship": false}' "$GATE_POLICY_FILE" > "$GATE_POLICY_FILE.t"
  mv "$GATE_POLICY_FILE.t" "$GATE_POLICY_FILE"
  d=$(mkrepo offpolicy https://github.com/mujtaba3B/offpolicy.git)
  run gp_gate_config "$d" ship
  [ "$status" -ne 0 ]
  run gp_gate_config "$d" deploy
  [ "$status" -eq 0 ]
}

# Setting defaults.<gate> to false is how a gate goes off for every repo. Each test
# below pairs the OFF with something that proves WHY: gp_gate_config returns 1 for
# scope, for a jq failure and for a local opt-out too, so a bare non-zero status
# would pass for the wrong reason.
set_default_false() {
  jq --arg g "$1" '.defaults[$g] = false' "$GATE_POLICY_FILE" > "$GATE_POLICY_FILE.t"
  mv "$GATE_POLICY_FILE.t" "$GATE_POLICY_FILE"
}
set_override() {
  jq --arg r "$1" --argjson v "$2" '.overrides[$r] = $v' "$GATE_POLICY_FILE" > "$GATE_POLICY_FILE.t"
  mv "$GATE_POLICY_FILE.t" "$GATE_POLICY_FILE"
}

@test "a default of literal false disarms that gate for every repo, and only that gate" {
  set_default_false qa-plan
  d=$(mkrepo plain https://github.com/mujtaba3B/plain.git)
  run gp_gate_config "$d" qa-plan
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # Same repo, same policy file: still in scope and jq still parsed it, so the
  # non-zero above came from the false and not from either of those.
  run gp_repo_in_scope "$d"
  [ "$output" = "in" ]
  run gp_gate_config "$d" ship
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ttl_seconds":1200'
  run gp_gate_config "$d" deploy
  [ "$status" -eq 0 ]
}

@test "an override object re-arms a gate under a false default, with only its own config" {
  set_default_false qa-plan
  set_override "mujtaba3b/backon" '{"qa-plan":{"gates":["pr"]}}'
  d=$(mkrepo backon https://github.com/mujtaba3B/backon.git)
  run gp_gate_config "$d" qa-plan
  [ "$status" -eq 0 ]
  [ "$output" = '{"gates":["pr"]}' ]
  # A neighbour with no override is still off, so the re-arm is this repo's alone.
  other=$(mkrepo other https://github.com/mujtaba3B/other.git)
  run gp_gate_config "$other" qa-plan
  [ "$status" -ne 0 ]
}

@test "an override of true re-arms under a false default instead of erroring into OFF" {
  # `{} * true` is a jq error, and gp_gate_config turns a jq error into return 1,
  # so without the normalization `true` would silently mean off.
  set_default_false qa-plan
  set_override "mujtaba3b/backon" '{"qa-plan":true}'
  d=$(mkrepo backon https://github.com/mujtaba3B/backon.git)
  run gp_gate_config "$d" qa-plan
  [ "$status" -eq 0 ]
  [ "$output" = '{}' ]
}

@test "an override of true keeps the defaults when the default is an object" {
  set_override "mujtaba3b/tuned" '{"ship":true}'
  d=$(mkrepo tuned https://github.com/mujtaba3B/tuned.git)
  run gp_gate_config "$d" ship
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ttl_seconds":1200'
}

@test "an override of false under a false default stays off" {
  set_default_false qa-plan
  set_override "mujtaba3b/plain" '{"qa-plan":false}'
  d=$(mkrepo plain https://github.com/mujtaba3B/plain.git)
  run gp_gate_config "$d" qa-plan
  [ "$status" -ne 0 ]
}

@test "a gate MISSING from defaults stays ON: absence is not false" {
  # The fail-closed half of the switch. Deleting a block, or a typo in its name,
  # must not read as a decision to disarm.
  jq 'del(.defaults["qa-plan"])' "$GATE_POLICY_FILE" > "$GATE_POLICY_FILE.t"
  mv "$GATE_POLICY_FILE.t" "$GATE_POLICY_FILE"
  d=$(mkrepo plain https://github.com/mujtaba3B/plain.git)
  run gp_gate_config "$d" qa-plan
  [ "$status" -eq 0 ]
  [ "$output" = '{}' ]
}

@test "a default of true stays ON: undoing the switch must not disarm the gate" {
  jq '.defaults["qa-plan"] = true' "$GATE_POLICY_FILE" > "$GATE_POLICY_FILE.t"
  mv "$GATE_POLICY_FILE.t" "$GATE_POLICY_FILE"
  d=$(mkrepo plain https://github.com/mujtaba3B/plain.git)
  run gp_gate_config "$d" qa-plan
  [ "$status" -eq 0 ]
  [ "$output" = '{}' ]
}

@test "a malformed gate value fails OPEN but LOGS it, and leaves other gates alone" {
  jq '.defaults["qa-plan"] = "on"' "$GATE_POLICY_FILE" > "$GATE_POLICY_FILE.t"
  mv "$GATE_POLICY_FILE.t" "$GATE_POLICY_FILE"
  d=$(mkrepo plain https://github.com/mujtaba3B/plain.git)
  run gp_gate_config "$d" qa-plan
  [ "$status" -ne 0 ]
  grep -q 'FAIL-OPEN gate=qa-plan repo=mujtaba3b/plain' "$GATE_POLICY_LOG"
  run gp_gate_config "$d" ship
  [ "$status" -eq 0 ]
}

@test "a default of literal false is not logged as a failure: it is a decision" {
  set_default_false qa-plan
  d=$(mkrepo plain https://github.com/mujtaba3B/plain.git)
  run gp_gate_config "$d" qa-plan
  [ "$status" -ne 0 ]
  ! grep -q 'FAIL-OPEN' "$GATE_POLICY_LOG"
}

@test "a default of null stays ON too: null is absence, not a decision" {
  jq '.defaults["qa-plan"] = null' "$GATE_POLICY_FILE" > "$GATE_POLICY_FILE.t"
  mv "$GATE_POLICY_FILE.t" "$GATE_POLICY_FILE"
  d=$(mkrepo plain https://github.com/mujtaba3B/plain.git)
  run gp_gate_config "$d" qa-plan
  [ "$status" -eq 0 ]
  [ "$output" = '{}' ]
}

@test "GATE_POLICY_FILE is IGNORED without GATE_POLICY_TEST, and the ignore is logged" {
  # The override used to be a one-variable way to disarm every gate. It is test
  # plumbing, so it now requires an explicit second flag and says so in the log.
  real="$HOME/dev/gate-policy.json"
  GATE_POLICY_TEST="" run gp_policy_file
  [ "$output" = "$real" ]
  GATE_POLICY_TEST="" gp_policy_file >/dev/null
  grep -q "IGNORED GATE_POLICY_FILE" "$GATE_POLICY_LOG"
}

@test "GATE_POLICY_FILE is honored when GATE_POLICY_TEST=1" {
  run gp_policy_file
  [ "$output" = "$GATE_POLICY_FILE" ]
}

@test "GATE_LOCAL_FILE is ignored without test mode too" {
  GATE_POLICY_TEST="" run gp_local_file
  [ "$output" = "$HOME/dev/.gates/local.json" ]
}

# ---- scope.extra_roots: ~/agents beside ~/dev (mutwo-tools#152 step 0c) ----------
# The agent repos move to ~/agents, a sibling of ~/dev. ~/agents is itself a repo
# (mujtaba3B/agents) with tier folders, and persona repos nest in those folders.
# Without extra_roots every one of them is outside-root, which is an ALLOW.

# mkagents: the agents repo, a tier folder, and a persona repo nested in it.
mkagents() {
  mkdir -p "$ROOT/agents/mu4/fitness"
  git -C "$ROOT/agents" init -q
  git -C "$ROOT/agents" remote add origin https://github.com/mujtaba3B/agents.git
  git -C "$ROOT/agents/mu4/fitness" init -q
  git -C "$ROOT/agents/mu4/fitness" remote add origin https://github.com/mujtaba3B/fitness.git
}

with_extra_root() {
  jq --arg r "$1" '.scope.extra_roots = [$r]' "$GATE_POLICY_FILE" > "$ROOT/p.tmp"
  mv "$ROOT/p.tmp" "$GATE_POLICY_FILE"
}

@test "without extra_roots a persona repo under ~/agents is outside-root (the hole)" {
  mkagents
  run gp_repo_in_scope "$ROOT/agents/mu4/fitness"
  [ "$status" -eq 1 ]
  [ "$output" = "outside-root" ]
}

@test "extra_roots gates a persona repo nested in a tier folder of the agents repo" {
  mkagents
  with_extra_root "$ROOT/agents"
  run gp_repo_in_scope "$ROOT/agents/mu4/fitness"
  [ "$status" -eq 0 ]
  [ "$output" = "in" ]
  run gp_gate_config "$ROOT/agents/mu4/fitness" ship
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ttl_seconds":1200'
}

@test "extra_roots gates the agents repo itself (the Base)" {
  mkagents
  with_extra_root "$ROOT/agents"
  run gp_repo_in_scope "$ROOT/agents"
  [ "$output" = "in" ]
}

@test "extra_roots keeps the owner and nested rules, judged against its own root" {
  mkagents
  with_extra_root "$ROOT/agents"
  mkdir -p "$ROOT/agents/mu4/fitness/vendor/x"
  git -C "$ROOT/agents/mu4/fitness/vendor/x" init -q
  git -C "$ROOT/agents/mu4/fitness/vendor/x" remote add origin https://github.com/mujtaba3B/x.git
  run gp_repo_in_scope "$ROOT/agents/mu4/fitness/vendor/x"
  [ "$output" = "nested" ]
  mkdir -p "$ROOT/agents/mu4/foreign"
  git -C "$ROOT/agents/mu4/foreign" init -q
  git -C "$ROOT/agents/mu4/foreign" remote add origin https://github.com/someone/foreign.git
  run gp_repo_in_scope "$ROOT/agents/mu4/foreign"
  [ "$output" = "foreign-owner" ]
}

@test "extra_roots accepts a ~ path and gp_policy_roots lists root first" {
  with_extra_root "~/agents-test-root"
  run gp_policy_roots
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$ROOT/dev" ]
  [ "${lines[1]}" = "$HOME/agents-test-root" ]
}

@test "a repo outside every root stays outside with extra_roots set" {
  mkagents
  with_extra_root "$ROOT/agents"
  d="$ROOT/elsewhere"; mkdir -p "$d"; git -C "$d" init -q
  git -C "$d" remote add origin https://github.com/mujtaba3B/elsewhere.git
  run gp_repo_in_scope "$d"
  [ "$output" = "outside-root" ]
}

@test "the ship and deploy gates' repo resolver binds a repo under an extra root" {
  # sg_dev_repo_gitdir is what ship-pr-gate, deploy-gate and the sentinel use to
  # decide "is this a governed repo". It hard-coded ~/dev, so the policy alone
  # was not enough: the gate would still have allowed.
  mkagents
  . "${BATS_TEST_DIRNAME}/../scripts/ship-gate-repo-lib.sh"
  run sg_dev_repo_gitdir "$ROOT/agents/mu4/fitness"
  [ "$status" -ne 0 ]
  with_extra_root "$ROOT/agents"
  unset GP_SCOPE_LOADED
  run sg_dev_repo_gitdir "$ROOT/agents/mu4/fitness"
  [ "$status" -eq 0 ]
  want=$(cd -P "$ROOT/agents/mu4/fitness" && pwd)
  [ "${output%%$'\t'*}" = "$want" ]
  run sg_dev_repo_roots
  echo "$output" | grep -qx "$ROOT/agents/mu4/fitness"
  echo "$output" | grep -qx "$ROOT/agents"
}

@test "a malformed extra_roots (a string, not a list) does not disarm ~/dev" {
  # One jq call reads the whole scope block, so a type error in extra_roots used
  # to fail the read and turn every gate off, ~/dev included. Found in review.
  jq '.scope.extra_roots = "~/agents"' "$GATE_POLICY_FILE" > "$ROOT/p.tmp"
  mv "$ROOT/p.tmp" "$GATE_POLICY_FILE"
  d=$(mkrepo plain https://github.com/mujtaba3B/plain.git)
  run gp_repo_in_scope "$d"
  [ "$output" = "in" ]
  run gp_gate_config "$d" ship
  [ "$status" -eq 0 ]
  grep -q "BAD scope.extra_roots.*not-an-array" "$GATE_POLICY_LOG"
}

@test "relative, numeric and object extra_roots entries are dropped and logged" {
  mkagents
  jq --arg r "$ROOT/agents" '.scope.extra_roots = ["agents", 1, null, {"a":"/x"}, $r]' \
    "$GATE_POLICY_FILE" > "$ROOT/p.tmp"
  mv "$ROOT/p.tmp" "$GATE_POLICY_FILE"
  run gp_policy_roots
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "$ROOT/agents" ]
  run gp_repo_in_scope "$ROOT/agents/mu4/fitness"
  [ "$output" = "in" ]
  grep -q "BAD scope.extra_roots.*bad-entries" "$GATE_POLICY_LOG"
}

@test "a ~/dev repo's worktree parked inside an extra root is judged by its main checkout" {
  # Found in review: inside ~/agents the worktree's own path matched first, so
  # one parked under a persona repo read as nested (an allow). Before
  # extra_roots it fell back to the main checkout and read as in.
  mkagents
  with_extra_root "$ROOT/agents"
  d=$(mkrepo devrepo https://github.com/mujtaba3B/devrepo.git)
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$d" worktree add -q -b parked "$ROOT/agents/mu4/fitness/wt" 2>/dev/null
  run gp_repo_in_scope "$ROOT/agents/mu4/fitness/wt"
  [ "$output" = "in" ]
  [ "$status" -eq 0 ]
}

@test "the repo walk emits each repo once when an extra root sits inside scope.root" {
  mkdir -p "$ROOT/dev/inner/r1"
  git -C "$ROOT/dev/inner/r1" init -q
  with_extra_root "$ROOT/dev/inner"
  . "${BATS_TEST_DIRNAME}/../scripts/ship-gate-repo-lib.sh"
  run sg_dev_repo_roots
  [ "$(printf '%s\n' "$output" | grep -cx "$ROOT/dev/inner/r1")" -eq 1 ]
}
