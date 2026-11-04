# The QA posture contract (`QA_STATUS` / `EVIDENCE`)

QA is a first-class, recorded decision, not something review has to catch. A `qa:browser` run ends by STATING its posture in a fixed format. The PR qa-gate CI reads that posture with a strict match, so write it in the form below.

The postures are **two-phase**: Development QA is verified in a dev / preview environment before the PR merges; Production QA is verified live after deploy. The legacy flat `verified` stays valid as an alias for `dev_verified`; in the PR body, write the plain `QA_STATUS: verified` spelling, which is the only one the CI qa-gate accepts. The two-phase QA plan itself (Development + Production checklists) is authored into the PR body by `/qa:plan`; the posture line below states which phase you verified.

## The postures

```
QA_STATUS: dev_verified
EVIDENCE: <command run / URL hit / screenshot path / test name proving you exercised the Development QA Plan live in dev / preview>
# `verified` is the same posture; use that plain spelling in the PR body (CI rejects dev_verified).

QA_STATUS: prod_verified
EVIDENCE: <live check proving the Production QA Plan passed after deploy (build-procedure step 11)>

QA_STATUS: awaiting_human
DRIVER: <roster id, usually mujtaba>
CHECK: <the exact thing the human must do, and what they should see>
PHASE: <dev or prod>      # only a human can do the last check; nothing failed
EVIDENCE: <the rows you ran; unless PHASE is plainly dev, cite the exact production artifact>

QA_STATUS: blocked
REASON: <what prevents QA right now>

QA_STATUS: skip_requested
REASON: <why QA is not feasible>          # then ask the human, escalate to skip_approved

QA_STATUS: skip_approved
QA_SKIP_APPROVED_BY: <github-handle> <YYYY-MM-DD> <why QA is not feasible / not needed>
```

## The PR qa-gate CI (strict)

No hook checks your final message; end it with the posture line anyway, because that is the record of what you did. The per-repo `.github/workflows/qa-gate.yml` (e.g. hesco) checks the posture in the PR BODY. Its match is strict:

- The posture must be on its OWN line: `QA_STATUS: verified` (or `blocked` or `skip_approved`) as a SINGLE keyword, with NO `<` or `|` on the line, and not inside an HTML comment or code fence.
- The unedited template menu line `QA_STATUS: <verified | blocked | skip_approved>` is REJECTED.
- Alternatively a `QA_SKIP_APPROVED_BY: <handle>` line passes.

So the QA block you hand the user for the PR body must be CI-clean: a real single-keyword line, not the menu, not fenced, not commented.

## The asymmetry that bites: intermediate postures

| Posture | CI qa-gate |
|---|---|
| `verified` + `EVIDENCE` | passes |
| `dev_verified` + `EVIDENCE` (same posture, longer spelling) | **fails** (the matcher takes only the plain `verified` keyword, so the PR body needs `QA_STATUS: verified`) |
| `deploy_branch_for_manual_qa` + `DRIVER` + `DEPLOYED` | **fails** (not an accepted keyword) |
| `prod_verified` + `EVIDENCE` | n/a (post-deploy, not a pre-merge gate) |
| `awaiting_human` + `DRIVER` + `CHECK` + `PHASE` | **fails** for `PHASE: dev` (a pending human check never greens a merge); n/a for `PHASE: prod` (post-deploy) |
| `blocked` + `REASON` | passes |
| `skip_requested` + `REASON` | **fails** (not an accepted keyword) |
| `skip_approved` + `QA_SKIP_APPROVED_BY` | passes |
| `no_tracked_change` | n/a (no tracked change to merge) |

This table is a summary; the full contract for every posture is `docs/qa-status-postures.md` at the qa plugin's root.

`skip_requested` is a valid stated posture but the CI gate does NOT accept it. If QA is genuinely infeasible, you must escalate: state `skip_requested` + `REASON`, ask the human "ok to skip QA for <reason>", and on approval record `skip_approved` + `QA_SKIP_APPROVED_BY: <handle> <date> <reason>` in the PR body. Emitting `skip_requested` alone leaves the PR red.

`awaiting_human` with `PHASE: dev` behaves the same way on purpose: it ends the turn honestly while the human's check is pending. Leave that check's Dev QA box unchecked until they report back: that box, not CI, is what blocks the merge. Run every check you can before handing off; `CHECK:` names only what no agent can do. Unless the handoff is plainly `PHASE: dev` (a missing, malformed or mixed `PHASE:` counts as prod), your handoff must cite the plan's exact production artifact outside any code fence (an `EVIDENCE:` line is the place for it), and one naming only a base / proxy artifact does not meet the bar, and while awaiting you write "I'll mark it verified once you confirm", never the literal `QA_STATUS: prod_verified` line.

## Honesty (non-negotiable)

Nothing verifies your evidence. That makes honesty your job. Emit `QA_STATUS: verified` ONLY when you actually drove the real UI and observed the outcome. Never from a dry run, a code read, or an endpoint-only check. If you got partway, emit `blocked` with what you reached. A fabricated `verified` defeats the entire point of the gate.

## What good evidence looks like

Cite real, checkable artifacts, mirroring the report's scenario table:

```
QA_STATUS: verified
EVIDENCE: drove /suggest-intros/ live via abrowser for all 3 scenarios + the 🔍 company-blanked probe; observed 302 -> /preview/ (scenario 1) and 302 -> /complete/ (probe) via location.pathname; screenshots in ~/.gstack/projects/<slug>/qa-quincey/reports/; 72 targeted tests green.
```
