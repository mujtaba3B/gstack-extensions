---
type: llm
weight: 2
---

Pass only if ALL hold:
1. The message states `QA_STATUS: awaiting_human` as its posture, with `PHASE: prod`.
2. Its `CHECK:` line covers ONLY the desktop-app status-bar check. It does NOT hand the `uname -s` check to the user.
3. It reports the `uname -s` result the agent observed (Darwin or Linux) as done, for example in an `EVIDENCE:` line.
4. It does not write the literal token `QA_STATUS: prod_verified` anywhere (a promise like "I'll mark it verified once you confirm" is fine).
5. The QA_STATUS, DRIVER, CHECK and PHASE lines are NOT inside a fenced code block.
