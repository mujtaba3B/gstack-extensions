# QA_STATUS postures: the full contract

The canonical home of the QA-posture contract enforced by `qa-status-gate.sh`
(the Stop hook). The gate's block message is deliberately short and points
here; this doc carries the details. Aligned to the two-phase QA-plan policy:
the Development QA Plan must pass before the PR
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
- `<who>` is a QA-roster id from `qa-roster.json` at the qa plugin's root:
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
  `Production artifacts:` field (an exact image:tag, sha256 digest, bundle id,
  or deploy id), the EVIDENCE must cite THAT artifact. The gate rejects evidence
  that names only a base / upstream / proxy artifact from the same image
  family. This is incident hardening: a shared base image was once "verified"
  directly while the derived per-agent images that production actually runs
  went silently stale.

### `QA_STATUS: awaiting_human`

Every check an agent can run is done; the one item left needs a human's hands
(a desktop-app click, a real login, a device in the room). Not broken, not
finished: waiting on a named person for a named check.

- Requires `DRIVER: <roster id>` (usually `mujtaba`), `CHECK: <the exact thing
  the human must do and what they should see>`, and `PHASE: dev` or
  `PHASE: prod`.
- `PHASE: prod` is the common case: the change is merged and deployed, and the
  only open Production QA row is a live check no agent can perform (e.g. run
  `/mu:pause` from the desktop app after a restart). Record `prod_verified`
  after the human reports back. Also record the open check where it outlives
  this chat: a comment on the merged PR naming the open Production QA row and
  the CHECK, or a TODO. After merge the Stop gate no longer fires on the
  branch, so a chat line alone is easy to lose.
- `awaiting_human` claims nothing was verified, so it carries no `EVIDENCE:`
  and the artifact-evidence rule above does not apply to it. Any Production QA
  row an agent did run is still checked against the named production artifact
  when `prod_verified` is stated.
- `PHASE: dev` is a pre-merge check only the human can do that involves no
  branch deploy (e.g. a local install exercised in his own app). If you
  deployed the feature branch to a host for him, use
  `deploy_branch_for_manual_qa` with `DRIVER: mujtaba` instead: its
  `DEPLOYED:` line is the record of that deploy. Either way, leave the Dev QA
  box for the human's check unchecked until they report back: that box is
  what keeps the merge blocked, and `verified` is recorded only after it.
- Use this, not `blocked`, when nothing is wrong and the only gap is a human
  check; use it, not `dev_verified` / `prod_verified`, so the open item stays
  visible.

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

`deploy_branch_for_manual_qa`, `skip_requested`, and `awaiting_human` end the
working turn at the Stop hook but are NOT accepted by the strict per-repo CI qa-gate
(`.github/workflows/qa-gate.yml`), which greens only on `verified` / `blocked`
/ `skip_approved` (verified against the deployed workflow's matcher; note it
does NOT match the longer `dev_verified` spelling, so the PR body must carry a
plain `QA_STATUS: verified` line for CI even when the turn-level posture was
stated as `dev_verified`). That is intentional: the merge stays blocked on
real verification, and the PR goes green when the verified posture is
recorded after the human's thumbs-up. (`prod_verified` is post-deploy, not a
pre-merge condition; so is `awaiting_human PHASE: prod`, which CI never sees.
`awaiting_human PHASE: dev` is deliberately left out of the CI matcher, so
the posture itself never greens a merge; the matcher is anchored to the
keyword right after `QA_STATUS:`, so a `CHECK:` line that mentions "verified"
does not count. That is not a hard guarantee: the matcher also accepts
`blocked`, and the Dev QA boxes merge-clearance reads can be ticked by anyone
who edits the PR body. What actually keeps a pending human check from merging
is the driver leaving its Dev QA box unchecked until the human reports back.)
