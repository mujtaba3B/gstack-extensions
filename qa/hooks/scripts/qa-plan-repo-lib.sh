#!/bin/bash
# Impure repo-resolution helpers for the QA-plan PR gate's cross-cwd binding.
#
# Kept OUT of the pure qa-plan-gate-lib.sh (which must stay live-repo-free so it can
# be unit tested without a filesystem) exactly as the ship gate keeps
# ship-gate-repo-lib.sh separate from the pure ship-pr-gate-lib.sh. These functions
# read git + the filesystem; they never write.
#
# WHY this exists: the ship PR gate can bind a `gh pr create --repo <owner/name>` run
# from a cwd OUTSIDE ~/dev to that repo's local ~/dev checkout and gate it there
# (ship-gate-repo-lib.sh's sg_dev_checkout_for_repo). The QA-plan PR gate had no
# equivalent, so from a session anchored outside ~/dev (a persona working in a
# Drive/tmp workspace) the repo read "out of scope" and the QA-plan approval policy
# silently did not fire at all. These helpers give the QA-plan gate the same reach,
# with one dimension the ship gate does not need: the QA-plan approval stamp is
# per-BRANCH and lives in the PER-WORKTREE git dir the stamp writer targeted
# (gstack-extensions#89), so the bind must resolve the specific ~/dev WORKTREE that is
# on the PR's --head branch, not merely the first same-origin checkout.
#
# qpg_norm_repo and qpg_repo_from_flags mirror ship-gate-repo-lib.sh's sg_norm_repo /
# sg_repo_from_flags on purpose: the two gates must read --repo/-R/GH_REPO identically.
# A qa-local copy is required because a plugin cannot source another plugin's install
# tree by relative path (eng and qa install to separate cache dirs). If the two ever
# drift, tests/qa-plan-repo-lib.bats and eng's ship-pr-gate.bats both pin the parse.

# qpg_norm_repo <string>
#   Normalize a repo reference (git remote URL, scp-form remote, bare owner/name, or
#   gh's [HOST/]OWNER/REPO) to lowercase "owner/name". Lowercase first so an uppercase
#   scheme and a `--repo Owner/Name` both fold; then strip an scp `git@host:` prefix, a
#   `scheme://` prefix, a trailing `.git`, trailing slashes, and keep the LAST two path
#   segments (dropping any host/userinfo) while leaving a bare owner/name untouched.
qpg_norm_repo() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E '
        s#^git@([^:/]+):#\1/#;
        s#^[a-z][a-z0-9+.-]*://##;
        s#^git@##;
        s#\.git/*$##;
        s#/+$##;
        s#.*/([^/]+/[^/]+)$#\1#;
      '
}

# qpg_repo_from_flags <cmd>
#   Echo the normalized owner/name a `gh pr create` explicitly targets via `--repo X`,
#   `--repo=X`, `-R X`, `-R=X`, the compact `-RX`, or a `GH_REPO=X` assignment; return 1
#   when none is named. Takes the LAST match, mirroring gh (a later flag wins). Greps
#   text, so a flag string smuggled inside a quoted --body/--title can fool it; that is
#   deliberate-evasion territory, outside this accident-guard's threat model.
qpg_repo_from_flags() {
  local cmd="$1" t
  t=$(printf '%s' "$cmd" \
    | grep -oE '(--repo[= ]|(^|[[:space:]])-R[= ]?)[^[:space:]]+' \
    | sed -E 's#^[[:space:]]*(--repo[= ]|-R[= ]?)##' \
    | tail -1)
  [ -z "$t" ] && t=$(printf '%s' "$cmd" | grep -oE '(^|[[:space:]])GH_REPO=[^[:space:]]+' | tail -1 | sed -E 's#.*GH_REPO=##')
  [ -z "$t" ] && return 1
  qpg_norm_repo "$t"
}

# qpg_head_branch_from_cmd <cmd>
#   Echo the PR head branch a `gh pr create` names via `--head X` / `--head=X` / `-H X` /
#   the compact `-HX`, with a leading `owner:` (cross-fork head) stripped so only the
#   branch remains; return 1 when none is named. The cross-cwd bind needs the branch
#   alone to match a worktree's checked-out ref. Last match wins, mirroring gh.
qpg_head_branch_from_cmd() {
  local cmd="$1" h
  h=$(printf '%s' "$cmd" \
    | grep -oE '(--head[= ]|(^|[[:space:]])-H[= ]?)[^[:space:]]+' \
    | sed -E 's#^[[:space:]]*(--head[= ]|-H[= ]?)##' \
    | tail -1)
  [ -z "$h" ] && return 1
  printf '%s' "${h##*:}"
}

# qpg_dev_repo_roots
#   Echo every git checkout root under ~/dev, one per line, with NO depth limit. A
#   breadth-first walk rather than `find` (which keeps descending inside each repo after
#   matching its .git, so it walks every source file on the machine). Mirrors
#   ship-gate-repo-lib.sh's sg_dev_repo_roots: emit a repo root and do NOT descend into
#   it (the speed win), except ~/dev itself (a repo) which is emitted then descended so
#   the repos beneath it are not hidden. node_modules is skipped; dotglob/nullglob are
#   set so a checkout under a hidden dir is visible and a childless dir yields nothing.
qpg_dev_repo_roots() {
  local queue="$HOME/dev" dir sub base restore
  [ -d "$queue" ] || return 0
  restore=$(shopt -p dotglob nullglob)
  shopt -s dotglob nullglob
  while [ -n "$queue" ]; do
    dir=${queue%%$'\n'*}
    if [ "$queue" = "$dir" ]; then queue=""; else queue=${queue#*$'\n'}; fi
    [ -d "$dir" ] || continue
    # A repo root is marked by .git as either a directory (main checkout) or a file
    # (linked worktree), so test -e, not -d, or worktrees are invisible to the walk.
    if [ -e "$dir/.git" ]; then
      printf '%s\n' "$dir"
      [ "$dir" = "$HOME/dev" ] || continue
    fi
    for sub in "$dir"/*/; do
      [ -d "$sub" ] || continue
      sub=${sub%/}
      base=${sub##*/}
      case "$base" in node_modules|.git) continue ;; esac
      queue="${queue:+$queue$'\n'}$sub"
    done
  done
  eval "$restore"
}

# qpg_dev_worktree_for_repo_branch <owner/name> <branch>
#   Echo "<worktree-top><TAB><absolute-git-dir>" for the governed ~/dev worktree of
#   <owner/name> whose checked-out branch is <branch>, and return 0; else return 1. This
#   is the READ twin of the stamp writer's `--worktree` target: the stamp lives in that
#   worktree's git dir keyed to that branch (gstack-extensions#89), so the gate must
#   resolve the SAME worktree to read it. "Governed" is asked of the policy
#   (gp_gate_config), the single source of truth, exactly as sg_dev_checkout_for_repo
#   does; absent that helper (flat deployment) it falls back to same-origin-match so the
#   caller still binds rather than silently skipping a real checkout. First match wins.
qpg_dev_worktree_for_repo_branch() {
  local target branch top url wt gitdir line
  command -v git >/dev/null 2>&1 || return 1
  target=$(qpg_norm_repo "$1"); branch="$2"
  { [ -n "$target" ] && [ -n "$branch" ]; } || return 1
  while IFS= read -r top; do
    [ -n "$top" ] || continue
    case "$top" in "$HOME/dev"|"$HOME/dev/"*) ;; *) continue ;; esac
    url=$(git -C "$top" remote get-url origin 2>/dev/null) || continue
    [ "$(qpg_norm_repo "$url")" = "$target" ] || continue
    if command -v gp_gate_config >/dev/null 2>&1; then
      gp_gate_config "$top" qa-plan >/dev/null 2>&1 || continue
    fi
    # `git worktree list --porcelain` reports, from ANY worktree of the repo, every
    # worktree's path and its checked-out branch. Find the one on <branch> and return
    # its own per-worktree git dir (--absolute-git-dir), which is where its stamp lives.
    wt=""
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) wt="${line#worktree }" ;;
        "branch refs/heads/$branch")
          gitdir=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || { wt=""; continue; }
          printf '%s\t%s' "$wt" "$gitdir"
          return 0 ;;
      esac
    done < <(git -C "$top" worktree list --porcelain 2>/dev/null)
  done < <(qpg_dev_repo_roots)
  return 1
}
