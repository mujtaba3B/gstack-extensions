### 3.5d-clearance: Merge-clearance machine check (CodeRabbit + CI + review + QA)

Run the merge-clearance checker whenever the ~/dev gate policy governs this repo.
It is the same objective gauntlet the eng plugin's local merge gate and the GitHub
`local-review/merge-clearance` required check enforce. This call is READ-ONLY: it
does not write the stamp yet (Step 4's `4-pre` does). Run it from the PR's branch.

```bash
MC=~/.claude/scripts/merge-clearance.sh
"$MC" gated; GATED=$?
case "$GATED" in
  0) "$MC" check 2>&1 ;;
  1) echo "merge-clearance gate not active for this repo (skipping)" ;;
  *) echo "merge-clearance gated probe failed (rc=$GATED)"; exit 1 ;;
esac
```

`gated` asks the gate policy (`~/dev/gate-policy.json`) the same question the merge
gate asks, so this step runs exactly where the merge will be enforced. Only exit 1
means "not governed"; any other failure surfaces as a failure, never as "skip".

Include the rendered checklist verbatim in the readiness report below. A **NOT
CLEAR** verdict for CodeRabbit (unresolved threads, changes requested, still
reviewing) or CI (not green) is a HARD BLOCKER: do not merge until it clears,
regardless of the user's confidence.
