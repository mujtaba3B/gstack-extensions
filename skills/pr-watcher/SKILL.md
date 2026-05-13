---
name: pr-watcher
description: Foreground watcher that polls a GitHub PR for CodeRabbit feedback, classifies each comment locally, and spawns Claude subagents to apply small in-scope fixes (read file, edit, run tests, commit, push, reply on the PR). Blocks the current session; never detaches; never merges; never resolves conversations; never pushes without passing tests; never touches files outside the PR's own diff. Use when asked to "watch the PR", "watch coderabbit", "pr watch", or invoked manually as `/pr-watcher <PR_URL>` after /ship.
---

# pr-watcher

You are running the `/pr-watcher` skill. It watches a single PR for CodeRabbit (`coderabbitai[bot]`) activity and applies fixes the user approves in the watcher's contract.

## How this skill executes

The skill alternates between two phases until the PR is closed/merged or a wall-clock timeout fires:

1. **POLL** — one Bash call that runs an inner loop of `gh` queries, sleeping ~60s between rounds, exiting early when it finds new CodeRabbit activity, when the PR is no longer OPEN, or after ~9 minutes (to stay inside the Bash tool timeout). Idle minutes produce zero conversation turns.
2. **HANDLE** — if the POLL exited because of new actionable items, dispatch each one to a triage subagent via the Agent tool, then resume POLL.

You re-enter POLL after every HANDLE phase. The loop ends when POLL reports `STATE=closed`, `STATE=merged`, or `STATE=timeout`.

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

Run this Bash with `timeout: 570000` (9.5 minutes). The inner loop exits as soon as actionable items appear, the PR closes, or 9 minutes pass. **Re-invoke this same block after every HANDLE phase** until `STATE` reports `closed`, `merged`, or `timeout`.

```bash
set -euo pipefail
PR_NUM="<resolved in Step 0>"
OWNER="<resolved>"
REPO="<resolved>"
STATE_DIR="$HOME/.cache/pr-watcher/${OWNER}__${REPO}__${PR_NUM}"
STARTED=$(cat "$STATE_DIR/started" | cut -d= -f2)
TIMEOUT_SECONDS=28800   # or value resolved in Step 2

INNER_DEADLINE=$(( $(date +%s) + 540 ))   # 9 minutes from now
RESULT_FILE=$(mktemp)
echo '{"new":[],"escalated":[]}' > "$RESULT_FILE"

while : ; do
  NOW=$(date +%s)
  if (( NOW > STARTED + TIMEOUT_SECONDS )); then
    echo "STATE=timeout"
    break
  fi
  if (( NOW > INNER_DEADLINE )); then
    echo "STATE=idle"
    break
  fi

  # Check PR state
  PR_STATE=$(gh pr view "$PR_NUM" --repo "$OWNER/$REPO" --json state -q .state 2>/dev/null || echo "UNKNOWN")
  case "$PR_STATE" in
    MERGED) echo "STATE=merged"; break ;;
    CLOSED) echo "STATE=closed"; break ;;
    OPEN)   ;;
    *)      echo "WARN: pr-state=$PR_STATE, treating as transient"; sleep 30; continue ;;
  esac

  # Fetch the three comment streams in parallel
  ISSUE_JSON=$(gh api "repos/$OWNER/$REPO/issues/$PR_NUM/comments?per_page=100" 2>/dev/null || echo "[]")
  REVIEWS_JSON=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUM/reviews?per_page=100" 2>/dev/null || echo "[]")
  RCOMMENTS_JSON=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUM/comments?per_page=100" 2>/dev/null || echo "[]")

  # Filter to coderabbitai[bot], compute fingerprint = sha256(updated_at + body), diff vs seen
  process_stream() {
    local kind="$1" json="$2"
    local seen_file="$STATE_DIR/${kind}.seen.json"
    echo "$json" | jq -c --arg kind "$kind" '
      .[] | select(.user.login == "coderabbitai[bot]") |
      { id: (.id|tostring),
        kind: $kind,
        url: (.html_url // .pull_request_url),
        updated_at,
        body,
        path: (.path // null),
        line: (.line // .original_line // null) }
    ' | while read -r item; do
      local id fp prev body
      id=$(echo "$item" | jq -r .id)
      fp=$(echo "$item" | jq -r '.updated_at + "\n" + .body' | shasum -a 256 | cut -d' ' -f1)
      prev=$(jq -r --arg id "$id" '.[$id] // ""' "$seen_file")
      if [[ "$fp" == "$prev" ]]; then continue; fi
      body=$(echo "$item" | jq -r .body)
      # Classify locally
      if echo "$body" | grep -qE '^(<!-- This is an auto-generated.*-->|🐰|Currently processing|Review triggered|Walkthrough by CodeRabbit|## Summary by CodeRabbit|<details>.*<summary>.*Walkthrough)'; then
        class="status_ping"
      elif echo "$body" | grep -qE '^Actionable comments posted: 0\b' \
        || echo "$body" | grep -qE '_nitpick_total_: [1-9]' && echo "$body" | grep -qE 'Actionable comments posted: 0'; then
        class="nitpick_only"
      else
        class="actionable"
      fi
      # Mark seen NOW for non-actionable (we never want to re-process them). Actionable items get
      # marked seen only AFTER the subagent reports success.
      if [[ "$class" != "actionable" ]]; then
        tmp=$(mktemp)
        jq --arg id "$id" --arg fp "$fp" '. + {($id): $fp}' "$seen_file" > "$tmp" && mv "$tmp" "$seen_file"
        continue
      fi
      # Emit actionable
      jq -n --argjson item "$item" --arg fp "$fp" '$item + {fingerprint: $fp}'
    done
  }

  NEW_ACTIONABLE=$(
    { process_stream issue_comments "$ISSUE_JSON";
      process_stream reviews         "$REVIEWS_JSON";
      process_stream review_comments "$RCOMMENTS_JSON"; } | jq -s '.'
  )
  COUNT=$(echo "$NEW_ACTIONABLE" | jq 'length')

  if (( COUNT > 0 )); then
    echo "STATE=actionable"
    echo "COUNT=$COUNT"
    echo "$NEW_ACTIONABLE" > "$STATE_DIR/inbox.json"
    break
  fi

  # Idle tick
  sleep 60
done
```

After this block returns to you:

- `STATE=merged` or `STATE=closed` → say `PR is <state>. Watcher exiting.` and stop. End of skill.
- `STATE=timeout` → say `Watch timed out after <h> hours. Stopping.` and stop. End of skill.
- `STATE=idle` → no new activity in the inner window. Re-run Step 3 immediately.
- `STATE=actionable` with `COUNT=N` → proceed to Step 4 for each item in `$STATE_DIR/inbox.json`.

## Step 4: HANDLE — dispatch each actionable item to a subagent

For each item in `$STATE_DIR/inbox.json`, call the Agent tool ONCE. Do not batch multiple items into a single Agent call — one finding per subagent so the diff stays small and reviewable.

Use this dispatch contract:

- `subagent_type`: `"general-purpose"`
- `description`: `"pr-watcher fix: <kind> <id>"`
- `prompt`: the template below, with placeholders filled in
- `run_in_background`: omit (must default to false; this skill is foreground)

**Subagent prompt template** (fill in the bracketed values):

```
You are a triage subagent spawned by the /pr-watcher skill. A single CodeRabbit
comment is yours to handle. Read your contract before doing anything.

PR: [PR_URL]
Repo root: [absolute path to repo]
Test command: [TEST_CMD]
Fix scope (you may ONLY edit files matching this list — refuse anything else):
[output of: gh pr diff <PR> --name-only]

Comment to triage:
  kind: [issue_comments | reviews | review_comments]
  id: [id]
  url: [html_url]
  path: [file path or null]
  line: [line number or null]
  body:
  <<<
  [body]
  >>>

Your job:

1. Classify the comment as exactly one of:
   - valid_actionable    : a concrete fix you can make within fix scope
   - already_fixed       : the issue is already resolved on HEAD (verify by reading the cited file)
   - false_positive      : CodeRabbit is wrong; explain why
   - out_of_scope        : valid suggestion but outside fix scope or architectural in nature
   - needs_user_input    : ambiguous, requires human judgment, or affects multiple unrelated files

2. For valid_actionable ONLY:
   a. Read the cited file. Apply the smallest possible fix.
   b. Run the test command exactly as given. If any test fails, REVERT your edit
      (git checkout -- <file>) and reclassify as needs_user_input with the failure
      output in your evidence. Do NOT push.
   c. If tests pass: stage only the file(s) you edited, commit with this message:
        Address CodeRabbit: <one-line summary>

        Comment: <url>
      Then push to the PR's branch (git push). Capture the commit SHA.
   d. Reply on the PR. For inline review_comments use:
        gh api -X POST repos/<owner>/<repo>/pulls/<PR>/comments/<id>/replies \
          -f body="Addressed in <SHA>."
      For issue_comments and reviews, post a new top-level comment:
        gh pr comment <PR> --body "Addressed CodeRabbit comment <url> in <SHA>."

3. For already_fixed: post a reply citing the existing commit/line that resolves it.
   Do not edit anything.

4. For false_positive: post a reply with a one-paragraph explanation. Do not edit.

5. For out_of_scope or needs_user_input: do NOT post on the PR. Do NOT edit anything.
   These will be surfaced to the human watching the session.

Hard limits you must respect:
- Never edit files outside fix scope.
- Never push without passing tests.
- Never merge the PR. Never resolve conversations. Never close the PR.
- Never change architecture or rewrite unrelated code.
- Never touch the test command's config to make it pass.
- If anything is unclear, return needs_user_input. Erring toward escalation is correct.

End by emitting EXACTLY ONE JSON object as your final message, with no surrounding prose:

{
  "id": "[id]",
  "kind": "[kind]",
  "classification": "valid_actionable|already_fixed|false_positive|out_of_scope|needs_user_input",
  "commit_sha": "<sha or null>",
  "replied": true|false,
  "reason": "<short string>",
  "evidence": "<test output, file excerpt, or empty string>"
}
```

After the subagent returns, parse its final JSON object. Then:

- If `classification` is `valid_actionable | already_fixed | false_positive`:
  - Mark the item seen by writing its fingerprint to the appropriate `*.seen.json`.
  - Print: `✅ <kind> <id> → <classification> (<commit_sha or "no commit">)`.
- If `classification` is `out_of_scope | needs_user_input`:
  - Append a line to `$STATE_DIR/escalations.jsonl` with id, url, classification, reason, evidence, timestamp.
  - Mark seen so it does not re-fire.
  - Print: `⚠️  <kind> <id> needs you — see $STATE_DIR/escalations.jsonl`.
- If the subagent failed (no parseable JSON, error, or refused):
  - Leave the item unseen so it retries on the next POLL.
  - Print: `❌ <kind> <id> subagent failed — will retry. Reason: <error>`.

Update seen state via:

```bash
mark_seen() {
  local seen_file="$1" id="$2" fp="$3"
  tmp=$(mktemp)
  jq --arg id "$id" --arg fp "$fp" '. + {($id): $fp}' "$seen_file" > "$tmp" && mv "$tmp" "$seen_file"
}
```

When every item in `inbox.json` has been processed, **re-enter Step 3 (POLL)**.

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
  inbox.json                    # transient: latest batch of actionable items
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
5. Enter the alternation: POLL → (if actionable) HANDLE each item via Agent → POLL → ...
6. On any stop condition, print the summary and end.

Do not silently skip the test command. Do not call Agent with `run_in_background: true`. Do not batch findings into one subagent. Do not edit files yourself — fixes are the subagent's job; you are the dispatcher.
