---
name: review-agent-pr
description: Review someone else's GitHub pull request (typically one opened by an autonomous agent like MuTwo/MuThree) and leave one well-structured review comment on it. Resolves the PR, ensures the pr-review-toolkit review engine is available (offers to install it if not), fans the diff out across six specialized review lenses (bugs/CLAUDE.md, silent failures, test gaps, type design, comment rot, simplification), verifies the sharp findings against the actual repo rather than trusting the PR description, gives the user a quick chat summary, then posts ONE structured comment via gh pr comment after a confirm gate. Never merges, never pushes, never resolves conversations, never touches the assignee. Use when asked to "review this PR", "review the agent PR", "is this good to deploy?", "look at PR #N", "review MuThree's PR", or invoked as `/review-agent-pr <PR# | URL>`.
---

# review-agent-pr

You are running the `/review-agent-pr` skill. The goal is a high-signal review of a pull request you did **not** author (usually an autonomous-agent PR), ending in: (1) a quick verdict + summary to the user in chat, and (2) one structured review comment posted on the PR itself.

The reference for what "good" output looks like is a verdict-first comment: **a clear merge/don't-merge call, numbered blockers each with a concrete fix, lower-priority items, credit for what's right, a short to-do list, and an explicit no-merge-until line.**

## What this skill WILL NOT do

- Merge or close the PR.
- Push commits to the PR branch or apply fixes (this is review-only; if the user wants fixes, that's a separate `/pr-watcher` or hands-on session).
- Mark conversations resolved.
- Change the PR's assignee, labels, or title.
- Post the comment without showing the draft and getting a confirm.

If a finding needs code changes, describe the fix in the comment for the author to apply. Do not apply it.

## The core discipline: verify, don't trust

Agent PRs come with confident descriptions and self-reviews that are often wrong about their own code (e.g. a description claims "fail-open" while the code fails closed; a hook claims to "block" while emitting the wrong schema). **The PR body and any self-review are claims, not evidence.** Every blocking finding must be checked against the actual diff and the actual repo before it goes in the comment. When a finding depends on framework/tool behavior (hook schemas, API contracts, CLI flags), verify the real contract , read the docs or the sibling code , rather than asserting from memory.

---

## Step 0 — Resolve the PR

Determine the PR from the user's invocation:
- Full GitHub URL → use as-is.
- `#123` or `123` → resolve against the current repo.
- Empty → `gh pr view --json url -q .url` on the current branch (and confirm with the user that's the one they mean).

Capture the repo `owner/name` for later `gh` calls.

## Step 1 — Ensure the review engine is available

This skill uses the **`pr-review-toolkit`** plugin's six review subagents as the review engine. It does not vendor them; it checks for them at runtime.

```bash
claude plugin list 2>/dev/null | grep -A2 'pr-review-toolkit'
```

- **Enabled** (`Status: ✔ enabled`) → continue to Step 2.
- **Disabled or absent** → do NOT silently degrade. Tell the user the engine isn't active and offer to install it, using `AskUserQuestion` with options:
  - **Install it now (recommended)** — run the install + reload below, then continue with the full six-lens review.
  - **Run a degraded inline review** — skip the plugin; you (the main agent) review the diff yourself against the same six lenses listed in Step 3. Lower depth, single context, no parallel specialists. Say so explicitly in the summary and the comment.
  - **Cancel** — stop the skill.

Install + activate (non-interactive, no session restart needed):

```bash
claude plugin install pr-review-toolkit@claude-plugins-official
```

Then run `/reload-plugins` (as a slash command) to make the subagents callable this session. After reload, re-check with `claude plugin list` before relying on the agents.

## Step 2 — Gather context

```bash
gh pr view <N>   --repo <owner/name> --json title,body,author,baseRefName,headRefName,additions,deletions,changedFiles,mergeable,reviewDecision,state,url
gh pr diff <N>   --repo <owner/name>
gh pr checks <N> --repo <owner/name>
gh pr view <N>   --repo <owner/name> --json reviews,comments
```

Read the diff yourself first to form an independent picture. Note any claims in the PR body / self-review that you will need to verify (Step 4).

To give the review subagents real surrounding-code context (not just the diff), check out the PR branch , but protect the user's working state:

1. Record the current branch: `git rev-parse --abbrev-ref HEAD`.
2. If the working tree is dirty (`git status --porcelain` non-empty), STOP and ask the user before switching , do not stash silently.
3. `gh pr checkout <N> --repo <owner/name>`.
4. After the review (Step 6, and on any early exit/error), restore: `git checkout -` (back to the recorded branch).

## Step 3 — Fan out the review lenses

With the plugin enabled, spawn these six subagents via the Agent tool, in parallel, each scoped to this PR's changed files. Pass each the PR's changed-file list and base branch so it reviews the PR diff, not the whole repo:

| `subagent_type` | Lens |
|---|---|
| `pr-review-toolkit:code-reviewer` | Bugs + CLAUDE.md compliance (confidence-scored; only ≥80 reported) |
| `pr-review-toolkit:silent-failure-hunter` | Swallowed errors, bad fallbacks, missing logging |
| `pr-review-toolkit:pr-test-analyzer` | Behavioral test-coverage gaps |
| `pr-review-toolkit:type-design-analyzer` | Type encapsulation / invariants |
| `pr-review-toolkit:comment-analyzer` | Comment rot / doc accuracy |
| `pr-review-toolkit:code-simplifier` | Clarity / simplification (lowest priority) |

(Degraded inline path: skip the subagents and review the diff yourself against these same six lenses, in one pass.)

## Step 4 — Consolidate and verify

- Collect all findings; dedupe overlaps (the lenses overlap on error handling and bugs).
- For every **blocking / high-confidence** finding: verify it against the actual diff and repo before it goes in the comment. Read the real file, the sibling code, or the authoritative doc. Discard anything you can't substantiate; downgrade anything that's a style nit.
- Cross-check the PR's own claims: does the code actually do what the body says? Mismatches are themselves findings.
- Bucket survivors into **Blockers** (must fix before merge), **Important** (should fix), **Nits/Suggestions**, and **Strengths**.

## Step 5 — Quick chat summary

Give the user a tight verdict first: **good to deploy / not yet, and why in one line.** Then the bucketed findings, blockers first, each one sentence. This is the at-a-glance read before anything is posted.

## Step 6 — Draft and post one comment

Draft a single review comment in this shape (model it on a strong manual review):

```
## Verdict: <one-line merge/don't-merge call>

<one or two sentences on overall state; note if CI/cloud review passed but doesn't exercise the real risk>

### Blockers
1. **<title>** — <what's wrong, verified against the code>. Fix: <concrete fix, code if useful>.
2. ...

### Important / lower priority
- ...

### Credit where due
- <what the PR / its self-review got right>

### To make this mergeable
1. ...

No merge until <condition>, verified live , not just asserted.
```

Then **show the user the drafted comment and confirm before posting** (posting is outward-facing on GitHub). On approval:

```bash
gh pr comment <N> --repo <owner/name> --body-file <draft.md>
```

Return the comment URL. Restore the original branch (`git checkout -`) if you checked out the PR. Do not merge, push, or resolve anything.

## Notes

- If `gh pr checks` shows CI/cloud review green, say so but don't treat it as sufficient , green CI rarely exercises the behavior an agent PR most often gets wrong. Call that out in the verdict.
- Keep the comment focused on what matters. A pile of nits buries the blockers. The whole point is signal.
