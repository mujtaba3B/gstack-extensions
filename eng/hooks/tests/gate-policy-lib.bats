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
    "merge-clearance": { "base_branches": ["main"], "required_checks": [] },
    "qa-plan": { "gates": ["build","pr","deploy"] },
    "deploy": { "hosts": [] }
  },
  "overrides": {
    "mujtaba3b/tuned": { "merge-clearance": { "required_checks": ["tests"] } }
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
  run gp_gate_config "$d" merge-clearance
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"required_checks":\["tests"\]'
}

@test "a stray marker file on disk has NO effect (markers are gone)" {
  # Markers were dropped entirely on 2026-09-02. A leftover one from before the
  # migration must not quietly re-acquire authority over the tracked policy.
  d=$(mkrepo tuned https://github.com/mujtaba3B/tuned.git)
  echo '{"required_checks":["from-marker"]}' > "$d/.merge-clearance.json"
  run gp_gate_config "$d" merge-clearance
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
  main_cfg=$(gp_gate_config "$d" merge-clearance)
  run gp_gate_config "$wt" merge-clearance
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
  run gp_gate_config "$d" merge-clearance   # only the named gate is off
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
  run gp_gate_config "$d" merge-clearance
  [ "$status" -eq 0 ]
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
