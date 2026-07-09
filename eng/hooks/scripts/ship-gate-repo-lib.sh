#!/bin/bash
# Shared repo-resolution helpers for the ship-PR gate and its sentinel writer.
#
# WHY this exists: the gate (ship-pr-gate.sh) and the mint (ship-gate-sentinel.sh)
# must agree on TWO things, or the gate dead-locks:
#   1. how to find the working directory a shell command targets (a leading
#      `cd <dir>` vs the session cwd), and
#   2. whether that directory is a ~/dev git repo, and which per-worktree git dir
#      keys its sentinel.
# Historically the gate parsed `cd` from the command while the mint keyed off the
# session cwd only. When the session cwd was OUTSIDE ~/dev (e.g. anchored in a
# Google Drive folder, or simply a DIFFERENT ~/dev repo than the target) but the
# agent cd'd into the target repo inside Bash, the mint never fired for the repo
# the gate was evaluating, so a real /ship could never clear `gh pr create`.
# Routing both through these functions makes the two sides physically incapable of
# disagreeing about "what repo is this command in".
#
# These touch git + the filesystem (so NOT in the pure ship-pr-gate-lib.sh), but
# they have no other side effects: they read, they echo, they never write.

# sg_workdir_from_cmd <cmd> <fallback_dir>
#   Resolve the working directory a shell command operates in: honor a single
#   leading `cd <dir>` (expanding a leading ~), else the fallback. Echoes the
#   resolved directory. A `cd` target that does not exist falls back too (the
#   command would have failed anyway). Mirrors the gate's original inline parse so
#   a `cd ~/dev/repo && <create>` is evaluated against repo, not the session.
sg_workdir_from_cmd() {
  local cmd="$1" fallback="$2" wd
  wd=$(printf '%s\n' "$cmd" | sed -nE 's/^[[:space:]]*cd[[:space:]]+([^[:space:];&|]+).*/\1/p' | head -1)
  # Literal "~/" is a match PATTERN here (input that starts with a tilde), not an
  # expansion; SC2088 misreads it, so silence it for this case.
  # shellcheck disable=SC2088
  case "$wd" in
    "~") wd="$HOME" ;;
    "~/"*) wd="${HOME}/${wd:2}" ;;
  esac
  { [ -n "$wd" ] && [ -d "$wd" ]; } || wd="$fallback"
  printf '%s' "$wd"
}

# sg_dev_repo_gitdir <workdir>
#   If <workdir> is inside a git repo whose toplevel is under ~/dev, echo
#   "<toplevel><TAB><absolute-git-dir>" and return 0. Otherwise return 1 (not a
#   repo, or out of the ~/dev scope). The git dir is the PER-WORKTREE one
#   (`--absolute-git-dir`, never the common dir), so sentinels keyed by it never
#   bleed across linked worktrees. Both the gate and the mint resolve the repo
#   this one way, so they can never key a different file.
sg_dev_repo_gitdir() {
  local wd="$1" top gitdir
  command -v git >/dev/null 2>&1 || return 1
  top=$(git -C "$wd" rev-parse --show-toplevel 2>/dev/null) || return 1
  case "$top" in
    "$HOME/dev"|"$HOME/dev/"*) ;;
    *) return 1 ;;
  esac
  gitdir=$(git -C "$wd" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  printf '%s\t%s' "$top" "$gitdir"
}

# sg_norm_repo <string>
#   Normalize a repo reference (a git remote URL or a bare owner/name) to lowercase
#   "owner/name": strip a scheme+host (https://host/, ssh://git@host/, git@host:), a
#   trailing ".git", and trailing slashes. Lowercased so a `--repo Owner/Name` and a
#   canonical remote URL compare equal (GitHub treats owner/name case-insensitively).
sg_norm_repo() {
  printf '%s' "$1" \
    | sed -E 's#^https?://[^/]+/##; s#^ssh://git@[^/]+/##; s#^git@[^:]+:##; s#\.git$##; s#/+$##' \
    | tr '[:upper:]' '[:lower:]'
}

# sg_repo_from_flags <cmd>
#   Extract an explicit target repo named on a `gh pr create` command line: `--repo X`,
#   `--repo=X`, `-R X`, `-R=X`, or a leading `GH_REPO=X` env assignment. Echoes the
#   normalized owner/name and returns 0, or returns 1 when no explicit target is named.
#   Same flag set the cross-repo guard already recognizes, factored out for reuse.
sg_repo_from_flags() {
  local cmd="$1" t
  t=$(printf '%s' "$cmd" | grep -oE '(--repo[ =]|(^|[[:space:]])-R[ =])[^[:space:]]+' | head -1 | sed -E 's/.*[ =]//')
  [ -z "$t" ] && t=$(printf '%s' "$cmd" | grep -oE 'GH_REPO=[^[:space:]]+' | head -1 | sed 's/GH_REPO=//')
  [ -z "$t" ] && return 1
  sg_norm_repo "$t"
}

# sg_dev_checkout_for_repo <owner/name>
#   Find a gated ~/dev checkout whose origin remote is <owner/name> and echo
#   "<toplevel><TAB><absolute-git-dir>" (return 0), else return 1. Only repos carrying
#   a .ship-gate.json marker are considered, so the scan is bounded to the handful of
#   opted-in repos (unmarked repos would be allowed anyway). This binds an explicit
#   `--repo`/`GH_REPO` target to its LOCAL checkout so a `gh pr create` run from a cwd
#   OUTSIDE ~/dev (e.g. a session anchored in a Google Drive folder) is still gated for
#   the repo it names, instead of falling through as "out of scope".
sg_dev_checkout_for_repo() {
  local target top url gitdir marker
  command -v git >/dev/null 2>&1 || return 1
  target=$(sg_norm_repo "$1")
  [ -n "$target" ] || return 1
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    top=$(git -C "$(dirname -- "$marker")" rev-parse --show-toplevel 2>/dev/null) || continue
    case "$top" in "$HOME/dev"|"$HOME/dev/"*) ;; *) continue ;; esac
    url=$(git -C "$top" remote get-url origin 2>/dev/null) || continue
    [ "$(sg_norm_repo "$url")" = "$target" ] || continue
    gitdir=$(git -C "$top" rev-parse --absolute-git-dir 2>/dev/null) || return 1
    printf '%s\t%s' "$top" "$gitdir"
    return 0
  done <<EOF
$(find "$HOME/dev" -maxdepth 5 -name .ship-gate.json -not -path '*/node_modules/*' 2>/dev/null)
EOF
  return 1
}
