# The QA posture contract (`QA_STATUS` / `EVIDENCE`)

QA is a first-class, recorded decision, not something review has to catch. A `qa:browser` run ends by STATING its posture in a fixed format. That one posture feeds two enforcement points with DIFFERENT match rules. Satisfy both.

The postures are **two-phase**, matching `~/dev/BUILD-PROCEDURE.md`: Development QA is verified in a dev / preview environment before the PR merges; Production QA is verified live after deploy. The legacy flat `verified` stays valid as an alias for `dev_verified`. The two-phase QA plan itself (Development + Production checklists) is authored into the PR body by `/qa:plan`; the posture line below states which phase you verified.

## The postures

```
QA_STATUS: dev_verified
EVIDENCE: <command run / URL hit / screenshot path / test name proving you exercised the Development QA Plan live in dev / preview>
# `verified` is accepted as an alias for dev_verified.

QA_STATUS: prod_verified
EVIDENCE: <live check proving the Production QA Plan passed after deploy (build-procedure step 11)>

QA_STATUS: blocked
REASON: <what prevents QA right now>

QA_STATUS: skip_requested
REASON: <why QA is not feasible>          # then ask the human, escalate to skip_approved

QA_STATUS: skip_approved
QA_SKIP_APPROVED_BY: <github-handle> <YYYY-MM-DD> <why QA is not feasible / not needed>
```

## Gate 1: the build-time Stop hook (lenient)

`~/dev/claude-hooks/scripts/qa-status-gate.sh` is a Claude Code Stop hook. When your final assistant message claims coding work is done (`done`, `shipped`, `ready to merge`, ...) on a branch with shippable changes, it blocks the stop unless the message carries a `QA_STATUS:` line.

- The match is lenient: ANY line containing `QA_STATUS:` (case-insensitive) anywhere in the final message satisfies it. It strips code fences and is negation-aware, and it fails OPEN on any doubt.
- So: just end your final message with the posture line. That is all the Stop hook needs.

## Gate 2: the PR qa-gate CI (strict)

The per-repo `.github/workflows/qa-gate.yml` (e.g. hesco) re-checks the same posture in the PR BODY, as the audit trail that survives a forgotten hook. Its match is strict:

- The posture must be on its OWN line: `QA_STATUS: verified` (or `blocked` or `skip_approved`) as a SINGLE keyword, with NO `<` or `|` on the line, and not inside an HTML comment or code fence.
- The unedited template menu line `QA_STATUS: <verified | blocked | skip_approved>` is REJECTED.
- Alternatively a `QA_SKIP_APPROVED_BY: <handle>` line passes.

So the QA block you hand the user for the PR body must be CI-clean: a real single-keyword line, not the menu, not fenced, not commented.

## The asymmetry that bites: `skip_requested`

| Posture | Stop hook | CI qa-gate |
|---|---|---|
| `dev_verified` + `EVIDENCE` (alias: `verified`) | passes | passes |
| `prod_verified` + `EVIDENCE` | passes | n/a (post-deploy, not a pre-merge gate) |
| `blocked` + `REASON` | passes | passes |
| `skip_requested` + `REASON` | passes (stated) | **fails** (not an accepted keyword) |
| `skip_approved` + `QA_SKIP_APPROVED_BY` | passes | passes |

`skip_requested` is a valid stated posture for the Stop hook but the CI gate does NOT accept it. If QA is genuinely infeasible, you must escalate: state `skip_requested` + `REASON`, ask the human "ok to skip QA for <reason>", and on approval record `skip_approved` + `QA_SKIP_APPROVED_BY: <handle> <date> <reason>` in the PR body. Emitting `skip_requested` alone passes the hook but leaves the PR red.

## Honesty (non-negotiable)

The Stop hook only checks for the STRING `QA_STATUS:`; it never verifies your evidence. That makes honesty your job. Emit `QA_STATUS: verified` ONLY when you actually drove the real UI and observed the outcome. Never from a dry run, a code read, or an endpoint-only check. If you got partway, emit `blocked` with what you reached. A fabricated `verified` defeats the entire point of the gate.

## What good evidence looks like

Cite real, checkable artifacts, mirroring the report's scenario table:

```
QA_STATUS: verified
EVIDENCE: drove /suggest-intros/ live via abrowser for all 3 scenarios + the 🔍 company-blanked probe; observed 302 -> /preview/ (scenario 1) and 302 -> /complete/ (probe) via location.pathname; screenshots in ~/.gstack/projects/<slug>/qa-quincey/reports/; 72 targeted tests green.
```
