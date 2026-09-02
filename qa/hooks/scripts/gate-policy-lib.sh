#!/bin/bash
# Shared gate-policy resolution: which gates apply to a checkout, and with what
# config. Sourced by every gate in the eng and qa plugins so they can never
# disagree about whether a repo is gated.
#
# WHY this exists: the four opt-in markers (.ship-gate.json / .qa-plan-gate.json /
# .merge-clearance.json / .deploy-gate.json) are machine-local and git-ignored, and
# the gates fail OPEN without them. Marker-presence-as-the-switch therefore had
# three silent holes:
#
#   1. WORKTREES. `git worktree add` populates from the index, so git-ignored files
#      are by design not carried over. Every fresh worktree of a gated repo was an
#      UN-gated copy and nothing said so. Observed live on mutwo-skills PR #182: a
#      bare `gh pr create` succeeded where the ship gate should have blocked it, no
#      QA plan was demanded, and `merge-clearance status` reported a phantom
#      `ci=missing` because with no marker to read required_checks from it fell back
#      to a context literally named "ci". That last one does not fail open, it fails
#      CONFUSING: it looks like broken CI, so the reflex is to go debug CI.
#   2. REGISTRY DRIFT. The old ~/dev/gated-repos.json was keyed by filesystem path
#      and listed 5 repos while 15 checkouts actually carried markers, so 10 were
#      gated on disk but invisible to arm-gates.sh and the drift check.
#   3. PARTIAL COVERAGE. 7 of 18 marker-carrying checkouts were missing gates they
#      should have had. ~/dev itself had no ship-gate; apps/sms-hero had a
#      deploy.json and no deploy-gate, the exact shape of the 2026-07-24 incident.
#
# All three are one root cause: the switch that arms a gate was a file that could
# silently fail to exist. So the model is INVERTED here. Every repo under the policy
# root is gated by default; a marker no longer switches a gate ON, it only TUNES one.
# There is nothing left that can go missing, so a worktree, a fresh clone, or a brand
# new repo cannot be silently un-gated again.
#
# Exclusions are DERIVED, never curated: a hand-maintained exclusion list is the same
# drift problem wearing a different hat.
#
# These functions read git, the policy file, and the filesystem. They echo and they
# never write.

# ---- file locations (overridable for tests) --------------------------------
# GATE_POLICY_FILE : tracked policy (defaults + scope + per-repo overrides).
# GATE_LOCAL_FILE  : machine-local opt-outs, git-ignored, never committed. Kept
#                    CENTRAL and keyed by repo identity rather than one file per
#                    repo, which is what stops the worktree hazard reappearing in
#                    the opt-out layer itself.
gp_policy_file() { printf '%s' "${GATE_POLICY_FILE:-$HOME/dev/gate-policy.json}"; }
gp_local_file()  { printf '%s' "${GATE_LOCAL_FILE:-$HOME/dev/.gates/local.json}"; }

# gp_log <msg>
#   Best-effort, never fatal. Anything that turns an UNKNOWN into an ALLOW is
#   logged, so a rotted policy is discoverable rather than a silent bypass.
gp_log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$*" \
    >> "${GATE_POLICY_LOG:-$HOME/.claude/gate-policy.log}" 2>/dev/null || true
}

# gp_norm_repo <string>
#   Normalize a remote URL / scp form / bare owner-name to lowercase "owner/name".
#   Self-contained rather than reusing eng's sg_norm_repo, because this lib ships
#   in the qa plugin too and must not depend on an eng-only lib.
gp_norm_repo() {
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

# gp_realpath <dir>
#   Physical path (symlinks resolved). Needed because gp_main_worktree derives its
#   answer through `cd -P`, so every comparison against a caller-supplied root must
#   be physical on BOTH sides. On macOS /var is a symlink to /private/var, so mixing
#   the two forms makes a main worktree compare as "not itself" and silently takes
#   the linked-worktree path.
gp_realpath() { (cd -P "$1" 2>/dev/null && pwd) || printf '%s' "$1"; }

# gp_main_worktree <top>
#   Echo the MAIN working tree root for the repo whose working tree root is <top>,
#   and return 0. For a linked worktree that is a different directory; for the main
#   worktree it is <top> itself.
#
#   `rev-parse --git-common-dir` returns a path RELATIVE to the queried directory in
#   the main worktree (plain ".git") and an ABSOLUTE path to the main .git from a
#   linked one, so the relative case is resolved against <top> before taking the
#   parent. Verified against git 2.39.5. Returns 1 for a bare repo or any layout
#   where the parent is not itself a working tree root, so callers fall back rather
#   than trusting a guess.
gp_main_worktree() {
  local top="$1" common main
  command -v git >/dev/null 2>&1 || return 1
  common=$(git -C "$top" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  case "$common" in /*) ;; *) common="$top/$common" ;; esac
  main=$(cd -P "$common/.." 2>/dev/null && pwd) || return 1
  [ -d "$main" ] || return 1
  # Confirm the parent really is a working tree root; a bare repo's parent is not.
  [ "$(git -C "$main" rev-parse --show-toplevel 2>/dev/null)" = "$main" ] || return 1
  printf '%s' "$main"
}

# gp_repo_identity <top>
#   Echo the repo's stable identity, lowercase "owner/name" from the origin remote.
#   Identity rather than path is what makes every clone and every worktree of a repo
#   resolve to the same policy entry, so registration can no longer drift by path.
#   Returns 1 when there is no origin remote (nothing stable to key on).
gp_repo_identity() {
  local top="$1" url id
  command -v git >/dev/null 2>&1 || return 1
  url=$(git -C "$top" remote get-url origin 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  id=$(gp_norm_repo "$url")
  case "$id" in */*) printf '%s' "$id" ;; *) return 1 ;; esac
}

# gp_policy_root
#   The directory tree the policy governs. Everything under it is gated by default.
gp_policy_root() {
  local pf root
  pf=$(gp_policy_file)
  root=$(jq -r '.scope.root // empty' "$pf" 2>/dev/null)
  [ -n "$root" ] || root="~/dev"
  case "$root" in "~") root="$HOME" ;; "~/"*) root="$HOME/${root:2}" ;; esac
  printf '%s' "$root"
}

# gp_nested_in_other_repo <top> <root>
#   Return 0 if <top> sits INSIDE another git repo's working tree (below <root>).
#   Vendored clones (tooling/mutwo/vendor/*) are checkouts of repos already gated at
#   their real paths; treating them as independent projects would give one repo two
#   sets of state.
gp_nested_in_other_repo() {
  local top="$1" root="$2" dir
  dir=$(dirname -- "$top")
  while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    case "$dir" in "$root"|"$root"/*) ;; *) return 1 ;; esac
    # The ROOT is checked for containment but never counts as the containing repo.
    # ~/dev is itself a git repo (mujtaba3B/dev), so testing it before stopping
    # would classify every single repo under it as nested and disarm everything.
    [ "$dir" = "$root" ] && return 1
    { [ -d "$dir/.git" ] || [ -f "$dir/.git" ]; } && return 0
    dir=$(dirname -- "$dir")
  done
  return 1
}

# gp_repo_in_scope <top>
#   Decide whether the repo at working tree root <top> is governed at all. Echoes
#   "in", or an out-of-scope reason (outside-root | excluded-path | foreign-owner |
#   nested | no-identity). Return 0 only for "in".
#
#   Every exclusion is derived from something already true about the repo, so there
#   is no list to maintain and nothing that can go stale:
#     - outside-root  : not under the policy root at all.
#     - excluded-path : a configured path prefix (legacy/ archives, third-party/).
#     - foreign-owner : origin owner not in the policy's owners list. This is what
#                       keeps someone else's upstream out: forcing /ship to bump a
#                       VERSION and write a CHANGELOG on a PR to a repo you do not
#                       own is simply wrong.
#     - nested        : a clone inside another repo's working tree (see above).
#
#   A repo with NO origin remote is deliberately NOT excluded. Identity is how
#   overrides and opt-outs are keyed, so without one a repo simply gets the bare
#   defaults, but excluding it would turn an UNKNOWN into an ALLOW: a repo whose
#   remote is missing, renamed, or not yet added would silently lose every gate,
#   which is the precise failure this file exists to eliminate. It is logged so the
#   degraded state is visible rather than assumed.
gp_repo_in_scope() {
  local top="$1" root rel id owner owners excl pf scope_top
  pf=$(gp_policy_file)
  # Physical form on BOTH sides of every containment test: gp_main_worktree answers
  # in physical paths, and on macOS /var vs /private/var would otherwise make a
  # perfectly in-root worktree read as outside-root (and so ungated).
  root=$(gp_realpath "$(gp_policy_root)")
  top=$(gp_realpath "$top")

  # Containment is judged on the MAIN worktree, not on <top>. A linked worktree can
  # legitimately sit outside the root (a worktree of the root repo itself has to),
  # and judging it by its own path would let anyone escape every gate by parking a
  # worktree in /tmp. The repo, not the directory, is what is governed.
  scope_top="$top"
  case "$top" in
    "$root"|"$root"/*) ;;
    *)
      scope_top=$(gp_main_worktree "$top") || { echo "outside-root"; return 1; }
      case "$scope_top" in
        "$root"|"$root"/*) ;;
        *) echo "outside-root"; return 1 ;;
      esac
      ;;
  esac

  rel="${scope_top#"$root"}"; rel="${rel#/}"
  excl=$(jq -r '(.scope.exclude_path_prefixes // []) | .[]' "$pf" 2>/dev/null)
  if [ -n "$excl" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$rel/" in "$p"*) echo "excluded-path"; return 1 ;; esac
    done <<EOF
$excl
EOF
  fi

  # No identity -> gate with defaults, never exclude. The owner check below is the
  # only thing identity gates, and "we cannot tell whose it is" is not evidence
  # that it is someone else's.
  if ! id=$(gp_repo_identity "$top"); then
    gp_log "NO-IDENTITY $top has no origin remote; gating with defaults (no overrides or opt-outs apply)"
    echo "in"; return 0
  fi
  owner="${id%%/*}"
  owners=$(jq -r '(.scope.owners // []) | .[] | ascii_downcase' "$pf" 2>/dev/null)
  if [ -n "$owners" ]; then
    local found=1
    while IFS= read -r o; do
      [ "$o" = "$owner" ] && { found=0; break; }
    done <<EOF
$owners
EOF
    [ "$found" -eq 0 ] || { echo "foreign-owner"; return 1; }
  fi

  if [ "$(jq -r '.scope.exclude_nested // true' "$pf" 2>/dev/null)" != "false" ]; then
    gp_nested_in_other_repo "$scope_top" "$root" && { echo "nested"; return 1; }
  fi

  echo "in"; return 0
}

# gp_known_gate <gate>
#   Validate a gate name. The four gates are fixed; an unknown name is a caller bug
#   and must not silently resolve to "no config" (which would read as "allowed").
gp_known_gate() {
  case "$1" in
    ship|qa-plan|merge-clearance|deploy) return 0 ;;
    *) return 1 ;;
  esac
}

# gp_local_entry <identity>
#   Echo the machine-local opt-out entry for <identity>, or nothing. An exact key
#   wins over an "owner/*" wildcard, so one wildcard entry covers a whole org (the
#   8 Unbound repos are one line) while a single repo can still be special-cased.
gp_local_entry() {
  local id="$1" lf owner exact wild
  lf=$(gp_local_file)
  [ -f "$lf" ] || return 1
  owner="${id%%/*}"
  # Keys are folded to lowercase on read so a policy written "DxAngels/alim" still
  # matches the normalized identity. A key that silently fails to match would be
  # invisible, which is the failure mode this whole change exists to remove.
  exact=$(jq -c --arg k "$id" \
    '(.repos // {} | with_entries(.key |= ascii_downcase))[$k] // empty' "$lf" 2>/dev/null)
  [ -n "$exact" ] && { printf '%s' "$exact"; return 0; }
  wild=$(jq -c --arg k "$owner/*" \
    '(.repos // {} | with_entries(.key |= ascii_downcase))[$k] // empty' "$lf" 2>/dev/null)
  [ -n "$wild" ] && { printf '%s' "$wild"; return 0; }
  return 1
}

# gp_skip_dimension <identity> <dimension>
#   Return 0 when a machine-local opt-out disables <dimension> (e.g. "coderabbit")
#   for this repo. Callers MUST report a skipped dimension in their verdict rather
#   than omitting it: a bypass that does not appear in the output is the exact class
#   of bug this whole change exists to remove.
gp_skip_dimension() {
  local id="$1" dim="$2" entry
  entry=$(gp_local_entry "$id") || return 1
  printf '%s' "$entry" | jq -e --arg d "$dim" \
    '((.skip_dimensions // []) | index($d)) != null' >/dev/null 2>&1
}

# gp_skip_reason <identity>
#   Echo the human-readable reason recorded alongside an opt-out, for the verdict.
gp_skip_reason() {
  local entry
  entry=$(gp_local_entry "$1") || return 1
  printf '%s' "$entry" | jq -r '.reason // "no reason recorded"' 2>/dev/null
}

# gp_gate_off_locally <identity> <gate>
#   Return 0 when a machine-local opt-out turns <gate> off entirely for this repo.
gp_gate_off_locally() {
  local id="$1" gate="$2" entry
  entry=$(gp_local_entry "$id") || return 1
  printf '%s' "$entry" | jq -e --arg g "$gate" \
    '((.gates_off // []) | index($g)) != null' >/dev/null 2>&1
}

# gp_gate_applicable <top> <gate>
#   Whether <gate> applies to this repo at all. Every gate applies to every governed
#   repo; this exists as the hook for a future gate that genuinely does not.
#
#   The deploy gate deliberately arms EVERYWHERE rather than only where a deploy.json
#   exists. It is command-shaped: it fires only on the repo's declared entrypoint or
#   the hand-rolled ssh build/restart form, so a repo that never runs a deploy command
#   never sees it, and arming it costs nothing. Deriving applicability from a
#   deploy.json looked tidier but under-armed the one gate whose failure mode is an
#   outage (the 2026-07-24 crash-loop came from a deploy that skipped the ceremony),
#   and a repo can deploy via scripts/deploy.sh with no deploy.json at all.
gp_gate_applicable() {
  gp_known_gate "$2"
}

# gp_gate_config <top> <gate>
#   THE entry point every gate calls. Echo the effective config JSON for <gate> in
#   the repo at <top>, and return 0, when the gate applies. Return 1 when it does
#   not (out of scope, not applicable, or locally switched off), in which case the
#   caller allows the action.
#
#   The tracked policy is the ONLY source. There are deliberately no per-repo marker
#   files any more: a machine-local, git-ignored file that arms enforcement is the
#   thing that produced every hole this replaces, and even demoting it to "tuning
#   only" left a file that vanishes in a worktree and changes behavior. One tracked
#   file, keyed by repo identity, is the whole configuration surface.
#
#   Precedence, lowest to highest:
#     1. policy .defaults[<gate>]
#     2. policy .overrides["<owner>/<name>"][<gate>]
#   Shallow merge (jq `*`), so an override sets only the keys it names.
#
#   FAIL-OPEN on a broken or absent policy, but LOUDLY. A gate that fails closed on
#   its own bug across every repo gets ripped out, which is worse than the hole. The
#   session-start drift check reports a missing or unparseable policy, so the
#   degraded state is announced rather than silent.
gp_gate_config() {
  local top="$1" gate="$2" pf id scope defaults over merged
  command -v jq >/dev/null 2>&1 || return 1
  gp_known_gate "$gate" || return 1
  pf=$(gp_policy_file)

  if [ ! -f "$pf" ]; then
    gp_log "FAIL-OPEN policy file missing: $pf (every gate is allowing)"
    return 1
  fi
  if ! jq -e . "$pf" >/dev/null 2>&1; then
    gp_log "FAIL-OPEN policy file unparseable: $pf (every gate is allowing; fix it)"
    return 1
  fi

  scope=$(gp_repo_in_scope "$top") || return 1
  gp_gate_applicable "$top" "$gate" || return 1

  # Absent identity is not fatal: overrides and opt-outs simply do not apply.
  id=$(gp_repo_identity "$top" 2>/dev/null || true)
  [ -n "$id" ] && gp_gate_off_locally "$id" "$gate" && {
    gp_log "LOCAL-OFF gate=$gate repo=$id reason=$(gp_skip_reason "$id")"
    return 1
  }

  defaults=$(jq -c --arg g "$gate" '.defaults[$g] // {}' "$pf" 2>/dev/null)
  # Override keys folded to lowercase for the same reason as gp_local_entry.
  over=$(jq -c --arg k "${id:-__none__}" --arg g "$gate" \
    '((.overrides // {} | with_entries(.key |= ascii_downcase))[$k] // {})[$g] // {}' \
    "$pf" 2>/dev/null)
  [ "$over" = "false" ] && return 1

  merged=$(printf '%s\n%s\n' "${defaults:-{\}}" "${over:-{\}}" \
    | jq -sc '.[0] * .[1]' 2>/dev/null) || return 1
  printf '%s' "$merged"
}
