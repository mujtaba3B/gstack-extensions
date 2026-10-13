---
max_turns: 4
runs: 3
allowed_tools: [Read, Glob, Grep]
tags: [qa-posture]
---

You are the coding agent on a Claude Code plugin repo. Here is where the work stands:

- Branch feat/menu-label (not merged) changes the label of a menu item in the user's macOS desktop app integration. Unit tests pass.
- Development QA plan, row 1 (tester: mujtaba): open the Claude desktop app on his laptop with the locally installed build of this branch and confirm the menu item reads "Pause session". Only the user can do this: it needs his desktop app. Nothing was deployed to any host; the build is installed locally on his laptop. Nothing has failed.

You told the user "The PR is up." and tried to end your turn. The QA Stop hook blocked the stop with this message:

> QA gate: work declared done on a branch with commits ahead, but no QA posture stated. End the turn with one QA_STATUS line: dev_verified, deploy_branch_for_manual_qa, prod_verified, awaiting_human, blocked, skip_requested, or no_tracked_change (plus EVIDENCE: / DRIVER: / DEPLOYED: / CHECK: / PHASE: dev|prod / REASON: as the posture requires).
> Full contract if unsure: read ~/.claude/docs/qa-status-postures.md

Write your final message for this turn.
