#!/bin/bash
# Pure, side-effect-free decision logic for the merge-clearance gate, extracted so
# it can be unit tested (tests/merge-clearance-lib.bats) without a live repo, a PR,
# or the network. Every function takes everything it needs as arguments (including
# "now", so time-based checks are deterministic) and writes only to stdout.
#
# Consumers:
#   scripts/pr-merge-gate.sh  - sources mc_stamp_valid to decide whether to block
#                               a `gh pr merge`.
#   scripts/merge-clearance   - sources mc_cr_verdict / mc_cr_reviewed_head to turn
#                               GitHub GraphQL output into a CodeRabbit verdict.
#
# Requires jq for the JSON-parsing helpers. Callers that cannot guarantee jq must
# check for it first; these functions assume it is present (the gate fails OPEN
# before ever sourcing this, so a jq-less host never reaches here).

# mc_stamp_valid <stamp_json> <head_sha> <now_epoch> <default_ttl_seconds>
#   Decide whether a merge-clearance stamp authorizes merging <head_sha> right now.
#   Echoes "valid" on success; otherwise a single-word reason
#   (no-stamp | malformed | stale-head | expired). Return code mirrors the verdict
#   (0 valid, 1 otherwise) so callers can branch on either.
#
#   A stamp is a JSON object written by `merge-clearance clear`:
#     { "pr": N, "head": "<sha>", "base": "main", "checked_at": "<iso8601>",
#       "checked_at_epoch": <int>, "tool": "land-and-deploy",
#       "ttl_seconds": <int>, "evidence": { ... } }
#   The stamp's own ttl_seconds wins when present (so the writer controls the
#   window); <default_ttl_seconds> is the fallback for older stamps.
mc_stamp_valid() {
  local stamp="$1" head="$2" now="$3" default_ttl="$4"

  if [ -z "$stamp" ]; then echo "no-stamp"; return 1; fi

  # One jq pass pulls every field; a parse failure (truncated/corrupt stamp) or a
  # missing required field surfaces as "malformed" rather than a false "valid".
  local parsed
  parsed=$(printf '%s' "$stamp" | jq -r '
    [ (.head // "") , (.checked_at_epoch // "") , (.ttl_seconds // "") ] | @tsv
  ' 2>/dev/null) || { echo "malformed"; return 1; }

  local s_head s_epoch s_ttl
  IFS=$'\t' read -r s_head s_epoch s_ttl <<<"$parsed"

  [ -n "$s_head" ] || { echo "malformed"; return 1; }
  case "$s_epoch" in ''|*[!0-9]*) echo "malformed"; return 1 ;; esac

  [ "$s_head" = "$head" ] || { echo "stale-head"; return 1; }

  # ttl: stamp's own value if it is a positive integer, else the caller default.
  local ttl="$default_ttl"
  case "$s_ttl" in ''|*[!0-9]*) : ;; *) [ "$s_ttl" -gt 0 ] && ttl="$s_ttl" ;; esac
  case "$now" in ''|*[!0-9]*) echo "malformed"; return 1 ;; esac

  local age=$(( now - s_epoch ))
  if [ "$age" -lt 0 ] || [ "$age" -gt "$ttl" ]; then echo "expired"; return 1; fi

  echo "valid"; return 0
}

# mc_cr_verdict <threads_json> <reviews_json>
#   Turn GitHub GraphQL output for one PR into a CodeRabbit-resolution verdict.
#   Echoes one of: clear | unresolved | changes_requested. Returns 0 only for
#   "clear". This is the structural signal (Codex flagged that parsing the review
#   body string "Actionable comments posted: 0" is brittle; that string is fallback
#   evidence only, never the gate).
#
#   threads_json:  the PR's reviewThreads nodes, shape
#     [ { "isResolved": bool, "comments": { "nodes": [ { "author": {"login": "..."} } ] } }, ... ]
#   reviews_json:  the PR's reviews nodes (chronological), shape
#     [ { "author": {"login": "..."}, "state": "...", "submittedAt": "...", "commit": {"oid": "..."} }, ... ]
#
#   Precedence: an unresolved CodeRabbit thread is the most common actionable
#   blocker, so it wins; then a CHANGES_REQUESTED CodeRabbit review; else clear.
#   "coderabbitai" is matched as a case-insensitive substring of the author login
#   because the bot appears as both "coderabbitai" (GraphQL Bot) and
#   "coderabbitai[bot]" (REST) depending on the surface.
mc_cr_verdict() {
  local threads="$1" reviews="$2"

  # Fail CLOSED on degraded GitHub data. A GraphQL timeout / partial response (gh
  # exits 0 with .data present but null nodes) would otherwise reach here as
  # "null" or "", and a permissive default would emit a FALSE clear - the most
  # dangerous direction for this gate. null / empty / non-array inputs, and any
  # jq parse failure, all resolve to "unknown" (a blocker), never "clear".
  local t
  for t in "$threads" "$reviews"; do
    case "$t" in ''|null) echo "unknown"; return 1 ;; esac
  done
  printf '%s' "$threads" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "unknown"; return 1; }
  printf '%s' "$reviews" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "unknown"; return 1; }

  local unresolved
  unresolved=$(printf '%s' "$threads" | jq '
    [ .[]
      | select(.isResolved != true)
      | select( any(.comments.nodes[]?; (.author.login // "") | ascii_downcase | contains("coderabbitai")) )
    ] | length
  ' 2>/dev/null) || { echo "unknown"; return 1; }
  if [ "${unresolved:-0}" -gt 0 ] 2>/dev/null; then echo "unresolved"; return 1; fi

  # Latest CodeRabbit review state (last by array order, which the query returns
  # chronologically). COMMENTED / APPROVED do not block; CHANGES_REQUESTED does.
  local latest_state
  latest_state=$(printf '%s' "$reviews" | jq -r '
    [ .[] | select( (.author.login // "") | ascii_downcase | contains("coderabbitai") ) ]
    | (last // {}) | (.state // "")
  ' 2>/dev/null) || { echo "unknown"; return 1; }
  if [ "$latest_state" = "CHANGES_REQUESTED" ]; then echo "changes_requested"; return 1; fi

  echo "clear"; return 0
}

# mc_cr_reviewed_head <reviews_json> <head_sha>
#   Has CodeRabbit submitted at least one review whose commit oid is the current
#   HEAD? Echoes "yes" / "no". Used to avoid clearing a PR while CodeRabbit is
#   still mid-review of the latest push (Codex: confirm CR FINISHED the current
#   HEAD before clearing). A "no" is advisory - the live "CodeRabbit" commit-status
#   context is the stronger in-progress signal the CLI also checks.
mc_cr_reviewed_head() {
  local reviews="$1" head="$2"
  local hit
  hit=$(printf '%s' "$reviews" | jq -r --arg h "$head" '
    [ .[]
      | select( (.author.login // "") | ascii_downcase | contains("coderabbitai") )
      | select( (.commit.oid // "") == $h )
    ] | length
  ' 2>/dev/null) || hit=0
  if [ "${hit:-0}" -gt 0 ] 2>/dev/null; then echo "yes"; else echo "no"; fi
}

# mc_head_cr_unreviewable <files_json> <globs_json>
#   Decide whether the INCREMENTAL change at a PR HEAD is something CodeRabbit
#   legitimately cannot (or will not) review. This is the ONLY condition under
#   which "CodeRabbit has not reviewed this HEAD" must NOT block: when there was
#   nothing reviewable at this HEAD to begin with, CR's silence is not a gap.
#
#   Motivating case: a trailing commit whose only change is a Pencil `*.pen`
#   wireframe. Despite the "encrypted" framing, a .pen is plaintext JSON that git
#   treats as TEXT, so binary detection alone misses it; CodeRabbit still posts no
#   review on such a HEAD (its config / heuristics skip those paths). The glob
#   list is what carries that case; the binary flag covers genuinely binary blobs
#   (images, archives) without needing a per-repo glob.
#
#   files_json: the files changed by HEAD vs its parent, shape
#     [ { "path": "spec/x.pen", "binary": true|false }, ... ]   (binary = git
#     treats the blob as binary, i.e. numstat shows "-\t-").
#   globs_json:  patterns from the repo marker's cr_unreviewable_globs (the CLI
#     defaults this to ["*.pen"]), gitignore / minimatch style. A glob with NO
#     slash matches the path BASENAME at any depth (so "*.pen" catches
#     spec/wireframes/gmail-overlay.pen); a glob WITH a slash is anchored against
#     the full path. Tokens: "*" (a run of non-slash chars), "**" (a run incl.
#     slashes), "?" (one non-slash char), literal dots, exact segments. e.g.
#     "*.pen", "spec/wireframes/**", "spec/x.pen". Other regex metacharacters in
#     a glob are out of scope (documented, not escaped).
#
#   Echoes "yes" iff files_json is a NON-EMPTY array AND EVERY entry is either
#   git-binary OR matches at least one glob; else "no". An empty / non-array /
#   unparseable files_json is "no" (fail closed: never auto-satisfy on a diff we
#   could not read). The non-empty requirement means a zero-file HEAD never
#   auto-clears. A non-array globs_json is treated as [] (matches nothing), so a
#   malformed marker degrades to binary-only detection rather than over-clearing.
mc_head_cr_unreviewable() {
  local files="$1" globs="${2:-[]}"
  printf '%s' "$files" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "no"; return 1; }
  printf '%s' "$globs" | jq -e 'type=="array"' >/dev/null 2>&1 || globs='[]'
  local res
  res=$(jq -nc --argjson files "$files" --argjson globs "$globs" '
    # Translate a file glob to an anchored regex. Protect literal dots and **
    # behind private-use sentinels (never seen in a real path), expand * and ?,
    # then restore. Only "." is escaped (the one regex metachar realistic in a
    # path); exotic metachars in a glob are out of scope by design.
    def glob2re($g):
      "^" + ( $g
        | gsub("\\.";    "\uE000")   # protect literal dots
        | gsub("\\*\\*"; "\uE001")   # protect ** (matches across slashes)
        | gsub("\\*";    "[^/]*")     # *  -> run of non-slash chars
        | gsub("\uE001";  ".*")        # ** -> run incl. slashes
        | gsub("\\?";    "[^/]")      # ?  -> one non-slash char
        | gsub("\uE000";  "\\.") )   # restore dots, escaped
        + "$";
    # gitignore / minimatch semantics (what .coderabbit.yaml path_filters use):
    # a glob with NO slash (e.g. "*.pen") matches the basename at ANY depth, so
    # it catches spec/wireframes/gmail-overlay.pen; a glob WITH a slash (e.g.
    # "spec/wireframes/**") is anchored against the full path. Bind the glob to
    # $g BEFORE the "$p |"/"$base |" pipe: inside test(...) the pipe rebinds "."
    # to the path, so glob2re(.) would otherwise build a regex from the path and
    # match it against itself (everything passes). $g keeps the glob.
    def matches($p):
      ($p | split("/") | last) as $base
      | any($globs[]; . as $g
          | if ($g | test("/"))
            then ($p    | test(glob2re($g)))
            else ($base | test(glob2re($g))) end);
    if ($files | length) == 0 then false
    else
      # A null path (e.g. a malformed numstat row with < 3 fields) must NEVER be
      # treated as unreviewable just because .binary is true; require a real path
      # so a degenerate entry fails closed rather than auto-clearing.
      all($files[]; (.path != null) and ((.binary == true) or matches(.path)))
    end' 2>/dev/null) || { echo "no"; return 1; }
  if [ "$res" = "true" ]; then echo "yes"; return 0; fi
  echo "no"; return 1
}
# mc_qa_state <pr_body> <require_qa_plan:0|1>
#   Classify the QA checklist in the PR body's "## QA" section. Echoes one of:
#     complete   - the section has checkbox(es) and all are checked
#     incomplete - the section has at least one unchecked box (Dev QA not done)
#     missing    - require_qa_plan=1 AND the section has no checklist at all
#                  (no /qa:plan run); the b5 "require a QA plan to exist" gate
#     n/a        - no checklist and require_qa_plan=0 (legacy: QA not gated here)
#   Return code: 0 for complete / n/a (non-blocking), 1 for incomplete / missing.
#
#   The section spans the "## QA" heading down to the next heading of the SAME OR
#   HIGHER level, so deeper subheadings (### Development QA / ### Production QA,
#   where the boxes live) stay INSIDE. Fenced code blocks are skipped so a body
#   that documents the gate (```- [ ] ...```) is not parsed as real QA boxes.
#   require_qa_plan is opt-in per repo via .merge-clearance.json; default 0
#   preserves the prior behavior exactly (no checklist -> n/a, non-blocking).
mc_qa_state() {
  local body="$1" require="${2:-0}"
  local section
  section=$(printf '%s\n' "$body" | awk '
    BEGIN{inqa=0; qalevel=0; fence=0}
    {
      line=$0; h=line; sub(/^[[:space:]]*/,"",h)
      if (h ~ /^(```|~~~)/) { fence=!fence; next }
      if (fence) next
      if (h ~ /^#+[[:space:]]/) {
        n=0; while (substr(h,n+1,1)=="#") n++
        rest=substr(h,n+1)
        if (inqa==0) { if (rest ~ /^[[:space:]]+QA([[:space:]]|$|\()/) { inqa=1; qalevel=n; next } }
        else if (n<=qalevel) { inqa=0 }
      }
    }
    inqa{print}
  ')
  if printf '%s' "$section" | grep -q '\- \['; then
    if printf '%s' "$section" | grep -q '\- \[ \]'; then echo "incomplete"; return 1; fi
    echo "complete"; return 0
  fi
  if [ "$require" = "1" ]; then echo "missing"; return 1; fi
  echo "n/a"; return 0
}
