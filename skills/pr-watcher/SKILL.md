---
name: pr-watcher
description: Foreground watcher that pairs the main agent (dispatcher and fix-applier) with a passive polling subagent (sensor) to handle CodeRabbit feedback on a GitHub PR. The sensor blocks silently in one Agent call until CR posts a settled round of feedback, then returns a single JSON blob. The main agent classifies, applies fixes, runs tests, commits, pushes, and replies on the PR itself, then spawns the next sensor. Never merges; never resolves conversations; never pushes without passing tests; never touches files outside the PR's own diff; never parallelizes fixes. Use when asked to "watch the PR", "watch coderabbit", "pr watch", or invoked manually as `/pr-watcher <PR_URL>` after /ship.
---

# pr-watcher

You are running the `/pr-watcher` skill. It watches a single PR for CodeRabbit (`coderabbitai[bot]`) activity and applies fixes within the watcher's contract.

## Architecture: dispatcher + sensor

This skill splits work between two roles:

- **Main agent (you) = dispatcher + gate + fix-applier.** You read the sensor's JSON, classify each finding, apply fixes with Edit/Write, run tests, commit, push, and post PR replies. You hold all user-facing decisions.
- **Sensor subagent = pure polling sensor.** Spawned via the Agent tool, it blocks for up to 30 minutes waiting for CR to post AND settle a new round of feedback, then returns ONE JSON blob. It never edits files, never runs git, never writes on the PR.

Loop: spawn sensor, await return, process batch in the main turn, spawn the next sensor with updated baseline IDs. Repeat until merged / closed / user stops / sensor returns `idle_timeout` and you decide to stop.

Why this shape:
- One Agent call can wait up to 30 minutes for real signal, instead of the main agent re-entering a 9-minute Bash poll every cycle.
- Main context absorbs one short JSON per cycle, not minutes of "tick" lines.
- One sensor at a time + main-owned git = zero risk of concurrent edits on the branch.

## What this skill WILL NOT do

- Merge the PR
- Mark CodeRabbit conversations as resolved
- Push a commit when tests do not pass
- Edit files outside the PR's own changed-file list (the "fix scope")
- Change architecture, scope, or design decisions locked before this watch began
- Run in the background after the session exits

If a finding requires any of the above, mark it seen with reason `needs_user_input`, log to `escalations.jsonl`, and continue.

---

## Step 0: Resolve the PR

Determine the PR URL from the user's invocation. Full GitHub URL → use as-is. `#123` or `123` → resolve against the current repo. Empty → `gh pr view --json url -q .url` on the current branch.

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

if [[ "$PR_URL" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
  PR_NUM="${BASH_REMATCH[3]}"
else
  echo "ERROR: PR_URL does not look like a GitHub PR URL: $PR_URL" >&2; exit 2
fi

KEY="${OWNER}__${REPO}__${PR_NUM}"
STATE_DIR="$HOME/.cache/pr-watcher/$KEY"
mkdir -p "$STATE_DIR"
echo "PR=$PR_URL"; echo "KEY=$KEY"; echo "STATE_DIR=$STATE_DIR"
```

## Step 1: Verify prerequisites

```bash
command -v gh >/dev/null || { echo "ERROR: gh CLI not installed" >&2; exit 2; }
command -v jq >/dev/null || { echo "ERROR: jq not installed" >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated. Run: gh auth login" >&2; exit 2; }
```

## Step 2: Discover config

Three pieces of config: **fix scope** (files you may edit), **test command** (what to run before pushing), and **timeout** (when to give up).

Fix scope defaults to the set of files currently changed in this PR. Refresh on every cycle so newly-touched files come into scope.

```bash
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

If `TEST_CMD` is `<unknown>`, ask the user once via AskUserQuestion: "What's the test command for this repo? (e.g., `bun test`, `pytest`, `make test`)" Save to `$STATE_DIR/test_cmd`.

Initialize the per-PR baseline ID stores if absent. Baselines hold IDs the main agent has already processed (or, on a fresh watch, all currently-existing CR comments so the first sensor only returns truly new ones).

```bash
for f in issue_comments reviews review_comments; do
  [[ -f "$STATE_DIR/baseline_${f}.json" ]] || echo '[]' > "$STATE_DIR/baseline_${f}.json"
done
: > "$STATE_DIR/escalations.jsonl"

# On a fresh watch (no prior baselines), seed with all existing CR IDs so we
# only react to genuinely NEW activity going forward.
if [[ "$(jq 'length' "$STATE_DIR/baseline_reviews.json")" == "0" ]]; then
  gh api "repos/$OWNER/$REPO/issues/$PR_NUM/comments?per_page=100" \
    | jq '[.[] | select(.user.login == "coderabbitai[bot]") | .id | tostring]' \
    > "$STATE_DIR/baseline_issue_comments.json"
  gh api "repos/$OWNER/$REPO/pulls/$PR_NUM/reviews?per_page=100" \
    | jq '[.[] | select(.user.login == "coderabbitai[bot]") | .id | tostring]' \
    > "$STATE_DIR/baseline_reviews.json"
  gh api "repos/$OWNER/$REPO/pulls/$PR_NUM/comments?per_page=100" \
    | jq '[.[] | select(.user.login == "coderabbitai[bot]") | .id | tostring]' \
    > "$STATE_DIR/baseline_review_comments.json"
fi
```

Print a one-line start banner:

```
🐇 Watching PR #<NUM> (<owner>/<repo>). Tests: <TEST_CMD>. Timeout: <hours>h. Ctrl-C to stop.
```

## Step 3: SENSE — spawn one passive polling subagent

This is the single Agent call per cycle. Read current baselines, capture the latest pushed SHA for log clarity, then spawn the sensor and await its return. The main agent stays silent until the sensor returns — no per-minute output in the transcript.

Resolve the inputs:

```bash
BASE_ISSUE=$(cat "$STATE_DIR/baseline_issue_comments.json")
BASE_REVIEW=$(cat "$STATE_DIR/baseline_reviews.json")
BASE_RCOMMENT=$(cat "$STATE_DIR/baseline_review_comments.json")
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
```

Spawn the sensor via the Agent tool:

- `subagent_type`: `"general-purpose"`
- `description`: `"pr-watcher sensor: PR #<NUM>"`
- `run_in_background`: omit (must default to false)
- `prompt`: the sensor template below, with placeholders substituted verbatim

### Sensor prompt template (paste verbatim, substitute bracketed values)

The sensor uses CodeRabbit's **commit status** (legacy GitHub Statuses API) as its
primary signal: CR posts a `CodeRabbit` context status on each new HEAD commit
that transitions `pending` → `success`/`failure` when its review pass finishes.
That single endpoint is cheap to poll and gives a clear "review just finished"
edge. Comment-stream fetches happen only when the status transitions.

If a repo's CR setup does not post a commit status (some self-hosted or older
installs), the sensor falls back to comment-stream polling at the original 60s
cadence so the watcher still works.

```text
You are a passive polling sensor for the /pr-watcher skill. Your only job is to
wait for CodeRabbit (coderabbitai[bot]) to finish a review pass on
PR [PR_URL], then return a short summary. You do NOT edit code, push commits,
or reply on the PR.

Treat these IDs as already-known baseline (do NOT report them as new):
- issue_comments:  [BASE_ISSUE]
- reviews:         [BASE_REVIEW]
- review_comments: [BASE_RCOMMENT]

Most recent pushed commit at watch start (for log context only): [HEAD_SHA]

Primary signal — CodeRabbit commit status:
CR posts a legacy commit status with context "CodeRabbit", creator
coderabbitai[bot], state pending → success (or failure). Each new push to the
PR head triggers a fresh pending → terminal transition. The endpoint is
GET /repos/[OWNER]/[REPO]/commits/<head_sha>/statuses and is cheap, so the
sensor polls it at a tight cadence and only fetches comment streams when the
status flips.

Polling protocol:
0. Init pass (run ONCE before the 15s loop, immediately on spawn):
   a. Resolve current PR head:
      gh pr view [PR_NUM] --repo [OWNER]/[REPO] --json state,headRefOid
      If state is MERGED or CLOSED, return outcome: pr_closed immediately.
      Let CURRENT_SHA = headRefOid.
   b. Fetch the commit status list for CURRENT_SHA (same endpoint and filter as
      step 2b below). Let INIT_CR_STATUS = (state, updated_at) of the latest
      CodeRabbit entry, or null if absent.
   c. Fetch the three comment streams once and filter to coderabbitai[bot]
      items NOT in the baseline (same as step 3). Call the result INIT_NEW.
   d. If INIT_CR_STATUS is terminal (success/failure/error) AND INIT_NEW is
      empty across all three streams, CR is already caught up on this HEAD.
      Return outcome: already_settled IMMEDIATELY with cr_status_state =
      INIT_CR_STATUS.state, cr_status_updated_at = INIT_CR_STATUS.updated_at,
      settled_via: "n/a", and empty new_* arrays. Do NOT wait 30 minutes.
   e. If INIT_NEW is non-empty (CR has new items the dispatcher has not yet
      processed, regardless of status state), return outcome: new_cr_feedback
      IMMEDIATELY with settled_via: "status_transition" if INIT_CR_STATUS is
      terminal, else "marker" / "quiet_period" / "n/a" as best fits. Do NOT
      wait. The dispatcher needs to drain the backlog before we resume polling.
   f. Otherwise (status is pending or absent, no new items): set
      last_terminal_status_updated_at = (INIT_CR_STATUS.updated_at if state
      is terminal, else null) and proceed to the 15s loop. Note: when status
      is terminal but seeding-baselines-from-current produced an empty INIT_NEW,
      we will have already returned via 0d above.
1. Initialize fallback_tick_counter = 0.
2. Every 15 seconds:
   a. Resolve current PR head via
      gh pr view [PR_NUM] --repo [OWNER]/[REPO] --json state,headRefOid
      If state is MERGED or CLOSED, return outcome: pr_closed immediately.
      Let CURRENT_SHA = headRefOid.
   b. Fetch the commit status list for CURRENT_SHA:
      gh api "repos/[OWNER]/[REPO]/commits/$CURRENT_SHA/statuses?per_page=100"
      Filter to context == "CodeRabbit" AND creator.login == "coderabbitai[bot]"
      (creator may be missing on some entries; treat that as a match too if the
      context is "CodeRabbit"). Take the entry with the latest updated_at.
      Call its (state, updated_at) the LATEST_CR_STATUS.
   c. If LATEST_CR_STATUS is present and state in ("success", "failure", "error")
      and updated_at > last_terminal_status_updated_at, this is a fresh review
      transition. Proceed to step 3.
   d. If LATEST_CR_STATUS is absent (no CR status on this SHA at all),
      increment fallback_tick_counter. Every 4th tick (every ~60s), fall
      through to step 4 (comment-stream poll) so we still notice activity in
      repos where CR does not post a commit status.
   e. Otherwise sleep until the next 15s tick.
3. Status just transitioned to terminal. Set
   last_terminal_status_updated_at = LATEST_CR_STATUS.updated_at.
   Wait 5 seconds to let CR's comment writes settle (status sometimes flips
   slightly before the last review_comment write is visible to the API), then
   fetch all three streams once:
     gh api "repos/[OWNER]/[REPO]/issues/[PR_NUM]/comments?per_page=100"
     gh api "repos/[OWNER]/[REPO]/pulls/[PR_NUM]/reviews?per_page=100"
     gh api "repos/[OWNER]/[REPO]/pulls/[PR_NUM]/comments?per_page=100"
   Filter each to user.login == "coderabbitai[bot]" and to IDs not in the
   baseline. If any new items are present, return outcome: new_cr_feedback with
   settled_via: "status_transition". If zero new items (status flipped to
   success but CR posted nothing actionable, e.g. a 0-finding pass), still
   return new_cr_feedback so the dispatcher can mark the round seen; the
   dispatcher will classify everything as nitpick_only / status_ping and move
   on.
4. Fallback: same comment-stream fetch as step 3, plus a freshness check using
   the original quiet_period logic — return new_cr_feedback when there is at
   least one new CR item AND either:
     (a) a new review body matches ^Actionable comments posted:, OR
     (b) a new comment/review body contains the literal sentinel
         "<!-- This is an auto-generated comment by CodeRabbit for review status -->", OR
     (c) 180 seconds have passed since the latest new item's updated_at with
         no further changes in a subsequent poll.
   Reset fallback_tick_counter to 0 after each fallback fetch.
5. After 1800 seconds (30 minutes) wall-clock with no terminal status
   transition and no qualifying fallback activity, return outcome:
   idle_timeout.

Emit EXACTLY ONE JSON object as your final message. No prose before or after.
Full comment bodies, no truncation.

Schema:
{
  "outcome": "new_cr_feedback" | "pr_closed" | "idle_timeout" | "already_settled",
  "polled_for_seconds": <int>,
  "ticks": <int>,
  "head_sha_at_return": "<sha>",
  "cr_status_state": "pending" | "success" | "failure" | "error" | null,
  "cr_status_updated_at": "<iso8601 | null>",
  "settled_via": "status_transition" | "marker" | "quiet_period" | "n/a",
  "new_issue_comments":  [{"id":"...","updated_at":"...","body":"..."}, ...],
  "new_reviews":         [{"id":"...","state":"...","submitted_at":"...","body":"..."}, ...],
  "new_review_comments": [{"id":"...","path":"...","line":N,"updated_at":"...","body":"..."}, ...]
}

Hard limits:
- No file edits. No git commands. No PR writes (no gh pr comment, no gh api -X POST).
- Maximum 30 minutes wall-clock.
- One JSON object as your final message, nothing else.
```

After the sensor returns, branch on `outcome`:

- `"pr_closed"` → print `PR is closed/merged. Watcher exiting.` and end the skill.
- `"already_settled"` → CodeRabbit's review on the current HEAD is already terminal and there are no unprocessed CR items. Print `🐇 CodeRabbit is caught up on HEAD <sha> (status: <state>). Nothing to address. Watcher exiting.` and end the skill. Do NOT loop again; spawning another sensor would just reproduce this outcome.
- `"idle_timeout"` → ask the user (via AskUserQuestion) whether to keep watching or stop. Default recommendation: **stop** (long silence after watcher start almost always means CR is done; the user can re-invoke /pr-watcher when there is new activity). If they choose to keep watching, spawn another sensor.
- `"new_cr_feedback"` → proceed to Step 4.

If the sensor fails to return parseable JSON, count it as a sensor failure. After **three consecutive sensor failures**, print an error and stop.

## Step 4: PROCESS — classify, fix, push, reply (in the main turn)

You are now back in the main agent with a JSON blob describing every new CR item. The fix work runs **here**, in the dispatcher, not in a subagent.

### 4a. Refresh fix scope

```bash
FIX_SCOPE=$(gh pr diff "$PR_NUM" --repo "$OWNER/$REPO" --name-only)
```

You may edit only files in `FIX_SCOPE`. Anything else is `out_of_scope`.

### 4b. Classify each finding

For every item across `new_issue_comments`, `new_reviews`, `new_review_comments`, classify as exactly one of:

- `status_ping` — CR's placeholder / walkthrough / "currently processing" body. Bodies starting with `<!-- This is an auto-generated`, `🐰`, `Currently processing`, `Review triggered`, `Walkthrough by CodeRabbit`, `## Summary by CodeRabbit`, or a `<details><summary>…Walkthrough` block. Ignore (mark baseline, no reply).
- `nitpick_only` — review body starts with `Actionable comments posted: 0`. Mark baseline, no reply.
- `valid_actionable` — concrete fix you can make inside fix scope.
- `already_fixed` — issue resolved on HEAD (verify by reading the cited file before declaring).
- `false_positive` — CR is wrong; you can explain why.
- `out_of_scope` — valid suggestion but outside fix scope, or architectural / cross-cutting.
- `needs_user_input` — ambiguous, requires human judgment.

Apply the project's coding principles when filtering. Reject suggestions that introduce single-use abstractions, speculative error handling, or "cleanup" outside the task.

### 4c. Surface ambiguous items to the user before acting

For each item that lands in `needs_user_input` or where you're between `valid_actionable` and `false_positive`, ask the user one question at a time (per the global "one question at a time" rule, with the `❓ QUESTION` blockquote format). Skip this step for clear-cut items.

### 4d. Apply fixes — atomic commit per finding

For each `valid_actionable` finding, in the order returned by the sensor:

1. Read the cited file.
2. Apply the minimal fix using Edit/Write.
3. Run the test command exactly as configured. If any test fails:
   - `git checkout -- <files you touched>` to revert.
   - Reclassify as `needs_user_input` with the failure output as evidence.
   - Continue to the next finding. Do not push. Do not abort the batch.
4. If tests pass:
   - Stage only the files you edited.
   - Commit with: `Address CodeRabbit: <one-line summary>` followed by a blank line and `Comment: <url>`.
   - `git push`. Capture the commit SHA.
   - Subsequent findings start from the new HEAD (so they may see prior fixes as `already_fixed`).

If `git push` is rejected (concurrent push by a human):
- `git pull --rebase` once and retry.
- If the rebase conflicts, `git reset --hard HEAD~1` then `git pull --rebase`, reclassify the finding as `needs_user_input` (reason: "concurrent push conflict"), continue.

Before starting each finding's fix, verify `git status` is clean. If not, `git checkout -- .` and skip the current finding as `needs_user_input` (reason: "working tree was dirty").

### 4e. Reply on the PR

Reply on every finding the user expects feedback on:

- Inline review_comments (have `path` + `line`): thread the reply under CR's comment.
  ```bash
  gh api -X POST "repos/$OWNER/$REPO/pulls/$PR_NUM/comments/<ID>/replies" \
    -f body="Addressed in <SHA>."
  ```
- Issue comments and review-level comments: post a top-level PR comment.
  ```bash
  gh pr comment "$PR_NUM" --body "Addressed CodeRabbit comment <URL> in <SHA>."
  ```

For `already_fixed`: post a reply citing the existing commit/line.
For `false_positive`: post a one-paragraph explanation.
For `out_of_scope` / `needs_user_input`: do NOT reply on the PR. Log to `$STATE_DIR/escalations.jsonl` instead.

Capture the IDs of replies you just posted so the next sensor cycle does not see them as "new":

```bash
# After each reply, append the new comment ID to the appropriate baseline list.
# gh pr comment prints the URL; parse the ID. For gh api -X POST on /replies,
# the response JSON has the new comment's id.
```

### 4f. Update baselines

For each CR item handled (any classification, including `status_ping` and `nitpick_only`), append its ID to the matching baseline file:

```bash
for kind in issue_comments reviews review_comments; do
  tmp=$(mktemp)
  jq --argjson new "$NEW_IDS_JSON_ARRAY" '. + $new | unique' \
    "$STATE_DIR/baseline_${kind}.json" > "$tmp" && mv "$tmp" "$STATE_DIR/baseline_${kind}.json"
done
```

Also append any reply IDs you just posted (issue_comments for top-level replies, review_comments for inline replies).

### 4g. Print a batch summary

```
🐇 batch done: <fixed> fixed, <already_fixed> already-fixed, <false_positive> false-positive, <escalated> escalated.
```

### 4h. All-clear exit check

The loop's exit condition is "CodeRabbit has nothing left for us." Detect that here, before spawning the next sensor, so the watcher does not spin a 30-minute idle_timeout waiting for a transition that will never come.

Exit the skill (do NOT spawn another sensor) when ALL the following hold for the batch you just processed:

- `pushed_commits_this_batch == 0` (no `valid_actionable` finding made it through tests + commit + push this batch). If you pushed even once, CR will re-review the new HEAD, so do not exit.
- The sensor returned `cr_status_state == "success"` AND `settled_via == "status_transition"`. (CR's terminal pass on the current HEAD finished cleanly. `failure`/`error` is also "done" in CR's sense, but signals a CR-side problem worth keeping the watcher alive for a human to inspect, so do not auto-exit on those.)
- All findings in the batch classified as `status_ping`, `nitpick_only`, `already_fixed`, or `false_positive` (no `valid_actionable`, `out_of_scope`, or `needs_user_input` left in flight). `out_of_scope` and `needs_user_input` items both escalate to `escalations.jsonl` rather than being replied to on the PR (see Step 4e), so leaving them unresolved means there is still pending human work; the watcher should keep the loop alive so the user can see them when they return.

When the condition is met, print:

```text
🐇 CodeRabbit's review on HEAD <sha> is clean (Actionable comments posted: 0). Watcher exiting.
```

and end the skill.

Then return to Step 3 and spawn the next sensor.

## Stop conditions

The skill exits when any of:

- Sensor returns `outcome: pr_closed`.
- Sensor returns `outcome: already_settled` (CR already done on the current HEAD at sensor spawn).
- Step 4h all-clear check fires (CR's terminal pass on the current HEAD posted nothing actionable and we did not push during the batch).
- Sensor returns `outcome: idle_timeout` and the user chooses to stop.
- Wall-clock timeout reached (default 8h, override via `PR_WATCHER_TIMEOUT`).
- User interrupts the session (Ctrl-C, /exit).
- Three consecutive sensor failures (malformed JSON, agent errors, etc.).

On exit, print:

```
🐇 pr-watcher stopped. PR <state>. Handled <N> items, <M> escalated. State: $STATE_DIR
```

## State directory layout

```
~/.cache/pr-watcher/<owner>__<repo>__<pr>/
  started                          # WATCH_STARTED=<epoch>
  test_cmd                         # if user was asked
  baseline_issue_comments.json     # JSON array of CR comment IDs already processed
  baseline_reviews.json
  baseline_review_comments.json
  escalations.jsonl                # append-only, one JSON per line
```

State is per-PR and persists across sessions. Re-invoking `/pr-watcher` on the same PR after `/exit` resumes from the saved baselines, never re-processing items already handled.

## Failure handling

| Failure | Response |
|---|---|
| `gh` rate-limited (HTTP 403 with `X-RateLimit-Remaining: 0`) | Sensor sleeps until the reset time reported by the header, then resumes. |
| `gh` returns 401 | Print `ERROR: gh auth expired. Run gh auth login.` Exit with status 1. |
| Test command fails after a fix | Revert the edit, reclassify as `needs_user_input`, continue. |
| Concurrent push by a human | `git pull --rebase` once and retry; on conflict, revert and escalate that finding. |
| PR force-pushed (head SHA changed) | Inline review comment IDs may become stale. On the next cycle, clear `baseline_review_comments.json` and re-seed from the current CR comments. |
| Sensor returns malformed JSON | Count as a sensor failure. After 3 consecutive failures, exit. |

## What you (the running session) actually do

1. Step 0 → resolve PR.
2. Step 1 → verify prereqs.
3. Step 2 → discover config (ask about test command if unknown). Seed baselines on first run.
4. Print the start banner.
5. Loop: spawn ONE sensor subagent (Step 3) → await its JSON → process the batch yourself (Step 4) → spawn the next sensor.
6. On any stop condition, print the summary and end.

Do not edit files in a sensor subagent. Do not call Agent with `run_in_background: true`. Do not spawn more than one sensor at a time. Do not skip the test command before pushing. Do not merge the PR. Do not resolve conversations.
