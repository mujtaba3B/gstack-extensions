# gstack patch: wire `/land-and-deploy` into the merge-clearance gate

`land-and-deploy` lives in the upstream `garrytan/gstack` clone at
`~/.claude/skills/gstack/land-and-deploy/SKILL.md`, so `/gstack-upgrade` (or any
`git pull` there) can clobber the two small insertions below. This file is the
re-appliable record. After an upgrade, if `merge-clearance` calls are gone from
that SKILL.md, re-apply both hunks.

The heavy logic lives in this repo (`scripts/merge-clearance.sh`,
`scripts/merge-clearance-lib.sh`, `scripts/pr-merge-gate.sh`), so these SKILL.md
edits are intentionally tiny - only the two call sites change.

Verify whether the patch is present:

```bash
grep -c 'merge-clearance.sh' ~/.claude/skills/gstack/land-and-deploy/SKILL.md   # expect 4
```

## Hunk 1 - read-only check inside the readiness gate (Step 3.5)

Anchor: the line `### 3.5e: Readiness report and confirmation`, preceded by
`If only docs changed (no code): skip this check.`. Insert a new sub-step
`### 3.5d-bis` immediately before `### 3.5e`:

````markdown
### 3.5d-bis: Merge-clearance machine check (CodeRabbit + CI + review + QA)

If `~/.claude/scripts/merge-clearance.sh` exists AND this repo carries a
`.merge-clearance.json` marker at its root, run the clearance checker. It is the
same objective gauntlet the local merge gate and the GitHub `local-review/merge-clearance`
required check enforce. This call is READ-ONLY - it does not write the stamp yet.

```bash
test -f ~/.claude/scripts/merge-clearance.sh && test -f "$(git rev-parse --show-toplevel)/.merge-clearance.json" \
  && ~/.claude/scripts/merge-clearance.sh check 2>&1 || echo "merge-clearance gate not active for this repo (skipping)"
```

Include its rendered checklist verbatim in the readiness report below. A **NOT
CLEAR** verdict for CodeRabbit (unresolved threads / changes requested / still
reviewing) or CI (not green) is a HARD BLOCKER: do not merge until it clears,
regardless of the user's confidence. (If the gate is not active for this repo,
skip this and rely on the existing readiness checks.)
````

## Hunk 2 - write the clearance immediately before the merge (Step 4)

Anchor: in `## Step 4: Merge the PR`, between the paragraph
`Record the start timestamp ... for the deploy report.` and
`Try auto-merge first (respects repo merge settings and merge queues):`. Insert a
new sub-step `### 4-pre` there:

````markdown
### 4-pre: Write the merge clearance (stamp + required GitHub check)

If the merge-clearance gate is active for this repo (the `.merge-clearance.json`
marker exists and `~/.claude/scripts/merge-clearance.sh` is present), this is the
sanctioned act that authorizes the merge. It writes the local clearance stamp AND
posts the required `local-review/merge-clearance` GitHub status. Run it as LATE as
possible (right here, immediately before merging) so the clearance-to-merge
window stays small (CodeRabbit can post a new comment after we clear without HEAD
changing).

```bash
if test -f ~/.claude/scripts/merge-clearance.sh && test -f "$(git rev-parse --show-toplevel)/.merge-clearance.json"; then
  ~/.claude/scripts/merge-clearance.sh clear 2>&1
fi
```

If it exits non-zero, it is REFUSING to clear (CodeRabbit unresolved, CI not
green, /review stale, or QA boxes unchecked). **STOP.** Show the checklist, fix
the blocker, and re-run /land-and-deploy. Do NOT attempt `gh pr merge` - the local
gate and the GitHub required check will both reject it anyway. Only when
`merge-clearance clear` succeeds (or the gate is not active for this repo) continue
to the merge below.
````
