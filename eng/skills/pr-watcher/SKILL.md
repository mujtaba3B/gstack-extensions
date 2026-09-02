---
name: pr-watcher
description: Foreground watcher that pairs the main agent (dispatcher and fix-applier) with a deterministic polling script (the sensor, scripts/sensor-poll.sh) to handle CodeRabbit feedback on a GitHub PR. The dispatcher runs the script in foreground Bash slices; it blocks until CR posts a settled round of feedback (or a budget expires) and prints exactly one JSON blob per invocation. The main agent classifies, applies fixes, runs tests, commits, pushes, and replies on the PR itself, then starts the next sense cycle. Never merges; never resolves conversations; never pushes without passing tests; never touches files outside the PR's own diff; never parallelizes fixes. Use when asked to "watch the PR", "watch coderabbit", "pr watch", or invoked manually as `/eng:pr-watcher <PR_URL>` after /ship.
---

## Update check (run first)

Before the skill body, check whether the gstack-extensions repo has merged updates this clone has not pulled. Silent unless an upgrade is available; never changes anything:

```bash
~/dev/tooling/gstack-extensions/bin/gstack-extensions-update-check 2>/dev/null || true
```

If there is no output, proceed straight to the skill body. If it prints `UPGRADE_AVAILABLE <n> <range>`, tell the user via AskUserQuestion that gstack-extensions is `<n>` commit(s) behind `origin/main` and offer:

- **Upgrade now (recommended)**: run `~/dev/tooling/gstack-extensions/bin/gstack-extensions-upgrade`, then continue. It fast-forwards `main` and refreshes the installed plugins, and refuses safely (printing why) if the clone is not on a clean `main`; relay that message and continue without upgrading if so.
- **Skip this time**: run `~/dev/tooling/gstack-extensions/bin/gstack-extensions-update-check --snooze` to suppress the prompt for ~8h (so other skills do not re-ask this session), then continue without upgrading.

Do not upgrade without asking. Ask at most once per session: if you have already prompted (or the user skipped) this session, proceed silently.

# eng:pr-watcher

You are running the `/eng:pr-watcher` skill. It watches a single PR for CodeRabbit (`coderabbitai[bot]`) activity and applies fixes within the watcher's contract.

**Where this sits in the family.** `eng:cr` *performs* reviews; this skill and `eng:address-pr-feedback` *respond* to them. This skill is the **autonomous** responder: it polls and auto-handles each settled CodeRabbit round. `eng:address-pr-feedback` is the **manual** sibling for working comments one at a time with explicit lesson capture. They share the same job (respond to review feedback on your own PR); pick autonomous vs manual by whether you want to walk away or stay in the loop. When the watcher escalates an item it cannot handle (`needs_user_input`), `eng:address-pr-feedback` is the natural follow-up for working it by hand.

## Architecture: dispatcher + deterministic sensor script

This skill splits work between two roles:

- **Main agent (you) = dispatcher + gate + fix-applier.** You read the sensor's JSON, classify each finding, apply fixes with Edit/Write, run tests, commit, push, and post PR replies. You hold all user-facing decisions.
- **Sensor = `scripts/sensor-poll.sh`, a deterministic script.** You run it in a FOREGROUND Bash call. It implements the whole polling protocol (init pass, status-primary 15s loop, comment-stream fallback, settle conditions, budgets) and prints EXACTLY ONE JSON object per invocation. It never edits files, never runs git, never writes on the PR (read-only `gh` calls).

Loop: run one sense cycle (foreground script, sliced; see Step 3), process the batch in the main turn, update baselines, run the next sense cycle. Repeat until merged / closed / user stops / the sensor returns `idle_timeout` and you decide to stop.

Why a script and not a subagent (v4; the v2/v3 sensor was a general-purpose subagent):
- The old contract ("block 30 minutes inside one agent turn, then return one JSON") is unsatisfiable with harness primitives: foreground `sleep` is blocked for agents, and both background tasks and Monitor END the agent's turn, which the dispatcher reads as the sensor's final answer. In the 2026-07-20 incident (email-hero PR 79) the sensor parked twice on monitors whose conditions fired correctly within a minute of CR finishing, with no agent left to consume them.
- A script that sleeps INTERNALLY runs fine in one foreground Bash call, so "one command in, one JSON out" holds by construction. No prompt for a model to drift on, no turn to end early, and no second agent burning tokens to babysit a loop.
- Main context absorbs one short JSON per cycle, not minutes of "tick" lines.
- One sense cycle at a time + main-owned git = zero risk of concurrent edits on the branch.

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

Two pieces of config: **fix scope** (files you may edit) and **timeout** (when to give up). Test command is intentionally NOT part of the watcher's contract — it added friction for repos without a test framework and a wrong default is worse than no gate.

Fix scope defaults to the set of files currently changed in this PR. Refresh on every cycle so newly-touched files come into scope.

```bash
TIMEOUT_SECONDS="${PR_WATCHER_TIMEOUT:-28800}"  # default 8 hours
echo "TIMEOUT_SECONDS=$TIMEOUT_SECONDS"
echo "WATCH_STARTED=$(date +%s)" > "$STATE_DIR/started"
```

Initialize the per-PR baseline ID stores if absent. Baselines hold IDs the main agent has already processed and intentionally skipped.

```bash
for f in issue_comments reviews review_comments; do
  [[ -f "$STATE_DIR/baseline_${f}.json" ]] || echo '[]' > "$STATE_DIR/baseline_${f}.json"
done
: > "$STATE_DIR/escalations.jsonl"
```

On a fresh watch (state dir just created, all three baselines are empty arrays), seed baselines with **only the CR items that already look addressed**. "Addressed" means a human has weighed in on the item, either by replying inside the CR thread or by referencing the CR comment's URL in another PR comment. Unaddressed items get left out of the baseline so the first sensor cycle returns them and the dispatcher processes them in Step 4.

Why this shape: a CR comment with no human follow-up is exactly the case the watcher should pick up, whether the PR is brand-new or a month old. A CR comment that already has a reply (the watcher's own "Addressed in <sha>...", your manual "skipping because X", a teammate's "won't fix") is signal that someone already decided, and the watcher should not re-litigate. The "skipping because X" reply pattern doubles as the manual opt-out: if you don't want a specific CR comment processed, reply to it with your reason and the next fresh watch will baseline it.

```bash
# Fresh-watch detection: all three baselines are empty arrays.
IS_FRESH=1
for f in issue_comments reviews review_comments; do
  [[ "$(jq 'length' "$STATE_DIR/baseline_${f}.json")" == "0" ]] || { IS_FRESH=0; break; }
done

if [[ "$IS_FRESH" == "1" ]]; then
  # Note on pagination: every gh-api call below caps at per_page=100 and the
  # GraphQL reviewThreads query caps at first:100 / first:50 comments per
  # thread. On a PR with >100 CR items across one stream (or a thread with
  # >50 comments), older items past the cap will be missed during baseline
  # init and re-processed on cycle one. This is intentional. Pagination
  # would add complexity for a case that doesn't happen on real-world PRs;
  # if it ever does, Step 4b's status_ping / nitpick_only auto-classification
  # absorbs the noise without making edits.

  # Pull all CR items from each stream (id + html_url for URL-reference detection).
  CR_ISSUE_COMMENTS=$(gh api "repos/$OWNER/$REPO/issues/$PR_NUM/comments?per_page=100" \
    | jq '[.[] | select(.user.login == "coderabbitai[bot]") | {id:(.id|tostring), html_url}]')
  CR_REVIEWS=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUM/reviews?per_page=100" \
    | jq '[.[] | select(.user.login == "coderabbitai[bot]") | {id:(.id|tostring), html_url}]')
  CR_REVIEW_COMMENTS=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUM/comments?per_page=100" \
    | jq '[.[] | select(.user.login == "coderabbitai[bot]") | {id:(.id|tostring), html_url}]')

  # Concatenate every non-CR PR comment body. Used as a haystack for URL-reference
  # detection: any CR item whose html_url appears here counts as addressed.
  HUMAN_BODIES=$(gh api "repos/$OWNER/$REPO/issues/$PR_NUM/comments?per_page=100" \
    | jq -r '[.[] | select(.user.login != "coderabbitai[bot]") | .body // ""] | join("\n---\n")')

  # GraphQL: reviewThreads expose the inline-comment thread structure. A CR
  # review_comment is "addressed" if any non-CR author also commented in its
  # thread. The bot login under .author.login is "coderabbitai" (no [bot]).
  ADDRESSED_INLINE_IDS=$(gh api graphql -f query='
    query($owner:String!,$repo:String!,$pr:Int!){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$pr){
          reviewThreads(first:100){
            nodes{
              comments(first:50){
                nodes{ databaseId author{ login } }
              }
            }
          }
        }
      }
    }' -F owner="$OWNER" -F repo="$REPO" -F pr="$PR_NUM" 2>/dev/null \
    | jq '[.data.repository.pullRequest.reviewThreads.nodes[]
           | select(any(.comments.nodes[]; .author.login != "coderabbitai"))
           | .comments.nodes[]
           | select(.author.login == "coderabbitai")
           | .databaseId | tostring] | unique')
  [[ -z "$ADDRESSED_INLINE_IDS" || "$ADDRESSED_INLINE_IDS" == "null" ]] && ADDRESSED_INLINE_IDS='[]'

  # Helper: given a CR-items JSON array, return the subset whose html_url
  # appears in $HUMAN_BODIES. The `.html_url as $url` bind is load-bearing:
  # inside `$bodies | contains(.html_url)`, the `.html_url` would otherwise
  # be re-evaluated against the $bodies string and jq errors with
  # "Cannot index string with string html_url".
  filter_url_referenced() {
    jq --arg bodies "$HUMAN_BODIES" '
      [.[] | .html_url as $url | select($bodies | contains($url)) | .id] | unique
    ' <<<"$1"
  }

  # review_comments: addressed if in inline-reply set OR url-referenced.
  URL_REF_REVIEW_COMMENTS=$(filter_url_referenced "$CR_REVIEW_COMMENTS")
  jq -n --argjson a "$ADDRESSED_INLINE_IDS" --argjson b "$URL_REF_REVIEW_COMMENTS" \
    '$a + $b | unique' > "$STATE_DIR/baseline_review_comments.json"

  # issue_comments and review bodies: addressed iff url-referenced. Note that
  # CR's walkthrough/summary and "Actionable comments posted: 0" review bodies
  # are auto-classified as status_ping / nitpick_only in Step 4b, so leaving
  # them unbaselined here is cheap (one cycle to silently classify them).
  filter_url_referenced "$CR_ISSUE_COMMENTS" > "$STATE_DIR/baseline_issue_comments.json"
  filter_url_referenced "$CR_REVIEWS"        > "$STATE_DIR/baseline_reviews.json"
fi
```

If any of the API calls above fail (auth, rate limit, network), the helper steps fall back to empty baselines for that stream and the first cycle will see those CR items as new. That is acceptable: the dispatcher's classification step (4b) catches CR noise (`status_ping`, `nitpick_only`) without making fixes, so the worst case is one extra processing cycle, not an unwanted edit.

Print a one-line start banner:

```
🐇 Watching PR #<NUM> (<owner>/<repo>). Timeout: <hours>h. Ctrl-C to stop.
```

## Step 3: SENSE - run the sensor script in the foreground

Sensing is one deterministic script, run as a foreground Bash command. The script reads the baselines straight from `$STATE_DIR` (no input marshalling) and prints one JSON object per invocation.

The sensor's primary signal is CodeRabbit's **commit status** (legacy GitHub Statuses API): CR posts a `CodeRabbit` context status on each new HEAD commit that transitions `pending` → `success`/`failure` when its review pass finishes. That single endpoint is cheap, so the script polls it every 15s and fetches the three comment streams only when the status transitions. When there is no CR commit status to watch (a repo whose CR setup never posts one, or a status stuck in `pending` while comments still arrive), it falls back to comment-stream polling every ~60s with the marker / quiet-period settle conditions. The init pass (before the loop) returns immediately when CR is already terminal on the current HEAD: `already_settled` (success, nothing unprocessed), `cr_failure` (failure/error, nothing unprocessed), or `new_cr_feedback` (unprocessed backlog with a settle condition already holding).

Resolve the script from the installed plugin (repo checkout as fallback) and start the cycle fresh:

```bash
SENSOR="${CLAUDE_PLUGIN_ROOT:-$HOME/dev/tooling/gstack-extensions/eng}/skills/pr-watcher/scripts/sensor-poll.sh"
rm -f "$STATE_DIR/sensor-state.json"   # new sense cycle: the init pass runs again
```

Then run the slice loop, repeating this SAME command while the printed outcome is `"continue"`:

```bash
"$SENSOR" --owner "$OWNER" --repo "$REPO" --pr "$PR_NUM" --state-dir "$STATE_DIR"
```

Slice mechanics (why "continue" exists): a foreground Bash call caps at 10 minutes, so the script returns within ~9 minutes per invocation (`--slice-seconds 540`) and spans the cycle's 30-minute budget (`--total-seconds 1800`) across at most 4 invocations, persisting its place in `$STATE_DIR/sensor-state.json` between them. Rules:

- Run it FOREGROUND: pass `timeout: 600000` on the Bash call and OMIT `run_in_background`.
- `"continue"` is not a failure and needs no user interaction: immediately run the same command again.
- NEVER wrap the script in a background task, a Monitor, or an Agent subagent. The v3 sensor subagent parked exactly that way (turn ended, JSON never arrived) while CodeRabbit was already finished; sensing is this one repeated foreground command, by design.

### Sensor output schema

One JSON object on stdout per invocation. Full comment bodies, no truncation.

```json
{
  "outcome": "new_cr_feedback" | "pr_closed" | "idle_timeout" | "already_settled" | "cr_failure" | "continue" | "error",
  "polled_for_seconds": 0,
  "ticks": 0,
  "head_sha_at_return": "<sha>",
  "cr_status_state": "pending | success | failure | error | null",
  "cr_status_updated_at": "<iso8601 | null>",
  "settled_via": "status_transition | marker | quiet_period | n/a",
  "new_issue_comments":  [{"id": "...", "updated_at": "...", "body": "..."}],
  "new_reviews":         [{"id": "...", "state": "...", "submitted_at": "...", "body": "..."}],
  "new_review_comments": [{"id": "...", "path": "...", "line": 0, "updated_at": "...", "body": "..."}],
  "error_message": "only present when outcome is error"
}
```

After the sensor returns, branch on `outcome`:

- `"continue"` → the slice budget expired before CR settled: run the same sensor command again immediately (already covered by the slice loop above; it is not a failure and does not reach the decisions below).
- `"pr_closed"` → print `PR is closed/merged. Watcher exiting.` and end the skill.
- `"already_settled"` → CodeRabbit's review on the current HEAD is terminal `success` and there are no unprocessed CR items. (Sensor returns this only for `success`, never for `failure`/`error`.) Print `🐇 CodeRabbit is caught up on HEAD <sha> (status: success). Nothing to address. Watcher exiting.` and end the skill. Do NOT loop again; another sense cycle would just reproduce this outcome.
- `"cr_failure"` → CodeRabbit's review on the current HEAD ended in `failure` or `error` with no actionable comments to drain. CR has emitted its final word; no new transition will arrive without a new push. **Check for a rate-limit FIRST, before the genuine-failure exit below.** Two independent signals, either of which means rate limit rather than a real CR error: (a) CR's comments contain the `rate limited by coderabbit.ai` marker, or (b) the CodeRabbit commit status's own DESCRIPTION says rate limited (e.g. `Review rate limited`). Signal (b) is the common one on an incremental pass that burns the limit, and CR often posts NO marker comment in that flavour, so check it explicitly: `gh api repos/<owner>/<repo>/commits/<HEAD>/statuses -q 'first(.[] | select(.context=="CodeRabbit") | .description)'` and match `rate limit` case-insensitively. The sensor does not carry the description; this is a one-call dispatcher-side check. On either signal, take the Step 4h rate-limited short-circuit instead of exiting to inspect. If a current `/eng:cr` review backstops this HEAD (`review-skill-head` == HEAD) the PR is clear to land via `/land-and-deploy`; otherwise run `/eng:cr` first, then land. Watching will not help, because CR will not review this HEAD without a new push. **Only if it is NOT a rate-limit** (a genuine CR failure): print `⚠️ CodeRabbit review on HEAD <sha> ended in <state> (updated_at: <ts>). No comments were posted; this typically indicates a CR-side problem (internal error, repo config). Watcher exiting; please inspect the PR and re-invoke /eng:pr-watcher after the next push.` and end the skill. Do NOT loop; another sense cycle would reproduce this outcome.
- `"idle_timeout"` → ask the user (via AskUserQuestion) whether to keep watching or stop. Default recommendation: **stop** (long silence after watcher start almost always means CR is done; the user can re-invoke /eng:pr-watcher when there is new activity). If they choose to keep watching, start another sense cycle.
- `"new_cr_feedback"` → proceed to Step 4.
- `"error"` → the script's `gh` calls failed repeatedly (rate limit, expired auth, network) or its lib is missing; `error_message` says which. Count it as a sensor failure.

If the sensor prints unparseable output or `outcome: error`, count it as a sensor failure. After **three consecutive sensor failures**, print an error (include the last `error_message`) and stop.

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

**Rate-limit detection (overrides the classifications above).** Set a `cr_rate_limited` flag for this batch when EITHER signal is present: (a) an item's body contains the literal `rate limited by coderabbit.ai` (CodeRabbit's rate-limit notice, posted as an auto-generated `status_ping`-shaped comment), or (b) the CodeRabbit commit status on HEAD is `failure` and its description matches `rate limit` (the same one-call check the `cr_failure` branch in Step 3 makes). CodeRabbit did not COMPLETE a review of this HEAD (in the missing and pending shapes it never reviewed it at all; in the failure shape it may have reviewed HEAD and only tripped the limit on a trailing incremental pass), so its status here is not a real review verdict: do not let it read as a clean pass. Handle it in the Step 4h short-circuit rather than looping. This is the same rate-limit marker the merge gate keys on. The gate recognizes THREE rate-limit shapes, and the watcher should reach the same conclusion on each:

| CR commit status on HEAD | Signal | Gate function |
|---|---|---|
| `missing` (CR never started) | marker comment anywhere on the PR | `mc_cr_rate_limited` |
| `pending`, stuck (started, then hit the limit) | marker is CR's LATEST comment | `mc_cr_rate_limited_latest` |
| `failure` (an incremental pass burned the limit) | status DESCRIPTION says rate limited (non-negated), or the marker is CR's LATEST comment | `mc_cr_failure_rate_limited` |

Note the marker strictness: only row 1 accepts the marker anywhere on the PR, and it can afford to because a `missing` status means CR never posted anything for this HEAD at all. Rows 2 and 3 require the marker to be CR's LATEST comment, because in both of those CR demonstrably ran: a stale marker from an earlier commit must not make a later, genuine CR verdict read as a rate limit.

In every shape the gate treats the rate limit as satisfied ONLY when a current local `/eng:cr` review backstops the HEAD, so the watcher's advice ("run `/eng:cr`, then land") is exactly what the gate will require. A GENUINE CR failure (none of these signals) is different: the gate blocks it unless the operator passes `--override-cr-failure`, which also requires the current local review. The watcher never makes that call; it exits and asks the human to inspect.

Apply the project's coding principles when filtering. Reject suggestions that introduce single-use abstractions, speculative error handling, or "cleanup" outside the task.

### 4c. Surface ambiguous items to the user before acting

For each item that lands in `needs_user_input` or where you're between `valid_actionable` and `false_positive`, ask the user one question at a time (per the global "one question at a time" rule, with the `❓ QUESTION` blockquote format). Skip this step for clear-cut items.

### 4d. Apply fixes — atomic commit per finding

For each `valid_actionable` finding, in the order returned by the sensor:

1. Read the cited file.
2. Apply the minimal fix using Edit/Write.
3. Stage only the files you edited.
4. Commit with: `Address CodeRabbit: <one-line summary>` followed by a blank line and `Comment: <url>`.
5. `git push`. Capture the commit SHA.
6. Subsequent findings start from the new HEAD (so they may see prior fixes as `already_fixed`).

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

The loop's exit condition is "CodeRabbit has nothing left for us." Detect that here, before starting the next sense cycle, so the watcher does not spin a 30-minute idle_timeout waiting for a transition that will never come.

Exit the skill (do NOT start another sense cycle) when ALL the following hold for the batch you just processed:

- `pushed_commits_this_batch == 0` (no `valid_actionable` finding made it through tests + commit + push this batch). If you pushed even once, CR will re-review the new HEAD, so do not exit.
- The sensor returned `cr_status_state == "success"` AND `settled_via == "status_transition"`. (CR's terminal pass on the current HEAD finished cleanly. `failure`/`error` is also "done" in CR's sense, but signals a CR-side problem worth keeping the watcher alive for a human to inspect, so do not auto-exit on those.)
- All findings in the batch classified as `status_ping`, `nitpick_only`, `already_fixed`, or `false_positive` (no `valid_actionable`, `out_of_scope`, or `needs_user_input` left in flight). `out_of_scope` and `needs_user_input` items both escalate to `escalations.jsonl` rather than being replied to on the PR (see Step 4e), so leaving them unresolved means there is still pending human work; the watcher should keep the loop alive so the user can see them when they return.

**Rate-limited short-circuit (check this FIRST, before the clean-exit line below).** If `cr_rate_limited` was set for this batch (Step 4b, via either the marker comment or a rate-limited status description), CodeRabbit hit its limit INSTEAD of finishing the review, so its status on this HEAD is not a real review verdict and there is nothing to keep watching for: CR will not review this HEAD without a new push. Do the same thing the merge gate does (`merge-clearance.sh` `CR_RATE_LIMITED` / `CR_RL_BACKSTOPPED`): fall back to the current local `/eng:cr` review. Compare `<git-dir>/review-skill-head` against the PR HEAD:

- Backstopped (`review-skill-head` == HEAD): a current `/eng:cr` review already covers this HEAD. Print `🐇 CodeRabbit is rate-limited (no real review on HEAD <sha>); a current /eng:cr review backstops it. Nothing to watch. Land via /land-and-deploy.` and end the skill.
- Not backstopped: print `🐇 CodeRabbit is rate-limited (no real review on HEAD <sha>) and no current /eng:cr review backstops it. Run /eng:cr on this HEAD, then land via /land-and-deploy. Not watching further.` and end the skill.

Do NOT start another sense cycle in either case. Only when `cr_rate_limited` is NOT set does the genuine clean-exit below apply.

When the condition is met, print:

```text
🐇 CodeRabbit's review on HEAD <sha> is clean (Actionable comments posted: 0). Watcher exiting.
```

and end the skill.

Then return to Step 3 and run the next sense cycle.

## Stop conditions

The skill exits when any of:

- Sensor returns `outcome: pr_closed`.
- Sensor returns `outcome: already_settled` (CR already done on the current HEAD when the sense cycle started).
- Step 4h all-clear check fires (CR's terminal pass on the current HEAD posted nothing actionable and we did not push during the batch).
- Sensor returns `outcome: idle_timeout` and the user chooses to stop.
- Wall-clock timeout reached (default 8h, override via `PR_WATCHER_TIMEOUT`).
- User interrupts the session (Ctrl-C, /exit).
- Three consecutive sensor failures (unparseable output or `outcome: error`).

On exit, print:

```
🐇 eng:pr-watcher stopped. PR <state>. Handled <N> items, <M> escalated. State: $STATE_DIR
```

## State directory layout

```
~/.cache/pr-watcher/<owner>__<repo>__<pr>/
  started                          # WATCH_STARTED=<epoch>
  baseline_issue_comments.json     # JSON array of CR comment IDs already processed
  baseline_reviews.json
  baseline_review_comments.json
  escalations.jsonl                # append-only, one JSON per line
  sensor-state.json                # transient: sensor-poll.sh's place within ONE
                                   # sense cycle (survives "continue" slices; removed
                                   # on terminal outcomes; the dispatcher's rm at each
                                   # cycle start is the backstop)
```

State is per-PR and persists across sessions. Re-invoking `/eng:pr-watcher` on the same PR after `/exit` resumes from the saved baselines, never re-processing items already handled.

## Failure handling

| Failure | Response |
|---|---|
| `gh` rate-limited or failing transiently | In the 15s loop the script tolerates failing ticks and keeps polling; after ~10 minutes of consecutive failures it returns `outcome: error` with the captured gh stderr in `error_message`. The init pass is tighter: 3 attempts ~15s apart, then `outcome: error` (a dead API at cycle start is likely auth/config, not weather). The dispatcher counts an `error` as a sensor failure. |
| `gh` returns 401 | Surfaces as `outcome: error` whose `error_message` carries gh's stderr; when it names 401/auth, print `ERROR: gh auth expired. Run gh auth login.` and stop instead of retrying. |
| Concurrent push by a human | `git pull --rebase` once and retry; on conflict, revert and escalate that finding. |
| PR force-pushed (head SHA changed) | Inline review comment IDs may become stale. On the next cycle, clear `baseline_review_comments.json` and re-seed from the current CR comments. |
| Sensor prints unparseable output or `outcome: error` | Count as a sensor failure. After 3 consecutive failures, exit. |

## What you (the running session) actually do

1. Step 0 → resolve PR.
2. Step 1 → verify prereqs.
3. Step 2 → discover config (timeout, baselines). Seed baselines on first run.
4. Print the start banner.
5. Loop: run ONE sense cycle (Step 3: the foreground sensor script, re-run while it says `continue`) → read its JSON → process the batch yourself (Step 4) → next sense cycle.
6. On any stop condition, print the summary and end.

Do not run the sensor script in a background task, a Monitor, or an Agent subagent; it runs foreground, in your own turn. Do not run more than one sense cycle at a time. Do not merge the PR. Do not resolve conversations.
