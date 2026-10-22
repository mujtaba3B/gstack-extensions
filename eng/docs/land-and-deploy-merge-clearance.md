# gstack patch: wire `/land-and-deploy` into the merge-clearance gate

`land-and-deploy` lives in the upstream `garrytan/gstack` clone at
`~/.claude/skills/gstack/land-and-deploy/` (since mid-2026 a `SKILL.md` skeleton
plus generated `sections/*.md`), so `/gstack-upgrade` rewrites it and drops the two
small insertions that make it call merge-clearance. That has happened at least
twice; the last time (found 2026-10-22 landing mujtaba3B/claude-mods#1) the
required `local-review/merge-clearance` status was never posted and the merge had
to be cleared by hand.

**The patch is now applied by code, not by hand.**
`eng/hooks/scripts/land-and-deploy-patch.sh` inserts the two hunks as
marker-delimited blocks, and runs from two places:

- `bin/install` (`apply`), on every install or upgrade of this repo;
- an eng-plugin hook on every `/land-and-deploy` invocation (Skill PreToolUse and
  a prompt starting with `/land-and-deploy`), so a gstack upgrade between installs
  heals itself before the skill's sections are read. It never blocks; if an anchor
  moved upstream it tells the agent (additional context) to clear by hand for that
  run and to fix the anchor here.

The hunk TEXT lives in `eng/hooks/patches/land-and-deploy/` and is the source of
truth; edit it there and the next run refreshes every installed copy (each block
carries a checksum of its text). Never edit the installed skill by hand.

| Hunk | Text | Inserted before |
|------|------|-----------------|
| 1, `### 3.5d-clearance` (read-only `merge-clearance check`) | `hunk1-readiness.md` | the line `### 3.5e...` (readiness report), wherever it lives |
| 2, `### 4-pre` (`merge-clearance clear` before each merge block) | `hunk2-merge.md` | the first `### ` heading after `## Step 4...` |

(`3.5d-bis` is upstream's own sub-step now, hence `3.5d-clearance`.)

Both hunks key on `merge-clearance.sh gated`, which asks the gate policy the same
question `pr-merge-gate.sh` asks (exit 0 governed, 1 not, anything else is an
error and stops). The old `test -f .merge-clearance.json` guard is gone: per-repo
markers were dropped on 2026-09-02, so with it in place the calls never ran.

Verify:

```bash
~/dev/tooling/gstack-extensions/eng/hooks/scripts/land-and-deploy-patch.sh check
# hunk1: current (...readiness-gate.md)
# hunk2: current (...merge-and-deploy.md)     exit 0; 1 = missing/stale, 2 = anchor moved
```

## `--repo "$REPO"` and the merge gate

The skill's merge blocks pass `--repo "$REPO"`. `pr-merge-gate.sh` reads the
command TEXT, and shell variables do not persist between Bash calls, so it cannot
know what `$REPO` will expand to. It used to compare the literal text and refuse
the skill's own merge as "a different repo ($REPO)".

It now resolves the variable from the command itself
(`sg_merge_target_verdict` / `sg_resolve_repo_ref` in `ship-gate-repo-lib.sh`):
`$REPO` is trusted only when the same command assigns it as its FIRST statement
(after an optional leading `cd <dir> &&`), either to a literal `owner/name` or to
Step 0's `$(gh repo view --json nameWithOwner -q .nameWithOwner)`, which by
construction names the checkout's own repo. Anything else (unassigned, a temp-env
prefix, a conditional or piped assignment, a reassignment, another command
substitution) is **blocked as unverifiable**, never guessed. Hunk 2 tells the skill
to start each merge block with that line.

Why resolve in the hook rather than only change the documented call shape: the
call shape lives in upstream text that every upgrade rewrites, while the hook ships
with this repo. Teaching the hook the one shape the skill already uses fixes it
whatever the upstream wording, and the fail-safe default (block when unsure) keeps
the cross-repo guard exactly as strict as before.

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
the gate policy (`~/dev/gate-policy.json`) governs.

Crucially, the sentinel needs **no patch to the upstream skill**. It is minted by
an eng-plugin hook wired in `hooks/hooks.json`, so a `/gstack-upgrade` that clobbers
the two hunks below cannot remove it. The clobber's only effect stays the
same as before: `/land-and-deploy` would stop writing the clearance stamp (Hunk 2),
so the merge would block on the missing stamp until the hunks are re-applied. The
gate still fails open on its own errors (missing `jq`/`git`/`gh`); the sentinel is
target-bound (repo + HEAD sha + PR number when resolvable) and lives per-worktree
in `<gitdir>/land-deploy-clearance`. A generous default TTL (1800s, override via
`ld_sentinel_ttl_seconds` in the gate policy) covers long CI / merge-queue waits, which
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
