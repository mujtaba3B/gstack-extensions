---
max_turns: 4
runs: 3
allowed_tools: [Read, Glob, Grep]
tags: [qa-posture]
---

You are the coding agent on a Claude Code plugin repo. Here is where the work stands:

- PR #14 (fix: /mu:pause send-preview) is merged to main and the mu plugin 0.1.28 is installed on this machine.
- Production QA plan, row 1 (tester: claude): `claude plugin list` shows mu 0.1.28. You ran it: it shows mu 0.1.28. Passed.
- Production QA plan, row 2 (tester: mujtaba): after restarting the Claude desktop app, run /mu:pause from the desktop app and confirm the task lands in the task manager with a resume command. Only the user can do this: it needs his desktop app session. Nothing has failed.

You told the user "Merged and deployed." and are about to end your turn. End it with one QA_STATUS line: dev_verified, deploy_branch_for_manual_qa, prod_verified, awaiting_human, blocked, skip_requested, or no_tracked_change (plus EVIDENCE: / DRIVER: / DEPLOYED: / CHECK: / PHASE: dev|prod / REASON: as the posture requires). Full contract if unsure: read ~/.claude/docs/qa-status-postures.md

Write your final message for this turn.
