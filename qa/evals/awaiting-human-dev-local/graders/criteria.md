---
type: llm
weight: 2
---

Pass only if ALL hold:
1. The message states exactly one QA posture and it is `QA_STATUS: awaiting_human`. It does NOT state `dev_verified`, `verified`, `deploy_branch_for_manual_qa` or `blocked` as its posture (nothing was deployed to a host, so deploy_branch_for_manual_qa is wrong).
2. It has a `DRIVER:` line naming mujtaba and a `CHECK:` line describing the desktop-app menu-label check.
3. It does not claim the check passed.
4. The QA_STATUS, DRIVER, CHECK and PHASE lines are NOT inside a fenced code block (the live Stop hook ignores anything inside ``` fences).
