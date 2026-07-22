---
name: qa-plan
version: 2.2.0
description: |
  QA Quincey's planning skill: turn a change's success criteria into a two-phase
  QA plan written into the PR body, BEFORE the PR is reviewed or merged. Produces a
  Development QA section (must pass in a dev / preview environment before merge),
  a Production QA section (verified live after deploy), and a Definition of Done.
  It also publishes a companion Claude artifact: a rendered, pointable, always-linked
  view of the same plan (the PR body stays the machine source of truth the gates read).
  Each item traces to an acceptance criterion (Given/When/Then or EARS) and names
  the tool that exercises it. It PLANS QA; it does not execute it (Development QA is
  run by /qa, qa:browser, or qa:headless; Production QA by /canary). It ENDS by
  presenting the plan (and a recommended QA driver from the qa plugin's qa-roster.json,
  default mutwo, named in the PR body with their handle) for the human's approval
  and, on a yes, writing the approval stamp the QA-plan gates read (build / PR /
  deploy). It feeds the two-phase QA posture (dev_verified /
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
  - Artifact
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

You are running `/qa:plan`. Your job is to turn a change's success criteria into a **two-phase QA plan** and write it into the **PR body**, so QA is planned before the PR is reviewed and gated by construction. This authors the two-phase QA plan (Development + Production) before the PR is reviewed.

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

## Step 3: Build the two-phase plan (split by phase)

The plan is **two small tables under two headings**, so what **blocks the merge** and what is **checked after deploy** read apart at a glance:

- `### 🖥️ Development` -- the merge-gating phase (exercised in a dev / preview environment **before the PR merges**). Columns `✓ | Tester | Check | Expect | Notes`. One row per real acceptance criterion. The `✓` cell is a **`[ ]` checkbox** the driver flips to `[x]` when the check passes; these gate the merge. Name the flow in `Check`: `/qa` (bug sweep), `qa:browser` (a UI flow), `qa:headless` (a backend side effect), or an explicit command.
- `### 🚀 Production` -- the post-deploy phase, **verified live after deploy** (build-procedure step 11). Columns `Tester | Check | Expect | Notes`. It has **no `✓` column and NO `[ ]`** so it never trips the pre-merge gate; verified post-deploy via the `prod_verified` posture. Name the check in `Check`: `/canary`, a smoke URL, a log line, or a metric.
- Under each heading, add a one-line **ELI5**: a plain-language `_italic_` sentence explaining how that phase tests THIS change, no jargon. Development = how we prove it in a safe / preview copy before merge; Production = how we confirm the real live thing after deploy.

Column discipline (this is what keeps it readable): `Check` and `Expect` are **one line each**; the long mechanics, setup, gotchas, and exact URLs go in `Notes` (may be blank) or, if they run long, in the companion artifact (Step 4b). Use **simple tester names** in the `Tester` column: `claude`, `mutwo`, `mujtaba` (also `muthree` / `mufour` when they own the repo/host). These are the roster `id`s (`qa-roster.json`), not labels or handles: write `claude`, not "the building agent (this session)"; write `mutwo`, not "MuTwo (`@mutwo-ai`)". The handle still appears once, in the `**QA driver:**` line, where the gate/@-mention needs it.

The routine automated checks (unit tests, lint/types, CI, `/eng:cr`) are NOT rows: they collapse into the one-line **`Standard (all green)`** header above the tables. Dev QA rows are only the manual / bespoke flows that standard automation does not already cover.

**Name the production artifact (required for every PROD row).** In the `**Production artifacts:**` block below the table, name for each PROD row the EXACT thing production runs (an image digest/tag, a bundle id, a deploy/run id) plus the host and how it is exercised. The QA-status gate reads this: when you later state `QA_STATUS: prod_verified`, it rejects EVIDENCE that names only an upstream / base / proxy artifact instead of this one. Write it so a machine can match it (a literal image:tag or `sha256:` digest), not a vague description.

**Layer-walk (only when the diff touches a build / derivation / deploy layer:** a container image, bundled binary, lambda layer, CDN asset, vendored copy, or multi-stage build. Skip it otherwise.) Ask: between the code I changed and what the user/agent actually runs, what layers exist, which one does production execute, does my QA hit THAT one, and is the derived artifact rebuilt automatically when my change lands or does it go stale until a separate trigger? Make the answer the production artifact and write the PROD row to verify through it. This exists because a shared base image was once "verified" by testing the base directly while the per-agent images derived from it silently went stale.

**Mockup-first rule:** if the change has a user-facing surface, at least one DEV row must compare the live result against the Pencil mockup.

Right-size it: one row per real acceptance criterion. Do not pad the table with generic "page loads" checks that prove nothing.

## Step 4: Write it into the PR body (idempotent)

Insert or replace a `## QA` section in the PR body, matched by the HTML-comment marker so re-runs update in place rather than duplicating. The section shape:

```markdown
## QA

<!-- qa-plan: managed by /qa:plan -->

📄 **Plan view:** <artifact-url>  (rendered, always-linked; this section stays the source of truth)

**QA driver:** <Label> (`<@handle>`) -- <one-line why>
**Standard (all green):** unit tests · lint/types · CI · `/eng:cr`

### 🖥️ Development

_<one plain-language line: how this phase tests the change, before merge>_

| ✓ | Tester | Check | Expect | Notes |
|---|---|---|---|---|
| [ ] | <tester> | <one line: what to do> | <one line: what proves it passed> | <extra detail, or blank> |
| [ ] | <tester> | ... | ... | ... |

### 🚀 Production

_<one plain-language line: how this phase confirms the change live, after deploy>_

| Tester | Check | Expect | Notes |
|---|---|---|---|
| <tester> | <one line: live check after deploy> | <one line: result> | <extra detail, or blank> |

**Production artifacts:** for each Prod QA row, name the exact thing production runs (image digest/tag, bundle id, deploy/run id) + host + how it is exercised.

**Definition of Done:**
- [ ] Tests written and green
- [ ] Independent local review clear (`/eng:cr`) + CodeRabbit addressed
- [ ] Docs updated where user-facing
- [ ] `where-things-run.json` bumped if the deploy changed hosts

**QA posture:** Pre-merge -> state `QA_STATUS: dev_verified` + `EVIDENCE:` once every Dev QA `✓` box and every Definition-of-Done box is `[x]`. Post-deploy -> state `QA_STATUS: prod_verified` + `EVIDENCE:` once the Prod QA rows are verified live.
```

Format rules the gates depend on:
- The **`📄 Plan view:` line** carries the companion artifact URL (Step 4b). It is a plain link; leave it out on the first pass if the artifact is not published yet, then add it once you have the URL. The PR-body section, not the artifact, is the source of truth.
- The **QA driver** line names who is on the hook to run the Dev QA, recommended by /qa:plan and approved by the human (roster: the qa plugin's `qa-roster.json`). It carries the driver's handle for the @-mention; for the agent (`claude`) write "the building agent (this session)" with no handle.
- The **`Tester` column uses simple names**: `claude`, `mutwo`, `mujtaba` (or `muthree` / `mufour`), the roster `id`s. No handles or verbose phrasing in the cell: the handle lives once in the QA-driver line above.
- **`Check` and `Expect` are one line each**; the **`Notes` column** holds any longer detail (setup, gotchas, exact URLs, data). Notes may be blank.
- A **Dev QA row's `✓` cell is a `[ ]` checkbox** (merge-gating); the driver flips it to `[x]` when the check passes.
- A **Prod QA table has no `✓` column and NO `[ ]`** (so it does not gate the merge; it is verified post-deploy).
- **Definition of Done stays `- [ ]` bullets** (also merge-gating).
- Never use an em-dash (U+2014). Use a hyphen `-` everywhere.
- **No literal `[ ]` (or `[x]`) anywhere except a Dev QA `✓` cell or a Definition-of-Done bullet.** The merge-clearance QA gate reads ANY checkbox bracket in the `## QA` section (its section runs to the next `##`, so the `###` sub-tables stay inside), so a literal `[ ]` in a `Check` / `Expect` / `Notes` cell, in the Prod QA table, in the QA-driver line, or in prose falsely reads as an unchecked box and blocks the merge. Describe such things in words ("an unchecked Dev QA box") instead of the glyph.

**Pick the QA driver** for the `**QA driver:**` line: read `../../qa-roster.json` (the plugin root, relative to this skill's base directory) and recommend one (a best guess; the human approves or refines it in Step 6). Heuristic: default `mutwo` (`@mutwo-ai`); a different Mu clone when it owns the repo/host; `mujtaba` (`@mujtaba3B`) when it needs his taste/judgment or only he holds the live session/data; `claude` (the building agent, no handle) when the flow is automatable and this session can drive it now. Write the chosen driver's label + handle into the line so the PR body names who is on the hook.

Mechanics:
- With a PR open: read the current body, replace the existing `## QA`...marker block if present (idempotent) else append it, and `gh pr edit <n> --body-file <tmp>`.
- No PR yet: print the block and tell the user `/ship` will fold it into the PR body, or they can paste it.
- Keep posture lines free of `<` and `|` on any line that could be mistaken for a bare keyword: the strict CI qa-gate rejects the menu form. The real posture keyword is emitted at done-time, not here.

## Step 4b: Publish the companion artifact (pointable plan view)

Publish a rendered, always-linked view of the same plan as a Claude **artifact**, so there is one pretty page to point at. The artifact is a **companion**, not the source of truth: the gates only ever read the PR-body `## QA` section (Step 4). The artifact can carry the full mechanics that would bloat the table.

1. **Build the HTML.** Copy `references/artifact-template.html` (this skill's base directory) to the session scratchpad and swap the content between the `FILL:` markers: the **title**, the story-first **context blocks** (STORY / SOLUTION / PROOF, below), the **Development** ELI5 + rows, the **Production** ELI5 + rows, the **Production artifacts**, and the **Definition of Done**. The artifact is the leaner companion view: it deliberately drops the QA-driver line, the `Standard (all green)` line, and the QA-posture line (those live in the PR body, the source of truth).

   **Story-first context blocks (required).** The page opens with three blocks ABOVE the Development section, headed tersely **"Story"**, **"Solution"**, and **"How this plan proves it"**, so a reader gets what problem is being solved, what is being built, and how the plan proves it before any table:
   - `FILL: STORY` - the change's user story in one sentence (`As <user>, when <situation>, I want <capability>, so <outcome>`), then the observed problem in a muted line (the incident, gap, or pain that motivated the change, with date/PR when one exists), then a muted **`Linked issue:`** line: link the GitHub issue when one exists; otherwise write `none` plus where the change originated (e.g. "requested in-session, <date>"). Derive it all from the same success criteria Step 2 pulled (spec, issue, mockup, or the user's own words); never invent it.
   - `FILL: SOLUTION` - a short **bullet list** (2-5 bullets, `ul.proof` markup), never a paragraph, naming what is being built to deliver that outcome, concrete enough that the QA rows below visibly test it.
   - `FILL: PROOF` - 2-4 numbered bullets mapping the plan to the story: each states one thing the plan establishes and ends with a muted pointer to the rows that establish it (for example "(Dev rows 1-3.)", "(Prod row 2.)"). This is the bridge that lets the reader see the QA verifies the solution actually solves the story's problem.

   The **Production artifacts** block is likewise a **bullet list** (one bullet per artifact fact), never a paragraph.

   The template is self-contained (inline CSS + data-URI images, theme-aware, no external assets, which the artifact CSP requires) and carries **NO checkboxes of any kind**: no checkbox column in the Development table, plain bullets in the Definition of Done, and never square-bracket boxes. Checkbox state lives ONLY in the PR body's `## QA` section, the source of truth the merge gates read; the artifact is the readable view of the plan, not a tracker.

   **Driver avatars.** The `Tester` cell shows a logo-only avatar that carries the driver's identity for assistive tech via `role="img"` + `aria-label` (the `title` is the hover tooltip), with the decorative inner `.pic` marked `aria-hidden`: `<span class="av" title="<id>" role="img" aria-label="<id>"><span class="pic <id>" aria-hidden="true"></span></span>`, where `<id>` is a roster id with a built-in avatar (`claude` `mutwo` `muthree` `mufour` `mujtaba`). For any driver without one, use the initials fallback: `<span class="av" title="<id>" role="img" aria-label="<id>"><span class="pic generic" aria-hidden="true">M5</span></span>`. The template's header comment documents how to add a new avatar (inline its `github.com/<handle>.png` as a data URI in a new `.pic.<id>` rule; `claude` is a hand-drawn inline-SVG burst on Anthropic clay).

2. **Publish, idempotently.**
   - **Re-run (URL already in the PR body):** read the existing `📄 Plan view:` URL from the body and call `Artifact` with that same `file_path` AND `url: <existing-url>` so it updates in place and the link never changes.
   - **First run (no URL yet):** call `Artifact` with the `file_path` (no `url`). Use a **stable** `title` and `favicon` (🧪) so redeploys stay one artifact. Take the returned URL and write it into the `📄 Plan view:` line of the PR body (re-edit the body via `gh pr edit`). If there is no PR yet, hold the URL and include the `📄 Plan view:` line when `/ship` folds the section in (or hand the user the URL to paste).

3. **Tell the user it is private.** Artifacts are private by default. If a reviewer or teammate needs to open the plan view, the user shares it from the artifact page's share menu; the PR body link works for anyone who can see the PR regardless. Note that the artifact is a **snapshot at plan-authoring time** and deliberately carries no checkboxes; the live checkbox state is in the PR body's `## QA` section. Re-running `/qa:plan` refreshes the artifact.

If the `Artifact` tool is unavailable (non-interactive / headless run), skip this step, keep the PR-body section (the source of truth) intact, and note that the companion artifact was not published.

## Step 5: State what the plan enables

Tell the user, in one tight readout:
- The **Dev QA `✓` checkboxes** gate the merge: while any is unchecked, the merge-clearance QA dimension blocks (it reads both the Dev QA table checkboxes and the Definition-of-Done bullets). Flipping them all to `[x]` is what lets you state `QA_STATUS: dev_verified`.
- The **Prod QA rows** are the post-deploy plan `/canary` (or the named check) runs; verifying them live is `QA_STATUS: prod_verified`.
- The **`📄 Plan view:` link** is the pointable companion artifact (Step 4b); point them at it.
- Point at the aligned QA-status gate (the qa plugin's `hooks/scripts/qa-status-gate.sh`) for the posture contract.

## Step 6: Present the plan for approval, then write the approval stamp

The load-bearing step: it makes QA approval come **before** building. The two-phase QA-plan approval policy requires the plan to be presented to and approved by the human before implementation. The gates (`qa-plan-build-gate.sh` / `qa-plan-pr-gate.sh`) enforce it: in an opted-in repo, source edits and `gh pr create` are blocked until the branch has an approval stamp.

1. **Render the plan in chat, THEN ask.** Present the plan in two parts, in this order:

   1. **Render the full plan as a turn-final chat message.** Print the entire `## QA` section (the `📄 Plan view:` link, the `Standard (all green)` line, both the **Dev QA and Prod QA tables**, the Production-artifacts block, Definition of Done, and the QA posture line) as a normal message the human reads full-width. This is the plan; do not compress it into a modal preview. Make it the last thing in the turn so it is on screen when the modal opens.
   2. **Then fire one slim `AskUserQuestion`** (header `"QA plan"`, single-select). Do NOT cram the plan into an option preview; a one-line option description is all each option needs. Options:
      - **Approve** (recommended): the plan and driver above are right, build against it.
      - **Rework it**: capture the changes (to the plan and/or the QA driver), edit the tables / driver line (back to Step 3 / Step 4), refresh the companion artifact in place (Step 4b), re-render the plan in chat, re-ask. Do NOT stamp.
      - **Skip the gate**: the human chooses to build without an approved plan. Do NOT stamp; note that a `spike/` branch bypasses the build gate and the deploy gate still requires QA to pass.

   The canonical plan lives in the PR body (Step 4); the chat render is the approval-time copy the human reads. If the human refines the driver, update the `**QA driver:**` line in the PR body to the chosen roster entity + handle before stamping.

2. **On Approve, write the stamp.** Run from the repo (or the branch's worktree). The stamp script ships inside this plugin at `../../hooks/scripts/qa-plan-stamp.sh` relative to this skill's base directory (named in the preamble); resolve it from there:

   ```bash
   "<this skill's base directory>/../../hooks/scripts/qa-plan-stamp.sh" write \
     --digest "$(printf '%s' "<your QA section text>" | shasum -a 256 | cut -d' ' -f1)"
   ```

   `--digest` is optional (hashes the approved plan so later drift is detectable); omit if awkward. The script keys the stamp to the current branch and prints its path. Confirm: "QA plan approved and stamped for `<branch>`; building is unblocked."

3. **Only stamp on an explicit Approve.** The stamp records the human's approval; never write it on their behalf. On Rework it, re-present and stamp only after the next Approve. A detached HEAD or base-branch checkout refuses to stamp by design; branch first.

## What this skill does NOT do

- It does not **execute** QA. Development QA is `/qa` / `qa:browser` / `qa:headless`; Production QA is `/canary`. This skill writes the plan they run against.
- It does not **invent** criteria. It pulls them from `/spec`, the issue, the mockup, or the user.
- It does not **merge or open the PR**. Opening the PR is `/ship`; the merge-clearance stamp is `/eng:cr`. The only stamp this skill writes is the QA-plan **approval** stamp (`<git-dir>/qa-plan-approved`), and only after the human approves in Step 6.
