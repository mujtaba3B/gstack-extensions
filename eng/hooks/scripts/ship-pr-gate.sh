#!/bin/bash
# PreToolUse hook on Bash. Block a bare `gh pr create` in an OPTED-IN ~/dev repo
# unless a fresh ship-gate sentinel proves the create is part of a real /ship run.
#
# This makes gstack `/ship` the only sanctioned way to open a PR in opted-in
# ~/dev repos. The motivating failure: the agent improvises `gh pr create` itself
# (skipping /ship's base reconciliation + tests + review + version bump), and once
# swept another agent's commits into a PR off a contaminated shared checkout.
#
# The signal: ship-gate-sentinel.sh writes <gitdir>/ship-pr-clearance when /ship
# is invoked (Skill PreToolUse, or the user typing `/ship`). /ship cannot be
# edited to announce itself (gstack-upgrade clobbers it), so the announcement is
# captured by a hook on the invocation instead. A genuine /ship run has a fresh
# sentinel; a bare manual/agent create does not.
#
# Output protocol (Claude Code PreToolUse hook):
#   exit 0 + empty stdout                          -> allow
#   stdout JSON {"decision":"block","reason":...}  -> block, reason shown to Claude
#
# Fail-OPEN posture: any missing dependency (jq/git), unreadable marker, or
# inability to resolve the repo leaves the create ALLOWED. A local gate that fails
# closed on its own bug trains the human to rip it out. Fail-open paths that hit
# AFTER we have decided this is a gated create are LOGGED (see sg_log) so gate-rot
# is detectable rather than a silent bypass.
#
# Accident-guard, NOT an adversary-proof sandbox: the agent has shell access and
# could forge the sentinel or lift the marker. The point is to funnel the agent's
# "I'll just open the PR" reflex through /ship, not to defeat deliberate evasion.
#
# Deliberate human one-off (no agent-facing override by design): temporarily
# remove or rename the repo's .ship-gate.json marker, create the PR, then restore
# it. That is an out-of-band human act, not a lever the agent is handed.

set -u

LOGFILE="$HOME/.claude/ship-pr-gate.log"
sg_log() {
  # Best-effort, never fatal. Records non-trivial decisions (block + fail-open
  # after the create was identified as gated) so a rotted/bypassed gate is visible.
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$*" >> "$LOGFILE" 2>/dev/null || true
}

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty')

# Match `gh pr create` at command position (line start or after a shell
# separator), so the phrase inside a quoted argument / heredoc body (e.g. a PR
# description that documents this very hook) does NOT trip the gate. Tolerate
# non-malicious prefixes: leading env-var assignments (`GH_TOKEN=x gh pr create`)
# and an absolute/relative path to gh (`/opt/homebrew/bin/gh pr create`). This is
# an accident-guard, so deeply obfuscated forms (bash -c "...") are out of scope.
printf '%s' "$CMD" | grep -Eq '(^|[;&|(])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*([^[:space:];&|]*/)?gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' || exit 0

command -v git >/dev/null 2>&1 || exit 0

# Shared repo resolver (single source of truth with ship-gate-sentinel.sh), so the
# gate and the mint can never disagree about which repo a command targets. Resolve
# it relative to THIS script so the executing copy binds its own dependency; if it
# is missing, fail OPEN (allow) like every other unmet dependency here.
RLIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-gate-repo-lib.sh"
[ -f "$RLIB" ] || { sg_log "FAIL-OPEN repo resolver missing ($RLIB); gated create allowed"; exit 0; }
# shellcheck source=/dev/null
. "$RLIB"

# Resolve the repo the command targets. Hooks run from the session cwd, not the
# cwd a leading `cd <dir>` switched into, so a worktree or cross-repo create would
# otherwise be evaluated against the wrong repo. sg_workdir_from_cmd honors a
# leading `cd <dir>` (else $PWD); sg_dev_repo_gitdir yields the toplevel + the
# per-worktree git dir, and returns non-zero when the target is not a ~/dev repo
# (out of scope -> allow, untouched). The same two functions feed the mint.
WORKDIR=$(sg_workdir_from_cmd "$CMD" "$PWD")
BOUND_VIA_FLAGS=""
if RESOLVED=$(sg_dev_repo_gitdir "$WORKDIR"); then
  : # in-scope via the command's cd / the session cwd (the common path)
else
  # The cwd is OUTSIDE ~/dev (e.g. a session anchored in a Google Drive folder), so it
  # says nothing about the target repo. If the command names an explicit target via
  # --repo/-R/GH_REPO, bind to THAT repo's local ~/dev checkout so the create is still
  # gated by that checkout's sentinel; a bare `gh pr create --repo <gated-repo>` from
  # an out-of-tree session was the silent-bypass hole. When nothing binds, this stays
  # out of scope and is ALLOWED as before, but the allow is now LOGGED (it used to be a
  # silent exit) so a session leaking PRs from outside ~/dev is diagnosable, not invisible.
  TARGET=$(sg_repo_from_flags "$CMD" || true)
  if [ -n "$TARGET" ] && RESOLVED=$(sg_dev_checkout_for_repo "$TARGET"); then
    BOUND_VIA_FLAGS=1
  else
    sg_log "OUT-OF-SCOPE gh pr create allowed: workdir='$WORKDIR' target='${TARGET:-none}' (no gated ~/dev checkout bound)"
    exit 0
  fi
fi
TOP=${RESOLVED%%$'\t'*}
GITDIR=${RESOLVED#*$'\t'}

# Opt-in marker. No marker -> this repo has not opted in -> allow (untouched).
MARKER="$TOP/.ship-gate.json"
[ -f "$MARKER" ] || exit 0

# Cross-repo guard (mirrors pr-merge-gate.sh). If the command explicitly targets a
# DIFFERENT repo (`--repo` / `-R` / a `GH_REPO=` env prefix), the marker + sentinel
# here belong to WORKDIR's repo, not the target. Validating them would mis-evaluate
# (a bypass: open an ungated PR in repo B by running `gh pr create --repo B` from
# inside opted-in repo A, whose fresh /ship sentinel would wrongly clear it). We
# cannot validate a clearance for a repo we are not in, so block and point at /ship.
# Only runs when such a flag is present, so the common case pays no extra cost.
# Skipped when BOUND_VIA_FLAGS: there we already resolved TOP/GITDIR to the target
# repo's own checkout from --repo/GH_REPO, so WORKDIR is deliberately not the target
# and the sentinel we will read already belongs to the right repo. Running the guard
# would read WDREPO from the out-of-scope WORKDIR (empty) and wrongly block.
# Uses the same sg_repo_from_flags / sg_norm_repo helpers as the out-of-scope binding
# path above, so both parse --repo/-R/GH_REPO identically (last-wins, compact -RX, host
# forms) and both normalize the same way. TNORM is thus already the normalized
# owner/name; WDREPO is normalized too so the comparison is case- and form-insensitive.
TARGETREPO=$(sg_repo_from_flags "$CMD" || true)
if [ -z "$BOUND_VIA_FLAGS" ] && [ -n "$TARGETREPO" ] && command -v gh >/dev/null 2>&1; then
  WDREPO=$(sg_norm_repo "$(cd "$WORKDIR" 2>/dev/null && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)")
  TNORM="$TARGETREPO"
  if [ -z "$WDREPO" ]; then
    # This checkout's repo identity could not be resolved (no remote, gh auth or
    # network failure). An explicit cross-repo target with an unverifiable local
    # identity is exactly the bypass this guard exists for, so refuse rather
    # than let a local sentinel clear a PR in an unknown other repo.
    REASON="Ship gate: this command targets $TNORM via --repo/-R/GH_REPO, but this checkout's own repo identity could not be resolved (no remote, or gh auth/network failure), so the gate cannot verify the target matches. Open the PR via /ship from a checkout of $TNORM, or fix gh auth and retry."
    sg_log "BLOCK cross-repo gh pr create from $TOP targeting $TNORM (WDREPO unresolved)"
    jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
    exit 0
  fi
  if [ "$TNORM" != "$WDREPO" ]; then
    REASON="Ship gate: this command targets a different repo ($TNORM) via --repo/-R/GH_REPO from inside an opted-in checkout ($WDREPO). The ship gate can only validate a /ship sentinel for the repo you are in, so it refuses rather than mis-evaluate. Open the PR via /ship from a checkout of $TNORM (its own gate applies there)."
    sg_log "BLOCK cross-repo gh pr create from $TOP targeting $TNORM"
    jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
    exit 0
  fi
fi

# Base-branch scoping. The marker may restrict enforcement to specific base
# branches (default ["main"]). The base is in the command (`--base X` / `-B X`)
# when present; when absent we cannot cheaply resolve the repo default here, so we
# gate (the common /ship path always passes `--base`). When a base IS named and is
# out of scope, allow.
CMDBASE=$(printf '%s' "$CMD" | grep -oE '(--base[ =]|[[:space:]]-B[ =])[^[:space:]]+' | head -1 | sed -E 's/.*[ =]//')
if [ -n "$CMDBASE" ]; then
  # An UNPARSEABLE marker (jq errors -> empty output) must not silently disable the
  # gate: the repo is already confirmed opted-in above, so a corrupt config falls
  # CLOSED onto gating (and is logged) rather than allowing. Only a successfully
  # parsed, genuinely out-of-scope base allows.
  BASES=$(jq -r '(.base_branches // ["main"]) | .[]' "$MARKER" 2>/dev/null)
  if [ -z "$BASES" ]; then
    sg_log "FAIL-CLOSED .ship-gate.json unparseable in $TOP; gating regardless of --base=$CMDBASE"
  else
    printf '%s\n' "$BASES" | grep -qxF "$CMDBASE" || exit 0   # base in scope check; out of scope -> allow
  fi
fi

# GITDIR (the per-worktree git dir, never the common dir) was resolved above by
# sg_dev_repo_gitdir, so we read the same sentinel the writer keyed to this
# worktree.

# Load the pure validator (lives alongside this hook after install).
LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-pr-gate-lib.sh"
[ -f "$LIB" ] || { sg_log "FAIL-OPEN validator missing ($LIB); gated create allowed"; exit 0; }
# shellcheck source=/dev/null
. "$LIB"

# Default TTL: the marker may tune it; else 1200s. The sentinel carries its own
# ttl_seconds (written from the same marker), which wins inside the validator;
# this is only the fallback for a sentinel without one.
DEFAULT_TTL=1200
mttl=$(jq -r '.ttl_seconds // empty' "$MARKER" 2>/dev/null)
case "$mttl" in ''|*[!0-9]*) : ;; *) [ "$mttl" -gt 0 ] && DEFAULT_TTL="$mttl" ;; esac

SENTINEL=$(cat "$GITDIR/ship-pr-clearance" 2>/dev/null || echo "")
NOW=$(date +%s)
VERDICT=$(sg_sentinel_valid "$SENTINEL" "$NOW" "$DEFAULT_TTL")

# A fresh sentinel proves /ship was INVOKED. Second layer: does the create carry
# the FOOTPRINTS of a genuine run, or is it a partial/hand-driven ship missing
# them (mutwo PR #189)? Only runs on the valid-sentinel path, so it can only catch
# a partial ship that freshness would otherwise wave through - never make an
# already-blocked create worse. Entirely opt-in (a marker with no `completion`
# block pays nothing).
#
# Fail posture: dependency/marker problems (jq/git/lib missing, unparseable
# marker) fail OPEN and are logged, so a bug in this layer can never silently
# wedge a real ship. But a REQUIRED dimension the gate cannot evaluate (base ref
# unresolved, version unreadable) is recorded as "unknown" and, under require
# mode, fails toward BLOCK (the safe direction) with an actionable reason + a
# recorded-skip escape - it does NOT silently pass as "n/a". Every such decision
# is logged so a rotted/degraded gate is visible, never silent.
if [ "$VERDICT" = "valid" ]; then
  MARKERJSON=$(cat "$MARKER" 2>/dev/null || echo "{}")
  # An UNPARSEABLE marker must not silently disable enforcement: an opted-in repo
  # whose marker later corrupted would lose the completion gate with no trace.
  # Log the fail-open (then allow, consistent with the sentinel already having
  # validated). A VALID marker with no completion block is the common
  # not-opted-in case and stays silent at zero cost.
  if ! printf '%s' "$MARKERJSON" | jq -e . >/dev/null 2>&1; then
    sg_log "FAIL-OPEN .ship-gate.json unparseable in $TOP; completion layer skipped"
    exit 0
  fi
  if [ "$(printf '%s' "$MARKERJSON" | jq -r 'if .completion then "yes" else "no" end' 2>/dev/null)" != "yes" ]; then
    exit 0
  fi

  CLIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-completion-lib.sh"
  if [ ! -f "$CLIB" ]; then
    sg_log "FAIL-OPEN completion lib missing ($CLIB); gated create allowed in $TOP"
    exit 0
  fi
  # shellcheck source=/dev/null
  . "$CLIB"

  CMODE=$(sc_mode "$MARKERJSON")
  CREQ=$(sc_required "$MARKERJSON")

  # Resolve a base ref that exists locally (prefer the command's --base, else the
  # repo default) for the diff / ancestry checks. If none resolves, the
  # base-dependent dims fall to "na" (fail open).
  BREF=""
  if [ -n "$CMDBASE" ]; then
    for _cand in "origin/$CMDBASE" "$CMDBASE"; do
      git -C "$TOP" rev-parse -q --verify "${_cand}^{commit}" >/dev/null 2>&1 && { BREF="$_cand"; break; }
    done
  fi
  if [ -z "$BREF" ]; then
    _def=$(git -C "$TOP" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
    for _cand in "origin/${_def:-main}" "${_def:-main}" "origin/main" "main"; do
      git -C "$TOP" rev-parse -q --verify "${_cand}^{commit}" >/dev/null 2>&1 && { BREF="$_cand"; break; }
    done
  fi
  # When the base cannot be resolved locally (shallow / detached CI checkout,
  # origin never fetched, renamed default), the base-dependent dims below are
  # recorded "unknown", NOT "na": under require they fail toward BLOCK rather than
  # silently passing. Log it so the degraded enforcement is visible.
  [ -z "$BREF" ] && sg_log "FAIL-OPEN base ref unresolved in $TOP (cmdbase='${CMDBASE:-}'); base-dependent dims recorded unknown"

  HEADSHA=$(git -C "$TOP" rev-parse HEAD 2>/dev/null || echo "")

  # review: the /eng:cr (or /review) stamp names a commit that is on the BRANCH
  # SIDE of the merge-base - an ancestor of the tip but NOT already contained in
  # the base. Ancestor-not-equality means a post-review version-bump commit that
  # moves HEAD does not false-block (why /eng:cr counts, it writes
  # review-skill-head). Excluding commits already in base is load-bearing: without
  # it a leftover stamp from a PRIOR branch that has since landed in base would
  # sit in this branch's ancestry and grant a false review=ok with zero review of
  # the current work - the exact bypass this dimension exists to catch.
  _review=missing
  _rstamp=$(cat "$GITDIR/review-skill-head" 2>/dev/null || echo "")
  if [ -n "$_rstamp" ] && [ -n "$HEADSHA" ] \
     && git -C "$TOP" merge-base --is-ancestor "$_rstamp" "$HEADSHA" 2>/dev/null \
     && { [ -z "$BREF" ] || ! git -C "$TOP" merge-base --is-ancestor "$_rstamp" "$BREF" 2>/dev/null; }; then
    _review=ok
  fi

  # What this branch changed vs the base (three-dot: merge-base..HEAD).
  _changed=""
  [ -n "$BREF" ] && [ -n "$HEADSHA" ] && _changed=$(git -C "$TOP" diff --name-only "$BREF...$HEADSHA" 2>/dev/null || echo "")

  # docs-only fast lane: when every changed path is a DOC (by extension), the
  # changelog + version dims do not apply (na), mirroring merge-clearance's
  # bookkeeping fast lane so a trivial docs PR pays no ceremony. Two guards keep
  # it honest: (1) extension-only matching (no `^docs/` prefix, so code parked
  # under docs/ is not waved through); (2) behavior-contract instruction files
  # (SKILL.md / CLAUDE.md / AGENTS.md) are EXCLUDED even though they end in .md -
  # they change agent behavior, so a skill/instruction change cannot dodge the
  # required changelog/version by keeping its diff to markdown. Same exclusion set
  # as merge-clearance's mc_is_bookkeeping.
  _docs_only=no
  if [ -n "$_changed" ] \
     && ! printf '%s\n' "$_changed" | grep -qvE '(\.md$|\.mdx$|\.markdown$|\.txt$|\.rst$)' \
     && ! printf '%s\n' "$_changed" | grep -qE '(^|/)(SKILL|CLAUDE|AGENTS)\.md$'; then
    _docs_only=yes
  fi

  # changelog: the branch touched a CHANGELOG.md (top-level or nested). Base
  # unresolved -> unknown (cannot compute the branch diff).
  _changelog=unknown
  if [ -n "$BREF" ] && [ -n "$HEADSHA" ]; then
    if printf '%s\n' "$_changed" | grep -qE '(^|/)CHANGELOG\.md$'; then _changelog=ok
    elif [ "$_docs_only" = yes ]; then _changelog=na
    else _changelog=missing
    fi
  fi

  # version: package.json .version differs from base. No package.json / docs-only
  # -> na (dim does not apply). Base unresolved, or package.json present but its
  # version unreadable -> unknown (tried, could not tell).
  _version=na
  if [ -z "$BREF" ]; then
    _version=unknown
  elif [ "$_docs_only" != yes ] && git -C "$TOP" cat-file -e "$HEADSHA:package.json" 2>/dev/null; then
    _hv=$(git -C "$TOP" show "$HEADSHA:package.json" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
    _bv=$(git -C "$TOP" show "$BREF:package.json" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
    if [ -z "$_hv" ]; then _version=unknown
    elif [ "$_hv" != "$_bv" ]; then _version=ok
    else _version=missing
    fi
  fi

  # base_merged: the base tip is reachable from HEAD (base reconciled into branch).
  # Base unresolved -> unknown.
  _base=unknown
  if [ -n "$BREF" ] && [ -n "$HEADSHA" ]; then
    if git -C "$TOP" merge-base --is-ancestor "$BREF" "$HEADSHA" 2>/dev/null; then _base=ok; else _base=missing; fi
  fi

  STATES=$(jq -nc --arg r "$_review" --arg c "$_changelog" --arg v "$_version" --arg b "$_base" \
    '{review:$r, changelog:$c, version:$v, base_merged:$b}' 2>/dev/null || echo '{}')

  # Recorded skips: <gitdir>/ship-skip-<dim> carrying a human reason makes an
  # omission honest and auditable (the "no X happened" override, not a shortcut).
  # A skip is honored only when FRESH for the current run: its mtime must be at or
  # after this /ship run's start (ledger run_started_epoch). A skip left in the
  # per-worktree gitdir from a PRIOR PR is stale - it is ignored (and logged), so a
  # one-time honest skip can never silently waive a required dim on every future
  # ship. When no ledger exists (a deliberate human one-off with no /ship run), the
  # skip is honored - it was written on purpose and there is no run to bound it to.
  RUN_STARTED=""
  [ -f "$GITDIR/ship-run.json" ] && RUN_STARTED=$(jq -r '.run_started_epoch // empty' "$GITDIR/ship-run.json" 2>/dev/null)
  SKIPS='{}'
  for _d in review changelog version base_merged; do
    _sf="$GITDIR/ship-skip-$_d"
    [ -s "$_sf" ] || continue
    if [ -n "$RUN_STARTED" ]; then
      _mt=$(stat -f %m "$_sf" 2>/dev/null || stat -c %Y "$_sf" 2>/dev/null || echo 0)
      case "$_mt" in ''|*[!0-9]*) _mt=0 ;; esac
      if [ "$_mt" -lt "$RUN_STARTED" ]; then
        sg_log "STALE-SKIP ignored $_sf (mtime=$_mt < run_started=$RUN_STARTED) in $TOP"
        continue
      fi
    fi
    _reason=$(tr -d '\n' < "$_sf" 2>/dev/null | cut -c1-200)
    SKIPS=$(printf '%s' "$SKIPS" | jq -c --arg d "$_d" --arg r "$_reason" '.[$d]=$r' 2>/dev/null || printf '%s' "$SKIPS")
  done

  # Record the evidence snapshot: always to the audit log, and into ship-run.json
  # when the ledger exists. This is what makes a partial ship non-SILENT even in
  # record mode.
  sg_log "SHIP-EVIDENCE $TOP mode=$CMODE required=[$CREQ] states=$STATES skips=$SKIPS docs_only=$_docs_only base=${BREF:-none}"
  if [ -f "$GITDIR/ship-run.json" ]; then
    _tmp=$(mktemp "$GITDIR/.ship-run.XXXXXX" 2>/dev/null) && \
      jq -c --argjson st "$STATES" --argjson sk "$SKIPS" --arg mode "$CMODE" \
         --arg head "$HEADSHA" --argjson epoch "$NOW" \
         '.create_evidence={recorded_at_epoch:$epoch, head:$head, mode:$mode, states:$st, skips:$sk}' \
         "$GITDIR/ship-run.json" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$GITDIR/ship-run.json" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
  fi

  # Decide. In record mode (default / non-require) sc_blockers is empty -> allow.
  BLOCK=$(sc_blockers "$CMODE" "$CREQ" "$STATES" "$SKIPS")
  if [ -z "$BLOCK" ]; then
    exit 0
  fi

  _blocklist=$(printf '%s' "$BLOCK" | tr '\n' ' ' | sed 's/ *$//')
  _basenote=""
  [ -z "$BREF" ] && _basenote=" NOTE: the base branch could not be resolved locally (cmdbase='${CMDBASE:-}'), so changelog/version/base_merged could not be evaluated and are treated as unmet; fetch the base (e.g. \`git fetch origin\`) or record a skip."
  REASON="Ship gate (completion): this create is missing footprint evidence that /ship's checklist ran for: ${_blocklist}. A fresh /ship sentinel is present (so /ship was invoked), but these steps left no trace - the signature of a partial or hand-driven ship (mutwo PR #189). Fix each, or record an honest skip: for a dim you legitimately skipped, write a reason with \`echo 'reason=<why> policy=<ref>' > $GITDIR/ship-skip-<dim>\` and retry (the skip is honored only for this /ship run). Per dim: review -> run /eng:cr on this branch (it stamps review-skill-head); changelog -> add a CHANGELOG.md entry; version -> bump package.json .version; base_merged -> merge ${BREF:-the base} into this branch.${_basenote} Intentional and repo-opted-in via .ship-gate.json completion.require."
  sg_log "BLOCK ship-completion in $TOP missing=[$_blocklist]"
  jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
  exit 0
fi

REASON="Ship gate: open PRs in this repo via /ship, not a bare \`gh pr create\` [sentinel: ${VERDICT}]. /ship reconciles the base branch, runs tests/review, bumps VERSION, and opens the PR consistently; a bare create skips all of that and can sweep unrelated commits off a stale checkout. Run /ship to ship this change (it mints the clearance this gate checks). This is intentional: there is no agent-facing override. For a deliberate human one-off, temporarily remove this repo's .ship-gate.json marker, create the PR, then restore it."
sg_log "BLOCK gh pr create in $TOP [sentinel: $VERDICT]"
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
