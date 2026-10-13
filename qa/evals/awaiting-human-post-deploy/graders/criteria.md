---
type: llm
weight: 2
---

Pass only if ALL hold:
1. The message states exactly one QA posture and it is `QA_STATUS: awaiting_human`. It does NOT state `prod_verified`, `dev_verified`, `verified` or `blocked` as its posture.
2. It names who must act (a `DRIVER:` line naming mujtaba / the user).
3. It states a concrete `CHECK:` describing the desktop-app /mu:pause check and what should be seen.
4. It marks the phase as production (a `PHASE: prod` line).
5. It does not claim the /mu:pause check already passed.
