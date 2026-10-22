#!/bin/bash
# land-and-deploy-patch - keep the gstack /land-and-deploy skill wired into the
# merge-clearance gate.
#
# WHY: /land-and-deploy lives in the upstream garrytan/gstack clone, so every
# /gstack-upgrade rewrites it. Twice that silently dropped the two merge-clearance
# call sites (the last time on 2026-10-22, after upstream split the skill into
# SKILL.md + sections/*.md), so /land-and-deploy stopped posting the required
# `local-review/merge-clearance` status and every merge had to be cleared by hand.
# A doc describing the hunks was not enough: nothing re-applied it.
#
# This script IS the re-application. The hunk texts live next to it
# (../patches/land-and-deploy/*.md) and are inserted as marker-delimited blocks:
#   hunk1-readiness.md  before the line `### 3.5e...` (the readiness report)
#   hunk2-merge.md      before the first `### ` heading inside `## Step 4...`
# Anchors are searched across SKILL.md and sections/*.md (generated files only,
# never *.tmpl), so a move between files does not break it. Each block carries a
# checksum of its hunk text, so editing a hunk here re-applies it everywhere.
#
# Who runs it:
#   - bin/install (`apply`), on every install / upgrade of this repo.
#   - the eng plugin's hooks (`hook`), on every /land-and-deploy invocation, so a
#     gstack upgrade between installs heals itself before the skill body is read.
#
# Verbs:
#   apply [skill-dir]  insert or refresh both blocks. Exit 0 applied or current,
#                      2 an anchor is missing (that file is left untouched),
#                      3 the skill is not installed.
#   check [skill-dir]  read-only. Exit 0 both current, 1 missing or stale,
#                      2 an anchor is missing, 3 not installed.
#   hook (or no verb)  PreToolUse(Skill) / UserPromptSubmit payload on stdin. Only
#                      acts on a /land-and-deploy invocation, runs `apply`, and
#                      NEVER blocks (always exit 0); a missing anchor is reported
#                      as additional context so the agent knows the gate wiring is
#                      absent for this run.
#
# Default skill dir: $GSTACK_LAND_DEPLOY_DIR, else ~/.claude/skills/gstack/land-and-deploy.

set -u

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES="$HERE/../patches/land-and-deploy"
MARK="gstack-extensions:merge-clearance"

# hunk id : hunk text file
HUNKS="hunk1:hunk1-readiness.md hunk2:hunk2-merge.md"

hunk_sum() { cksum < "$PATCHES/$1" | cut -d' ' -f1; }

# The generated markdown files to search, in a stable order.
skill_files() {
  local d="$1" f
  [ -f "$d/SKILL.md" ] && printf '%s\n' "$d/SKILL.md"
  for f in "$d"/sections/*.md; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

# anchor_line <hunk-id> <file>: 1-based line to insert BEFORE, or empty.
anchor_line() {
  case "$1" in
    hunk1) awk '/^### 3\.5e[: ]/ { print NR; exit }' "$2" ;;
    # Bounded to Step 4: a Step 4 with no ### sub-step is an anchor miss (exit 2),
    # never an insertion into the next ## section.
    hunk2) awk 'in4 && /^## / { exit } in4 && /^### / { print NR; exit } /^## Step 4[: ]/ { in4=1 }' "$2" ;;
  esac
}

# block_state <hunk-id> <file>: current | stale | absent
block_state() {
  local id="$1" file="$2" sum
  sum=$(hunk_sum "${3}")
  if grep -qF "<!-- $MARK:$id:begin $sum -->" "$file"; then echo current
  elif grep -qF "<!-- $MARK:$id:begin" "$file"; then echo stale
  else echo absent; fi
}

# strip_block <hunk-id> <file> -> stdout without that hunk's block.
strip_block() {
  awk -v b="<!-- $MARK:$1:begin" -v e="<!-- $MARK:$1:end -->" '
    index($0, b) == 1 { skip = 1; next }
    skip && index($0, e) == 1 { skip = 0; next }
    !skip { print }' "$2"
}

# locate <hunk-id> <skill-dir>: "file<TAB>state" for the file holding the block
# (any state) or, failing that, the anchor. Empty when neither exists.
locate() {
  local id="$1" dir="$2" hf="$3" f
  while IFS= read -r f; do
    if grep -qF "<!-- $MARK:$id:begin" "$f"; then
      printf '%s\t%s' "$f" "$(block_state "$id" "$f" "$hf")"; return 0
    fi
  done < <(skill_files "$dir")
  while IFS= read -r f; do
    if [ -n "$(anchor_line "$id" "$f")" ]; then
      printf '%s\tabsent' "$f"; return 0
    fi
  done < <(skill_files "$dir")
  return 1
}

apply_one() {
  local id="$1" dir="$2" hf="$3" loc file state tmp line sum rc
  loc=$(locate "$id" "$dir" "$hf") || { echo "land-and-deploy-patch: $id anchor not found under $dir" >&2; return 2; }
  file=${loc%%$'\t'*}; state=${loc#*$'\t'}
  [ "$state" = current ] && return 0
  tmp=$(mktemp "${file}.XXXXXX") || return 2
  strip_block "$id" "$file" > "$tmp"
  line=$(anchor_line "$id" "$tmp")
  if [ -z "$line" ]; then
    rm -f "$tmp"
    echo "land-and-deploy-patch: $id anchor not found in $file" >&2
    return 2
  fi
  sum=$(hunk_sum "$hf")
  awk -v at="$line" -v b="<!-- $MARK:$id:begin $sum -->" -v e="<!-- $MARK:$id:end -->" -v body="$PATCHES/$hf" '
    NR == at {
      print b
      while ((getline l < body) > 0) print l
      print e
      print ""
    }
    { print }' "$tmp" > "$tmp.new" && mv -f "$tmp.new" "$tmp" && mv -f "$tmp" "$file"
  rc=$?
  rm -f "$tmp" "$tmp.new" 2>/dev/null
  [ "$rc" -eq 0 ] || return 2
  [ "$state" = stale ] && state=refreshed || state=applied
  echo "land-and-deploy-patch: $id $state in ${file#"$dir"/}"
  return 0
}

run() {
  local verb="$1" dir="$2" pair id hf loc rc=0 r
  [ -d "$dir" ] || { echo "land-and-deploy-patch: no skill at $dir (gstack not installed?)" >&2; return 3; }
  for pair in $HUNKS; do
    id=${pair%%:*}; hf=${pair#*:}
    if [ "$verb" = apply ]; then
      apply_one "$id" "$dir" "$hf"; r=$?
      [ "$r" -gt "$rc" ] && rc=$r
    else
      if ! loc=$(locate "$id" "$dir" "$hf"); then
        echo "$id: anchor missing"; rc=2; continue
      fi
      echo "$id: ${loc#*$'\t'} (${loc%%$'\t'*})"
      case "${loc#*$'\t'}" in current) ;; *) [ "$rc" -lt 1 ] && rc=1 ;; esac
    fi
  done
  return "$rc"
}

DIR_DEFAULT="${GSTACK_LAND_DEPLOY_DIR:-$HOME/.claude/skills/gstack/land-and-deploy}"

case "${1:-hook}" in
  apply|check)
    run "$1" "${2:-$DIR_DEFAULT}"; exit $? ;;
  hook)
    command -v jq >/dev/null 2>&1 || exit 0
    PAYLOAD=$(cat)
    EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null)
    case "$EVENT" in
      PreToolUse)
        [ "$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty')" = Skill ] || exit 0
        SKILL=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.skill // .tool_input.name // "") | ascii_downcase' 2>/dev/null)
        case "$SKILL" in land-and-deploy|*:land-and-deploy|*/land-and-deploy) ;; *) exit 0 ;; esac ;;
      UserPromptSubmit)
        printf '%s' "$PAYLOAD" | jq -r '.prompt // empty' \
          | grep -Eiq '^[[:space:]]*/land-and-deploy([[:space:]]|$)' || exit 0 ;;
      *) exit 0 ;;
    esac
    OUT=$(run apply "$DIR_DEFAULT" 2>&1); RC=$?
    if [ "$RC" -eq 2 ]; then
      MSG="The gstack /land-and-deploy skill could not be re-wired into the merge-clearance gate (an anchor moved upstream): $OUT. This run will not post the clearance by itself; before merging, run ~/.claude/scripts/merge-clearance.sh clear from the PR branch, and update eng/hooks/scripts/land-and-deploy-patch.sh anchors in gstack-extensions."
      jq -nc --arg e "$EVENT" --arg c "$MSG" '{hookSpecificOutput:{hookEventName:$e, additionalContext:$c}}'
    fi
    exit 0 ;;
  *)
    echo "usage: land-and-deploy-patch.sh <apply|check> [skill-dir] | hook" >&2
    exit 64 ;;
esac
