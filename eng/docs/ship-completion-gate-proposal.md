# Proposal: detect a silent partial `/ship`

**Status:** proposal, awaiting enforcement-strength decision
**Owner:** Engineer Ernie (eng plugin, ship-gate)
**Motivating failure:** mutwo PR #189
**Impl home:** `gstack-extensions/eng/hooks/scripts/` (the gate source; the plugin cache and `/ship` itself are both clobbered on upgrade, so durable logic cannot live there)

## The problem

The ship-PR gate proves `/ship` was **invoked**, not that it **completed**.

Invoking `/ship` fires a `PreToolUse:Skill` hook that arms a short-TTL freshness
sentinel (`<gitdir>/ship-pr-clearance`, default 1200s). That sentinel is the only
thing `ship-pr-gate.sh` checks before letting a `gh pr create` through. So an agent
can invoke `/ship`, arm the sentinel, then **hand-drive the individual steps** (or
skip them), and the create still passes.

That is exactly what happened on mutwo PR #189: `/ship` was invoked, then the agent
manually did the base-merge, version bump, CHANGELOG edit, a plain `git push`, and
`gh pr create`, reviewing with `/eng:cr` instead of `/ship`'s review-army. It
skipped `/ship` Steps 7 (coverage), 8 (plan-completion), 11 (adversarial), 14
(TODOS), 20 (metrics). The PR landed, CI passed, and nothing recorded that the
checklist never ran.

The goal is **"no SILENT partial ship"**, not "ship can never be adapted". Some
skips are legitimate and must stay legitimate:

- **Tests / coverage** are delegated to CI on this machine (a hard `~/.claude/CLAUDE.md`
  rule: the machine cannot run full suites locally). The mechanism must not force
  local test runs. CI is enforced later, at merge, by `merge-clearance`.
- **`/eng:cr` is the mandated local reviewer on mutwo** (it mints the merge-clearance
  stamp). "Used `/eng:cr` instead of review-army" is *correct* here and must read as
  satisfied, not as a skipped step.

## Why full enforcement is impossible (and what that implies)

Sort `/ship`'s steps by how observable their completion is at `gh pr create` time
(create is `/ship` Step 19, its last substantive step: `sections/pr-body.md:187`):

| Class | Steps | Observable at create? |
|---|---|---|
| **Footprint** | base-merge (3), review (9 / `/eng:cr`), version bump (12), CHANGELOG (13) | **Yes** — they leave a durable trace in the repo/gitdir |
| **Policy-delegated** | tests (4-6), coverage (7) | No, and correctly so — delegated to CI; `merge-clearance` gates CI at merge |
| **No-footprint** | plan-completion (8), adversarial (11), TODOS (14), metrics (20) | **No** — they leave no durable trace |

Three consequences:

1. We **can** detect the gross partial ship: review skipped, CHANGELOG missing,
   version not bumped, base not reconciled. High value, footprint-checkable.
2. We **cannot** hard-enforce the no-footprint quality steps. Only `/ship` actually
   executing them proves they ran, and `/ship` is upgrade-clobbered (so it cannot be
   reliably instrumented) and a hand-driving agent bypasses it entirely (so it would
   never self-report). The honest best is to **record their absence-of-evidence into
   a ledger** so a partial ship is never *silent* — it becomes greppable and surfaced.
3. The review dimension keys on `<gitdir>/review-skill-head`, which **`/eng:cr`
   writes**. So the load-bearing nuance is handled for free: an `/eng:cr` review reads
   as SATISFIED, exactly as intended.

## Rejected alternatives

- **Completion stamp required *before* create (Direction 1, literal).** Create is the
  last real step, so there is nothing to require before it. Reframed, the *evidence
  snapshot at create* IS the completion check. Folded into the recommendation.
- **Instrument `/ship` to write a per-step ledger.** `/ship` is regenerated from a
  template on `gstack-upgrade` (hand-edits are lost), and a hand-driving agent never
  runs `/ship`'s body anyway. Dead end.
- **Pin the review stamp to HEAD.** Every real `/ship` reviews, *then* bumps the
  version in a commit that moves HEAD, so a HEAD-pinned review check false-blocks the
  create. `ship-pr-gate-lib.sh:29-32` already documents this as why the sentinel binds
  on freshness, not HEAD. Use a branch-ancestor check instead (below), following the
  qa-plan precedent that "an approved plan stays approved as the branch's commits
  accumulate" (`qa-plan-gate-lib.sh:33-37`).
- **Force local test runs.** Violates the machine rule. Tests stay CI-delegated.

## Recommended mechanism: ship-run ledger + completion-evidence at create

Layer onto the existing gate (do not replace it). Two additions, both mirroring
patterns already in the codebase (merge-clearance's multi-dimension stamp,
qa-plan's branch-keyed validity).

### 1. Ledger init on arm

`ship-gate-sentinel.sh`, when it arms a `/ship` run (Skill:ship or `/ship` prompt),
also writes `<gitdir>/ship-run.json` atomically:

```json
{ "run_started_epoch": 1719800000, "branch": "fix/...", "head_at_start": "<sha>",
  "session": "<id>", "trigger": "skill" }
```

Records "a `/ship` run began on this branch, from this commit, at this time."

### 2. Evidence snapshot at `gh pr create`

`ship-pr-gate.sh`, at the create it already intercepts, computes the branch's
**non-skippable footprint set** and records it into `ship-run.json`
(`create_evidence` block) and the existing audit log (`~/.claude/ship-pr-gate.log`).

Dimensions are **branch-keyed, not HEAD-pinned** (survives the post-review version
bump):

| Dimension | Satisfied when |
|---|---|
| `review` | `review-skill-head` SHA is an ancestor of the branch tip (a review of a commit on this branch happened — `/eng:cr` or `/review` wrote it) |
| `changelog` | `git diff --name-only <base>...HEAD` includes `CHANGELOG.md` |
| `version` | version in `package.json` differs from base (repo-configurable; off where a repo does not bump per-PR) |
| `base_merged` | `git merge-base --is-ancestor origin/<base> HEAD` |

The `review` check requires the stamped commit to be on the **branch side** of the
merge-base (ancestor of HEAD but NOT of base), so a leftover `review-skill-head`
from a prior branch that has since landed in base cannot grant a false pass.

A **docs-only diff auto-satisfies** `changelog`/`version` (bookkeeping fast-lane,
reusing merge-clearance's idea) so trivial changes pay no ceremony. Docs are
matched by **extension** (`.md`/`.mdx`/`.markdown`/`.txt`/`.rst`), and
behavior-contract instruction files (`SKILL.md`/`CLAUDE.md`/`AGENTS.md`) are
excluded from the fast lane (same set as merge-clearance's `mc_is_bookkeeping`),
so a skill/instruction change cannot dodge the required evidence by keeping its
diff to markdown.

**Uncomputable vs not-applicable.** A dimension the gate genuinely cannot evaluate
(base ref unresolved, `package.json` version unreadable) is recorded as `unknown`,
distinct from `na`. Under `require`, `unknown` fails toward **BLOCK** (with the
recorded-skip escape) and is logged, so a shallow/detached checkout cannot silently
waive three of the four dims by having them all read `na`.

### 3. Enforcement dial (per-repo marker key)

`.ship-gate.json` gains a `completion` block. Default is **record-only**:

```jsonc
{ "base_branches": ["main"], "ttl_seconds": 1200,
  "completion": {
    "mode": "record",              // "record" (default) | "require"
    "require": []                  // dims that HARD-block when mode="require"
  } }
```

- **`record` (default):** snapshot written, non-blocking, missing dims surfaced in the
  audit log and to the agent. **Zero false-block risk. Silent becomes recorded.** This
  is the low-risk core and directly satisfies the stated goal.
- **`require: [dims]` (opt-in):** each listed dim HARD-blocks the create unless
  satisfied OR an explicit **recorded skip** exists.

### 4. Recorded-skip primitive (the honest skip)

To skip a required dim honestly, the operator writes a reason the gate reads and
logs:

```bash
echo "reason=docs-only policy=bookkeeping" > <gitdir>/ship-skip-changelog
```

A skip is honored **only for the run that authored it**: its file mtime must be at
or after the current `/ship` run's `run_started_epoch` (from the `ship-run.json`
ledger). A skip left over from a prior PR is stale, ignored, and logged, so a
one-time honest skip cannot silently waive a required dim on every future ship.
(With no ledger, e.g. a deliberate human one-off with no `/ship` run, the skip is
honored: it was written on purpose and there is no run to bound it to.)

This is Direction 4: the legitimate skip becomes a first-class, auditable action,
mirroring merge-clearance's principle that `--skip-review` is "the honest 'no review
happened' override, not a shortcut."

## What each mode catches

| Scenario | `record` | `require:[review,changelog,base_merged]` |
|---|---|---|
| Hand-driven create, no review at all | logged as `review=missing` | **blocked** (or recorded-skip) |
| Hand-driven, `/eng:cr` used | `review=ok` | passes (correct — `/eng:cr` is valid) |
| CHANGELOG forgotten | logged `changelog=missing` | **blocked** (or recorded-skip) |
| Adversarial/plan-completion skipped | logged as `unverified` (no footprint) | not blockable — but recorded, so not silent |
| Docs-only PR | fast-lane, all `n/a` | fast-lane, passes |

The no-footprint quality steps stay unenforceable, but both modes make their absence
**recorded** — which is the whole point.

## Fail posture

Dependency and marker problems fail **open** (and are logged): a missing jq/git, a
missing completion lib, or an unparseable `.ship-gate.json` allow the create rather
than wedge a real ship on the gate's own bug. A local gate that fails closed on its
own bug trains the human to rip it out.

But a **required dimension the gate cannot evaluate** (base ref unresolved, version
unreadable) is the `unknown` case above: under `require` it fails toward **BLOCK**
(the safe direction), with a distinct, actionable reason and the recorded-skip
escape. This is not "the gate's own bug" — it is a genuine "cannot verify", and
silently passing it as `na` is exactly the false-ALLOW this layer exists to prevent.
Every block and every degraded (unknown) evaluation is logged, so a rotted or
mis-firing gate is visible rather than silent.

## Where it lands

`gstack-extensions/eng/` (the gate's source repo), so it survives plugin upgrades and
benefits every opted-in `~/dev` repo. Pure decision logic goes in a `*-lib.sh` with a
`.bats` unit test, matching `ship-pr-gate-lib.sh` / `merge-clearance-lib.sh`. mutwo
opts in by extending its `.ship-gate.json` (and the `~/dev/gated-repos.json` source of
truth). This is a security-sensitive gate change → full `/eng:cr` before merge.
