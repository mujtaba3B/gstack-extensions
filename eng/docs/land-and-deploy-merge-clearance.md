# gstack patch: wire `/land-and-deploy` into the merge-clearance gate

`land-and-deploy` lives in the upstream `garrytan/gstack` clone at
`~/.claude/skills/gstack/land-and-deploy/SKILL.md`, so `/gstack-upgrade` (or any
`git pull` there) can clobber the two small insertions below. This file is the
re-appliable record. After an upgrade, if `merge-clearance` calls are gone from
that SKILL.md, re-apply both hunks.

The heavy logic lives in the eng plugin (`eng/hooks/scripts/merge-clearance.sh`,
`eng/hooks/scripts/merge-clearance-lib.sh`, `eng/hooks/scripts/pr-merge-gate.sh`),
reached through the stable shim `~/.claude/scripts/merge-clearance.sh` that
`bin/install` writes, so these SKILL.md edits are intentionally tiny - only the
two call sites change.

Verify whether the patch is present:

```bash
grep -c 'merge-clearance.sh' ~/.claude/skills/gstack/land-and-deploy/SKILL.md   # expect 6
```

## The `/land-and-deploy` sentinel makes it the SINGLE merge path (no patch needed)

As of eng `v2.1.0`, the merge gate requires TWO things, not one: a valid
merge-clearance stamp AND a fresh, target-matched `/land-and-deploy` sentinel.

The stamp alone can be written by a bare `merge-clearance clear`, so the stamp by
itself never proved the merge came through `/land-and-deploy`. The sentinel closes
that gap: it is minted ONLY by invoking `/land-and-deploy` (the
`land-deploy-sentinel.sh` hook fires on the Skill invocation and on a prompt
starting with `/land-and-deploy`), and `pr-merge-gate.sh` now blocks a bare
`gh pr merge` unless that sentinel is present, fresh, and bound to this PR's HEAD.
A manual `merge-clearance clear` followed by `gh pr merge` no longer merges: it has
the stamp but not the sentinel. This is **default-on fleet-wide** in every repo
carrying a `.merge-clearance.json` marker.

Crucially, the sentinel needs **no patch to the upstream skill**. It is minted by
an eng-plugin hook wired in `hooks/hooks.json`, so a `/gstack-upgrade` that clobbers
the two SKILL.md hunks above cannot remove it. The clobber's only effect stays the
same as before: `/land-and-deploy` would stop writing the clearance stamp (Hunk 2),
so the merge would block on the missing stamp until the hunks are re-applied. The
gate still fails open on its own errors (missing `jq`/`git`/`gh`); the sentinel is
target-bound (repo + HEAD sha + PR number when resolvable) and lives per-worktree
in `<gitdir>/land-deploy-clearance`. A generous default TTL (1800s, override via
`ld_sentinel_ttl_seconds` in the marker) covers long CI / merge-queue waits, which
is safe because the binding is to a specific commit, not just freshness.

### Threat model and limitations (read before trusting it)

This is an **accident-guard**, not an adversary-proof sandbox, the same posture
`pr-merge-gate.sh` already states for the stamp. Two things defeat the local hook
by construction, and both are accepted because the GitHub required status check is
the real authority:

- A direct write to `<gitdir>/land-deploy-clearance` (the `.git` dir is writable)
  forges a sentinel. So does the stamp file.
- The sentinel is minted on the `/land-and-deploy` **Skill invocation** (before the
  skill body runs), so invoking the skill and aborting it instantly still mints a
  sentinel for the current HEAD.

Both require deliberately invoking `/land-and-deploy` or hand-writing a `.git` file,
neither of which is the "agent took a lazy shortcut" path this guards against. The
hard backstop for an actual bypass is the GitHub `local-review/merge-clearance`
required check, which binds the web Merge button and `--admin` too.

**Run `/land-and-deploy` from the PR's branch.** The sentinel records the local
`git rev-parse HEAD` at invocation; the gate matches it against the PR's remote
`headRefOid`. On the PR branch (pushed, no unpushed local commits) these are equal.
Invoking `/land-and-deploy #N` from a *different* branch records that branch's HEAD,
which will not match PR #N's head, so the gate false-blocks (safe direction: it
never lets a wrong merge through, it just makes you re-run from the PR branch). This
is also why the binding is a strict equality, not an ancestor check: an
ancestor-match would let a sentinel minted on an old commit authorize merging a
newer pushed commit, which is exactly the stale-sentinel hole the HEAD binding closes.

### Ceiling

A local hook can only gate the CLI `gh pr merge`. The GitHub web Merge
button stays gated by the `local-review/merge-clearance` required status check
(clearance), which GitHub cannot tie to `/land-and-deploy` provenance. So the
sentinel makes `/land-and-deploy` the only CLI merge path; the web button remains
clearance-gated.

Verify the sentinel wiring is installed:

```bash
jq -r '.hooks.PreToolUse[].hooks[].command' \
  ~/.claude/plugins/cache/gstack-extensions/eng/*/hooks/hooks.json | grep -c land-deploy-sentinel
# expect >= 1
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
if test -f ~/.claude/scripts/merge-clearance.sh && test -f "$(git rev-parse --show-toplevel)/.merge-clearance.json"; then
  ~/.claude/scripts/merge-clearance.sh check 2>&1
else
  echo "merge-clearance gate not active for this repo (skipping)"
fi
```

(The `if` form matters: only the two `test -f` probes may downgrade to
"not active". A failing `check` run, including a shim that cannot resolve an
installed eng plugin copy, must surface as a failure, never be relabeled
"not active".)

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
