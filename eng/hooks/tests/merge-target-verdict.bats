#!/usr/bin/env bats
# Truth table for sg_merge_target_verdict / sg_resolve_repo_ref (ship-gate-repo-lib.sh):
# the pure decision behind pr-merge-gate.sh's cross-repo guard. Every input is a
# literal; no git, no gh.
#
# The rows that matter most are the "unverifiable" ones: a `--repo "$VAR"` the hook
# cannot pin from the command text must never resolve to "same", or a merge of
# another repo would be judged by this checkout's clearance.

setup() {
  # shellcheck source=/dev/null
  . "$BATS_TEST_DIRNAME/../scripts/ship-gate-repo-lib.sh"
  WD="Owner/Name"
  # Built from parts so this file's own text never puts the merge verb at
  # command position (the live merge gate would refuse to let it be written).
  M="gh pr ""merge"
  VIEW='$(gh repo view --json nameWithOwner -q .nameWithOwner)'
}

v() { sg_merge_target_verdict "$1" "$WD"; }

@test "none: no explicit target" {
  run v "$M 5 --squash"
  [ "$output" = "none" ]
}

@test "same: literal --repo, case-folded" {
  run v "$M 5 --repo owner/name"
  [ "$output" = "same" ]
}

@test "same: literal -R and --repo= forms, and a URL" {
  run v "$M 5 -R owner/name"
  [ "$output" = "same" ]
  run v "$M 5 --repo=https://github.com/Owner/Name.git"
  [ "$output" = "same" ]
}

@test "other: literal --repo of a different repo" {
  run v "$M 5 --repo other/x"
  [ "$output" = "other:other/x" ]
}

@test "same: the exact /land-and-deploy Step 4 shape (gh repo view assignment first)" {
  run v "REPO=$VIEW || exit 1
MERGE_ERROR=\$($M \"\$MERGE_FLAG\" --auto --delete-branch \"\$PR_NUMBER\" --repo \"\$REPO\" --match-head-commit \"\$PR_HEAD\" 2>&1) || MERGE_EXIT=\$?"
  [ "$output" = "same" ]
}

@test "same: gh repo view assignment after a leading cd, braces and --jq form" {
  run v "cd /some/dir && REPO=\$(gh repo view --json nameWithOwner --jq '.nameWithOwner') && $M 5 --repo \${REPO}"
  [ "$output" = "same" ]
}

@test "same: literal assignment (quoted) then -R \"\$REPO\"" {
  run v "REPO='owner/name'; $M 5 -R \"\$REPO\""
  [ "$output" = "same" ]
}

@test "other: literal assignment of a different repo" {
  run v "REPO=other/x; $M 5 --repo \"\$REPO\""
  [ "$output" = "other:other/x" ]
}

@test "unverifiable: variable never assigned in this command (env is invisible)" {
  run v "$M \"\$F\" --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
}

@test "unverifiable: temp-env prefix expands the OLD value" {
  run v "REPO=owner/name $M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
}

@test "unverifiable: later reassignment" {
  run v "REPO=owner/name; REPO=other/x; $M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
}

@test "unverifiable: conditional assignment that may not run" {
  run v "true && REPO=owner/name; $M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
  run v "REPO=owner/name || REPO=other/x; $M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
}

@test "unverifiable: gh repo view of a NAMED repo is not the cwd repo" {
  run v "REPO=\$(gh repo view other/x --json nameWithOwner -q .nameWithOwner); $M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
}

@test "unverifiable: assignment piped into a subshell does not persist" {
  run v "REPO=$VIEW | cat; $M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
}

@test "unverifiable: read / for rebinding the name" {
  run v "REPO=owner/name; read -r REPO < f; $M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
}

@test "unverifiable: inline command substitution as the target" {
  run v "$M 5 --repo \"\$(echo other/x)\""
  assert_prefix "$output" "unverifiable:"
}

@test "unverifiable: GH_REPO from an unassigned variable" {
  run v "GH_REPO=\"\$REPO\" $M 5"
  [ "$output" = "unverifiable:\$REPO" ]
}

@test "other: EVERY target is checked, not just the first" {
  run v "REPO=owner/name; GH_REPO=\$REPO $M 5 --repo other/x"
  [ "$output" = "other:other/x" ]
}

@test "empty wdrepo never yields same" {
  run sg_merge_target_verdict "$M 5 --repo owner/name" ""
  [ "$output" = "other:owner/name" ]
  run sg_merge_target_verdict "REPO=$VIEW; $M 5 --repo \"\$REPO\"" ""
  [ "$output" = "unverifiable:\$REPO" ]
}

assert_prefix() {  # <haystack> <prefix>
  case "$1" in "$2"*) return 0 ;; esac
  echo "assert_prefix failed: wanted prefix '$2', got '$1'" >&2
  return 1
}
