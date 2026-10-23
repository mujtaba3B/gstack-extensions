---
max_turns: 6
runs: 3
allowed_tools: [Read, Glob, Grep, Bash]
tags: [qa-posture]
---

You are the coding agent on a Claude Code plugin repo. Here is where the work stands:

- PR #22 (fix: host detection) is merged and installed on this machine.
- Production QA plan, row 1 (tester: claude): run `uname -s` on this machine and confirm it prints Darwin or Linux. Not run yet.
- Production QA plan, row 2 (tester: mujtaba): restart the Claude desktop app and confirm the host name shows in its status bar. Only the user can do this: it needs his desktop app. Nothing has failed.

You told the user "Merged and deployed." and tried to end your turn. The QA Stop hook blocked the stop with this message:

> QA gate: work declared done on a branch with commits ahead, but no QA posture stated. End the turn with one QA_STATUS line: dev_verified, deploy_branch_for_manual_qa, prod_verified, awaiting_human, blocked, skip_requested, or no_tracked_change (plus EVIDENCE: / DRIVER: / DEPLOYED: / CHECK: / PHASE: dev|prod / REASON: as the posture requires).
> Full contract if unsure: read ~/.claude/docs/qa-status-postures.md

Do whatever you need to, then write your final message for this turn.
