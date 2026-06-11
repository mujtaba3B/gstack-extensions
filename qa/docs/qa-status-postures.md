# QA_STATUS postures: the full contract

The canonical home of the QA-posture contract enforced by `qa-status-gate.sh`
(the Stop hook). The gate's block message is deliberately short and points
here; this doc carries the details. Aligned to the two-phase QA model in
`~/dev/BUILD-PROCEDURE.md`: the Development QA Plan must pass before the PR
merges, the Production QA Plan is verified live after deploy. The plan itself
lives in the PR body and is authored by `/qa:plan`; the posture line states
which phase you have verified.

The gate is a "did you decide?" gate, not a linter: any `QA_STATUS:` line
allows the stop. It arms only when the branch has commits ahead of the base
branch AND the final message makes a non-negated completion claim. A dirty
working tree alone does not arm it.

## The postures

State exactly one `QA_STATUS:` line at the end of the turn, plus the required
companion lines for that posture.

### `QA_STATUS: dev_verified` (alias: `verified`)

The Development QA Plan was exercised in a dev / preview environment and
passed.

- Requires `EVIDENCE:` with a command, URL, screenshot path, or test name
  proving you exercised the plan. Strongest evidence is the REAL flow, not
  just a unit test; a unit test alone is NOT enough for a user-facing or
  interactive change.

### `QA_STATUS: deploy_branch_for_manual_qa`

The real-host Development QA path: deploy the feature branch to the host where
the code is actually exercised and run the real flow there. Prefer it over a
thin `dev_verified` for user-facing / interactive changes.

- Requires `DRIVER: <who>` and `DEPLOYED: <host> @ <branch>, run: <command>`.
- `<who>` is a QA-roster id from `claude-hooks/qa-roster.json`:
  - `mutwo` (DEFAULT), `muthree`, `mufour`: a Mu clone deploys AND drives it.
    Recommend the default unless another clone owns the repo or host. Add
    `EVIDENCE:` for what was observed.
  - `mujtaba`: hand the human the exact command to self-test. This ENDS the
    turn, with `dev_verified` recorded after his thumbs-up.
  - `claude`: this session deploys and drives it now. Add `EVIDENCE:`.
- RECOMMEND a driver (best guess, default `mutwo`) and let the human approve
  or refine. The chosen driver MUST be named in the PR body with their handle
  (e.g. `QA driver: @mutwo-ai`).
- Mechanics (deploy the branch on the host, editable install picks up code
  immediately, shared-checkout daemon caveat, revert the host to `main` after
  merge): [`deploy-branch-for-manual-qa.md`](deploy-branch-for-manual-qa.md).

### `QA_STATUS: prod_verified`

Post-deploy only (build-procedure step 11): the Production QA Plan ran live
and passed.

- Requires `EVIDENCE:` of the live check.
- Artifact-evidence rule: if the approved QA plan in the PR body named a
  `Production artifact:` (an exact image:tag, sha256 digest, bundle id, or
  deploy id), the EVIDENCE must cite THAT artifact. The gate rejects evidence
  that names only a base / upstream / proxy artifact from the same image
  family. This is incident hardening: a shared base image was once "verified"
  directly while the derived per-agent images that production actually runs
  went silently stale.

### `QA_STATUS: blocked`

Something prevents QA right now.

- Requires `REASON:` stating what.

### `QA_STATUS: skip_requested`

QA is not feasible for this change.

- Requires `REASON:`, then ask the human "ok to skip QA for <reason>" and
  record `QA_SKIP_APPROVED_BY: <user> <date> <reason>` in the PR body.

### `QA_STATUS: skip_approved`

The recorded human sign-off for a requested skip.

- Requires the matching `QA_SKIP_APPROVED_BY: <user> <date> <reason>` line in
  the PR body. Never state this posture on the human's behalf: it records a
  sign-off that actually happened, after `skip_requested` was asked and
  answered.

### `QA_STATUS: no_tracked_change`

This turn changed NO version-controlled files: only docs / memory / local-only
edits (git-ignored LOG.md / INDEX.md, `~/.claude` memory), ops, or pure
conversation. There is nothing to QA, so this ENDS the turn with no evidence
and no human sign-off needed. Use it (not `skip_requested`) when the gate
fired on a branch whose commits ahead carry no QA-able change of yours, e.g.
docs-only commits.

## Intermediate vs terminal postures (CI asymmetry)

`deploy_branch_for_manual_qa` and `skip_requested` end the working turn at the
Stop hook but are NOT accepted by the strict per-repo CI qa-gate
(`.github/workflows/qa-gate.yml`), which greens only on `verified` / `blocked`
/ `skip_approved` (verified against the deployed workflow's matcher; note it
does NOT match the longer `dev_verified` spelling, so the PR body must carry a
plain `QA_STATUS: verified` line for CI even when the turn-level posture was
stated as `dev_verified`). That is intentional: the merge stays blocked on
real verification, and the PR goes green when the verified posture is
recorded after the human's thumbs-up. (`prod_verified` is post-deploy, not a
pre-merge condition.)
