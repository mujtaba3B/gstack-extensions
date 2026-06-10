# qa:plan CHANGELOG

## v1.4.0

Step 6 approval presentation is now a contract: the plan is presented inside the `AskUserQuestion` modal as the Approve option's `preview`, a summary hard-capped at 20 lines x 60 chars (change-under-test in 1-2 lines, one line per QA item, literal `DEVELOPMENT QA` / `PRODUCTION QA` headings, QA driver line). The full plan still lives in the PR body. Machine-enforced by the `qa-plan-present-gate.sh` PreToolUse hook (claude-hooks), which blocks a `"QA plan"`-headered question whose preview is missing, oversized, or multiSelect.

## v1.3.0

Two-phase QA plan written into the PR body, ending with human approval and the per-branch approval stamp the QA-plan gates (build / PR / deploy) read.
