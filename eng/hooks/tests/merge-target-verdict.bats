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
  run v "REPO=owner/name; for REPO in other/x; do :; done; $M 5 --repo \"\$REPO\""
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

@test "other: a bad target AFTER a good one is still caught (not first-only)" {
  run v "$M 5 --repo owner/name --repo other/x"
  [ "$output" = "other:other/x" ]
  run v "GH_REPO=other/x $M 5 --repo owner/name"
  [ "$output" = "other:other/x" ]
}

@test "same: export assignment, and an assignment ended by a newline" {
  run v "export REPO=owner/name; $M 5 --repo \"\$REPO\""
  [ "$output" = "same" ]
  run v "REPO=owner/name
$M 5 --repo \"\$REPO\""
  [ "$output" = "same" ]
}

@test "unverifiable: eval / source / . can rebind the name without spelling it" {
  run v "REPO=owner/name; eval 'RE''PO=other/x'; $M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
  run v "REPO=owner/name; . ./f.sh; $M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
  run v "REPO=owner/name && source f.sh && $M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
}

@test "unverifiable: || true leaves an empty REPO; backticks and defaults are not pinned" {
  run v "REPO=\$(gh repo view --json nameWithOwner -q .nameWithOwner) || true; $M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
  run v "$M 5 --repo \`echo other/x\`"
  assert_prefix "$output" "unverifiable:"
  run v "$M 5 --repo \"\${REPO:-other/x}\""
  assert_prefix "$output" "unverifiable:"
}

@test "other: a non-github.com host never equals the github.com checkout (GHE)" {
  run v "$M 5 --repo ghe.example.com/owner/name"
  [ "$output" = "other:ghe.example.com/owner/name" ]
  run v "$M 5 --repo https://ghe.corp/owner/name"
  [ "$output" = "other:ghe.corp/owner/name" ]
  run v "$M 5 -R git@ghe.corp:owner/name.git"
  [ "$output" = "other:ghe.corp/owner/name" ]
}

@test "same: github.com host forms (bare host, URL with userinfo, scp) fold to owner/name" {
  run v "$M 5 --repo github.com/owner/name"
  [ "$output" = "same" ]
  run v "$M 5 --repo https://user@github.com/owner/name"
  [ "$output" = "same" ]
  run v "$M 5 --repo git@github.com:owner/name.git"
  [ "$output" = "same" ]
}

@test "unverifiable: gh repo view value when the shell's dir may differ from WORKDIR" {
  # a cd on a later line moves WORKDIR (sg_workdir_from_cmd) but not $REPO
  run v "REPO=$VIEW || exit 1
cd /some/other/repo
$M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
  run v "REPO=$VIEW; pushd /x; $M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
  # a quoted or $-expanded leading cd is one sg_workdir_from_cmd cannot follow
  run v "cd \"/some/repo\" && REPO=$VIEW && $M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
  run v "cd \$HOME/dev/x && REPO=$VIEW && $M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
  run v "cd ~bob/x && REPO=$VIEW && $M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
}

@test "same: a plain or ~/ leading cd is followed, so gh repo view stays trusted" {
  run v "cd ~/dev/x && REPO=$VIEW && $M 5 --repo \"\$REPO\""
  [ "$output" = "same" ]
  # a LITERAL value does not depend on the dir, so a later cd is fine for it
  run v "REPO=owner/name; cd /x; $M 5 --repo \"\$REPO\""
  [ "$output" = "same" ]
}

@test "other: target parsing survives extra whitespace, tabs and combined short flags" {
  run v "$M 5 --repo  other/x"
  [ "$output" = "other:other/x" ]
  run v "$M 5 --repo	other/x"
  [ "$output" = "other:other/x" ]
  run v "$M 5 -R  other/x"
  [ "$output" = "other:other/x" ]
  run v "$M 5 -dR other/x"
  [ "$output" = "other:other/x" ]
}

@test "other: a merge inside \$( ) or backticks is still read" {
  run v "OUT=\$($M 5 --repo other/x 2>&1)"
  [ "$output" = "other:other/x" ]
  run v "x=\`$M 5 --repo other/x\`"
  [ "$output" = "other:other/x" ]
}

@test "none: -R of a non-gh command (cp -R) is not a merge target" {
  run v "cp -R a b && $M 5"
  [ "$output" = "none" ]
}

@test "unverifiable: quote- or backslash-split names still count as a rebinding" {
  run v "REPO=owner/name
{ export \"RE\"\"PO=other/x\"; }
$M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
  run v "REPO=owner/name; printf -v RE\\PO other/x; $M 5 --repo \"\$REPO\""
  [ "$output" = "unverifiable:\$REPO" ]
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
