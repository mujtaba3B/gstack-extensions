# Gate inheritance by default

**Status:** shipped (2026-09-02)
**Repos touched:** `gstack-extensions` (this PR), `~/dev` (policy file, separate PR), machine-local `~/.claude/scripts` + `~/.config/git/ignore` (no PR)

## Problem

The four gate opt-in markers are machine-local and git-ignored, and the gates
fail OPEN without them. That combination produces silent, invisible holes.

1. **Worktrees.** `git worktree add` populates from the index, so git-ignored
   files are by design not carried over. Every fresh worktree of a gated repo is
   an UN-gated copy, and nothing says so. Observed live on mutwo-skills PR #182:
   `gh pr create` succeeded where it should have been blocked, no QA plan was
   demanded, and `merge-clearance status` reported a phantom `ci=missing` because
   with no marker to read `required_checks` from it fell back to looking for a
   context literally named `ci`. That third failure does not fail open, it fails
   CONFUSING: it looks like broken CI, so the reflex is to debug CI.
2. **Registry drift.** `gated-repos.json` is keyed by filesystem path and lists 5
   repos. 15 checkouts under `~/dev` actually carry markers, so 10 are gated on
   disk but invisible to `arm-gates.sh` and to the session-start drift check.
   Nothing will ever restore them.
3. **Partial coverage.** 7 of the 18 marker-carrying checkouts are missing gates
   they should have. `~/dev` itself has no ship-gate. `apps/sms-hero` has a
   `deploy.json` and no deploy-gate, which is the exact shape of the 2026-07-24
   incident.

All three are the same root cause: **the switch that arms a gate is a file that
can silently fail to exist.**

## Design

Invert it. Presence of a marker stops being the switch.

- **Inheritance by default.** Every git repo under `~/dev` is gated. There is no
  marker to be missing, so no worktree, clone, or new repo can be silently
  un-gated again. A worktree inherits because it is under `~/dev`, like anything
  else, not because a file got copied into it.
- **Markers are dropped entirely.** Not demoted to "tuning only": a
  machine-local, git-ignored file that changes enforcement is the whole problem,
  and one that vanishes in a worktree still changes behavior there even if it can
  no longer arm anything. Per-repo tuning (`required_checks`, `ttl_seconds`,
  `base_branches`, `completion`) moves into the tracked policy's `overrides`
  block, keyed by repo identity, so it is the same answer from every checkout.
- **Exclusions are derived, never curated.** A hand-maintained exclusion list is
  the same drift problem wearing a different hat.
  - origin owner not in the policy's `owners` list (excludes `third-party/`:
    `forrestchang/andrej-karpathy-skills`, `rzeydelis/personal-finance-app`.
    Forcing `/ship` to bump a VERSION and write a CHANGELOG on a PR to someone
    else's upstream is simply wrong)
  - path prefix `legacy/` (30 archived repos; gates would never fire there
    anyway, this just keeps the surface honest)
  - a repo nested inside another repo's working tree (`tooling/mutwo/vendor/*`:
    three clones of repos already gated at their real paths)
- **Per-gate applicability is derived too.** The deploy-gate arms only where a
  `deploy.json` exists. That alone closes the `sms-hero` gap with no config.

### Why CodeRabbit needs an explicit opt-out

`merge-clearance` treats CodeRabbit as a machine-hard dimension: no auto-satisfy
except the rate-limit and unreviewable-globs escapes. Probed 2026-09-02:

| Org | CodeRabbit on recent PRs |
|---|---|
| `mujtaba3B/*` | yes |
| `DxAngels/alim` | yes |
| `Unbound-Clinicians/*` | **no** (backend #86, uc-mobile-app #50: zero CR comments) |

Under inheritance-by-default that would deadlock every Unbound merge permanently,
with no override. So the opt-out is a requirement, not a convenience.

It is keyed by **repo identity, not path**, so one entry covers every checkout and
worktree of that repo. It lives in ONE central machine-local file rather than a
file per repo, which is what keeps the worktree hazard from reappearing.

Note the failure direction: were this a per-repo git-ignored file, a worktree
missing it would make the gate STRICTER (block), not looser. It fails closed.
Central-and-identity-keyed avoids even that wedge.

## Config shapes

### `~/dev/gate-policy.json` (tracked, replaces `gated-repos.json`)

```json
{
  "scope": {
    "root": "~/dev",
    "owners": ["mujtaba3B", "DxAngels", "Unbound-Clinicians",
               "Healthcare-Super-Connectors", "Mu-5-Music"],
    "exclude_path_prefixes": ["legacy/", "third-party/"],
    "exclude_nested": true
  },
  "defaults": {
    "ship":            { "base_branches": ["main"], "ttl_seconds": 1200 },
    "qa-plan":         { "base_branches": ["main"], "gates": ["build","pr","deploy"] },
    "merge-clearance": { "base_branches": ["main"], "required_checks": [] },
    "deploy":          { "requires": "deploy.json", "hosts": [] }
  },
  "overrides": {
    "mujtaba3B/mutwo-skills": {
      "merge-clearance": { "required_checks": ["tests", "manifests"] }
    },
    "Healthcare-Super-Connectors/user_growth": {
      "merge-clearance": { "required_checks": ["test", "qa-status"] }
    },
    "mujtaba3B/mutwo": {
      "ship": { "completion": { "mode": "require",
                "require": ["review","changelog","version","base_merged"] } },
      "deploy": { "hosts": ["mutwos-mac-mini"] }
    }
  }
}
```

Keyed on `owner/name` from the origin remote, so every clone and worktree of a
repo resolves to the same entry. There is no path left to drift.

### `~/dev/.gates/local.json` (machine-local, git-ignored, never committed)

```json
{
  "_comment": "Machine-local gate opt-outs. Keyed by repo identity so one entry covers every clone and worktree. Ignored via a .gates/ line in ~/.config/git/ignore, which is itself outside any repo, so no .gitignore change is committed anywhere.",
  "repos": {
    "Unbound-Clinicians/*": {
      "skip_dimensions": ["coderabbit"],
      "reason": "CodeRabbit is not installed on this org (verified 2026-09-02)"
    }
  }
}
```

Owner wildcards supported, so the 8 Unbound repos are one entry. A skipped
dimension is reported in the verdict as `CR - SKIPPED (local opt-out: <reason>)`,
never omitted. A bypass that does not appear in the output is the bug we are
fixing, so a bypass must always be visible.

## What retires

`arm-gates.sh`, `arm-gates-lib.sh`, and the drift check's marker arm. There is
nothing left to arm. Their `~/.claude/scripts` home is not a git repo, so this is
a machine-local deletion with no PR.

## Verification

The A/B harness (`probe.sh`) drives the four real gate scripts against a target
checkout and reports allow/BLOCK. Before this change, in a fresh worktree of a
gated repo, all four report `allow`; copying the markers in flips all four to
`BLOCK`, which isolates marker presence as the single variable. After this
change, the fresh worktree must report `BLOCK` on all four with NO markers
present, and `merge-clearance` must read the repo's real `required_checks`
rather than the phantom `ci`.

Control note: do not use the primary `gstack-extensions` checkout as the "armed"
arm of the A/B. On 2026-09-02 it carried a live `/ship` sentinel from a
concurrent session, which allows every gate and masks the variable under test.
