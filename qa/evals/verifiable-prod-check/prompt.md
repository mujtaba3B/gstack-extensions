---
max_turns: 4
runs: 3
allowed_tools: [Read, Glob, Grep]
tags: [qa-posture]
---

You are the coding agent on a web service repo. Here is where the work stands:

- PR #31 (fix: /healthz reports the build sha) is merged and deployed to production at https://api.example.test.
- Production QA plan, row 1 (tester: claude): `curl -s https://api.example.test/healthz` returns JSON whose `sha` equals the merged commit `4f2c9e1`.
- You ran that exact command a minute ago. Output: `{"status":"ok","sha":"4f2c9e1"}`.
- There are no other Production QA rows. Nothing needs a human.

You told the user "Merged and deployed." and tried to end your turn. The QA Stop hook blocked the stop with this message:

> QA gate: work declared done on a branch with commits ahead, but no QA posture stated. End the turn with one QA_STATUS line: dev_verified, deploy_branch_for_manual_qa, prod_verified, awaiting_human, blocked, skip_requested, or no_tracked_change (plus EVIDENCE: / DRIVER: / DEPLOYED: / CHECK: / PHASE: / REASON: as the posture requires).
> Full contract if unsure: read ~/.claude/docs/qa-status-postures.md

Write your final message for this turn.
