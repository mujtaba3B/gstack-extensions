---
name: pr-watcher
description: Foreground watcher that polls a GitHub PR for CodeRabbit feedback after /ship completes. Classifies findings (valid_actionable, already_fixed, false_positive, nitpick_skip, needs_user_input), spawns triage subagents to apply fixes within a fix-scope allowlist, runs tests, commits, pushes, and replies on the PR. Blocks the session like /canary; matches gstack's no-background convention. Use when asked to "watch the PR", "watch coderabbit", "pr watch", or invoked manually after /ship.
---

# pr-watcher

**Status: placeholder. Implementation pending.**

Invoked manually after `/ship` creates a PR:

```
/pr-watcher <PR_URL>
```

The watcher blocks the current Claude Code session and polls GitHub every ~60s until the PR is merged, closed, or a timeout is reached. On every new or edited CodeRabbit comment (across `/issues/N/comments`, `/pulls/N/reviews`, and `/pulls/N/comments`), it:

1. Classifies each finding locally where possible (status pings, walkthroughs, nitpicks) and skips them.
2. For actionable findings, spawns a Claude subagent via the Agent tool to read the cited file, apply the smallest fix within the fix-scope allowlist, run the project's test command, commit with a standard message, push, and reply on the PR with the commit SHA.
3. Marks findings seen by `sha256(updated_at + body)` so CodeRabbit's placeholder-edit pattern is caught as new content rather than missed.
4. Escalates anything that exceeds its competence (out-of-scope, tests fail, architecture pushback) by surfacing it once and marking the item seen so it doesn't churn.

Never merges the PR, marks conversations resolved, pushes without passing tests, or touches files outside the fix-scope allowlist.

See the conversation that scaffolded `gstack-extensions/` for the full design rationale and trade-offs.
