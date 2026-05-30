---
name: review-agent-pr
description: Review someone else's GitHub pull request (typically one opened by an autonomous agent like MuTwo/MuThree) and leave one well-structured review comment on it. Resolves the PR, locates the pr-review-toolkit review engine (offers to install it if missing), runs the diff through six toolkit review lenses (bugs/CLAUDE.md, silent failures, test gaps, type design, comment rot, simplification) plus a seventh design/blast-radius lens the main agent always applies, verifies the sharp findings against the actual repo rather than trusting the PR description, gives the user a quick chat summary, then posts ONE structured comment via gh pr comment after a confirm gate. Never merges, never pushes, never resolves conversations, never touches the assignee. Use when asked to "review this PR", "review the agent PR", "is this good to deploy?", "look at PR #N", "review MuThree's PR", or invoked as `/review-agent-pr <PR# | URL>`.
---

# review-agent-pr

You are running the `/review-agent-pr` skill. The goal is a high-signal review of a pull request you did **not** author (usually an autonomous-agent PR), ending in two things: (1) a quick verdict and summary to the user in chat, and (2) one structured review comment posted on the PR itself.

The reference for what "good" output looks like is a verdict-first comment: **a clear merge / don't-merge call, numbered blockers each with a concrete fix, lower-priority items, credit for what's right, a short to-do list, and an explicit no-merge-until line.**

## What this skill WILL NOT do

- Merge or close the PR.
- Push commits to the PR branch or apply fixes (this is review-only; if the user wants fixes, that is a separate `/pr-watcher` or hands-on session).
- Mark conversations resolved.
- Change the PR's assignee, labels, or title.
- Post the comment without showing the draft and getting a confirm.

If a finding needs code changes, describe the fix in the comment for the author to apply. Do not apply it.

## The core discipline: verify, don't trust

Agent PRs come with confident descriptions and self-reviews that are often wrong about their own code (a description claims "fail-open" while the code fails closed; a hook claims to "block" while emitting the wrong schema). **The PR body and any self-review are claims, not evidence.** Every blocking finding must be checked against the actual diff and the actual repo before it goes in the comment. When a finding depends on framework or tool behavior (hook schemas, API contracts, CLI flags), verify the real contract by reading the docs or the sibling code, rather than asserting from memory. The most valuable findings, and the most embarrassing misses, both come from actually running or reading the thing instead of trusting the text.

---

## Step 0: Resolve the PR

Determine the PR from the user's invocation:
- Full GitHub URL: use as-is.
- `#123` or `123`: resolve against the current repo.
- Empty: `gh pr view --json url -q .url` on the current branch (and confirm with the user that is the one they mean).

Capture the repo `owner/name` for later `gh` calls.

## Step 1: Locate the review engine

This skill uses the prompts from the **`pr-review-toolkit`** plugin's review agents as its review engine. It does not vendor them, and it does not depend on the plugin being "enabled": plugin subagents are **not** reliably invocable through the Agent tool's `subagent_type` (in many harnesses the Agent tool only exposes `general-purpose` and a few built-ins). What is reliable is that the agent prompt files ship in the plugin's marketplace cache and can be read directly, whether or not the plugin is enabled.

Find them:

```bash
find ~/.claude/plugins -path '*pr-review-toolkit/agents/*.md' 2>/dev/null
```

- **Files found**: note the directory and continue to Step 2. In Step 3 you pass each file's contents as the prompt to a `general-purpose` subagent.
- **Nothing found** (plugin not downloaded): do NOT silently skip the lenses. Use `AskUserQuestion` to offer:
  - **Install it (recommended)**: `claude plugin install pr-review-toolkit@claude-plugins-official`, then re-run the `find` above.
  - **Degraded inline review**: you (the main agent) apply the lenses yourself in one pass (Step 3 lists them). State this in the summary and the comment.
  - **Cancel**: stop the skill.

## Step 2: Gather context

```bash
gh pr view <N>   --repo <owner/name> --json title,body,author,baseRefName,headRefName,additions,deletions,changedFiles,mergeable,reviewDecision,state,url
gh pr diff <N>   --repo <owner/name>
gh pr checks <N> --repo <owner/name>
gh pr view <N>   --repo <owner/name> --json reviews,comments
```

Read the diff yourself first to form an independent picture. Note any claims in the PR body or self-review that you will need to verify (Step 4).

To give the review lenses real surrounding-code context (not just the diff), you may check out the PR branch, but only when the current directory is a clone of the PR's repo, and protect the working state:

1. Confirm cwd is the target repo: `git remote get-url origin` resolves to `owner/name`. If it does NOT (the user pasted a URL for a repo you are not sitting in), SKIP checkout entirely and review from `gh pr diff` plus `gh api` raw file reads. Never run `gh pr checkout` in an unrelated repo, it fails or pollutes that repo's refs.
2. Record the current branch: `git rev-parse --abbrev-ref HEAD`.
3. If the working tree is dirty (`git status --porcelain` is non-empty), STOP and ask the user before switching; do not stash silently.
4. `gh pr checkout <N>`.
5. After the review (Step 6, and on any early exit or error), restore: `git checkout -`.

## Step 3: Run the review lenses

For each lens, spawn a `general-purpose` subagent via the Agent tool, in parallel, giving it (a) the contents of the matching agent prompt file from Step 1 as its instructions, and (b) **the actual PR diff** (the `gh pr diff` output from Step 2) as the review target, plus the changed-file list and base branch. The diff is the subagent's primary input, so the lenses work whether or not you checked out the branch. If you DID check out the PR branch in Step 2, also tell the subagent the repo is checked out at the current directory so it can read surrounding files for context; if you skipped checkout, the diff is all it gets, which is enough to review the change itself. **Do not pass `subagent_type: pr-review-toolkit:...`** , those plugin-namespaced agents are not invocable via the Agent tool here; feeding their prompt text to a `general-purpose` agent is what actually works.

The six toolkit lenses (filenames under the `agents/` dir found in Step 1):

| Agent prompt file | Lens |
|---|---|
| `code-reviewer.md` | Bugs + CLAUDE.md compliance (confidence-scored; only the strong findings) |
| `silent-failure-hunter.md` | Swallowed errors, bad fallbacks, missing logging |
| `pr-test-analyzer.md` | Behavioral test-coverage gaps |
| `type-design-analyzer.md` | Type encapsulation / invariants |
| `comment-analyzer.md` | Comment rot / doc accuracy |
| `code-simplifier.md` | Clarity / simplification (lowest priority) |

Skip any lens with no surface on this PR (e.g. type-design or tests on a docs-only change); say which you skipped. On the degraded inline path, or for any lens whose file is missing, review the diff yourself against that lens in one pass.

**Then apply a seventh lens yourself, always: the design / blast-radius lens.** The six toolkit lenses are tuned for code-level defects (bugs, tests, types, comments, swallowed errors, clarity); none of them owns the question a human reviewer cares about most: *who and what else does this change affect?* An agent PR can be flawless line-by-line and still be wrong at the design level. Ask, against the actual diff:
- **Scope / blast radius.** Does this change a shared or checked-in config (a repo-root `.claude/settings.json`, a CI file, a shared env) that other people, agents, or repos inherit? Could it block, break, or surprise an actor other than the author?
- **Hardcoded identifiers in shared surfaces.** A name, ID, path, or assignee hardcoded into something other actors run (a hook everyone inherits, a shared workflow). Correct for the author, wrong for everyone else.
- **Reversibility.** Is there a migration, a one-way data change, a delete, or a default flip that is hard to undo?
- **Right altitude.** Is this solving the stated problem at the right layer, or is it a narrow patch where a structural fix belongs (or vice versa)?

This is the lens where a careful human out-reviews a naive pass. Weight it accordingly.

## Step 4: Consolidate and verify

- Collect all findings; dedupe overlaps (the lenses overlap on error handling and bugs).
- For every **blocking or high-confidence** finding: verify it against the actual diff and repo before it goes in the comment. Read the real file, the sibling code, or the authoritative doc. Discard anything you cannot substantiate; downgrade anything that is a style nit.
- Cross-check the PR's own claims: does the code actually do what the body says? Mismatches are themselves findings.
- Bucket survivors into **Blockers** (must fix before merge), **Important** (should fix), **Nits / Suggestions**, and **Strengths**.
- Do not let a clean code-level review bury a design-level problem. A blast-radius or scope finding (Step 3's seventh lens) often outranks every line-level nit: surface it as a Blocker or Important item, not a footnote, even when the code itself is correct.

## Step 5: Quick chat summary

Give the user a tight verdict first: **good to deploy or not yet, and why in one line.** Then the bucketed findings, blockers first, each one sentence. This is the at-a-glance read before anything is posted.

## Step 6: Draft and post one comment

Draft a single review comment in this shape (model it on a strong manual review):

```
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

Then **show the user the drafted comment and confirm before posting** (posting is outward-facing on GitHub). On approval, write the approved comment to a temp file and post it:

```bash
cat > /tmp/review-agent-pr-comment.md <<'EOF'
<the approved comment body>
EOF
gh pr comment <N> --repo <owner/name> --body-file /tmp/review-agent-pr-comment.md
```

Return the comment URL. Restore the original branch (`git checkout -`) if you checked out the PR. Do not merge, push, or resolve anything.

## Notes

- If `gh pr checks` shows CI or cloud review green, say so but do not treat it as sufficient: green CI rarely exercises the behavior an agent PR most often gets wrong. Call that out in the verdict.
- Keep the comment focused on what matters. A pile of nits buries the blockers. The whole point is signal.
