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
#   Normalize a repo reference (a git remote URL, an scp-form remote, a bare
#   owner/name, or gh's [HOST/]OWNER/REPO form) to lowercase "owner/name". Lowercase
#   FIRST so an uppercase scheme (HTTPS://) and a `--repo Owner/Name` both fold; then
#   drop an scp `git@host:` prefix, a `scheme://` prefix, a trailing `.git` (with any
#   trailing slashes), and finally keep the LAST two path segments, which drops any
#   host or userinfo (`github.com/o/n`, `user@host/o/n`, `host:port/o/n` all -> o/n)
#   while leaving a bare `owner/name` (or a repo name containing dots) untouched.
sg_norm_repo() {
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

# sg_repo_from_flags <cmd>
#   Extract the explicit target repo a `gh pr create` command names: `--repo X`,
#   `--repo=X`, `-R X`, `-R=X`, the compact `-RX`, or a `GH_REPO=X` assignment. Echoes
#   the normalized owner/name and returns 0, or returns 1 when no explicit target is
#   named. Takes the LAST match, mirroring gh (a later `--repo`/`-R` wins over an
#   earlier one); this and the compact `-RX` form are why it exists rather than the old
#   inline grep, which took the first match and missed `-RX`. It still greps text, so a
#   flag string smuggled inside a quoted `--body`/`--title` value can fool it; that is
#   deliberate-evasion territory, outside this accident-guard's threat model.
sg_repo_from_flags() {
  local cmd="$1" t
  t=$(printf '%s' "$cmd" \
    | grep -oE '(--repo[= ]|(^|[[:space:]])-R[= ]?)[^[:space:]]+' \
    | sed -E 's#^[[:space:]]*(--repo[= ]|-R[= ]?)##' \
    | tail -1)
  [ -z "$t" ] && t=$(printf '%s' "$cmd" | grep -oE '(^|[[:space:]])GH_REPO=[^[:space:]]+' | tail -1 | sed -E 's#.*GH_REPO=##')
  [ -z "$t" ] && return 1
  sg_norm_repo "$t"
}

# sg_dev_checkout_for_repo <owner/name>
#   Find a governed ~/dev checkout whose origin remote is <owner/name> and echo
#   "<toplevel><TAB><absolute-git-dir>" (return 0), else return 1. This binds an
#   explicit `--repo`/`GH_REPO` target to its LOCAL checkout, so a `gh pr create`
#   run from a cwd OUTSIDE ~/dev (a session anchored in a Google Drive folder, say)
#   is still gated for the repo it names instead of falling through as out of scope.
#
#   This used to enumerate `.ship-gate.json` marker files, which was both the bound
#   on the scan and the definition of "gated". Markers were dropped on 2026-09-02,
#   so it now enumerates git checkouts and asks the policy. The scan is wider, but
#   it only runs on the rare path where the cwd is outside ~/dev AND the command
#   names an explicit repo, and it stops at the first match.
sg_dev_checkout_for_repo() {
  local target top url gitdir gitmarker
  command -v git >/dev/null 2>&1 || return 1
  target=$(sg_norm_repo "$1")
  [ -n "$target" ] || return 1
  while IFS= read -r gitmarker; do
    [ -n "$gitmarker" ] || continue
    top=$(dirname -- "$gitmarker")
    case "$top" in "$HOME/dev"|"$HOME/dev/"*) ;; *) continue ;; esac
    url=$(git -C "$top" remote get-url origin 2>/dev/null) || continue
    [ "$(sg_norm_repo "$url")" = "$target" ] || continue
    # Governed? Ask the policy, the single source of truth. Absent the helper
    # (flat deployment without the lib), fall back to "found it" so the caller
    # still binds rather than silently skipping a real checkout.
    if command -v gp_gate_config >/dev/null 2>&1; then
      gp_gate_config "$top" ship >/dev/null 2>&1 || continue
    fi
    gitdir=$(git -C "$top" rev-parse --absolute-git-dir 2>/dev/null) || continue
    printf '%s\t%s' "$top" "$gitdir"
    return 0
  done <<EOF
$(find "$HOME/dev" -maxdepth 5 -name .git -not -path '*/node_modules/*' 2>/dev/null)
EOF
  return 1
}
