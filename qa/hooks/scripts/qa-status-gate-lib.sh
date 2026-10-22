#!/bin/bash
# Pure decision logic for the QA-status Stop gate, extracted so it can be unit
# tested without a live transcript or git repo. No side effects, no I/O beyond
# the args it is handed.
#
# qa_gate_decision <last_assistant_message> <shippable:0|1>
#   echoes "block" or "allow".
#
# Policy: make QA a first-class, stated posture at the moment work is declared
# done. If the message already carries a QA_STATUS line, the posture is stated,
# so allow. Otherwise, only gate when there is shippable work AND the message
# makes a (non-negated) completion claim. Everything else allows: this gate
# fails OPEN by design, so a miss is caught by the PR CI backstop rather than
# the gate nagging on a chat turn.
#
# Accepted postures (any one stated -> allow). The full contract for each, the
# QA-driver roster rules, and the CI asymmetry live in ONE home:
# docs/qa-status-postures.md. Keyword summary only here:
#   dev_verified                + EVIDENCE:   (alias: verified)
#   deploy_branch_for_manual_qa + DRIVER: <roster-id> + DEPLOYED:
#   prod_verified               + EVIDENCE:   (post-deploy only)
#   awaiting_human              + DRIVER: + CHECK: + PHASE: dev|prod
#   blocked                     + REASON:
#   skip_requested              + REASON:  (then a signed skip in the PR)
#   skip_approved               (the recorded human sign-off)
#   no_tracked_change           (docs/memory/ops-only turn; nothing to QA)
# This function only checks that SOME posture is stated, not that it is
# well-formed, on purpose: it is a "did you decide?" gate, not a linter. Keeping
# it shape-agnostic means a newly documented posture is accepted with no regex to
# keep in sync; docs/qa-status-postures.md carries the contract the agent reads
# (the block message names the keywords and points there).
#
# False-positive guards (the reason this is not a bare grep):
#   - Fenced code blocks are stripped before matching, so quoting or discussing
#     a trigger word (common in this very repo) does not block.
#   - The completion match is negation-aware ("not done", "isn't ready",
#     "don't merge yet" do NOT block), via fixed-width perl lookbehinds.

qa_gate_decision() {
  local msg="$1" shippable="$2"

  # Strip fenced code blocks FIRST, for BOTH checks: trigger words inside
  # ``` ... ``` (examples, quoted logs, the gate discussing itself) do not
  # count as a claim, and a QA_STATUS: token inside a fence is a quotation,
  # not a stated posture, so it must not satisfy the gate either.
  local clean
  clean=$(printf '%s\n' "$msg" | awk 'BEGIN{f=0} /^[[:space:]]*```/{f=!f; next} !f{print}')

  # Posture already stated (outside fences) -> allow regardless of anything else.
  if printf '%s' "$clean" | grep -qiE 'QA_STATUS:'; then
    echo allow
    return 0
  fi

  # No shippable work in the tree -> nothing to QA, allow.
  if [ "$shippable" != "1" ]; then
    echo allow
    return 0
  fi

  # Negation-aware completion claim. perl gives fixed-width negative lookbehinds
  # so "not done" / "isn't ready" / "never shipped" do not match. If perl is
  # missing or errors, the `if` sees a non-zero exit and we fall through to
  # allow (fail open).
  if printf '%s' "$clean" | /usr/bin/perl -0777 -ne '
      exit 0 if /(?<!not )(?<!n.t )(?<!never )\b(done|shipped|landed|opened (?:a |the )?pr|pr is up|ready to (?:merge|ship)|ready for merge|good to merge|all green)\b/i;
      exit 1;
  '; then
    echo block
    return 0
  fi

  echo allow
}

# ---------------------------------------------------------------------------
# Artifact-evidence check (incident hardening).
#
# Motivation: a change in a shared Docker BASE image was "prod_verified" by
# running the BASE image directly with `docker run`, but production runs
# PER-AGENT images derived FROM that base (e.g.
# nanoclaw-agent-v2-83c915c8:ag-...-main), which had silently gone stale. The
# QA plan had NAMED the correct production check; the executor substituted a
# weaker proxy at execution time and the gate accepted prod_verified on it. The
# bug was caught only by a later manual in-container smoke.
#
# These functions let the gate reject a Production-QA EVIDENCE line
# (prod_verified, or an awaiting_human production handoff) that names only an
# upstream / base / proxy artifact instead of the exact production artifact the
# approved plan named in its `Production artifacts:` field. They are PURE (no
# I/O): qa-status-gate.sh fetches the PR body, extracts the field, and passes
# it in.
#
# Conservative by construction (this gate fails OPEN and has fleet-wide blast
# radius). For prod_verified the only blocking verdict is `mismatch`, returned
# ONLY when the EVIDENCE references the SAME image family as a named plan
# artifact but NOT the exact production ref: the precise shape of a base/proxy
# substitution; evidence that does not reference the family at all passes. An
# engaged awaiting_human handoff is stricter: it must cite every required ref
# or digest of each artifact line (qa_awaiting_missing_refs), or it gets
# `block-uncited`. The awaiting_human path fails open when the field is absent
# or names no citable ref or digest (qa_citable_refs); the prod_verified path
# fails open when the field is absent or has no colon-joined token or digest
# at all (qa_artifact_refs / qa_artifact_digests).
# Enforcement engages only when a `Production artifacts:` field is actually
# present, so PRs without it behave exactly as before this change.

# qa_extract_evidence <message>
#   Echo every `EVIDENCE:` line found in the message (the substring from
#   `EVIDENCE:` to end of line). The downstream verdict does substring matching,
#   so the leading `EVIDENCE:` token is harmless and is left in place.
qa_extract_evidence() {
  printf '%s\n' "$1" | grep -oiE 'EVIDENCE:.*'
}

# qa_extract_prod_artifact <pr_body>
#   Echo each structured Production-artifact(s) field value from a PR body. The
#   /qa:plan template writes this field as `**Production artifacts:**` (bold,
#   plural); older plans wrote a plain `Production artifact:` line or a
#   `- Production artifact:` bullet. The match tolerates all of these: optional
#   leading indentation, list bullets, and `**` bold markers, in any order, with
#   the noun singular or plural. It stays ANCHORED to the start of a line so PROSE
#   that merely MENTIONS the words "Production artifact(s):" mid-sentence (e.g. a
#   PR summary describing the field, like this very repo's PRs) is NOT mistaken
#   for a declared artifact. Pure, so the hook's one impure step (the gh fetch) is
#   the only untested line.
#
#   The bullets under the label belong to the field too (see the function).
#
#   History: the anchor once required the singular `Production artifact:` with at
#   most one bullet char, so it never matched the template's bold plural label and
#   the artifact-evidence gate below sat DORMANT (fail-open on every PR). The
#   character class `[-*[:space:]]*` now absorbs `**`, bullets, and indent alike.
qa_extract_prod_artifact() {
  # The label line, plus what belongs to it: bullets, numbered items and
  # indented lines, even across blank lines (a label, a blank, then a list; or
  # a loose list), plain lead-in lines directly under the label, and the first
  # paragraph after a blank line when nothing else has been captured yet (a
  # label line naming a citable ref or digest, by the same qa_citable_refs /
  # qa_artifact_digests rule the gate uses, counts as captured). It ends at a heading, a table
  # row, an unindented bold `**Label:**` (a bulleted `- **Image:**` or indented
  # `  **Image:**` sub-label is part of the field), or a plain paragraph after
  # a blank line. /qa:plan writes the
  # field as a label with bullets underneath; a label-line-only match read that
  # as an EMPTY field, leaving the artifact check dormant on the common shape.
  # One capture flag per label line, in order, so a second field is judged
  # on its own label line rather than inheriting the first one's.
  local label_re='^[[:space:]]*[-*[:space:]]*production artifacts?:' rest lgs=""
  while IFS= read -r rest; do
    if [ -n "$(qa_citable_refs "$rest")$(qa_artifact_digests "$rest")" ]; then lgs="${lgs}1"; else lgs="${lgs}0"; fi
  done <<LABELS
$(printf '%s\n' "$1" | awk -v re="$label_re" '
    tolower($0) ~ re { r = substr($0, index(tolower($0), "production artifact")); sub(/^[^:]*:/, "", r); print r }')
LABELS
  printf '%s\n' "$1" | awk -v re="$label_re" -v lgs="$lgs" '
    { l = tolower($0) }
    l ~ re { n++; print; on = 1; gap = 0; got = substr(lgs, n, 1) + 0; next }
    !on { next }
    /^[[:space:]]*#/ || /^[[:space:]]*\|/ || /^\*\*[^*]+:\*\*/ { on = 0; next }
    /^[[:space:]]*$/ { gap = 1; next }
    /^[[:space:]]*[-*+][[:space:]]/ || /^[[:space:]]*[0-9]+[.)][[:space:]]/ || /^[[:space:]][[:space:]]+[^[:space:]]/ { print; gap = 0; got = 1; next }
    gap && got { on = 0; next }
    { print; gap = 0; got = 1 }
  '
}

# qa_artifact_refs / qa_artifact_digests <prod_artifact_field>  (PURE)
#   The machine-matchable production tokens the plan named, one per line:
#   every colon-joined name:tag token (image refs, host:port, skills, run ids;
#   not sha256:...) and sha256 digests. URLs are stripped first
#   so a "how it is exercised" URL like https://host:443/path is not read as an
#   image:tag ref. A registry with a port stays one token
#   (registry.acme.io:5000/team/agent:v1): split at ':5000/', the plan's
#   registry dropped out and a localhost:5000/... build cited the same path.
#   Shared by the verdict and the awaiting_human citation rule.
qa_artifact_refs() {
  printf '%s\n' "$1" | sed -E 's#https?://[^[:space:]]*##g' \
    | grep -oE '[A-Za-z0-9][A-Za-z0-9._/-]*(:[0-9]+/[A-Za-z0-9._/-]*)?:[A-Za-z0-9][A-Za-z0-9._-]*' | grep -viE '^sha256:' \
    | sed -E 's/[._-]+$//' || true
}
qa_artifact_digests() {
  printf '%s\n' "$1" | sed -E 's#https?://[^[:space:]]*##g' | grep -oiE 'sha256:[0-9a-f]{12,}' || true
}

# qa_citable_refs <prod_artifact_field>  (PURE)
#   The refs an awaiting_human handoff must cite, from the free-text field.
#   Included: a '/' in the name; a tag mixing digits with any non-digit
#   (letters, dots, hyphens: v1.4.2, 2026.10.13, 7f3c2a1, ag-1-main); an
#   all-digit tag of 6+ digits (no port or HH:MM is that long); an all-letter
#   tag (app:latest, but also a skill such as mu:pause from "/mu:pause"); a
#   short all-digit tag on a single-label name (agent:42, agent-web:1234, but
#   also host:port such as mini:22 or mac-mini:8080: a false block that names
#   it beats letting a short image name go unchecked). Dropped: an ISO time
#   such as 2026-10-13T14:05Z, an all-digit name or time range (14:05,
#   14:05/15:30), and dotted hostnames
#   or localhost with a port-length tag (the 6+-digit rule above runs first,
#   so registry.acme.io:20261013 is kept).
qa_citable_refs() {
  local tok base tag
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    base="${tok%:*}"; tag="${tok##*:}"
    case "$base" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) continue ;; esac
    case "$base" in *[!0-9:/]*) ;; *) continue ;; esac
    case "$base" in */*) printf '%s\n' "$tok"; continue ;; esac
    case "$tag" in *[!0-9]*) printf '%s\n' "$tok"; continue ;; esac
    [ "${#tag}" -ge 6 ] && { printf '%s\n' "$tok"; continue; }
    case "$base" in *.*|localhost) continue ;; esac
    printf '%s\n' "$tok"
  done <<EOF
$(qa_artifact_refs "$1")
EOF
  return 0
}

# qa_awaiting_missing_refs <fence_stripped_message> <prod_artifact_field>  (PURE)
#   The planned tokens an awaiting_human handoff has NOT cited, one per line;
#   empty means satisfied. Checked PER ARTIFACT LINE of the field (one bullet,
#   or the one inline line), so citing one image can never satisfy another: a
#   line is satisfied when every required ref on it is cited as a whole token
#   (a different build that merely extends a tag does not count), or every
#   digest on it is cited (a full digest citing a short planned one counts).
#   Every citable ref on a line is required: letting an unambiguous image ref
#   lower the bar for its neighbours masked second images on the same line
#   every way it was tried. A host or skill token beside an image (such as
#   mac-mini:8080 or /mu:pause) must be cited too; the block names it. A line's
#   digests count only when it names at most one required ref. Lines naming
#   nothing citable are skipped.
qa_awaiting_missing_refs() {
  local msg="$1" field="$2" tok line lrefs ldigs mrefs mdigs rmiss dmiss
  mrefs=$(qa_artifact_refs "$msg")
  mdigs=$(qa_artifact_digests "$msg")
  while IFS= read -r line; do
    ldigs=$(qa_artifact_digests "$line")
    lrefs=$(qa_citable_refs "$line")
    [ -n "$lrefs$ldigs" ] || continue
    rmiss=""; dmiss=""
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      printf '%s\n' "$mrefs" | grep -qxF -- "$tok" || rmiss="${rmiss}${tok}
"
    done <<EOF
$lrefs
EOF
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      printf '%s\n' "$mdigs" | grep -qiE "^${tok}" || dmiss="${dmiss}${tok}
"
    done <<EOF
$ldigs
EOF
    [ -n "$lrefs" ] && [ -z "$rmiss" ] && continue
    # A line's digests stand in for its refs only when it names at most one
    # required ref: one image's digest cannot vouch for a second image.
    if [ "$(printf '%s' "$lrefs" | grep -c .)" -le 1 ]; then
      [ -n "$ldigs" ] && [ -z "$dmiss" ] && continue
    fi
    printf '%s%s' "$rmiss" "$dmiss"
  done <<EOF
$field
EOF
  return 0
}

# qa_ref_families <ref>  (PURE)
#   The family names a ref belongs to, one per line: the base before the tag,
#   and, when its first path segment is a registry (has a '.' or ':', or is
#   localhost), the repo path without it, and for any path starting with
#   library/ (Docker Hub's implicit prefix, with or without a registry) the
#   name without it. A same-path image from another
#   registry or a local build (localhost:5000/team/agent) is then the same
#   family as registry.acme.io:5000/team/agent, so it reads as a substitution.
#   Callers match a distinctive family (6+ chars with '/' or '-') anywhere;
#   a short stripped name (myapp) only in image shape behind another
#   registry (mirror.io/myapp:v1, x/myapp@sha256), so prose cannot trip it.
qa_ref_families() {
  local base="${1%:*}" rp
  printf '%s\n' "$base"
  rp=$(printf '%s' "$base" | sed -E 's#^([^/]*[.:][^/]*|localhost)/##')
  [ "$rp" = "$base" ] || printf '%s\n' "$rp"
  # Docker Hub's implicit library/ prefix: docker.io/library/nginx-agent (or
  # library/nginx-agent) is also run as plain nginx-agent.
  case "$rp" in library/?*) printf '%s\n' "${rp#library/}" ;; esac
}

# qa_awaiting_citation_verdict <fence_stripped_message> <prod_artifact_field>
#   -> allow|block|block-uncited  (PURE)
#   allow when nothing is missing (qa_awaiting_missing_refs). Otherwise block
#   if the message names a missing ref's distinctive family (6+ chars with '/'
#   or '-', the base / proxy substitution): with another tag, path, digest or
#   suffix (family: family/ family@ family-), or bare when the token is image-shaped (a '/'
#   or a non-numeric tag), or when a short registry-stripped family appears in
#   image shape behind another registry (mirror.io/myapp:v1, x/myapp@sha256).
#   block-uncited otherwise, so a bare host named beside its uncited
#   host:port reads as a missing citation.
qa_awaiting_citation_verdict() {
  local msg="$1" field="$2" tok base missing fam_i
  missing=$(qa_awaiting_missing_refs "$msg" "$field")
  [ -n "$missing" ] || { echo allow; return 0; }
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    case "$tok" in sha256:*|SHA256:*) continue ;; esac
    fam_i=0
    while IFS= read -r base; do
      fam_i=$((fam_i + 1))
      if [ "$fam_i" -gt 1 ]; then
        case "$msg" in */"$base":*|*/"$base"@*) echo block; return 0 ;; esac
      fi
      if [ "${#base}" -ge 6 ] && printf '%s' "$base" | grep -qE '[/-]'; then
        # Another tag, path, digest or suffixed name (family-base) of the family
        # is a substitution. A bare
        # mention counts only for an image-shaped token (a '/' or a non-numeric
        # tag): a bare host such as mac-mini beside an uncited mac-mini:8080 is
        # a missing citation, not a stale image.
        case "$msg" in *"$base:"*|*"$base/"*|*"$base@"*|*"$base-"*) echo block; return 0 ;; esac
        case "$base:${tok##*:}" in */*:*|*:*[!0-9]*)
          case "$msg" in *"$base"*) echo block; return 0 ;; esac ;;
        esac
      fi
    done <<FAM
$(qa_ref_families "$tok")
FAM
  done <<EOF
$missing
EOF
  echo block-uncited
}

# qa_evidence_artifact_verdict <evidence_text> <prod_artifact_field>
#   Echo one of:
#     ok       -> evidence names the exact production artifact the plan named.
#     mismatch -> evidence references that artifact's image FAMILY (qa_ref_families:
#                 the base before the tag, the repo path without a
#                 registry segment, and a name without a leading library/)
#                 but NOT the exact ref -> a base/proxy
#                 substitution. THE ONLY BLOCKING VERDICT.
#     n/a      -> enforcement does not apply / cannot be decided -> fail open:
#                 no field, no machine-matchable token in the field, or the
#                 evidence does not reference the family at all.
#   Matchable tokens come from qa_artifact_refs / qa_artifact_digests: any
#   colon-joined name:tag (image refs, but also host:port, skills, run ids)
#   and sha256 digests. Artifacts with no `:` (a release version, a bundle id)
#   yield no token and return n/a; for those the plan prose carries the
#   discipline, not this gate. The family match is not limited to images, so
#   a planned host:port family (mac-mini) can drive mismatch here; the
#   awaiting_human verdict narrows that (qa_awaiting_citation_verdict). An
#   image pinned by digest only (repo@sha256:...) also adds its repo as a
#   family (mismatch only, never ok).
qa_evidence_artifact_verdict() {
  local evidence="$1" field="$2"

  # Backward compat: no Production artifacts field -> enforcement disabled.
  [ -n "$(printf '%s' "$field" | tr -d '[:space:]')" ] || { echo "n/a"; return 0; }

  local refs digests tok pinned
  refs=$(qa_artifact_refs "$field")
  digests=$(qa_artifact_digests "$field")
  # An image pinned by digest only (repo@sha256:...) has no name:tag token, so
  # its repo goes into the family check as repo:@ (the tag is never read).
  # The match must not start right after a ':' or a name character, so a
  # name:tag@sha256 ref (whose name:tag is already in $refs) adds nothing and
  # its tag never becomes a family.
  pinned=$(printf '%s\n' "$field" | sed -E 's#https?://[^[:space:]]*##g' \
    | grep -oE '(^|[^:A-Za-z0-9._/-])[A-Za-z0-9][A-Za-z0-9._/-]*(:[0-9]+/[A-Za-z0-9._/-]*)?@sha256:' \
    | sed -E 's/^[^A-Za-z0-9]//; s/@sha256:$/:@/' || true)

  # 1) Evidence names the exact production artifact (full ref or digest) -> ok.
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    case "$evidence" in *"$tok"*) echo "ok"; return 0 ;; esac
  done <<EOF
$refs
$digests
EOF

  # 2) Evidence references a ref's image FAMILY (qa_ref_families) but not the
  #    exact ref -> base/proxy substitution -> mismatch. A DISTINCTIVE family
  #    (length >= 6 AND containing '-' or '/') counts anywhere, so generic
  #    word:word prose cannot trigger a block; a short registry-stripped name
  #    counts only in image shape behind another registry.
  local base fam_i
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    fam_i=0
    while IFS= read -r base; do
      fam_i=$((fam_i + 1))
      if [ "${#base}" -ge 6 ] && printf '%s' "$base" | grep -qE '[/-]'; then
        case "$evidence" in *"$base"*) echo "mismatch"; return 0 ;; esac
      fi
      if [ "$fam_i" -gt 1 ]; then
        case "$evidence" in */"$base":*|*/"$base"@*) echo "mismatch"; return 0 ;; esac
      fi
    done <<FAM
$(qa_ref_families "$tok")
FAM
  done <<EOF
$refs
$pinned
EOF

  # 3) Evidence does not reference the family at all -> cannot decide -> fail open.
  echo "n/a"
  return 0
}

# qa_strip_fences <message>  -> message without ``` fenced blocks  (PURE)
#   The one fence stripper the artifact check uses, so the hook's network
#   prefilter and qa_artifact_gate decide on exactly the same text.
qa_strip_fences() {
  printf '%s\n' "$1" | awk 'BEGIN{f=0} /^[[:space:]]*```/{f=!f; next} !f{print}'
}

# The patterns qa_artifact_engages decides with and qa_artifact_engage_reason
# explains with. Shared so the explanation cannot drift from the decision.
# Plain (not readonly) so re-sourcing the lib, as bats does per test, is safe.
QA_PROD_VERIFIED_RE='QA_STATUS:[[:space:]]*prod_verified'
# Markup (bold, backticks) and a hyphen or space for the underscore all count:
# a reworded posture must not skip the check. prod_verified keeps its strict
# form here; its markup gap is the pre-existing follow-up, not this change.
QA_AWAITING_HUMAN_RE='QA_STATUS:[*`_[:space:]]*awaiting[-_[:space:]]?human'
QA_PHASE_TOKEN_RE='PHASE[*`_[:space:]]*[:=|-][^[:alnum:]]*[[:alnum:]][[:alnum:]-]*'
QA_PHASE_DEV_RE='[^[:alnum:]-](dev|development)$'
QA_PROD_WORD_RE='(^|[^[:alnum:]])(pre-?)?prod(uction)?([^[:alnum:]]|$)'

# qa_artifact_engages <fence_stripped_message>  -> yes|no  (PURE)
#   Whether a message makes a Production-QA evidence claim the artifact check
#   must inspect. A `QA_STATUS: prod_verified` posture engages. So does an
#   `awaiting_human` posture (bold or backticked too), UNLESS it is plainly dev:
#   every `PHASE <separator> <value>` token in the message (separator `:`, `=`,
#   `|` or a spaced ` - `, markup tolerated; an unspaced "PHASE-dev" is not
#   read as dev and engages) has the value `dev` or `development`, at
#   least one such token exists, and NO line pairs `PHASE` with the word prod
#   (`prod`, `production`, `pre-prod`, `preprod`; not "product" or "reproduce")
#   anywhere after it. So "PHASE: post-deploy" engages as surely as "prod".
#   An awaiting_human production handoff's EVIDENCE closes the agent-runnable
#   Production rows before the human's check, so a base / proxy artifact there
#   is the same stale-image risk.
#   Both tests match anywhere in the text rather than parsing "PHASE lines":
#   every line-parsing rule tried here was beaten by formatting (a one-line
#   posture, recap bullets, tables, list markers, "e.g."). Once a message has a
#   non-dev PHASE token or a PHASE/prod pairing, no added text can cancel it;
#   the only way out is a message whose every PHASE token is dev. Everything
#   ambiguous engages (fail closed): no PHASE at all, "devops", "dev and prod",
#   the "dev|prod" menu, prose such as "next we move to PHASE: prod". Engaging
#   only means evidence gets checked; a missing `Production artifacts:` field
#   (no PR on the current branch, e.g. a deploy run from main) still fails open
#   downstream. Known residual: an agent that never pairs PHASE with prod, and
#   declares PHASE: dev on what is really a post-deploy handoff, is not checked.
#   The block message must never coach that relabel.
qa_artifact_engages() {
  local msg="$1" values
  if printf '%s' "$msg" | grep -qiE "$QA_PROD_VERIFIED_RE"; then
    echo yes; return 0
  fi
  if printf '%s' "$msg" | grep -qiE "$QA_AWAITING_HUMAN_RE"; then
    values=$(printf '%s\n' "$msg" | grep -oiE "$QA_PHASE_TOKEN_RE")
    if [ -n "$values" ] \
       && ! printf '%s\n' "$values" | grep -viqE "$QA_PHASE_DEV_RE" \
       && ! printf '%s\n' "$msg" | grep -qiE "PHASE.*${QA_PROD_WORD_RE}"; then
      echo no; return 0
    fi
    echo yes; return 0
  fi
  echo no
}

# qa_artifact_engage_reason <fence_stripped_message>  -> one line  (PURE)
#   Why qa_artifact_engages said yes, for the block message, so an agent whose
#   honest dev handoff was engaged by a stray mention (a "Phase" table header,
#   a "PHASE: prod" remark) can see the exact text and reword it. Echoes the
#   prod_verified posture if stated, else the span from PHASE to prod on the
#   first line pairing them, else the first non-dev PHASE token, else a
#   neutral "treated as prod" note (worded so it never reads as "add PHASE:
#   dev"). Every branch is cut to 80 chars. It reads the same
#   QA_*_RE patterns as qa_artifact_engages, so the two cannot drift; it never
#   changes the decision, it only explains it.
qa_artifact_engage_reason() {
  local msg="$1" why line
  if printf '%s' "$msg" | grep -qiE "$QA_PROD_VERIFIED_RE"; then
    echo "QA_STATUS: prod_verified"; return 0
  fi
  line=$(printf '%s\n' "$msg" | grep -iE "PHASE.*${QA_PROD_WORD_RE}" | head -n 1)
  if [ -n "$line" ]; then
    # The span, so a trigger past column 80 of a wide row still shows.
    why=$(printf '%s\n' "$line" | grep -oiE "PHASE.{0,60}${QA_PROD_WORD_RE}" | head -n 1)
    [ -n "$why" ] || why=$(printf '%s\n' "$line" | grep -oiE 'PHASE.*' | head -n 1)
  else
    why=$(printf '%s\n' "$msg" | grep -oiE "$QA_PHASE_TOKEN_RE" \
          | grep -viE "$QA_PHASE_DEV_RE" | head -n 1)
  fi
  [ -n "$why" ] || why="awaiting_human with no PHASE stated (treated as prod)"
  printf '%s\n' "$why" | cut -c1-80
}

# qa_artifact_gate <message> <prod_artifact_field>  -> block|block-uncited|allow  (PURE)
#   The composable gate decision used by the Stop hook AND the bats tests. Blocks
#   ONLY when the message makes a Production-QA evidence claim
#   (qa_artifact_engages decides: prod_verified, or an awaiting_human that is
#   not plainly PHASE: dev) AND
#   its EVIDENCE names a base/proxy artifact instead of the production artifact
#   the plan named (block). For an engaged awaiting_human the WHOLE unfenced
#   message is matched instead of the EVIDENCE line: it must cite the exact
#   artifact when the plan names a citable ref (qa_citable_refs) or digest, or it gets
#   block-uncited (a base-only mention is block);
#   prod_verified with no EVIDENCE line still allows (follow-up).
#   Any other posture or a non-blocking verdict -> allow.
qa_artifact_gate() {
  local msg="$1" field="$2"

  # Strip fenced code blocks so a message that quotes or discusses the posture
  # inside ``` ... ``` does not engage enforcement (same guard as the posture gate).
  local clean
  clean=$(qa_strip_fences "$msg")

  # Scope: Production-QA claims only, as qa_artifact_engages decides. dev_verified and an
  # awaiting_human PHASE: dev handoff are exercised against a dev / preview
  # artifact by design; enforcing them would be a category error and could
  # false-block correct dev QA.
  [ "$(qa_artifact_engages "$clean")" = "yes" ] || { echo allow; return 0; }

  # An awaiting_human production handoff must CITE the artifact its agent rows
  # ran against: anywhere in the unfenced message, so a bold or dashed label
  # still counts, but a placeholder ("EVIDENCE: n/a"), a missing line, or prose
  # that never names the ref does not. Only when the plan names a citable ref
  # (see qa_citable_refs: an image ref, or a token such as app:latest,
  # mu:pause, agent-web:1234 or mac-mini:8080) or a digest; otherwise fail open.
  # prod_verified keeps its EVIDENCE-line rule below, missing line included,
  # until the follow-up gate change.
  if printf '%s' "$clean" | grep -qiE "$QA_AWAITING_HUMAN_RE" \
     && [ -n "$(qa_citable_refs "$field")$(qa_artifact_digests "$field")" ]; then
    qa_awaiting_citation_verdict "$clean" "$field"
    return 0
  fi
  # Nothing citable means nothing the gate could match is an image (a dotted
  # host, a bundle or deploy id): the EVIDENCE-line verdict below would read a
  # host named in EVIDENCE as an image "family" and false-block an honest
  # handoff, so an awaiting_human-only turn fails open here.
  if printf '%s' "$clean" | grep -qiE "$QA_AWAITING_HUMAN_RE" \
     && ! printf '%s' "$clean" | grep -qiE "$QA_PROD_VERIFIED_RE"; then
    echo allow; return 0
  fi

  local evidence
  evidence=$(qa_extract_evidence "$clean")
  [ -n "$evidence" ] || { echo allow; return 0; }   # no evidence to evaluate -> fail open

  if [ "$(qa_evidence_artifact_verdict "$evidence" "$field")" = "mismatch" ]; then
    echo block
    return 0
  fi
  echo allow
}
