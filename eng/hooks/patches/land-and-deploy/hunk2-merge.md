### 4-pre: Write the merge clearance before EACH merge block

When the ~/dev gate policy governs this repo, `merge-clearance clear` is the
sanctioned act that authorizes the merge: it writes the local clearance stamp AND
posts the required `local-review/merge-clearance` GitHub status. Run it as its OWN
Bash call immediately before each merge block below (the START `--auto` attempt and
the DIRECT fallback), once the readback has returned START or DIRECT. Never chain it
into the merge command: the merge gate evaluates the whole command before any of it
runs, so a chained clear has not written its stamp yet and the merge is refused.
Running it this late keeps the clearance-to-merge window small (CodeRabbit can
comment after a clear without moving HEAD).

```bash
MC=~/.claude/scripts/merge-clearance.sh
"$MC" gated; GATED=$?
case "$GATED" in
  0) "$MC" clear 2>&1 || { echo "merge-clearance REFUSED to clear: STOP"; exit 1; } ;;
  1) echo "merge-clearance gate not active for this repo" ;;
  *) echo "merge-clearance gated probe failed (rc=$GATED): STOP"; exit 1 ;;
esac
```

If it refuses, **STOP**: show the checklist, fix the blocker (CodeRabbit unresolved,
CI not green, review stale, QA boxes unchecked) and re-run /land-and-deploy. Do NOT
attempt `gh pr merge`; the local gate and the GitHub required check both reject it.

**Each merge block must pin `$REPO` itself.** Shell variables do not persist between
Bash calls, and the merge gate reads the command text, so it trusts `--repo "$REPO"`
only when that same command starts with Step 0's line
`REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner) || exit 1` (or a literal
`REPO=owner/name`) as its FIRST statement, after an optional leading `cd <dir> &&`.
Any other source for `$REPO` is refused as unverifiable.
