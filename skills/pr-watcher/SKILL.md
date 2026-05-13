---
name: pr-watcher
description: Foreground watcher that polls a GitHub PR for CodeRabbit feedback, waits for each CR review to finish posting, then dispatches the entire batch to ONE Claude subagent that works through findings sequentially in a single working tree (read file, edit, run tests, commit, push, reply on the PR). Blocks the current session; never detaches; never merges; never resolves conversations; never pushes without passing tests; never touches files outside the PR's own diff; never parallelizes fixes on the same branch. Use when asked to "watch the PR", "watch coderabbit", "pr watch", or invoked manually as `/pr-watcher <PR_URL>` after /ship.
---

# pr-watcher

You are running the `/pr-watcher` skill. It watches a single PR for CodeRabbit (`coderabbitai[bot]`) activity and applies fixes the user approves in the watcher's contract.

## How this skill executes

The skill alternates between two phases until the PR is closed/merged or a wall-clock timeout fires:

1. **POLL** — one Bash call that runs an inner loop of `gh` queries, sleeping ~60s between rounds. Actionable items accumulate into `inbox.json` across iterations. The loop exits early only when CodeRabbit's review has finished posting (see "Review-completion detection" below), when the PR is no longer OPEN, or after ~9 minutes. Idle minutes produce zero conversation turns.
2. **HANDLE** — when POLL exits with a non-empty inbox, dispatch the **entire batch** to a single triage subagent via the Agent tool. That subagent owns the working tree exclusively, processes findings sequentially, commits each fix atomically, and reports a list of results. Only one subagent is ever running at a time, so concurrent edits on the same branch are impossible.

You re-enter POLL after every HANDLE phase. The loop ends when POLL reports `STATE=closed`, `STATE=merged`, or `STATE=timeout`.

### Review-completion detection

CodeRabbit posts a placeholder comment first, then edits/finalizes its review over several seconds. Acting on partial output causes the subagent to fix a moving target. Wait for completion. The watcher considers a review "complete" when **either** signal fires:

- **Definitive marker.** A review record exists whose body matches `^Actionable comments posted:` (CR posts this once it has finished walking the diff). All inline review_comments tied to the same `submitted_at` window are then stable.
- **Quiet period.** At least 120 seconds have passed since the most recent new-or-edited CodeRabbit comment across all three streams, AND the inbox contains at least one unhandled actionable item.

Whichever fires first triggers POLL exit. If neither has fired within the 9-minute inner deadline, POLL exits with `STATE=idle_with_inbox` and you immediately re-invoke it — the inbox carries over.

## What this skill WILL NOT do

- Merge the PR
- Mark CodeRabbit conversations as resolved
- Push a commit when tests do not pass
- Edit files outside the PR's own changed-file list (the "fix scope")
- Change architecture, scope, or design decisions locked before this watch began
- Run in the background after the session exits

If a finding requires any of the above, mark it seen with `status=needs_user_input`, log it to `escalations.jsonl`, and continue.

---

## Step 0: Parse arguments and resolve the PR

Determine the PR URL from the user's invocation. If they passed a full GitHub URL, use it. If they passed `#123` or `123`, resolve against the current repo. If they passed nothing, use `gh pr view --json url -q .url` on the current branch.

```bash
set -euo pipefail
PR_INPUT="${1:-}"
if [[ -z "$PR_INPUT" ]]; then
  PR_URL=$(gh pr view --json url -q .url 2>/dev/null || true)
elif [[ "$PR_INPUT" =~ ^https?:// ]]; then
  PR_URL="$PR_INPUT"
elif [[ "$PR_INPUT" =~ ^#?([0-9]+)$ ]]; then
  PR_NUM="${BASH_REMATCH[1]}"
  PR_URL=$(gh pr view "$PR_NUM" --json url -q .url 2>/dev/null || true)
else
  PR_URL=""
fi
[[ -z "$PR_URL" ]] && { echo "ERROR: could not resolve PR. Pass a URL or run from a branch with an open PR." >&2; exit 2; }

# Parse owner / repo / number
if [[ "$PR_URL" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
  PR_NUM="${BASH_REMATCH[3]}"
else
  echo "ERROR: PR_URL does not look like a GitHub PR URL: $PR_URL" >&2
  exit 2
fi

KEY="${OWNER}__${REPO}__${PR_NUM}"
STATE_DIR="$HOME/.cache/pr-watcher/$KEY"
mkdir -p "$STATE_DIR"
echo "PR=$PR_URL"
echo "KEY=$KEY"
echo "STATE_DIR=$STATE_DIR"
```

If `PR_URL` cannot be resolved, stop and tell the user.

## Step 1: Verify prerequisites

```bash
command -v gh >/dev/null || { echo "ERROR: gh CLI not installed" >&2; exit 2; }
command -v jq >/dev/null || { echo "ERROR: jq not installed" >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated. Run: gh auth login" >&2; exit 2; }
```

## Step 2: Discover config

The watcher needs three pieces of config: **fix scope** (which files it may edit), **test command** (what to run before pushing a fix), and **timeout** (when to give up).

Fix scope defaults to the set of files currently changed in this PR. The watcher will refresh this list on every POLL so newly-touched files come into scope automatically.

```bash
# Test command: prefer CLAUDE.md "## Testing" section, fall back to package.json scripts.test, fall back to ask.
TEST_CMD=""
if [[ -f CLAUDE.md ]]; then
  TEST_CMD=$(awk '/^## Testing/{flag=1;next} /^## /{flag=0} flag && /^[ \t]*`/{gsub(/^[ \t]*`|`[ \t]*$/,""); print; exit}' CLAUDE.md 2>/dev/null || true)
fi
if [[ -z "$TEST_CMD" && -f package.json ]]; then
  TEST_CMD=$(jq -r '.scripts.test // empty' package.json 2>/dev/null)
  [[ -n "$TEST_CMD" ]] && TEST_CMD="npm test"
fi
echo "TEST_CMD=${TEST_CMD:-<unknown>}"

TIMEOUT_SECONDS="${PR_WATCHER_TIMEOUT:-28800}"  # default 8 hours
echo "TIMEOUT_SECONDS=$TIMEOUT_SECONDS"
echo "WATCH_STARTED=$(date +%s)" > "$STATE_DIR/started"
```

If `TEST_CMD` resolved to `<unknown>`, ask the user once via AskUserQuestion: "What's the test command for this repo? (e.g., `bun test`, `pytest`, `make test`)" Save their answer to `$STATE_DIR/test_cmd`.

Initialize seen-fingerprint stores if absent:

```bash
for f in issue_comments reviews review_comments; do
  [[ -f "$STATE_DIR/$f.seen.json" ]] || echo '{}' > "$STATE_DIR/$f.seen.json"
done
: > "$STATE_DIR/escalations.jsonl"
```

Print a one-line start banner:

```
🐇 Watching PR #<NUM> (<owner>/<repo>). Tests: <TEST_CMD>. Timeout: <hours>h. Ctrl-C to stop.
```

## Step 3: POLL — one inner-loop bash call

Run this Bash with `timeout: 570000` (9.5 minutes). The inner loop accumulates actionable items into `inbox.json` across polls and only exits with `STATE=actionable` once CodeRabbit's review is detected complete. **Re-invoke this same block after every HANDLE phase** until `STATE` reports `closed`, `merged`, or `timeout`.

```bash
set -euo pipefail
PR_NUM="<resolved in Step 0>"
OWNER="<resolved>"
REPO="<resolved>"
STATE_DIR="$HOME/.cache/pr-watcher/${OWNER}__${REPO}__${PR_NUM}"
STARTED=$(cat "$STATE_DIR/started" | cut -d= -f2)
TIMEOUT_SECONDS=28800   # or value resolved in Step 2
QUIET_PERIOD=120        # seconds of no CR activity to consider a review settled

INNER_DEADLINE=$(( $(date +%s) + 540 ))

# Inbox carries over between POLL invocations until HANDLE consumes it.
[[ -f "$STATE_DIR/inbox.json" ]] || echo '[]' > "$STATE_DIR/inbox.json"

# Completion-signal state carries over too. Reset on each successful HANDLE.
[[ -f "$STATE_DIR/last_cr_activity_at" ]] || echo 0 > "$STATE_DIR/last_cr_activity_at"
[[ -f "$STATE_DIR/completion_marker_seen" ]] || echo "false" > "$STATE_DIR/completion_marker_seen"

while : ; do
  NOW=$(date +%s)
  if (( NOW > STARTED + TIMEOUT_SECONDS )); then
    echo "STATE=timeout"
    break
  fi
  if (( NOW > INNER_DEADLINE )); then
    # Hand control back to the parent so we don't hit the Bash tool timeout.
    # Parent re-invokes POLL; inbox + state files persist.
    echo "STATE=idle_with_inbox"
    echo "INBOX_SIZE=$(jq 'length' "$STATE_DIR/inbox.json")"
    break
  fi

  PR_STATE=$(gh pr view "$PR_NUM" --repo "$OWNER/$REPO" --json state -q .state 2>/dev/null || echo "UNKNOWN")
  case "$PR_STATE" in
    MERGED) echo "STATE=merged"; break ;;
    CLOSED) echo "STATE=closed"; break ;;
    OPEN)   ;;
    *)      echo "WARN: pr-state=$PR_STATE, treating as transient"; sleep 30; continue ;;
  esac

  ISSUE_JSON=$(gh api "repos/$OWNER/$REPO/issues/$PR_NUM/comments?per_page=100" 2>/dev/null || echo "[]")
  REVIEWS_JSON=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUM/reviews?per_page=100" 2>/dev/null || echo "[]")
  RCOMMENTS_JSON=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUM/comments?per_page=100" 2>/dev/null || echo "[]")

  # Update last_cr_activity_at from the newest CR updated_at across all streams,
  # whether or not we've seen it before. Activity = "CR is still typing."
  LATEST_CR_TS=$(
    { echo "$ISSUE_JSON"; echo "$REVIEWS_JSON"; echo "$RCOMMENTS_JSON"; } \
      | jq -r '.[] | select(.user.login == "coderabbitai[bot]") | (.updated_at // .submitted_at)' \
      | sort -r | head -1
  )
  if [[ -n "$LATEST_CR_TS" ]]; then
    LATEST_CR_EPOCH=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$LATEST_CR_TS" +%s 2>/dev/null \
                     || date -d "$LATEST_CR_TS" +%s 2>/dev/null || echo 0)
    PREV_EPOCH=$(cat "$STATE_DIR/last_cr_activity_at")
    if (( LATEST_CR_EPOCH > PREV_EPOCH )); then
      echo "$LATEST_CR_EPOCH" > "$STATE_DIR/last_cr_activity_at"
    fi
  fi

  # Completion marker: any review whose body starts with "Actionable comments posted:"
  if echo "$REVIEWS_JSON" | jq -e '.[] | select(.user.login == "coderabbitai[bot]") | select(.body | test("^Actionable comments posted:"))' >/dev/null 2>&1; then
    echo "true" > "$STATE_DIR/completion_marker_seen"
  fi

  # Process each stream: classify, mark non-actionable seen immediately,
  # append new actionable items to inbox.json. Idempotent — items already
  # in inbox (by id+fingerprint) are not added twice.
  process_stream() {
    local kind="$1" json="$2"
    local seen_file="$STATE_DIR/${kind}.seen.json"
    echo "$json" | jq -c --arg kind "$kind" '
      .[] | select(.user.login == "coderabbitai[bot]") |
      { id: (.id|tostring),
        kind: $kind,
        url: (.html_url // .pull_request_url),
        updated_at: (.updated_at // .submitted_at),
        body,
        path: (.path // null),
        line: (.line // .original_line // null) }
    ' | while read -r item; do
      local id fp prev body class
      id=$(echo "$item" | jq -r .id)
      fp=$(echo "$item" | jq -r '.updated_at + "\n" + .body' | shasum -a 256 | cut -d' ' -f1)
      prev=$(jq -r --arg id "$id" '.[$id] // ""' "$seen_file")
      [[ "$fp" == "$prev" ]] && continue
      body=$(echo "$item" | jq -r .body)
      if echo "$body" | grep -qE '^(<!-- This is an auto-generated.*-->|🐰|Currently processing|Review triggered|Walkthrough by CodeRabbit|## Summary by CodeRabbit|<details>.*<summary>.*Walkthrough)'; then
        class="status_ping"
      elif echo "$body" | grep -qE '^Actionable comments posted: 0\b'; then
        class="nitpick_only"
      else
        class="actionable"
      fi
      if [[ "$class" != "actionable" ]]; then
        tmp=$(mktemp)
        jq --arg id "$id" --arg fp "$fp" '. + {($id): $fp}' "$seen_file" > "$tmp" && mv "$tmp" "$seen_file"
        continue
      fi
      # Append to inbox if not already present by (kind,id,fingerprint)
      tmp=$(mktemp)
      jq --argjson new "$(jq -n --argjson item "$item" --arg fp "$fp" '$item + {fingerprint: $fp}')" '
        if any(.[]; .kind == $new.kind and .id == $new.id and .fingerprint == $new.fingerprint)
        then .
        else . + [$new]
        end
      ' "$STATE_DIR/inbox.json" > "$tmp" && mv "$tmp" "$STATE_DIR/inbox.json"
    done
  }

  process_stream issue_comments "$ISSUE_JSON"
  process_stream reviews         "$REVIEWS_JSON"
  process_stream review_comments "$RCOMMENTS_JSON"

  INBOX_SIZE=$(jq 'length' "$STATE_DIR/inbox.json")
  COMPLETION_MARKER=$(cat "$STATE_DIR/completion_marker_seen")
  LAST_ACTIVITY=$(cat "$STATE_DIR/last_cr_activity_at")
  QUIET_FOR=$(( NOW - LAST_ACTIVITY ))

  # Trigger HANDLE when inbox non-empty AND (completion marker seen OR quiet period elapsed)
  if (( INBOX_SIZE > 0 )) && \
     { [[ "$COMPLETION_MARKER" == "true" ]] || (( QUIET_FOR >= QUIET_PERIOD )); }; then
    echo "STATE=actionable"
    echo "COUNT=$INBOX_SIZE"
    echo "TRIGGER=$([[ "$COMPLETION_MARKER" == "true" ]] && echo marker || echo quiet)"
    break
  fi

  sleep 60
done
```

After this block returns to you:

- `STATE=merged` or `STATE=closed` → say `PR is <state>. Watcher exiting.` and stop. End of skill.
- `STATE=timeout` → say `Watch timed out after <h> hours. Stopping.` and stop. End of skill.
- `STATE=idle_with_inbox` → CR is mid-review or no activity yet; inner deadline hit. Re-run Step 3 immediately. The inbox persists.
- `STATE=actionable` with `COUNT=N` and `TRIGGER=marker|quiet` → proceed to Step 4 with the full batch in `$STATE_DIR/inbox.json`.

## Step 4: HANDLE — dispatch the full batch to ONE subagent

Call the Agent tool exactly once with the entire `inbox.json` as input. One subagent processes every finding sequentially inside a single working tree. This is the correctness boundary: two subagents racing on the same branch will collide on `git push`, on test state, on partially-applied edits. Never split the batch.

Dispatch contract:

- `subagent_type`: `"general-purpose"`
- `description`: `"pr-watcher: triage N CR findings on PR #<NUM>"`
- `prompt`: the template below, with placeholders filled in
- `run_in_background`: omit (must default to false)

Before invoking, capture the fix scope once and embed it in the prompt:

```bash
FIX_SCOPE=$(gh pr diff "$PR_NUM" --repo "$OWNER/$REPO" --name-only)
INBOX=$(cat "$STATE_DIR/inbox.json")
```

**Subagent prompt template** (fill in the bracketed values verbatim):

```
You are a triage subagent spawned by the /pr-watcher skill. You have a batch of
CodeRabbit findings to work through ON A SINGLE BRANCH. You are the only agent
touching this working tree for the duration of this run.

PR: [PR_URL]
Repo root: [absolute path to repo]
Test command: [TEST_CMD]
Fix scope (you may ONLY edit files matching this list — refuse anything else):
[FIX_SCOPE]

Findings to triage (JSON array):
[INBOX]

Each finding has: kind (issue_comments|reviews|review_comments), id, url,
path, line, body, fingerprint.

Process findings ONE AT A TIME, in array order. For each finding:

1. Classify as exactly one of:
   - valid_actionable    : a concrete fix you can make within fix scope
   - already_fixed       : the issue is already resolved on HEAD (verify by reading the file)
   - false_positive      : CodeRabbit is wrong; explain why
   - out_of_scope        : valid suggestion but outside fix scope or architectural
   - needs_user_input    : ambiguous, requires human judgment, or affects unrelated files

2. For valid_actionable:
   a. Read the cited file. Apply the smallest possible fix.
   b. Run the test command exactly as given.
   c. If any test fails: REVERT your edit (`git checkout -- <files>`), reclassify
      as needs_user_input with the failure output in evidence, and CONTINUE TO
      THE NEXT FINDING. Do not push. Do not abort the batch.
   d. If tests pass: stage only the file(s) you edited, commit with:
        Address CodeRabbit: <one-line summary>

        Comment: <url>
      Then `git push`. Capture the commit SHA. Move to the next finding from
      the new HEAD (subsequent findings see your fix as already-applied).
   e. Reply on the PR. For inline review_comments:
        gh api -X POST repos/<owner>/<repo>/pulls/<PR>/comments/<id>/replies \
          -f body="Addressed in <SHA>."
      For issue_comments and reviews:
        gh pr comment <PR> --body "Addressed CodeRabbit comment <url> in <SHA>."

3. For already_fixed: post a reply citing the existing commit/line. No edits.
4. For false_positive: post a reply with a one-paragraph explanation. No edits.
5. For out_of_scope or needs_user_input: do NOT post on the PR. No edits.

Between findings: do a quick sanity check. Run `git status` — the tree must be
clean before starting the next finding. If it is not clean (failed mid-fix,
unstaged changes from a revert), run `git checkout -- .` to reset and skip the
next finding as needs_user_input with reason "working tree was dirty".

If `git push` is rejected (human pushed concurrently): run `git pull --rebase`
once and retry. If the rebase has conflicts, revert your last commit
(`git reset --hard HEAD~1` then `git pull --rebase`), reclassify that finding
as needs_user_input with reason "concurrent push conflict", and continue.

Hard limits you must respect:
- Never edit files outside fix scope.
- Never push without passing tests.
- Never merge the PR. Never resolve conversations. Never close the PR.
- Never change architecture or rewrite unrelated code.
- Never touch the test command's config to make it pass.
- Never run more than one finding's git operations concurrently — you are
  strictly sequential within this run.
- If anything is unclear on a given finding, return needs_user_input for that
  finding and continue. Do not abort the whole batch over one ambiguous item.

End by emitting EXACTLY ONE JSON object as your final message (no surrounding
prose), with one result entry per input finding, in input order:

{
  "results": [
    {
      "id": "<id>",
      "kind": "<kind>",
      "fingerprint": "<fingerprint from input>",
      "classification": "valid_actionable|already_fixed|false_positive|out_of_scope|needs_user_input",
      "commit_sha": "<sha or null>",
      "replied": true|false,
      "reason": "<short string>",
      "evidence": "<test output, file excerpt, or empty string>"
    },
    ...
  ],
  "summary": {
    "total": N,
    "fixed": N,
    "already_fixed": N,
    "false_positive": N,
    "escalated": N
  }
}
```

After the subagent returns, parse the final JSON. For each entry in `results`:

- If `classification` is `valid_actionable | already_fixed | false_positive`:
  - Mark the item seen using its fingerprint:
    ```bash
    tmp=$(mktemp)
    jq --arg id "$ID" --arg fp "$FP" '. + {($id): $fp}' \
       "$STATE_DIR/${KIND}.seen.json" > "$tmp" && mv "$tmp" "$STATE_DIR/${KIND}.seen.json"
    ```
  - Print: `✅ <kind> <id> → <classification> (<commit_sha or "no commit">)`.
- If `classification` is `out_of_scope | needs_user_input`:
  - Append to `$STATE_DIR/escalations.jsonl` (timestamp, id, url, classification, reason, evidence).
  - Mark seen so it does not re-fire.
  - Print: `⚠️  <kind> <id> needs you — see $STATE_DIR/escalations.jsonl`.

After all `results` are processed:

```bash
echo '[]' > "$STATE_DIR/inbox.json"            # batch consumed
echo "false" > "$STATE_DIR/completion_marker_seen"   # next CR review starts fresh
```

Print the summary line: `🐇 batch done: <fixed> fixed, <already_fixed> already-fixed, <false_positive> false-positive, <escalated> escalated.`

If the subagent failed to return parseable JSON, or returned fewer results than findings: leave inbox.json untouched (items remain unseen) and the next POLL will re-trigger HANDLE. After 3 consecutive failures on the same batch, escalate all items and clear the inbox.

When HANDLE completes, **re-enter Step 3 (POLL)**.

## Stop conditions

The skill exits when any of:

- PR state is `MERGED` or `CLOSED` (clean exit, status code 0).
- Wall-clock timeout reached (default 8h, override via `PR_WATCHER_TIMEOUT` env var).
- User interrupts the session (Ctrl-C, /exit).
- Three consecutive POLL bash calls fail (auth lost, network gone, etc.).

On exit, print a one-line summary:

```
🐇 pr-watcher stopped. PR <state>. Handled <N> items, <M> escalated. State: $STATE_DIR
```

## State directory layout

```
~/.cache/pr-watcher/<owner>__<repo>__<pr>/
  started                       # WATCH_STARTED=<epoch>
  test_cmd                      # if user was asked
  issue_comments.seen.json      # { "<id>": "<fp>", ... }
  reviews.seen.json
  review_comments.seen.json
  inbox.json                    # actionable items accumulating across polls; consumed by HANDLE
  last_cr_activity_at           # epoch of most recent CR comment/review, used for quiet-period detection
  completion_marker_seen        # "true" if CR posted "Actionable comments posted:" since last HANDLE
  escalations.jsonl             # append-only, one JSON per line
```

State is per-PR and persists across sessions. If you re-invoke `/pr-watcher` on the same PR after `/exit`, it picks up where it left off, never re-processing items it already marked seen.

## Failure handling

| Failure | Response |
|---|---|
| `gh` rate-limited (HTTP 403 with `X-RateLimit-Remaining: 0`) | Inner loop sleeps until reset time reported by header, then resumes. |
| `gh` returns 401 | Print `ERROR: gh auth expired. Run gh auth login.` Exit with status 1. |
| Test command fails after a fix | Subagent reverts, reclassifies as `needs_user_input`. Watcher continues. |
| Human pushed a commit concurrently | Subagent's `git push` will reject; subagent runs `git pull --rebase` once, retries; on conflict, reverts and escalates. |
| CodeRabbit edits its placeholder | Fingerprint changes; item reappears as new. Correct behavior. |
| PR force-pushed (head SHA changed) | Inline review comment IDs may become stale; on next POLL, delete `review_comments.seen.json` and re-sync. Add a one-line check at the start of each POLL: `gh pr view --json headRefOid` and compare to a stored value. |
| Subagent returns malformed JSON | Print error, leave unseen, retry next POLL. After 3 consecutive failures on the same id, escalate and mark seen. |

## What you (the running session) actually do

In order:

1. Run Step 0 → resolve PR.
2. Run Step 1 → verify prereqs.
3. Run Step 2 → discover config (ask about test command if unknown).
4. Print the start banner.
5. Enter the alternation: POLL (accumulating into inbox) → wait for completion → HANDLE entire batch via ONE Agent call → POLL → ...
6. On any stop condition, print the summary and end.

Do not silently skip the test command. Do not call Agent with `run_in_background: true`. Do not split the batch across multiple subagents — concurrent subagents on the same branch is the failure mode this design exists to prevent. Do not edit files yourself; fixes are the subagent's job; you are the dispatcher and the gate.
