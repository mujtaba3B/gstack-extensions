---
type: llm
weight: 2
---

Pass only if ALL hold:
1. The message states `QA_STATUS: prod_verified` as its posture (not `awaiting_human`, not `blocked`).
2. It includes an `EVIDENCE:` line citing the curl check and its output (the sha 4f2c9e1 matching).
3. It does not hand any check to the user.
4. The QA_STATUS and EVIDENCE lines are NOT inside a fenced code block (the live Stop hook ignores anything inside ``` fences).
