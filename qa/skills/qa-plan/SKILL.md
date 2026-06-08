---
name: qa-plan
version: 1.3.0
description: |
  QA Quincey's planning skill: turn a change's success criteria into a two-phase
  QA plan written into the PR body, BEFORE the PR is reviewed or merged. Produces a
  Development QA section (must pass in a dev / preview environment before merge),
  a Production QA section (verified live after deploy), and a Definition of Done.
  Each item traces to an acceptance criterion (Given/When/Then or EARS) and names
  the tool that exercises it. It PLANS QA; it does not execute it (Development QA is
  run by /qa, qa:browser, or qa:headless; Production QA by /canary). It ENDS by
  presenting the plan (and a recommended QA driver from claude-hooks/qa-roster.json,
  default mutwo, named in the PR body with their handle) for the human's approval
  and, on a yes, writing the approval stamp the QA-plan gates read (build / PR /
  deploy). It is step 3 of
  ~/dev/BUILD-PROCEDURE.md and feeds the two-phase QA posture (dev_verified /
  prod_verified) the QA-status gate reads. Use when the user says "qa plan", "write
  the qa plan", "plan the QA", "qa section for the PR", "dev and prod QA plan",
  "/qa:plan", or when a change needs its QA plan authored before the PR goes up.
  Sibling to qa:browser and qa:headless inside the qa plugin; shares the QA Quincey
  identity in shared/core.md. (gstack-extensions)
  Voice triggers (speech-to-text aliases): "qa plan", "write the qa plan", "plan the QA", "dev and prod QA plan".
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - AskUserQuestion
triggers:
  - qa plan
  - write the qa plan
  - plan the QA
  - qa section for the PR
  - dev and prod QA plan
---

## Update check (run first)

Before the skill body, check whether the gstack-extensions repo has merged updates this clone has not pulled. Silent unless an upgrade is available; never changes anything:

```bash
~/dev/gstack-extensions/bin/gstack-extensions-update-check 2>/dev/null || true
```

If there is no output, proceed straight to the skill body. If it prints `UPGRADE_AVAILABLE <n> <range>`, tell the user via AskUserQuestion that gstack-extensions is `<n>` commit(s) behind `origin/main` and offer:

- **Upgrade now (recommended)**: run `~/dev/gstack-extensions/bin/gstack-extensions-upgrade`, then continue. It fast-forwards `main` and refreshes the installed plugins, and refuses safely (printing why) if the clone is not on a clean `main`; relay that message and continue without upgrading if so.
- **Skip this time**: run `~/dev/gstack-extensions/bin/gstack-extensions-update-check --snooze` to suppress the prompt for ~8h (so other skills do not re-ask this session), then continue without upgrading.

Do not upgrade without asking. Ask at most once per session: if you have already prompted (or the user skipped) this session, proceed silently.

# /qa:plan: Author the two-phase QA plan into the PR body

You are running `/qa:plan`. Your job is to turn a change's success criteria into a **two-phase QA plan** and write it into the **PR body**, so QA is planned before the PR is reviewed and gated by construction. This is **step 3 of `~/dev/BUILD-PROCEDURE.md`**.

You **plan** QA. You do not execute it: Development QA is run by `/qa`, `qa:browser`, or `qa:headless`; Production QA by `/canary`. You do not merge or open the PR, and you do not mint the merge-clearance stamp (that is `/eng:cr`). The one stamp you DO write is the QA-plan **approval** stamp in Step 6, and only after the human approves.

## Step 1: Load the QA Quincey identity

Read `../../shared/core.md` (the plugin root's shared file; resolves wherever the `qa` plugin is installed). It carries your persona, the "acceptance criteria are the bar" principle, and the QA posture contract. Everything below assumes you have loaded it.

## Step 2: Resolve the change and pull its success criteria

1. Identify the change: the open PR (`gh pr view --json number,url,body,headRefName`) or, if none yet, the branch's diff against the base.
2. Pull the **success criteria**, in this order of preference. Never invent them silently:
   - A `/spec` artifact for this work, if one exists.
   - The linked GitHub issue (PM Penny's `## QA instructions` / acceptance criteria).
   - A Pencil `.pen` mockup whose flow defines the expected behavior (see `~/dev/WIREFRAMES.md`).
   - As a last resort, ask the user to state the acceptance criteria. Capture, do not paraphrase.
3. Express each criterion in a checkable form: **Given/When/Then** for behavior, **EARS** (`WHEN <x> THE SYSTEM SHALL <y>`) for system requirements.
4. Separate **per-change Acceptance Criteria** (what proves THIS change is correct) from the universal **Definition of Done** (the engineering bar every change meets).

If you cannot find or confirm criteria, stop and ask. A QA plan with invented criteria is worse than none.

## Step 3: Build the two-phase plan

For each acceptance criterion, decide how it is verified in each phase:

- **Development QA** (exercised in a dev / preview environment, **before the PR merges**). Name the tool that exercises it: `/qa` (bug sweep), `qa:browser` (a UI flow), `qa:headless` (a backend side effect), or an explicit command. Render each as a **checkbox** (`- [ ]`).
- **Production QA** (verified **live after deploy**, build-procedure step 11). Name the check: `/canary`, a smoke URL, a log line, or a metric. Render each as a **plain bullet** (`-`), NOT a checkbox, so it does not trip the pre-merge merge-clearance QA gate (which blocks on unchecked boxes). It is verified post-deploy via the `prod_verified` posture.

**Name the production artifact (required on every Production QA item).** Give each Production QA item a `Production artifact:` sub-line naming the EXACT thing production runs (an image digest/tag, a bundle id, a deploy/run id) plus the host and how it is exercised. The QA-status gate reads this field: when you later state `QA_STATUS: prod_verified`, it rejects EVIDENCE that names only an upstream / base / proxy artifact instead of this one. Write it so a machine can match it (a literal image:tag or `sha256:` digest), not a vague description.

**Layer-walk (only when the diff touches a build / derivation / deploy layer:** a container image, bundled binary, lambda layer, CDN asset, vendored copy, or multi-stage build. Skip it otherwise.) Ask: between the code I changed and what the user/agent actually runs, what layers exist, which one does production execute, does my QA hit THAT one, and is the derived artifact rebuilt automatically when my change lands or does it go stale until a separate trigger? Make the answer the `Production artifact:` and write the QA item to verify through it. This exists because a shared base image was once "verified" by testing the base directly while the per-agent images derived from it silently went stale.

**Mockup-first rule (from BUILD-PROCEDURE.md step 2):** if the change has a user-facing surface, at least one Development QA item must compare the live result against the Pencil mockup.

Right-size it: one QA item per real acceptance criterion. Do not pad the list with generic "page loads" checks that prove nothing.

## Step 4: Write it into the PR body (idempotent)

Insert or replace a `## QA` section in the PR body, matched by the HTML-comment marker so re-runs update in place rather than duplicating. The section shape:

```markdown
## QA

<!-- qa-plan: managed by /qa:plan -->

**QA driver:** <Label> (`<@handle>`) -- <one-line why>. Who is on the hook to run the Development QA, recommended by /qa:plan and approved by the human (roster: `claude-hooks/qa-roster.json`). For the agent (`claude`) write "the building agent (this session)" with no handle.

### Development QA (must pass before merge)
- [ ] <Given/When/Then or EARS criterion> via `<tool/command>`, expect <result>
- [ ] ...

### Production QA (verified after deploy, build-procedure step 11)
- <criterion> via `<check>`, expect <result>
  - Production artifact: `<exact image digest/tag | bundle id | deploy/run id>` on `<host>`, exercised by `<command/flow>`
- ...

### Definition of Done
- [ ] Tests written and green
- [ ] Independent local review clear (`/eng:cr`) + CodeRabbit addressed
- [ ] Docs updated where user-facing
- [ ] `where-things-run.json` bumped if the deploy changed hosts

### QA posture
- Pre-merge: state `QA_STATUS: dev_verified` + `EVIDENCE:` once every Development QA box is checked.
- Post-deploy: state `QA_STATUS: prod_verified` + `EVIDENCE:` once Production QA is verified live.
```

**Pick the QA driver** for the `**QA driver:**` line: read `claude-hooks/qa-roster.json` and recommend one (a best guess; the human approves or refines it in Step 6). Heuristic: default `mutwo` (`@mutwo-ai`); a different Mu clone when it owns the repo/host; `mujtaba` (`@mujtaba3B`) when it needs his taste/judgment or only he holds the live session/data; `claude` (the building agent, no handle) when the flow is automatable and this session can drive it now. Write the chosen driver's label + handle into the line so the PR body names who is on the hook.

Mechanics:
- With a PR open: read the current body, replace the existing `## QA`...marker block if present (idempotent) else append it, and `gh pr edit <n> --body-file <tmp>`.
- No PR yet: print the block and tell the user `/ship` will fold it into the PR body, or they can paste it.
- Keep posture lines free of `<` and `|` on any line that could be mistaken for a bare keyword: the strict CI qa-gate rejects the menu form. The real posture keyword is emitted at done-time, not here.

## Step 5: State what the plan enables

Tell the user, in one tight readout:
- The **Development QA** checkboxes gate the merge: while any is unchecked, the merge-clearance QA dimension blocks. Checking them all is what lets you state `QA_STATUS: dev_verified`.
- The **Production QA** bullets are the post-deploy plan `/canary` (or the named check) runs; verifying them live is `QA_STATUS: prod_verified`.
- Point at `~/dev/BUILD-PROCEDURE.md` (the procedure) and the aligned QA-status gate (`claude-hooks/scripts/qa-status-gate.sh`) for the posture contract.

## Step 6: Present the plan for approval, then write the approval stamp

The load-bearing step: it makes QA approval come **before** building. BUILD-PROCEDURE.md non-negotiable #4 requires the two-phase plan to be presented to and approved by the human before implementation. The gates (`qa-plan-build-gate.sh` / `qa-plan-pr-gate.sh`) enforce it: in an opted-in repo, source edits and `gh pr create` are blocked until the branch has an approval stamp.

1. **Present and ask.** Show the Development + Production QA sections AND the recommended **QA driver** (label + handle, from Step 4), then fire one `AskUserQuestion` (header `"QA plan"`):
   - **Approve** (recommended): plan and driver are right, build against it.
   - **Revise**: capture the changes (to the plan and/or the QA driver), edit the plan / driver line (back to Step 3 / Step 4), re-present. Do NOT stamp.
   - **Skip the gate**: the human chooses to build without an approved plan. Do NOT stamp; note that a `spike/` branch bypasses the build gate and the deploy gate still requires QA to pass.

   If the human refines the driver, update the `**QA driver:**` line in the PR body to the chosen roster entity + handle before stamping.

2. **On Approve, write the stamp.** Run from the repo (or the branch's worktree):

   ```bash
   ~/.claude/scripts/qa-plan-stamp.sh write \
     --digest "$(printf '%s' "<your QA section text>" | shasum -a 256 | cut -d' ' -f1)"
   ```

   `--digest` is optional (hashes the approved plan so later drift is detectable); omit if awkward. The script keys the stamp to the current branch and prints its path. Confirm: "QA plan approved and stamped for `<branch>`; building is unblocked."

3. **Only stamp on an explicit Approve.** The stamp records the human's approval; never write it on their behalf. On Revise, re-present and stamp only after the next Approve. A detached HEAD or base-branch checkout refuses to stamp by design; branch first.

## What this skill does NOT do

- It does not **execute** QA. Development QA is `/qa` / `qa:browser` / `qa:headless`; Production QA is `/canary`. This skill writes the plan they run against.
- It does not **invent** criteria. It pulls them from `/spec`, the issue, the mockup, or the user.
- It does not **merge or open the PR**. Opening the PR is `/ship`; the merge-clearance stamp is `/eng:cr`. The only stamp this skill writes is the QA-plan **approval** stamp (`<git-dir>/qa-plan-approved`), and only after the human approves in Step 6.
