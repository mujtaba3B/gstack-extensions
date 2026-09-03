#!/usr/bin/env bats
# End-to-end: drive the REAL gate scripts (not just the lib) and assert the
# inheritance contract. The lib unit tests prove the policy resolves correctly;
# these prove the gates actually act on it, which is the part that shipped broken.
#
# The motivating incident: mutwo-skills PR #182 went up from a fresh worktree where
# `git worktree add` had, by design, not carried the git-ignored markers over. Every
# gate silently allowed. So the load-bearing assertion here is a repo, and a
# worktree, with NO marker files present at all.

setup() {
  SCRIPTS="${BATS_TEST_DIRNAME}/../scripts"
  QASCRIPTS="${BATS_TEST_DIRNAME}/../../../qa/hooks/scripts"
  mkdir -p "$HOME/dev"   # hermetic on a clean runner: the gates scope to ~/dev
  ROOT=$(mktemp -d "$HOME/dev/.gitest.XXXXXX")
  export GATE_POLICY_TEST=1   # env overrides are honored only in test mode
  export GATE_POLICY_FILE="$ROOT/policy.json"
  export GATE_LOCAL_FILE="$ROOT/local.json"
  export GATE_POLICY_LOG="$ROOT/policy.log"

  # scope.root is the real ~/dev because the gates independently scope to it; the
  # temp repos live under it, exactly like the repos this governs in practice.
  cat > "$GATE_POLICY_FILE" <<JSON
{
  "scope": { "root": "$HOME/dev", "owners": ["testowner"],
             "exclude_path_prefixes": ["legacy/"], "exclude_nested": true },
  "defaults": {
    "ship": { "base_branches": ["main"], "ttl_seconds": 1200 },
    "merge-clearance": { "base_branches": ["main"], "required_checks": [] },
    "qa-plan": { "base_branches": ["main"], "gates": ["build","pr","deploy"] },
    "deploy": { "hosts": [] }
  },
  "overrides": {}
}
JSON
  echo '{"repos":{}}' > "$GATE_LOCAL_FILE"

  REPO="$ROOT/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" remote add origin https://github.com/testowner/repo.git
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$REPO" checkout -q -b feature
}

teardown() {
  git -C "$REPO" worktree prune 2>/dev/null || true
  rm -rf "$ROOT"
}

# decision <script> <json-payload> : echo "block" or "allow"
decision() {
  local out
  out=$(cd "$REPO" && printf '%s' "$2" | bash "$1" 2>/dev/null)
  if printf '%s' "$out" | grep -q '"block"'; then echo block; else echo allow; fi
}
bash_payload() {
  # hook_event_name is load-bearing: deploy-gate.sh exits early on an unrecognised
  # event, so a payload without it reads as "allow" for reasons unrelated to policy.
  jq -nc --arg c "$1" --arg cwd "${2:-$REPO}" --arg sid "${BATS_TEST_NAME:-t}" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$cwd,session_id:$sid}'
}

@test "no markers anywhere: the ship gate blocks a bare gh pr create" {
  [ ! -f "$REPO/.ship-gate.json" ]
  run decision "$SCRIPTS/ship-pr-gate.sh" "$(bash_payload 'gh pr create --base main --title x --body y')"
  [ "$output" = "block" ]
}

@test "no markers anywhere: the merge gate blocks a bare gh pr merge" {
  [ ! -f "$REPO/.merge-clearance.json" ]
  run decision "$SCRIPTS/pr-merge-gate.sh" "$(bash_payload 'gh pr merge 1 --squash')"
  [ "$output" = "block" ]
}

@test "no markers anywhere: the qa-plan PR gate blocks until a plan is approved" {
  [ ! -f "$REPO/.qa-plan-gate.json" ]
  run decision "$QASCRIPTS/qa-plan-pr-gate.sh" "$(bash_payload 'gh pr create --base main --title x --body y')"
  [ "$output" = "block" ]
}

@test "no markers anywhere: the qa-plan build gate blocks a source edit" {
  payload=$(jq -nc --arg f "$REPO/src/thing.py" --arg cwd "$REPO" \
    '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$f},cwd:$cwd}')
  run decision "$QASCRIPTS/qa-plan-build-gate.sh" "$payload"
  [ "$output" = "block" ]
}

@test "the deploy gate is armed for a governed repo with no deploy.json" {
  echo '{"deploy":{"command":"scripts/deploy.sh"}}' > "$REPO/deploy.json"
  run decision "$SCRIPTS/deploy-gate.sh" "$(bash_payload 'scripts/deploy.sh')"
  [ "$output" = "block" ]
  rm -f "$REPO/deploy.json"
  run decision "$SCRIPTS/deploy-gate.sh" "$(bash_payload 'scripts/deploy.sh')"
  [ "$output" = "block" ]
}

@test "A LINKED WORKTREE with no markers is gated (the PR #182 hole)" {
  WT="$ROOT/repo-worktree"
  git -C "$REPO" worktree add -q -b wtbranch "$WT"
  # Exactly the state git leaves behind: no git-ignored files carried over.
  [ ! -f "$WT/.ship-gate.json" ]
  [ ! -f "$WT/.merge-clearance.json" ]
  [ ! -f "$WT/.qa-plan-gate.json" ]
  out=$(cd "$WT" && bash_payload 'gh pr create --base main --title x --body y' "$WT" \
        | bash "$SCRIPTS/ship-pr-gate.sh" 2>/dev/null)
  printf '%s' "$out" | grep -q '"block"'
}

@test "a worktree resolves the repo's real required_checks, not a phantom ci" {
  # The confusing half of PR #182: with no marker to read, required_checks fell back
  # to a context literally named "ci" and the verdict looked like broken CI. Config
  # now comes from the tracked policy, so the checkout you stand in is irrelevant.
  jq '.overrides["testowner/repo"] = {"merge-clearance":{"required_checks":["tests","manifests"]}}' \
    "$GATE_POLICY_FILE" > "$GATE_POLICY_FILE.tmp" && mv "$GATE_POLICY_FILE.tmp" "$GATE_POLICY_FILE"
  WT="$ROOT/repo-worktree2"
  git -C "$REPO" worktree add -q -b wtbranch2 "$WT"
  # shellcheck source=/dev/null
  . "$SCRIPTS/gate-policy-lib.sh"
  run gp_gate_config "$WT" merge-clearance
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"required_checks":\["tests","manifests"\]'
  ! echo "$output" | grep -q '"required_checks":\["ci"\]'
}

@test "the ship sentinel mints for a marker-less repo, so the gate is clearable" {
  # The deadlock guard. Arming the gate for worktrees while the minter still keyed
  # off a literal marker file would make every worktree gated but unclearable.
  payload=$(jq -nc --arg cwd "$REPO" \
    '{hook_event_name:"PreToolUse",tool_name:"Skill",tool_input:{command:"/ship"},cwd:$cwd,session_id:"s1"}')
  (cd "$REPO" && printf '%s' "$payload" | bash "$SCRIPTS/ship-gate-sentinel.sh" >/dev/null 2>&1)
  gitdir=$(git -C "$REPO" rev-parse --absolute-git-dir)
  [ -f "$gitdir/ship-pr-clearance" ]
  run decision "$SCRIPTS/ship-pr-gate.sh" "$(bash_payload 'gh pr create --base main --title x --body y')"
  [ "$output" = "allow" ]
}

@test "a foreign-owner repo under the root is left alone" {
  git -C "$REPO" remote set-url origin https://github.com/someoneelse/repo.git
  run decision "$SCRIPTS/ship-pr-gate.sh" "$(bash_payload 'gh pr create --base main --title x --body y')"
  [ "$output" = "allow" ]
}

@test "an out-of-scope base branch still allows" {
  run decision "$SCRIPTS/ship-pr-gate.sh" "$(bash_payload 'gh pr create --base release --title x --body y')"
  [ "$output" = "allow" ]
}

@test "a worktree parked OUTSIDE ~/dev is still in gate scope (sg_dev_repo_gitdir)" {
  # A worktree of the ~/dev repo itself must live outside ~/dev, so a path-only
  # scope test exempted it from every gate while the policy called it governed.
  # The gate wins that disagreement, so the checkout was silently ungated.
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m wt
  OUTSIDE=$(mktemp -d "/tmp/.gitest-outside.XXXXXX"); rm -rf "$OUTSIDE"
  git -C "$REPO" worktree add -q -b outside-wt "$OUTSIDE"
  # shellcheck source=/dev/null
  . "$SCRIPTS/ship-gate-repo-lib.sh"
  run sg_dev_repo_gitdir "$OUTSIDE"
  [ "$status" -eq 0 ]

  # This assertion was DEAD until 2026-09-03. It was a bare `[[ ]]` with two lines
  # after it, which under bats-core 1.13 cannot fail the test, and the moment it
  # was made real it went red for two reasons the silence had been hiding:
  #
  #   1. It compared the UNRESOLVED $OUTSIDE against `git rev-parse
  #      --show-toplevel`, which resolves symlinks. On macOS /tmp is a symlink to
  #      /private/tmp, so the prefix never matched and never could.
  #   2. sg_dev_repo_gitdir returns TWO tab-separated fields, `<top>\t<gitdir>`,
  #      and a prefix test on the whole string only ever looked at the first. The
  #      comment claimed "keyed to the worktree, not the main checkout", which is
  #      a statement about the SECOND field, and nothing checked it.
  #
  # Both fields are asserted now, against the resolved path. The library was
  # correct all along; only the test was wrong.
  local want_top; want_top=$(cd -P "$OUTSIDE" && pwd)
  local got_top="${output%%$'\t'*}"
  local got_gitdir="${output#*$'\t'}"
  [ "$got_top" = "$want_top" ]
  # The worktree's own gitdir lives under <main>/.git/worktrees/<name>. If scope
  # ever regressed to the main checkout this would be a plain `<main>/.git`.
  case "$got_gitdir" in */.git/worktrees/*) ;; *)
    echo "expected the WORKTREE gitdir (.../.git/worktrees/...), not the main checkout" >&2
    echo "got: $got_gitdir" >&2; false ;;
  esac
  git -C "$REPO" worktree remove --force "$OUTSIDE" 2>/dev/null || true
}

@test "a directory genuinely outside any ~/dev repo stays out of gate scope" {
  . "$SCRIPTS/ship-gate-repo-lib.sh"
  run sg_dev_repo_gitdir /tmp
  [ "$status" -ne 0 ]
}
