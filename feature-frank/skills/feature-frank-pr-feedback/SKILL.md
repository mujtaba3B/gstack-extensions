---
name: feature-frank-pr-feedback
description: >
  Use this skill whenever the user wants to work through review comments on a
  pull request they authored — addressing each comment, patching the code, and
  capturing a durable lesson so the same mistake is not made again. Trigger
  when the user says "address PR comments", "review comments", "CR comments",
  "my PR has comments", "CodeRabbit flagged", "what does this reviewer want",
  "respond to reviewer", "fix review feedback", "learn from PR feedback", or
  "/feature-frank-pr-feedback". Use this even when the user only says
  "there are comments on my PR" — the skill covers both the triage and the
  fix-plus-learn loop.
---

# Feature Frank — PR Feedback

**Read first:** Load `shared/core.md` from the bundle root. It defines your identity, the team, how to think about PR feedback, the tooling layers you update, and commit style.

Your job here is to help the user *learn from* and *address* review comments on a pull request they authored. Every comment is an opportunity to patch not just the code, but the tooling that should have prevented the mistake in the first place.

---

## Invocation

- **No argument** → scan the user's open PRs for ones with actionable comments and present a batch overview.
- **Argument** (PR number, URL, or branch) → jump straight to that PR, skipping the scan.

---

## Step 1: Find the PR(s) to work on

### With an argument

Resolve the argument to a PR and skip to Step 2.

- PR number (e.g., `52`) → `gh pr view 52`
- URL → `gh pr view <url>`
- Branch name → `gh pr view <branch>`

### Without an argument — scan the user's PRs

```bash
WHOAMI=$(gh api user --jq .login)
gh pr list --author "@$WHOAMI" --state open --limit 30 \
  --json number,title,url,headRefName,reviewDecision,updatedAt
```

For each PR, fetch comments and count the ones that are **actionable** (see Step 2's definition). Comments include both line-level review comments and top-level issue comments — fetch both.

```bash
gh api repos/$REPO/pulls/$PR/comments --jq '[.[] | {user: .user.login, body: .body, path: .path, line: .line, html_url: .html_url, in_reply_to_id: .in_reply_to_id, id: .id}]'
gh api repos/$REPO/issues/$PR/comments --jq '[.[] | {user: .user.login, body: .body, html_url: .html_url, id: .id}]'
```

For resolved status on threaded review comments, use GraphQL:

```bash
gh api graphql -f query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100) {
          nodes {
            isResolved
            comments(first: 20) { nodes { id databaseId author { login } body path line url } }
          }
        }
      }
    }
  }' -F owner=$OWNER -F repo=$REPO_NAME -F pr=$PR
```

### Present the batch overview

Show a compact table — only PRs that have at least one actionable comment:

| PR | Title | Actionable | Reviewers | Updated |
|----|-------|------------|-----------|---------|

Below the table, flag anything worth noticing ("two PRs have comments from the same reviewer about X — possible pattern"). Then use **AskUserQuestion** to pick one PR.

If there are zero open PRs with actionable comments, say so clearly and stop.

---

## Step 2: Collect actionable comments on the chosen PR

An **actionable comment** is any of:

- A human comment that reads as a request for change, a question that expects a code answer, or a concrete critique (not pleasantries, not clarifying questions about intent, not resolved).
- A comment from a recognized code-review bot: **CodeRabbit** (`coderabbitai[bot]`, `coderabbitai-lite[bot]`), **Greptile** (`greptile-apps[bot]`), **codex**, **Sourcery**, or similar review bots.

Explicitly **skip**:

- Resolved review threads (check `isResolved` from the GraphQL query).
- The user's own comments and replies.
- Comments that are purely pleasantries ("LGTM", "nice work") with no change request.
- Outdated line-level comments whose `position` field is `null`.

When in doubt about whether a human comment is a change request, err on the side of including it and explain your read to the user in Part 1 of the per-comment output — they can tell you to skip.

Order the actionable comments: bot comments after human comments (since humans usually want their feedback acknowledged first), otherwise by file+line for locality so related fixes can potentially share a commit.

---

## Step 3: Per-comment loop

Work through comments **strictly one at a time**. This is load-bearing — don't batch.

The loop for each comment is:

1. Produce the three-part breakdown (below) for *this one comment only*.
2. **Stop.** Present it. Wait for the user's decision via AskUserQuestion.
3. Act on the decision (apply fix + commit, post reply, or skip).
4. Only then load the next comment and repeat.

Do not surface Comment 2's analysis before Comment 1 has been decided and acted on, even if it would be fast. The user wants to see the result of each decision before considering the next one — patterns across comments can shift what they'd do on later ones. Presenting multiple comments at once collapses that decision space and defeats the whole point of the loop.

If the user explicitly says "show me all the comments at once" or "batch them," honor that override. Otherwise: strict one-at-a-time.

### Part 1 — What it says

In plain English, summarize:

- Who commented (username + whether human or bot).
- Where (file:line or "top-level on PR").
- What they're asking for, in your own words.
- The literal comment quoted below your summary (so the user doesn't have to go to GitHub to verify).

Don't just restate the comment — interpret it. If the reviewer is hinting at a larger concern (e.g., "this looks like SQL injection" really means "you're interpolating user input into a query"), say so.

### Part 2 — How we missed it

Diagnose the root cause. Ask yourself:

- What rule, convention, or check should have caught this *before* the PR was opened?
- Was the rule absent from tooling, or present but vague, or present but ignored?
- Is this a one-off oversight or a symptom of a pattern you can name?

Then propose a concrete tooling update, scoped to one of:

- **Repo `AGENTS.md`** — a new bullet or section. Show the exact text you'd add, and where.
- **Repo `CLAUDE.md`** — same as above, if the project uses CLAUDE.md.
- **User-global `~/.claude/CLAUDE.md`** — if this is a cross-repo preference. Show the proposed line and where it'd go.
- **A gstack skill** — if the missed rule fits an existing gstack skill. Name the skill, quote the section to modify, show the edit.

If the repo has no `AGENTS.md`, propose creating one and say so explicitly — don't silently add it later.

If the root cause is genuinely one-off ("reviewer spotted a typo we'd miss once in a hundred PRs, no point hardening for it"), say that plainly. Not every comment deserves a tooling change, and padding AGENTS.md with weak lessons dilutes the real ones.

### Part 3 — The fix

Choose and show one of:

- **Code change** — the exact diff you'd apply. Be specific: file, line, old vs new.
- **Reply and push back** — a drafted reply explaining why you disagree. Keep it respectful, concrete, and short. No code change.
- **Reply with clarifying question** — when the comment is ambiguous and you genuinely need more info before acting. Draft the reply.

### Decision prompt

Use **AskUserQuestion** with these options:

- **Apply the fix** — make the code change, commit, and (if AGENTS.md/CLAUDE.md in-repo is affected) update it in the same commit with a note.
- **Reply and push back** — post the drafted reply, no code change.
- **Skip** — acknowledge the comment and move on without any action. Note the reason in internal tracking so you don't re-suggest it.
- **Redirect** — user will type their own guidance.

If the user picks *Apply the fix*, make the change, stage, commit atomically with a message referencing the comment (see `shared/core.md` → Commit style). Then continue to the next comment.

If the user picks *Reply and push back*, post with:

```bash
gh api repos/$REPO/pulls/$PR/comments/$COMMENT_ID/replies -f body="..."
```

(Or the top-level `issues/$PR/comments` endpoint for top-level comments.)

Track proposed tooling updates (Part 2) internally — **do not apply outside-repo changes yet**. Collect them for Step 4.

---

## Step 4: End-of-PR tooling consolidation

After the last comment, present two sections:

### In-repo updates (already applied)

List every `AGENTS.md` / `CLAUDE.md` in-repo change that was applied as part of the per-comment commits. Brief — this is a recap so the user knows what landed.

### Outside-repo recommendations (awaiting approval)

Present these as a consolidated, deduped set. If three comments all pointed at the same class of mistake, merge them into one lesson. For each:

- Where the change goes (`~/.claude/CLAUDE.md` or `~/.claude/skills/gstack/<skill>/SKILL.md`).
- The exact proposed edit (quote the surrounding text so the user can see context).
- The reasoning — which comments drove this lesson.

Use **AskUserQuestion** to ask which to apply. Offer: *Apply all*, *Apply some (pick individually)*, *Skip all*.

Only after the user approves each specific change, apply it. Never modify gstack or global CLAUDE.md silently.

---

## Step 5: Wrap up

Briefly summarize:

- Number of comments addressed (fixed vs replied-pushed-back vs skipped).
- Commits made, in order, with SHAs.
- AGENTS.md / in-repo CLAUDE.md updates landed.
- Outside-repo updates applied (if any).
- Any comments that still need the user's attention (ones they redirected or that you couldn't confidently categorize).

Push the branch at the end:

```bash
git push
```

Suggest the user re-request review if they applied fixes: `gh pr review --approve` is not what we want here; point them at the "Re-request review" button on the PR, or use `gh api repos/$REPO/pulls/$PR/requested_reviewers`.

---

## What this skill never does

- Does not force-push or use `--no-verify`.
- Does not auto-apply changes to files outside the current repo without explicit approval.
- Does not resolve review threads on the user's behalf — the reviewer resolves their own threads after they see the fix.
- Does not skip the "how did we miss this" step, even when a fix is obvious. The learning is the whole point.
- Does not treat every comment as a must-fix. Judgment is a first-class option.
