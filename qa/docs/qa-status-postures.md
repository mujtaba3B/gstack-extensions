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
  or deploy id), the EVIDENCE must cite THAT artifact (this also applies to an
  `awaiting_human` handoff unless it is plainly `PHASE: dev`). The gate rejects evidence
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
- Run every check an agent CAN run first. Each agent-runnable row must be
  closed with evidence that meets that phase's bar before you hand off (for
  Production rows, the `prod_verified` bar, including the artifact-evidence
  rule above). `CHECK:` names only what no agent can do; never move a
  runnable check into it.
- `PHASE: prod` is the common case: the change is merged and deployed, and the
  only open Production QA row is a live check no agent can perform (e.g. run
  `/mu:pause` from the desktop app after a restart). Record `prod_verified`
  after the human reports back. Also record the open check where it outlives
  this chat: a comment on the merged PR naming the open Production QA row and
  the CHECK, or a TODO. After merge the Stop gate no longer fires on the
  branch, so a chat line alone is easy to lose.
- `awaiting_human` claims nothing about the pending check. Its `EVIDENCE:`
  line cites the rows the agent did run, not the human's check. A `PHASE: dev`
  handoff may omit it. A production handoff (anything not plainly
  `PHASE: dev`) must cite the exact artifact the plan's `Production
  artifacts:` names, outside any code fence, even when the human's check is
  the only row left (name the deployed artifact). When that field names a
  citable ref or a sha256 digest, the gate blocks a handoff that does not cite
  it as a whole token (every citable ref, when it names several), whatever its
  EVIDENCE line says. Each artifact line of the field is checked on its own:
  cite every citable ref on it, the image refs and any host or skill token
  written beside them (mac-mini:8080, /mu:pause); citing its digests counts
  instead only when that line names at most one citable ref (a digest-only
  line is satisfied by its digest; a base's digest listed
  beside the image's cannot stand in for it). The block names the missing
  refs. A citable ref is any colon-joined `name:tag` token: image refs
  (ghcr.io/acme/app:v1, agent:42), a host:port on a single-label host
  (mini:22, mac-mini:8080), a skill (/mu:pause), or a colon-joined deploy or
  run id (run:4567). Dropped, so never required: ISO times
  (2026-10-13T14:05Z), all-digit names (14:05), dotted hostnames
  (sms-hero.example.com:443) and localhost. A dotted image name with a short
  all-digit tag (acme.agent:42) reads as a dotted host:port and is not
  checked; give such an image a registry path or a non-numeric tag. A field
  naming no citable ref or digest (only a bundle id, a deploy id written
  without a colon, a dotted hostname or localhost) is not checked: there is
  nothing the gate can match. The field is prose, so picking its image out is a heuristic; a
  dedicated machine-readable line is a planned follow-up.
- The gate enforces the Production bar: unless the message is plainly
  `PHASE: dev` (at least one PHASE token such as `PHASE: dev` or `PHASE=dev`
  anywhere in it, every such token `dev` or `development`, and nothing
  pairing PHASE with
  prod), the handoff is checked against the plan's `Production artifacts:`.
  Unlike `prod_verified`, which is judged on its `EVIDENCE:` line, the whole
  message outside code fences is matched (when the field names a citable ref
  or digest, see above): it must name the exact artifact, and a handoff naming only a
  base / proxy artifact is blocked. A missing or oddly formatted
  `PHASE:` is checked too (fail closed), as is any line pairing `PHASE`
  with prod. A plainly `PHASE: dev` handoff is not checked: dev QA runs a
  preview artifact. The check reads `Production artifacts:` from the PR of
  the current branch, so a handoff written from `main` (no PR) is not
  checked; close those rows against the named artifact yourself. A block
  names the text that engaged the check (a "Phase" table header, a
  "PHASE: prod" remark). The fix is to re-verify through the production
  artifact; restating as `PHASE: dev` is right only for a genuinely
  pre-merge handoff, never for one whose change is merged or deployed.
- While awaiting, say "I'll mark it verified once you confirm" rather than
  writing the literal `QA_STATUS: prod_verified` token: any unfenced
  `QA_STATUS: prod_verified` also engages the artifact check, by design (a
  rule that tried to tell a promise from a claim was beaten by markdown and
  HTML shapes and reverted).
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
