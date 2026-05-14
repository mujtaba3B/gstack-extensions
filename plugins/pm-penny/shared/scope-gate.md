# PM Penny — Scope Gate

Used by `pm-penny-feature` (and future skills) to push back when a request is too big for a single issue, and to break it into a tracked epic with sequential child issues.

Run this **before** the feature discovery questions. Skip the gate entirely if the caller passed in `epic_context` (see "Sequential child invocations" below) — that means you are already inside a break-up flow and should just file the one child you were asked to.

---

## Step 1 — Cheap scope check

Read the user's request and check it against these "too big" heuristics. If **any** trigger fires, do not proceed to normal discovery. Push back instead.

Triggers:
- Touches more than one UI surface (e.g. a new screen *and* a settings page *and* an admin view).
- Touches more than one data model / table in a non-trivial way.
- Cannot plausibly ship in a single PR by Feature Frank without intermediate review.
- Has internal sequencing (one part must land and be verified before the next can start).
- Bundles a backend change + a frontend change + a migration that could each be reviewed independently.
- The user used plural framing ("a few things", "and also", "while we're at it", "and then").
- You catch yourself wanting to write more than ~6 acceptance criteria, or acceptance criteria that read like separate features.

If none trigger and the request is obviously one coherent thing, skip straight to normal feature discovery. Do **not** drag the user through a scope conversation for a small ask.

---

## Step 2 — Push back (only if a trigger fired)

Tell the user, in plain language, *why* you think this is too big — name the specific trigger(s). Then offer them the choice via AskUserQuestion:

- **A) Break it into an epic + child issues** (recommended) — file a tracking issue, then a sequential child issue per slice.
- **B) File as a single issue anyway** — you'll do it, but flag the risk in the issue's Notes section.
- **C) Cut scope** — drop part of it for now and file only the v1 slice.

If the user picks B or C, return to normal feature discovery. If A, continue to Step 3.

---

## Step 3 — Planning round

Work with the user to produce a short, concrete break-up plan. Use AskUserQuestion one question at a time. You are looking for:

1. **The slices.** What are the 2–6 child features? Each must be shippable on its own (even if not user-visible yet).
2. **Order.** Which must come first? What depends on what?
3. **The epic's done-ness.** What single sentence describes the whole thing being finished?

Write the plan back to the user as a numbered list — title + one-line scope per child + dependency arrows. Get explicit approval before filing anything.

---

## Step 4 — File the epic first

Create a tracking issue so child issues can reference it by number.

Title format: `[Epic] <short name of the whole thing>`

Body template:

```markdown
## Summary
[1–2 sentences describing the whole effort and why it matters.]

## Done when
[The single sentence from Step 3.3.]

## Child issues
- [ ] (to be filled in as children are filed)

## Context
[Background, motivation, constraints. Note any reuse decisions that apply across children.]

## Notes
[Out-of-scope, follow-ups, open questions for the whole epic.]
```

Labels: `feature`, `epic`, plus the priority label. Create the `epic` label if missing:
```bash
gh label create "epic" --color "5319e7" --description "Tracking issue for a multi-issue effort"
```

File with `gh issue create` and capture the returned issue number — call it `EPIC#`.

---

## Step 5 — Sequential child invocations

For each child in the planned order, re-enter `pm-penny-feature` (do not try to file children directly from the gate — go through the normal feature flow so discovery, mockups, and preview all run). Pass the following `epic_context` blob into the next invocation:

```yaml
epic_context:
  epic_issue: <EPIC#>
  epic_title: "<title without the [Epic] prefix>"
  siblings: [<list of child issue numbers filed so far, in order>]
  position: "<n>/<total>"
  this_child:
    title: "<planned title for this child>"
    scope: "<one-line scope from the plan>"
  depends_on: [<list of sibling issue numbers this one needs first>]
```

The child invocation of `pm-penny-feature` will:
- Skip the scope gate (because `epic_context` is set).
- Run normal feature discovery, but seed the title and scope from `this_child`.
- Append to the issue body's `## Context` section:
  > Part of epic #`<EPIC#>` — `<epic_title>`. Position `<n>/<total>`. Depends on #`<each in depends_on>`. Siblings: #`<each in siblings>`.
- After `gh issue create` returns the new child number `CHILD#`:
  1. Append `CHILD#` to `siblings` for the next invocation.
  2. Update the epic's `## Child issues` checklist:
     ```bash
     gh issue edit <EPIC#> --body "$(updated body with - [ ] #CHILD# added)"
     ```
     (Read the current body first with `gh issue view <EPIC#> --json body -q .body`, append the line, write it back.)
  3. Report the child issue back to the user, then ask via AskUserQuestion whether to proceed to the next child, pause, or stop.

PR linking comes for free: each child issue says "Part of #EPIC", and when Feature Frank opens a PR with `Closes #CHILD`, GitHub threads the PR ↔ child ↔ epic automatically. Do not invent a separate PR-linking mechanism.

---

## Step 6 — When all children are filed

Post a final summary in chat:
- Epic issue link.
- Ordered list of child issue links with their one-line scopes.
- Any deferred / out-of-scope items the user dropped during planning.

Do **not** close the epic — Feature Frank and Deployer Danny close it when all children ship.
