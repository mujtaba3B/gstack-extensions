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
  local wd="$1" top gitdir main
  command -v git >/dev/null 2>&1 || return 1
  top=$(git -C "$wd" rev-parse --show-toplevel 2>/dev/null) || return 1
  # Scope follows the REPO, not the directory. A linked worktree can legitimately
  # sit outside ~/dev, and a worktree of the ~/dev repo itself HAS to, so judging
  # by <top>'s own path left those checkouts ungated: the policy said "governed"
  # while every gate said "not a ~/dev repo, allow", and the gate wins. Found when
  # the land-deploy sentinel would not mint in ~/dev-gates (and, in the same breath,
  # explained why that worktree's own `gh pr create` was never blocked).
  # <top> itself is still what gets returned, so sentinels stay keyed per-worktree.
  case "$top" in
    "$HOME/dev"|"$HOME/dev/"*) ;;
    *)
      main=$(git -C "$wd" rev-parse --git-common-dir 2>/dev/null) || return 1
      case "$main" in /*) ;; *) main="$top/$main" ;; esac
      main=$(cd -P "$main/.." 2>/dev/null && pwd) || return 1
      case "$main" in
        "$HOME/dev"|"$HOME/dev/"*) ;;
        *) return 1 ;;
      esac
      ;;
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

# sg_repo_ref_host <ref>
#   The explicit host a repo reference names, lowercased, or nothing for a bare
#   owner/name. `HOST/OWNER/REPO` (gh's own form), a URL, and an scp remote all
#   carry one. github.com is reported like any other host; callers decide.
sg_repo_ref_host() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -nE '
    s#^git@([^:/]+):.*#\1#p; t
    s#^[a-z][a-z0-9+.-]*://([^@/]*@)?([^/:]+).*#\2#p; t
    s#^([^/]+)/[^/]+/[^/]+/*$#\1#p'
}

# sg_resolve_repo_ref <token> <cmd> <wdrepo>
#   Resolve ONE explicit repo argument (the text after --repo / -R / GH_REPO=) to a
#   lowercase owner/name, or echo "unverifiable:<token>". Pure: no git, no gh.
#
#   A literal resolves to itself. A shell variable (`$REPO`, `${REPO}`, quoted or
#   not) resolves ONLY when the command itself pins it down, because a hook reads
#   the command text, not the shell it will run in: variables do not persist
#   between Bash calls, so anything not assigned here comes from an environment we
#   cannot see. The one accepted shape is the variable's assignment as the FIRST
#   statement (after an optional leading `cd <dir> &&`), ended by `;`, `&&`,
#   `|| exit`, a newline or end of input (that terminator rule rejects a temp-env
#   prefix `REPO=x gh ...`, which expands the OLD value), with no other bare
#   mention of the name anywhere, counted with quotes and backslashes removed so
#   `export "RE""PO=x"` still counts (that rules out a later reassignment, `read`,
#   `for`, `unset`, `export`, `printf -v`). Its value must be
#     - a literal owner/name, or
#     - $(gh repo view --json nameWithOwner -q .nameWithOwner), which names the
#       repo of the dir the shell is in at that moment. It is trusted only when
#       that dir is provably the gate's WORKDIR: the leading cd (if any) is a
#       plain path sg_workdir_from_cmd parses the same way (no quotes, `$`,
#       backticks or `~user`), and no other cd / pushd / popd appears anywhere.
#       This is the exact line /land-and-deploy Step 0 uses.
#   Everything else (a conditional or subshell assignment, any other command
#   substitution, a nested expansion, any eval / source / `.` in the command) is
#   unverifiable. The caller must BLOCK on that: guessing would let a merge of
#   another repo be judged by this checkout's clearance.
#
#   Known residual: a shell FUNCTION defined outside this command (a login
#   profile) that assigns the name when called. Same accident-guard posture as
#   the rest of this gate; the GitHub required check is the backstop.
#   A host other than github.com stays in the result (host/owner/name), so a
#   GitHub Enterprise target never equals a github.com checkout; a GHE checkout
#   naming its own host explicitly is therefore refused too (safe direction).
sg_resolve_repo_ref() {
  local t="$1" cmd="$2" wd="$3" name flat body bare val plain_cd=1
  t=$(printf '%s' "$t" | sed -E 's/[;&|)`]+$//')
  t=${t#[\"\']}; t=${t%[\"\']}
  case "$t" in
    *'$'*|*'`'*) ;;
    *) sg_qualified_repo "$t"; return 0 ;;
  esac
  # Single quotes are deliberate: the sed program matches a literal `$`.
  # shellcheck disable=SC2016
  name=$(printf '%s' "$t" | sed -nE 's/^\$([A-Za-z_][A-Za-z0-9_]*)$/\1/p; s/^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/\1/p')
  [ -n "$name" ] || { printf 'unverifiable:%s' "$t"; return 0; }

  # Exactly one bare (not $-prefixed) mention of the name: the assignment itself.
  # Quotes and backslashes are dropped first: `"RE""PO"` and `RE\PO` are REPO.
  flat=$(printf '%s' "$cmd" | tr -d "\"'\\\\")
  bare=$(printf '%s\n' "$flat" | grep -oE "(^|[^A-Za-z0-9_\${])${name}([^A-Za-z0-9_]|\$)" | wc -l | tr -d ' ')
  [ "$bare" = "1" ] || { printf 'unverifiable:%s' "$t"; return 0; }

  # eval / source / `.` can rebind the name without spelling it out (eval 'RE''PO=x').
  local dyn_re='(^|[;&|(]|'$'\n'')[[:space:]]*(eval|source|\.)[[:space:]]'
  [[ "$flat" =~ $dyn_re ]] && { printf 'unverifiable:%s' "$t"; return 0; }

  # The assignment must be the first statement, after one optional `cd <dir> &&`.
  body=$(printf '%s' "$cmd" | sed -E '1s/^[[:space:]]+//')
  local cd_any='^cd[[:space:]]+[^;&|[:space:]]+[[:space:]]*&&[[:space:]]*'
  local cd_plain='^cd[[:space:]]+(~|~/[^;&|[:space:]"'"'"'$`]*|[^~;&|[:space:]"'"'"'$`][^;&|[:space:]"'"'"'$`]*)[[:space:]]*&&[[:space:]]*'
  if [[ "$body" =~ $cd_any ]]; then
    [[ "$body" =~ $cd_plain ]] || plain_cd=0
    [[ "$body" =~ $cd_any ]] && body=${body:${#BASH_REMATCH[0]}}
  fi
  local asg_re="^(export[[:space:]]+)?${name}="
  [[ "$body" =~ $asg_re ]] || { printf 'unverifiable:%s' "$t"; return 0; }
  body=${body:${#BASH_REMATCH[0]}}

  local end='[[:space:]]*($|;|&&|\|\|[[:space:]]*exit([^A-Za-z0-9_]|$)|'$'\n'')'
  local view_re='^"?\$\(gh[[:space:]]+repo[[:space:]]+view[[:space:]]+--json[[:space:]]+nameWithOwner[[:space:]]+(-q|--jq)[[:space:]]+'"[\"']?"'\.nameWithOwner'"[\"']?"'\)"?'"$end"
  local lit_re="^[\"']?([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)[\"']?$end"
  local cd_later='(^|[;&|(]|'$'\n'')[[:space:]]*(cd|pushd|popd)([[:space:]]|$)'
  if [[ "$body" =~ $view_re ]]; then
    # gh repo view answers for the dir the shell is in NOW; trust it only when
    # that is provably the dir the gate resolved WDREPO from.
    [ "$plain_cd" = 1 ] || { printf 'unverifiable:%s' "$t"; return 0; }
    [[ "$body" =~ $cd_later ]] && { printf 'unverifiable:%s' "$t"; return 0; }
    val="$wd"
  elif [[ "$body" =~ $lit_re ]]; then
    val="${BASH_REMATCH[1]}"
  else
    printf 'unverifiable:%s' "$t"; return 0
  fi
  [ -n "$val" ] || { printf 'unverifiable:%s' "$t"; return 0; }
  sg_qualified_repo "$val"
}

# sg_qualified_repo <ref>
#   owner/name for github.com (or no host), host/owner/name for any other host,
#   so a GitHub Enterprise target never compares equal to a github.com checkout.
sg_qualified_repo() {
  local h
  h=$(sg_repo_ref_host "$1")
  case "$h" in
    ""|github.com|www.github.com) sg_norm_repo "$1" ;;
    *) printf '%s/%s' "$h" "$(sg_norm_repo "$1")" ;;
  esac
}

# sg_merge_target_verdict <cmd> <wdrepo>
#   Decide whether a `gh pr merge` command's explicit repo targets name the
#   checkout's own repo. Targets are EVERY --repo / -R (any whitespace after the
#   flag, `=`, compact `-RX`, and combined short flags like `-dR X`) in every gh
#   invocation in the command, plus every GH_REPO= anywhere. -R is read only
#   inside gh invocations, so `cp -R a b` earlier in the command is not a target.
#   Pure; one token out:
#     none                no explicit target
#     same                every target resolves to <wdrepo>
#     other:<owner/name>  a target resolves to a different repo
#     unverifiable:<ref>  a target is an expansion sg_resolve_repo_ref cannot pin
#   An empty <wdrepo> never yields "same".
sg_merge_target_verdict() {
  local cmd="$1" wd targets envt t res
  # Join backslash-newline continuations first, as the shell does, so a flag on a
  # continued line still belongs to its gh invocation.
  cmd=${cmd//$'\\\n'/ }
  wd=$(sg_norm_repo "$2")
  targets=$(printf '%s\n' "$cmd" \
    | tr ';&|()' '\n\n\n\n\n' \
    | grep -E '^[[:space:]]*([^[:space:]]*`)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:]]*/)?gh[[:space:]]' \
    | grep -oE '(--repo(=|[[:space:]]+)|(^|[[:space:]])-[A-Za-z]*R(=|[[:space:]]*))[^[:space:]]+' \
    | sed -E 's#^[[:space:]]*(--repo(=|[[:space:]]+)|-[A-Za-z]*R(=|[[:space:]]*))##')
  envt=$(printf '%s' "$cmd" | grep -oE '(^|[[:space:]])GH_REPO=[^[:space:]]+' | sed -E 's#.*GH_REPO=##')
  if [ -n "$targets" ] && [ -n "$envt" ]; then
    targets="$targets"$'\n'"$envt"
  else
    targets="$targets$envt"
  fi
  [ -n "$targets" ] || { printf 'none'; return 0; }
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    res=$(sg_resolve_repo_ref "$t" "$cmd" "$wd")
    case "$res" in unverifiable:*) printf '%s' "$res"; return 0 ;; esac
    if [ -z "$wd" ] || [ "$res" != "$wd" ]; then
      printf 'other:%s' "$res"; return 0
    fi
  done <<< "$targets"
  printf 'same'
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
#
#   No depth limit: the policy scope is "every repo under ~/dev", and a depth cap
#   silently exempted anything deeper (a repo at ~/dev/a/b/c/d/repo has its .git at
#   depth 6), so an explicit --repo create against it would not have been gated.
#   The walk is sg_dev_repo_roots, not find: see there for why.
sg_dev_checkout_for_repo() {
  local target top url gitdir
  command -v git >/dev/null 2>&1 || return 1
  target=$(sg_norm_repo "$1")
  [ -n "$target" ] || return 1
  # sg_dev_repo_roots streams checkout ROOTS, not .git paths, so each line IS the
  # toplevel. (It used to stream .git paths, hence a dirname here; keeping that
  # would resolve every candidate one directory too high, where `git -C` walks back
  # up and reports the PARENT repo's remote as if it were the candidate's.)
  while IFS= read -r top; do
    [ -n "$top" ] || continue
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
    # Streamed via process substitution, not a heredoc: a heredoc materializes the
    # whole walk before the first comparison, so the common case (an early match)
    # would still pay for scanning every repo on the machine.
  done < <(sg_dev_repo_roots)
  return 1
}

# sg_dev_repo_roots
#   Echo every git checkout root under ~/dev, one per line, with NO depth limit.
#
#   A breadth-first walk rather than `find`, because find keeps descending INSIDE
#   each repo after matching its .git, so it walks every source file on the machine:
#   measured at 10.3s for the whole tree, against 0.6s for the old depth-capped scan.
#   Stopping at each repo root instead is both correct and cheap, and it naturally
#   skips repos nested inside another checkout, which the policy excludes anyway.
#   node_modules is not descended.
sg_dev_repo_roots() {
  local queue="$HOME/dev" dir sub base restore
  [ -d "$queue" ] || return 0
  # dotglob: a plain */ glob does not match hidden directories, so a checkout under
  # one (or a temp repo in a test) was invisible to the walk. nullglob keeps a
  # childless directory from yielding the literal pattern. Both restored on exit.
  restore=$(shopt -p dotglob nullglob)
  shopt -s dotglob nullglob
  while [ -n "$queue" ]; do
    dir=${queue%%$'\n'*}
    if [ "$queue" = "$dir" ]; then queue=""; else queue=${queue#*$'\n'}; fi
    [ -d "$dir" ] || continue
    # A repo root: emit it and do NOT descend (that is the whole speed win).
    # The scan ROOT is the exception: ~/dev is itself a git repo, so stopping there
    # would emit only ~/dev and hide every repo beneath it. Emit it, then descend.
    if [ -e "$dir/.git" ]; then
      printf '%s\n' "$dir"
      [ "$dir" = "$HOME/dev" ] || continue
    fi
    for sub in "$dir"/*/; do
      [ -d "$sub" ] || continue
      sub=${sub%/}
      base=${sub##*/}
      # .git is the repo's own metadata, never a checkout to enqueue. Skipping other
      # dot-directories would be an exclusion with no basis in the policy: it would
      # hide a real checkout under one, the kind of quiet carve-out this change
      # exists to remove.
      case "$base" in node_modules|.git) continue ;; esac
      queue="${queue:+$queue$'\n'}$sub"
    done
  done
  eval "$restore"
}
