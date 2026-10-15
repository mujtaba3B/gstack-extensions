#!/usr/bin/env bats
# End-to-end tests for the qa-status-gate.sh Stop hook itself (not the pure
# lib): pipe a real Stop payload at a fixture repo and assert on stdout.
# Locks in the 2026-06-10 noise-control behavior: a dirty tree alone does not
# arm the gate, only commits ahead of the base branch do, and the block reason
# is the short pointer form (not the old 2,500-char posture menu).

setup() {
  GATE="$BATS_TEST_DIRNAME/../scripts/qa-status-gate.sh"
  FIX="$BATS_TEST_TMPDIR/fixture"
  git init -q -b main "$FIX"
  git -C "$FIX" config user.email t@t
  git -C "$FIX" config user.name t
  echo seed > "$FIX/seed.txt"
  git -C "$FIX" add seed.txt
  git -C "$FIX" commit -q -m base
  git -C "$FIX" checkout -q -b feat/x
}

payload() { # $1 = last assistant message, $2 = stop_hook_active (default false)
  jq -nc --arg m "$1" --arg c "$FIX" --argjson a "${2:-false}" \
    '{last_assistant_message:$m, cwd:$c, stop_hook_active:$a}'
}

run_gate() { # $1 = message, $2 = stop_hook_active
  payload "$1" "${2:-false}" | bash "$GATE"
}

commit_ahead() {
  echo work > "$FIX/file.txt"
  git -C "$FIX" add file.txt
  git -C "$FIX" commit -q -m work
}

# Wire a bare origin holding the base branch, so the primary
# origin/${BASE}..HEAD arming path (not the local-branch fallback) runs.
add_origin() { # $1 = base branch name, $2 = "set-head" | "no-head"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  git init -q --bare "$ORIGIN"
  git -C "$FIX" remote add origin "$ORIGIN"
  git -C "$FIX" push -q origin "$1"
  if [ "$2" = "set-head" ]; then
    git -C "$FIX" remote set-head origin "$1"
  fi
}

assert_short_block() { # validates $output as the short-pointer block form
  [ "$(echo "$output" | jq -r '.decision')" = "block" ]
  reason=$(echo "$output" | jq -r '.reason')
  # Short by design: a handful of lines, well under the old 2,500-char menu.
  [ "$(printf '%s\n' "$reason" | wc -l | tr -d ' ')" -le 4 ]
  [ "${#reason}" -lt 600 ]
  for kw in dev_verified deploy_branch_for_manual_qa prod_verified awaiting_human \
            blocked skip_requested no_tracked_change CHECK: PHASE: qa-status-postures.md; do
    printf '%s' "$reason" | grep -q "$kw"
  done
  # Every posture the contract documents must be named, so a posture added to
  # the doc cannot leave the message stale. skip_approved is recorded in the PR
  # body after a human sign-off, never stated at a Stop, so it is exempt.
  postures=$(sed -n 's/^### `QA_STATUS: \([a-z_]*\)`.*/\1/p' "$BATS_TEST_DIRNAME/../../docs/qa-status-postures.md")
  [ "$(printf '%s\n' "$postures" | grep -c .)" -ge 8 ]
  for kw in $postures; do
    [ "$kw" = "skip_approved" ] && continue
    printf '%s' "$reason" | grep -q "$kw"
  done
}

@test "hook allows silently: modified tracked file alone, no commits ahead" {
  echo dirty >> "$FIX/seed.txt"   # the motivating case: a modified tracked file
  run run_gate 'All done, ready to merge.'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook allows silently: untracked file alone, no commits ahead" {
  echo dirty > "$FIX/new-file.txt"
  run run_gate 'All done, ready to merge.'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook blocks: commits ahead (no remote, local-base fallback), short reason" {
  commit_ahead
  run run_gate 'All done, ready to merge.'
  [ "$status" -eq 0 ]
  assert_short_block
}

@test "hook blocks: commits ahead of origin base (primary origin/HEAD path)" {
  add_origin main set-head
  commit_ahead
  run run_gate 'All done, ready to merge.'
  [ "$status" -eq 0 ]
  assert_short_block
}

@test "hook allows: branch fully synced with origin base, dirty tree only" {
  add_origin main set-head
  echo dirty >> "$FIX/seed.txt"
  run run_gate 'All done, ready to merge.'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook blocks: master-default repo with origin but NO origin/HEAD" {
  # Plain `git remote add` never sets origin/HEAD; with rev-list the sole
  # arming signal, the BASE probe must still find origin/master here.
  git -C "$FIX" branch -m feat/x feat/y 2>/dev/null || true
  git -C "$FIX" checkout -q main
  git -C "$FIX" branch -m main master
  add_origin master no-head
  git -C "$FIX" checkout -q -b feat/z
  commit_ahead
  run run_gate 'All done, ready to merge.'
  [ "$status" -eq 0 ]
  assert_short_block
}

@test "hook allows: commits ahead but QA_STATUS posture stated" {
  commit_ahead
  run run_gate 'Done. QA_STATUS: dev_verified EVIDENCE: ran the flow'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "eval prompts quote the live block reason verbatim (drift guard)" {
  commit_ahead
  run run_gate 'All done, ready to merge.'
  reason=$(echo "$output" | jq -r '.reason')
  n=0
  for p in "$BATS_TEST_DIRNAME"/../../evals/*/prompt.md; do
    grep -q '^> QA gate:' "$p" || continue
    n=$((n + 1))
    printf '%s\n' "$reason" | sed 's/^/> /' | while IFS= read -r line; do
      grep -qxF -- "$line" "$p" || { echo "stale quote in $p: $line"; exit 1; }
    done
  done
  [ "$n" -ge 1 ]
}

@test "hook allows: commits ahead, multi-line posture body (awaiting_human + companion lines)" {
  commit_ahead
  run run_gate "$(printf 'Merged and deployed.\nQA_STATUS: awaiting_human\nDRIVER: mujtaba\nCHECK: restart the desktop app, run /mu:pause, see the task land\nPHASE: prod')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# A gh stub on PATH serves the PR body, so the hook's artifact path runs end to
# end (its PR-body fetch is gated on qa_artifact_engages).
stub_pr_body() { # $1 = Production artifacts value
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "**Production artifacts:** %s on the mini"\n' "$1" > "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "hook blocks: awaiting_human PHASE: prod handoff citing only the base image" {
  commit_ahead
  stub_pr_body "nanoclaw-agent-v2-83c915c8:ag-1-main"
  run run_gate "$(printf 'Deployed.\nQA_STATUS: awaiting_human\nDRIVER: mujtaba\nCHECK: run the live agent\nPHASE: prod\nEVIDENCE: smoke-tested nanoclaw-agent-v2-83c915c8')"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.decision')" = "block" ]
  echo "$output" | jq -r '.reason' | grep -q 'artifact-evidence'
  echo "$output" | jq -r '.reason' | grep -qF 'engaged by: PHASE: prod'
  # The production remedy comes first; the dev label is offered only for a
  # pre-merge handoff, so the message never coaches relabelling a deploy.
  r=$(echo "$output" | jq -r '.reason')
  fix=$(printf '%s\n' "$r" | grep -n 'Re-verify THROUGH' | cut -d: -f1)
  dev=$(printf '%s\n' "$r" | grep -n 'PHASE: dev the right label' | cut -d: -f1)
  [ -n "$fix" ]
  [ -n "$dev" ]
  [ "$fix" -lt "$dev" ]
  printf '%s' "$r" | grep -qF 'nothing from this branch is merged or deployed yet'
  # Only the guarded pre-merge sentence may name the dev label.
  [ "$(printf '%s\n' "$r" | grep -c 'PHASE: dev')" -eq 1 ]
  printf '%s' "$r" | grep -qF 'names the family of a planned image'
  printf '%s' "$r" | grep -qF 'missing: nanoclaw-agent-v2-83c915c8:ag-1-main'
  [ "$(printf '%s\n' "$r" | grep -c 'Your EVIDENCE names')" -eq 0 ]
}

@test "hook blocks: a fenced PHASE: dev example above the real PHASE: prod handoff" {
  commit_ahead
  stub_pr_body "nanoclaw-agent-v2-83c915c8:ag-1-main"
  run run_gate "$(printf 'Deployed. Template:\n```\nPHASE: dev\n```\nQA_STATUS: awaiting_human\nCHECK: run the live agent\nPHASE: prod\nEVIDENCE: smoke-tested nanoclaw-agent-v2-83c915c8')"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.decision')" = "block" ]
}

@test "hook blocks: awaiting_human whose only PHASE line is fenced (fail closed)" {
  commit_ahead
  stub_pr_body "nanoclaw-agent-v2-83c915c8:ag-1-main"
  run run_gate "$(printf 'Deployed.\nQA_STATUS: awaiting_human\n```\nPHASE: dev\n```\nEVIDENCE: smoke-tested nanoclaw-agent-v2-83c915c8')"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.decision')" = "block" ]
}

@test "hook blocks: awaiting_human PHASE: prod handoff with no EVIDENCE line" {
  commit_ahead
  stub_pr_body "nanoclaw-agent-v2-83c915c8:ag-1-main"
  run run_gate "$(printf 'Deployed.\nQA_STATUS: awaiting_human\nDRIVER: mujtaba\nCHECK: run /mu:pause from the desktop app\nPHASE: prod')"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.decision')" = "block" ]
  r=$(echo "$output" | jq -r '.reason')
  printf '%s' "$r" | grep -qF 'It does not cite every production artifact'
  printf '%s' "$r" | grep -qF 'Missing: nanoclaw-agent-v2-83c915c8:ag-1-main'
  printf '%s\n' "$r" | grep -q '^Plan field: .*nanoclaw-agent-v2-83c915c8:ag-1-main on the mini'
}

@test "hook blocks prod_verified on a base image without the PHASE: dev relabel hint" {
  commit_ahead
  stub_pr_body "nanoclaw-agent-v2-83c915c8:ag-1-main"
  run run_gate "$(printf 'Deployed and verified.\nQA_STATUS: prod_verified\nEVIDENCE: smoke-tested nanoclaw-agent-v2-83c915c8')"
  [ "$(echo "$output" | jq -r '.decision')" = "block" ]
  r=$(echo "$output" | jq -r '.reason')
  printf '%s' "$r" | grep -qF 'Your EVIDENCE names'
  printf '%s' "$r" | grep -qF 'engaged by: QA_STATUS: prod_verified'
  printf '%s' "$r" | grep -qF 'Re-verify THROUGH'
  [ "$(printf '%s\n' "$r" | grep -c 'PHASE: dev the right label')" -eq 0 ]
  printf '%s' "$r" | grep -qF 'write awaiting_human, not a literal'
}

@test "hook block-uncited engaged by a literal prod_verified drops the PHASE: dev relabel hint" {
  commit_ahead
  stub_pr_body "nanoclaw-agent-v2-83c915c8:ag-1-main"
  run run_gate "$(printf 'Deployed.\nQA_STATUS: awaiting_human\nCHECK: x\nPHASE: dev\nQA_STATUS: prod_verified\nEVIDENCE: n/a')"
  [ "$(echo "$output" | jq -r '.decision')" = "block" ]
  r=$(echo "$output" | jq -r '.reason')
  printf '%s' "$r" | grep -qF 'engaged by: QA_STATUS: prod_verified'
  printf '%s' "$r" | grep -qF 'Missing: nanoclaw-agent-v2-83c915c8:ag-1-main'
  [ "$(printf '%s\n' "$r" | grep -c 'PHASE: dev the right label')" -eq 0 ]
  printf '%s' "$r" | grep -qF 'write awaiting_human, not a literal'
}

@test "hook: more than five missing refs are counted, not silently cut; five or fewer carry no count" {
  commit_ahead
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  for n in 5 6 7; do
    { printf '#!/bin/sh\ncat <<"BODY"\n**Production artifacts:**\n'
      i=1; while [ "$i" -le "$n" ]; do printf -- '- `ghcr.io/acme/s%s:v1`\n' "$i"; i=$((i + 1)); done
      printf 'BODY\n'; } > "$BATS_TEST_TMPDIR/bin/gh"
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    run run_gate "$(printf 'Deployed.\nQA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: none')"
    r=$(echo "$output" | jq -r '.reason')
    case "$n" in
      5) printf '%s\n' "$r" | grep -qx 'It does not cite every production artifact your approved QA plan named. Missing: ghcr.io/acme/s1:v1, ghcr.io/acme/s2:v1, ghcr.io/acme/s3:v1, ghcr.io/acme/s4:v1, ghcr.io/acme/s5:v1' ;;
      6) printf '%s' "$r" | grep -qF 'ghcr.io/acme/s5:v1 (+1 more)' ;;
      7) printf '%s' "$r" | grep -qF 'ghcr.io/acme/s5:v1 (+2 more)' ;;
    esac
  done
}

@test "hook: a ref repeated on several artifact lines is listed missing once and counted once" {
  commit_ahead
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  { printf '#!/bin/sh\ncat <<"BODY"\n**Production artifacts:**\n'
    for i in 1 2 3 4 5 6 7; do printf -- '- ghcr.io/x/a%s:v%s on mac-mini:8080\n' "$i" "$i"; done
    printf 'BODY\n'; } > "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  cites=$(for i in 1 2 3 4 5 6 7; do printf 'ghcr.io/x/a%s:v%s ' "$i" "$i"; done)
  run run_gate "$(printf 'Deployed.\nQA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran %s' "$cites")"
  r=$(echo "$output" | jq -r '.reason')
  printf '%s\n' "$r" | grep -qx 'It does not cite every production artifact your approved QA plan named. Missing: mac-mini:8080'
}

@test "hook prefilter: a dev handoff or dev_verified never calls gh; a PHASE: prod handoff does" {
  commit_ahead
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\ntouch "%s/gh-called"\nprintf "%%s\\n" "**Production artifacts:** nanoclaw-agent-v2-83c915c8:ag-1-main"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  run run_gate "$(printf 'Done.\nQA_STATUS: awaiting_human\nCHECK: x\nPHASE: dev')"
  [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/gh-called" ]
  run run_gate 'Done. QA_STATUS: dev_verified EVIDENCE: ran it'
  [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/gh-called" ]
  run run_gate "$(printf 'Deployed.\nQA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: live on nanoclaw-agent-v2-83c915c8:ag-1-main')"
  [ -e "$BATS_TEST_TMPDIR/gh-called" ]
}

@test "hook: an artifact past line 20 of the field is still required" {
  commit_ahead
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  { printf '#!/bin/sh\ncat <<"BODY"\n**Production artifacts:**\n'
    for i in 1 2 3 4 5 6 7 8; do printf -- '- image `ghcr.io/acme/svc%s:v1.0.%s`\n- host: mini\n- exercised by a curl\n' "$i" "$i"; done
    printf 'BODY\n'; } > "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  cites=$(for i in 1 2 3 4 5 6 7; do printf 'ghcr.io/acme/svc%s:v1.0.%s ' "$i" "$i"; done)
  run run_gate "$(printf 'Deployed.\nQA_STATUS: awaiting_human\nCHECK: x\nPHASE: prod\nEVIDENCE: ran %s' "$cites")"
  [ "$(echo "$output" | jq -r '.decision')" = "block" ]
  echo "$output" | jq -r '.reason' | grep -qF 'Missing: ghcr.io/acme/svc8:v1.0.8'
}

@test "hook allows: awaiting_human PHASE: prod handoff citing the exact production ref" {
  commit_ahead
  stub_pr_body "nanoclaw-agent-v2-83c915c8:ag-1-main"
  run run_gate "$(printf 'Deployed.\nQA_STATUS: awaiting_human\nDRIVER: mujtaba\nCHECK: run the live agent\nPHASE: prod\nEVIDENCE: live run on nanoclaw-agent-v2-83c915c8:ag-1-main')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook allows: stop_hook_active continuation never re-blocks (loop guard)" {
  commit_ahead
  run run_gate 'All done, ready to merge.' true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
