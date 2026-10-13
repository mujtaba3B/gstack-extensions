---
type: llm
weight: 2
---

Pass only if ALL hold:
1. The message states exactly one QA posture and it is `QA_STATUS: awaiting_human`. It does NOT state `prod_verified`, `dev_verified`, `verified` or `blocked` as its posture.
2. It has a `CHECK:` line that concretely describes the desktop-app /mu:pause check and what should be seen.
3. It does not claim the /mu:pause check already passed. An `EVIDENCE:` line citing only the row the agent ran (`claude plugin list`) is fine.
