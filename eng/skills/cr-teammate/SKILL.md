---
name: cr-teammate
description: >-
  Review a GitHub pull request authored by SOMEONE ELSE (a human teammate or an autonomous agent like a mu*/*-ai bot) and leave one author-tagged review comment on it. This is eng:cr's specialist for reviewing someone else's PR: same shared review engine and lenses, findings verified against the actual repo rather than the PR description, a quick chat summary, then exactly ONE structured comment posted via gh pr comment led by an @<author> mention, after a confirm gate on the wording. Never merges, pushes, resolves conversations, or mints the merge-clearance stamp (that is eng:cr's job). Use for "review this PR", "review the teammate's PR", "review the agent PR", "is this good to deploy?", "look at PR #N", or "/eng:cr-teammate" with a PR number or URL.
---

## Update check (run first)

Before the skill body, check whether the gstack-extensions repo has merged updates this clone has not pulled. Silent unless an upgrade is available; never changes anything:

```bash
~/dev/gstack-extensions/bin/gstack-extensions-update-check 2>/dev/null || true
```

If there is no output, proceed straight to the skill body. If it prints `UPGRADE_AVAILABLE <n> <range>`, tell the user via AskUserQuestion that gstack-extensions is `<n>` commit(s) behind `origin/main` and offer:

- **Upgrade now (recommended)**: run `~/dev/gstack-extensions/bin/gstack-extensions-upgrade`, then continue. It fast-forwards `main` and refreshes the installed plugins, and refuses safely (printing why) if the clone is not on a clean `main`; relay that message and continue without upgrading if so.
- **Skip this time**: run `~/dev/gstack-extensions/bin/gstack-extensions-update-check --snooze` to suppress the prompt for ~8h (so other skills do not re-ask this session), then continue without upgrading.

Do not upgrade without asking. Ask at most once per session: if you have already prompted (or the user skipped) this session, proceed silently.

# eng:cr-teammate

**Read first:** Load `shared/review-engine.md` (the multi-lens review machinery this skill runs). This skill is `eng:cr`'s specialist for the "someone else's PR" case: same review engine, different terminal act. Where `eng:cr` reviews your own pre-merge work and mints the gate stamp, `eng:cr-teammate` reviews another author's PR and **posts one comment** so they are notified.

You are running `/eng:cr-teammate`. The goal is a high-signal review of a pull request you did **not** author (a human teammate's PR, or an autonomous-agent PR), ending in two things: (1) a quick verdict and summary to the user in chat, and (2) one structured review comment posted on the PR itself.

**The terminal outcome is always one comment posted on the PR, led by an `@<author>` mention.** This is not optional and not conditional on the verdict: whether the PR is clean or full of blockers, the skill ends by posting exactly one structured review comment, and that comment always opens by tagging the login that opened the PR so they are notified to act. The only gate is wording (Step 4 shows the user the draft and takes edits before it goes up); the gate decides *what the comment says*, never *whether a comment is posted*. A run that ends without a posted, author-tagged comment has not completed. The chat summary is a convenience, not a substitute for the comment.

The reference for "good" output is a verdict-first comment: **a clear merge / don't-merge call, numbered blockers each with a concrete fix, lower-priority items, credit for what is right, a short to-do list, and an explicit no-merge-until line.**

## What this skill WILL NOT do

- Merge or close the PR.
- Push commits or apply fixes (this is review-only; if the user wants fixes applied, that is `/eng:pr-watcher` or a hands-on session).
- Mark conversations resolved.
- Change the PR's assignee, labels, or title.
- Mint the merge-clearance stamp. That stamp records *your own* pre-merge review and belongs to `eng:cr`. (If you are the one about to merge this PR through the gate, run `eng:cr` in your local checkout to review and stamp; use this skill only to notify the author.)
- Post the comment without showing the draft and getting a confirm. (The confirm is about *wording*, not *whether* to post.)

If a finding needs code changes, describe the fix in the comment for the author to apply. Do not apply it.

---

## Step 0: Resolve the PR

Determine the PR from the user's invocation:
- Full GitHub URL: use as-is.
- `#123` or `123`: resolve against the current repo.
- Empty: `gh pr view --json url -q .url` on the current branch (and confirm with the user that is the one they mean).

Capture the repo `owner/name` and the PR author's login for later. You will lead the posted comment with `@<author-login>` so the author, human or agent, is notified to pick up the feedback. For agent PRs this mention is the whole point: it closes the review loop back to the bot that opened the PR.

## Step 1: Gather context

```bash
gh pr view <N>   --repo <owner/name> --json title,body,author,baseRefName,headRefName,additions,deletions,changedFiles,mergeable,reviewDecision,state,url
gh pr diff <N>   --repo <owner/name>
gh pr checks <N> --repo <owner/name>
gh pr view <N>   --repo <owner/name> --json reviews,comments
```

Read the diff yourself first to form an independent picture. Note any claims in the PR body or self-review you will need to verify.

## Step 2: Run the review engine

Run `shared/review-engine.md`:

- **Step A**: locate the pr-review-toolkit lenses (offer to install if missing).
- **Step B**: pick depth. A deliberate review of someone else's PR generally runs the full lens set; still skip lenses with no surface (e.g. type-design / tests on a docs-only change) and apply the hard-escalation rules.
- **Step C**: check the PR out into a detached worktree for surrounding-code context (the engine's worktree pattern), only when cwd is a clone of the PR's repo. Otherwise review from `gh pr diff` plus raw file reads.
- **Step D**: run the selected lenses as parallel `general-purpose` subagents (feed each toolkit prompt file's contents + the `gh pr diff` output), then apply the seventh design / blast-radius lens yourself.
- **Step E**: consolidate, verify every blocking finding against the actual repo, bucket into Blockers / Important / Nits / Strengths. Cross-check the PR's own claims against the code; mismatches are findings.

Tear down the worktree when the review is done (and on any early exit): `git worktree remove --force "$WT"`, then remove the mktemp parent.

## Step 3: Quick chat summary

Give the user a tight verdict first: **good to deploy or not yet, and why in one line.** Then the bucketed findings, blockers first, each one sentence. This is the at-a-glance read before anything is posted.

## Step 4: Draft and post one comment (always)

This step always runs and always ends in a posted comment. Draft a single review comment in this shape:

```markdown
@<pr-author-login> reviewed below.

## Verdict: <one-line merge / don't-merge call>

<one or two sentences on overall state; note if CI / cloud review passed but does not exercise the real risk>

### Blockers
1. **<title>**: <what is wrong, verified against the code>. Fix: <concrete fix, code if useful>.
2. ...

### Important / lower priority
- ...

### Credit where due
- <what the PR or its self-review got right>

### To make this mergeable
1. ...

No merge until <condition>, verified live, not just asserted.
```

Lead with `@<pr-author-login>` so the author is notified. Then **show the user the drafted comment and confirm before posting** (posting is outward-facing on GitHub). On approval, write the approved comment to a temp file and post it:

```bash
cat > /tmp/cr-teammate-comment.md <<'EOF'
<the approved comment body>
EOF
gh pr comment <N> --repo <owner/name> --body-file /tmp/cr-teammate-comment.md
```

Return the comment URL. Tear down the PR worktree if you created one. Do not merge, push, or resolve anything.

## Notes

- If `gh pr checks` shows CI or cloud review green, say so but do not treat it as sufficient: green CI rarely exercises the behavior an agent PR most often gets wrong. Call that out in the verdict.
- Keep the comment focused on what matters. A pile of nits buries the blockers. The whole point is signal.
