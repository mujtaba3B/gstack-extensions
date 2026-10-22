#!/usr/bin/env bats
# Tests for land-and-deploy-patch.sh, which re-applies the merge-clearance hunks to
# the gstack /land-and-deploy skill after a /gstack-upgrade drops them. Runs against
# a FIXTURE skill dir shaped like the real split skill (SKILL.md + sections/*.md);
# the installed skill is never touched (GSTACK_LAND_DEPLOY_DIR points at the fixture).

setup() {
  P="$BATS_TEST_DIRNAME/../scripts/land-and-deploy-patch.sh"
  D="$BATS_TEST_TMPDIR/land-and-deploy"
  mkdir -p "$D/sections"
  printf '# land-and-deploy\n\n## Step 1: Pre-flight\n\ntext\n' > "$D/SKILL.md"
  printf '## Step 3.5: Pre-merge readiness gate\n\n### 3.5d-bis: Deployment facts\n\nfacts\n\n### 3.5e: Readiness report and confirmation\n\nreport\n' > "$D/sections/readiness-gate.md"
  printf '## Step 4: Merge the PR\n\nintro\n\n### 4a-postfail: Post-failure PR-state check\n\nreadback\n\n## Step 5: Deploy\n\n### 5a: x\n' > "$D/sections/merge-and-deploy.md"
  printf 'template, never patched\n### 3.5e: Readiness report\n' > "$D/sections/readiness-gate.md.tmpl"
  export GSTACK_LAND_DEPLOY_DIR="$D"
}

count() { grep -c "$1" "$2" || true; }

@test "check on an unpatched skill: missing, exit 1" {
  run "$P" check "$D"
  [ "$status" -eq 1 ]
}

@test "apply inserts each hunk once, before its anchor, and check then passes" {
  run "$P" apply "$D"
  [ "$status" -eq 0 ]
  [ "$(count 'merge-clearance:hunk1:begin' "$D/sections/readiness-gate.md")" -eq 1 ]
  [ "$(count 'merge-clearance:hunk2:begin' "$D/sections/merge-and-deploy.md")" -eq 1 ]
  # hunk1 lands after 3.5d-bis and before 3.5e
  run awk '/3\.5d-bis/{a=NR} /### 3\.5d-clearance/{b=NR} /### 3\.5e/{c=NR} END{print (a<b && b<c)}' "$D/sections/readiness-gate.md"
  [ "$output" = "1" ]
  # hunk2 lands between the Step 4 intro and its first ### sub-step
  run awk '/^intro/{a=NR} /### 4-pre/{b=NR} /### 4a-postfail/{c=NR} END{print (a<b && b<c)}' "$D/sections/merge-and-deploy.md"
  [ "$output" = "1" ]
  [ "$(count 'merge-clearance.sh' "$D/sections/readiness-gate.md")" -eq 1 ]
  [ "$(count 'merge-clearance.sh' "$D/sections/merge-and-deploy.md")" -eq 1 ]
  run "$P" check "$D"
  [ "$status" -eq 0 ]
}

@test "the .tmpl is never modified, and files without an anchor are untouched" {
  cp "$D/sections/readiness-gate.md.tmpl" "$BATS_TEST_TMPDIR/tmpl.orig"
  cp "$D/SKILL.md" "$BATS_TEST_TMPDIR/skill.orig"
  "$P" apply "$D"
  cmp "$D/sections/readiness-gate.md.tmpl" "$BATS_TEST_TMPDIR/tmpl.orig"
  cmp "$D/SKILL.md" "$BATS_TEST_TMPDIR/skill.orig"
}

@test "a .tmpl holding the ONLY anchor is never patched: anchor miss instead" {
  sed -i.bak 's/### 3.5e:/### 3.6: Renamed/' "$D/sections/readiness-gate.md"; rm -f "$D/sections/"*.bak
  cp "$D/sections/readiness-gate.md.tmpl" "$BATS_TEST_TMPDIR/tmpl.orig"
  run "$P" apply "$D"
  [ "$status" -eq 2 ]
  cmp "$D/sections/readiness-gate.md.tmpl" "$BATS_TEST_TMPDIR/tmpl.orig"
}

@test "hunk2 never lands outside Step 4 (Step 4 with no ### sub-step is an anchor miss)" {
  printf '## Step 4: Merge the PR\n\nintro only\n\n## Step 5: Deploy\n\n### 5a: x\n' > "$D/sections/merge-and-deploy.md"
  cp "$D/sections/merge-and-deploy.md" "$BATS_TEST_TMPDIR/md.orig"
  run "$P" apply "$D"
  [ "$status" -eq 2 ]
  cmp "$D/sections/merge-and-deploy.md" "$BATS_TEST_TMPDIR/md.orig"
}

@test "apply keeps the patched file's mode, and leaves no temp files" {
  chmod 640 "$D/sections/readiness-gate.md"   # not the umask default, so a lost mode shows
  "$P" apply "$D"
  [ -n "$(find "$D/sections/readiness-gate.md" -perm 640)" ]
  [ -z "$(ls "$D/sections" | grep -E '\.md\.[A-Za-z0-9]{6}')" ]
}

@test "apply is idempotent: a second run changes nothing" {
  "$P" apply "$D"
  cp -R "$D" "$BATS_TEST_TMPDIR/once"
  run "$P" apply "$D"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  diff -r "$BATS_TEST_TMPDIR/once" "$D"
}

@test "a stale block (older hunk text) is replaced, not duplicated" {
  "$P" apply "$D"
  sed -i.bak 's/merge-clearance:hunk1:begin [0-9]*/merge-clearance:hunk1:begin 1/' "$D/sections/readiness-gate.md"
  run "$P" check "$D"
  [ "$status" -eq 1 ]
  run "$P" apply "$D"
  [ "$status" -eq 0 ]
  [ "$(count 'merge-clearance:hunk1:begin' "$D/sections/readiness-gate.md")" -eq 1 ]
  [ "$(count '### 3.5d-clearance' "$D/sections/readiness-gate.md")" -eq 1 ]
  run "$P" check "$D"
  [ "$status" -eq 0 ]
}

@test "a hunk that moved to another file upstream is still found" {
  printf '## Step 4: Merge the PR\n\n### 4a-postfail: x\n' >> "$D/SKILL.md"
  printf 'nothing here\n' > "$D/sections/merge-and-deploy.md"
  run "$P" apply "$D"
  [ "$status" -eq 0 ]
  [ "$(count 'merge-clearance:hunk2:begin' "$D/SKILL.md")" -eq 1 ]
}

@test "missing anchor: apply exits 2 naming the hunk, and leaves the file untouched" {
  sed -i.bak 's/### 3.5e:/### 3.6: Renamed/' "$D/sections/readiness-gate.md"; rm -f "$D/sections/"*.bak
  cp "$D/sections/readiness-gate.md" "$BATS_TEST_TMPDIR/rg.orig"
  run "$P" apply "$D"
  [ "$status" -eq 2 ]
  case "$output" in *"hunk1 anchor not found"*) ;; *) echo "$output"; false ;; esac
  cmp "$D/sections/readiness-gate.md" "$BATS_TEST_TMPDIR/rg.orig"
  # the other hunk still applies
  [ "$(count 'merge-clearance:hunk2:begin' "$D/sections/merge-and-deploy.md")" -eq 1 ]
  run "$P" check "$D"
  [ "$status" -eq 2 ]
}

@test "skill not installed: exit 3" {
  run "$P" apply "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 3 ]
}

@test "hook: a /land-and-deploy Skill invocation heals the skill, silently" {
  run bash -c "printf '%s' '{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"land-and-deploy\"}}' | '$P' hook"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run "$P" check "$D"
  [ "$status" -eq 0 ]
}

@test "hook: a prompt starting with /land-and-deploy heals the skill" {
  run bash -c "printf '%s' '{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"/land-and-deploy #12\"}' | '$P' hook"
  [ "$status" -eq 0 ]
  run "$P" check "$D"
  [ "$status" -eq 0 ]
}

@test "hook: any other skill or prompt touches nothing" {
  cp -R "$D" "$BATS_TEST_TMPDIR/before"
  run bash -c "printf '%s' '{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"ship\"}}' | '$P' hook"
  [ "$status" -eq 0 ]
  run bash -c "printf '%s' '{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"should I /land-and-deploy?\"}' | '$P' hook"
  [ "$status" -eq 0 ]
  diff -r "$BATS_TEST_TMPDIR/before" "$D"
}

@test "hook: missing anchor never blocks, but tells the agent via additionalContext" {
  sed -i.bak 's/### 3.5e:/### 3.6: Renamed/' "$D/sections/readiness-gate.md"
  run bash -c "printf '%s' '{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"gstack:land-and-deploy\"}}' | '$P' hook"
  [ "$status" -eq 0 ]
  hookout="$output"
  case "$hookout" in *'"decision"'*) echo "hook emitted a decision: $hookout"; false ;; esac
  run jq -r '.hookSpecificOutput.additionalContext' <<< "$hookout"
  case "$output" in *"merge-clearance.sh clear"*) ;; *) echo "$output"; false ;; esac
}

@test "hook: matcher tolerates the path form, .tool_input.name and case; no skill -> silent" {
  run bash -c "printf '%s' '{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Skill\",\"tool_input\":{\"name\":\"Skills/Land-And-Deploy\"}}' | '$P' hook"
  [ "$status" -eq 0 ]
  run "$P" check "$D"
  [ "$status" -eq 0 ]
  run bash -c "printf '%s' '{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"land-and-deploy\"}}' | GSTACK_LAND_DEPLOY_DIR='$BATS_TEST_TMPDIR/nope' '$P' hook"
  [ "$status" -eq 0 ]
  # a matched invocation with no skill dir is a contradiction the agent must hear
  case "$output" in *"was not found"*) ;; *) echo "$output"; false ;; esac
  case "$output" in *'"decision"'*) false ;; esac
}

@test "a missing hunk text refuses (4) instead of inserting an empty block" {
  "$P" apply "$D"
  cp "$D/sections/readiness-gate.md" "$BATS_TEST_TMPDIR/rg.good"
  PD="$BATS_TEST_TMPDIR/plugin"; mkdir -p "$PD"
  cp -R "$BATS_TEST_DIRNAME/../scripts" "$BATS_TEST_DIRNAME/../patches" "$PD/"
  : > "$PD/patches/land-and-deploy/hunk1-readiness.md"
  run "$PD/scripts/land-and-deploy-patch.sh" apply "$D"
  [ "$status" -eq 4 ]
  cmp "$D/sections/readiness-gate.md" "$BATS_TEST_TMPDIR/rg.good"
}

@test "refreshing a stale block repeatedly does not accumulate blank lines" {
  "$P" apply "$D"
  cp "$D/sections/readiness-gate.md" "$BATS_TEST_TMPDIR/rg.once"
  for i in 1 2 3; do
    sed -i.bak 's/merge-clearance:hunk1:begin [0-9]*/merge-clearance:hunk1:begin 1/' "$D/sections/readiness-gate.md"
    "$P" apply "$D"
  done
  cmp "$D/sections/readiness-gate.md" "$BATS_TEST_TMPDIR/rg.once"
}

# ---- merge-clearance.sh gated: the predicate both hunks key on ----------------
# Must agree with pr-merge-gate.sh's scope (gp_gate_config), and must answer
# without gh/network. Policy is pinned to a temp file (test mode), as in
# pr-merge-gate.bats.
gated_setup() {
  export GATE_POLICY_TEST=1
  export GATE_POLICY_FILE="$BATS_TEST_TMPDIR/gate-policy.json"
  export GATE_LOCAL_FILE="$BATS_TEST_TMPDIR/no-such-gate-local.json"
  jq -nc --arg root "$HOME/dev" \
    '{scope:{root:$root, exclude_path_prefixes:[], exclude_nested:false},
      defaults:{"merge-clearance":{"base_branches":["main"]}}, overrides:{}}' > "$GATE_POLICY_FILE"
  MC="$BATS_TEST_DIRNAME/../scripts/merge-clearance.sh"
}

@test "gated: exit 0 in a governed ~/dev repo" {
  gated_setup
  mkdir -p "$HOME/dev"
  R=$(mktemp -d "$HOME/dev/.ldptest.XXXXXX")
  git -C "$R" init -q
  run bash -c "cd '$R' && '$MC' gated"
  rm -rf "$R"
  [ "$status" -eq 0 ]
  [ "$output" = "gated" ]
}

@test "gated: answers without gh (a failing gh on PATH does not matter)" {
  gated_setup
  mkdir -p "$HOME/dev" "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "gh must not be called" >&2; exit 99\n' > "$BATS_TEST_TMPDIR/bin/gh"; chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  R=$(mktemp -d "$HOME/dev/.ldptest.XXXXXX")
  git -C "$R" init -q
  run bash -c "cd '$R' && PATH='$BATS_TEST_TMPDIR/bin':\"\$PATH\" '$MC' gated"
  rm -rf "$R"
  [ "$status" -eq 0 ]
}

@test "gated: a missing or unparseable policy is an error (2), never 'not gated'" {
  gated_setup
  mkdir -p "$HOME/dev"
  R=$(mktemp -d "$HOME/dev/.ldptest.XXXXXX")
  git -C "$R" init -q
  rm -f "$GATE_POLICY_FILE"
  run bash -c "cd '$R' && '$MC' gated"
  missing=$status
  printf '{not json' > "$GATE_POLICY_FILE"
  run bash -c "cd '$R' && '$MC' gated"
  bad=$status
  rm -rf "$R"
  [ "$missing" -eq 2 ]
  [ "$bad" -eq 2 ]
}

@test "gated: exit 1 for a repo outside the policy root, and outside any repo" {
  gated_setup
  R="$BATS_TEST_TMPDIR/outside"; mkdir -p "$R"; git -C "$R" init -q
  run bash -c "cd '$R' && '$MC' gated"
  [ "$status" -eq 1 ]
  run bash -c "cd / && '$MC' gated"
  [ "$status" -eq 1 ]
}
