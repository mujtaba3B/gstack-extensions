---
name: spike
description: Cheaply prove or disprove the riskiest unknown of a feature before committing to plan and build. Fire this skill whenever the user wants to "spike", "spike this", "spike a feature", "throwaway prove this works", "test the risky part first", "is this even possible", "smallest thing that proves the mechanic", "can we even do X", or otherwise signals they want to skip ahead and stress-test the one thing that could kill a feature before investing in the surrounding scaffolding. Proactively suggest this skill when the user is about to invoke `/plan-eng-review` or `/autoplan` on a feature that has a clear single unknown the plan would be guessing at. Drives a four-phase loop: lock the one-line outcome, write the leanest throwaway code that could falsify it on a `spike/<slug>` branch, escalate via `/second-opinion` (then user) when blocked, land a yes/no verdict in `SPIKE.md` before context compacts. NOT planning (`/plan-eng-review`), NOT ideation (`/office-hours`), NOT post-build QA (`/qa`), NOT change validation (`/verify`). Spike code is explicitly exempt from `karpathy-guidelines` production discipline. Also fires on `/eng:spike`.
---

## Update check (run first)

Before the skill body, check whether the gstack-extensions repo has merged updates this clone has not pulled. Silent unless an upgrade is available; never changes anything:

```bash
~/dev/gstack-extensions/bin/gstack-extensions-update-check 2>/dev/null || true
```

If there is no output, proceed straight to the skill body. If it prints `UPGRADE_AVAILABLE <n> <range>`, tell the user via AskUserQuestion that gstack-extensions is `<n>` commit(s) behind `origin/main` and offer:

- **Upgrade now (recommended)**: run `~/dev/gstack-extensions/bin/gstack-extensions-upgrade`, then continue. It fast-forwards `main` and re-installs symlinks, and refuses safely (printing why) if the clone is not on a clean `main`; relay that message and continue without upgrading if so.
- **Skip this time**: run `~/dev/gstack-extensions/bin/gstack-extensions-update-check --snooze` to suppress the prompt for ~8h (so other skills do not re-ask this session), then continue without upgrading.

Do not upgrade without asking. Ask at most once per session: if you have already prompted (or the user skipped) this session, proceed silently.

# Feature spike

This skill exists for one job: validate the riskiest unknown of a feature with the smallest possible throwaway-ok implementation, before any of the planning, scaffolding, or production-code discipline kicks in.

A spike is not a prototype, not a proof of concept presentation, not a research write-up. It is the smallest piece of running code that can answer one yes-or-no question about whether the proposed feature is even possible at the mechanic level. If the question resolves yes, the spike code is thrown away and the real plan starts. If it resolves no, the feature is rethought or killed before any of the work that would have been wasted gets done.

The point of having this as a skill (rather than just "go build a prototype") is to keep the agent honest: a clear single question, leanest code, escalate when stuck, land a verdict before context runs out. Each of those four moves is something Claude routinely fails to do without an explicit structure.

## When to use

Fire when the user has a feature in mind, names or implies a single riskiest unknown, and wants to test that unknown cheaply before any plan or build. Concrete entry shapes:

- "Can we spike this?" / "Let's spike a feature" / "Spike this first."
- "Is this even possible?" said about a mechanism, integration, or API behavior.
- "Throwaway prove this works before I commit to the full thing."
- "Test the risky part first."
- The user is mid-plan and you notice they are guessing at something that could be cheaply tested instead.

If the user is doing ideation with no specific feature in mind, fire `/office-hours` instead. If the user already has a plan and wants to lock execution details, fire `/plan-eng-review` instead. If the user wants to validate a change they already shipped, fire `/qa` or `/verify` instead. Boundary table below has the full discrimination.

## What this skill is NOT

| Looks like | Actually use | Why |
|---|---|---|
| Brainstorm new product ideas | `/office-hours` | No specific feature yet, no risky unknown to test |
| Lock in the execution plan for a feature | `/plan-eng-review` | Planning, not risk discovery; assumes feasibility |
| Run the full review gauntlet on a plan | `/autoplan` | Same as plan-eng-review, scaled up |
| Generate visual UI variants | `/design-shotgun` | Visual exploration, not code mechanics |
| Test the feature after it is built | `/qa` | Post-build, full implementation expected |
| Confirm a specific change behaves as intended | `/verify` | Validating something that exists, not discovering whether it can exist |
| Write production-quality code | follow `karpathy-guidelines` | Spike code is explicitly exempt; see Phase 2 |

If the user is in two of these categories at once (ideating AND wants to test one risky bit), do the spike first; ideation can resume after the verdict lands.

## The four phases

### Phase 1: Lock the outcome

Force a one-line goal of this exact shape:

> I will know **X** if **Y**.

Where X is a binary state ("injection into the messages.google.com reply box works", "the new pricing API returns the field we need", "the LLM can summarize this voice consistently") and Y is the observable that decides it ("the Send button enables after the injection sequence runs", "the API response contains `effective_unit_price` for plan ID 42", "five sample texts in my voice come back without me wanting to rewrite them").

Rules:

- If the user's invocation already contains a clean one-liner, accept it, restate it back in the canonical form, and proceed to Phase 2.
- If the outcome is vague ("see if this works", "try the new approach"), ask one question (use `AskUserQuestion` when the answer is castable as 2-4 discrete options, the fallback heading+bold pattern otherwise) to extract the binary X and the observable Y. Do not move forward with a vague goal. A spike that does not know what it is testing is just unsupervised coding.
- Resist the urge to broaden. If the user says "I will know if we can inject the draft into the reply box", do not silently expand to "and also verify Send fires the right RCS event". Two outcomes is two spikes. Sequence them.

The one-line outcome becomes the spike's name (kebab-case slug, e.g. `inject-draft-into-messages-reply-box`). The branch is `spike/<slug>`.

### Phase 2: Prepare isolation and open the ledger

Before writing any spike code, run a repo hygiene gate. Check `git status --short`.

- **Clean tree:** `git checkout -b spike/<slug>`. Record the starting branch and commit in SPIKE.md (next step).
- **Dirty tree:** do not silently stash. The default move is a worktree: `git worktree add ../<repo>-spike-<slug> -b spike/<slug>`. This keeps the user's in-flight work physically separated and means switching branches mid-spike is impossible by construction. If a worktree is impractical (the user's stack does not work cross-directory), ask once whether to (a) stash and continue on a branch, (b) wait and come back when committed, or (c) abort.

**Immediately after isolation, write the SPIKE.md stub** at the spike root. Treat it as a live ledger you update as the spike progresses, not as a writeup you create at the end. This is the most important rule in this skill: a SPIKE.md that exists from minute one cannot be lost to context compaction, premature stop, or over-exploration. The structure is in Phase 4; create the file with the outcome line, starting branch+commit, and verdict set to `INCONCLUSIVE` right now. Update the verdict and findings sections as you go.

The first line of SPIKE.md is a load-bearing marker:

```
THROWAWAY SPIKE: production guidelines intentionally suspended. Do not refactor, abstract, harden, test, or document beyond what is needed to answer the spike outcome. Do not promote this code directly to production.
```

This is the visible on-disk signal that `karpathy-guidelines` is OFF for everything on this branch. A future agent landing in this session sees the marker before it sees the code and knows not to "clean it up". For spike code that has to live inside an existing file (a quick endpoint on a real backend), wrap the additions with `// SPIKE ONLY` and `// /SPIKE ONLY` comments so the marker travels with the code.

Now write the leanest code that exercises the mechanic in Y. Spike code rules (these are the opposite of normal production rules; that is intentional):

- **Hardcode unless configurability is itself the unknown.** If the spike is "does the API accept this shape", a hardcoded payload is correct. If the spike is "does the API behave differently across N tenants", a tiny loop is correct because variation IS the question. Default to hardcoding; widen only when the variation is load-bearing for Y.
- **No tests.** The spike itself is the test.
- **No error handling.** If something throws, you learn from the traceback. Wrapping it in try/except just hides the answer.
- **No abstractions.** Three copy-pasted lines is correct here. A helper function is over-engineering.
- **No types beyond what the language forces.** No interfaces, no protocols, no generic parameters.
- **No docs except SPIKE.md.** The code is throwaway; the ledger is the documentation.

Pick the smallest scope that actually exercises Y. If Y is "the Send button enables after the injection sequence runs", do not also build a server-side draft endpoint that returns real content. Hardcode the draft string. The endpoint is a different spike if it is risky at all; usually it is not.

When the spike has to touch real files in the target repo, list those edits in SPIKE.md's "Reproducing artifact" section as you make them, so the cleanup at verdict is mechanical. Where possible, prefer `spikes/<slug>/` as a directory at the repo root for new files; this keeps the spike physically grouped.

### Phase 3: Escalate when blocked

A "block" is the second consecutive attempt at the **same blocking predicate** that did not move the spike forward. The predicate is the named thing preventing progress, not the surface error string. Examples:

- Same wall: "cannot authenticate" after two credential paths. The credentials differ, the symptom is the same; both attempts hit the same predicate.
- New wall: auth succeeds, schema validation fails. Different layer, different predicate; the counter resets.
- Same wall in disguise: "the React-aware setter does not fire input events that React acknowledges" after trying two event-construction patterns. Different code, same predicate.

An "attempt" is a materially different tactic that could plausibly remove the named blocker. A rerun is not an attempt. A syntax tweak is not an attempt. Two attempts means two genuinely different angles, both failed.

Before escalating, write a one-sentence blocker statement to the SPIKE.md "What happened" section and to your visible response:

> Blocker: I cannot **<predicate>** because **<observed reason>**, after attempts **A** (one line) and **B** (one line).

If you cannot write this sentence cleanly, you have not actually identified the blocker yet; do one more diagnostic pass before counting it as a block.

Then escalate, in this order:

1. **First, `/second-opinion`.** Pick the model that fits the failure mode:
   - Codex for code-level "why does this not work" / library behavior / language-runtime questions.
   - Gemini for system-design / cross-stack / "is there a totally different way to do this" questions.
   - The panel mode is overkill for a spike; pick one.
   Pass the second-opinion subagent the one-line outcome, the blocker sentence, the smallest reproducing snippet, and what was tried.
2. **Second, ask the user.** Lead with the blocker sentence. Offer the next two things you would try and ask which to pursue, or whether the spike has effectively answered "no".

Never silently grind. Three loops on the same predicate with no escalation is a spike-skill failure mode and should not happen.

### Phase 4: Complete the verdict

By this phase, SPIKE.md already exists. It was created in Phase 2 with the outcome line and `Verdict: INCONCLUSIVE`, and it has been getting updated as findings landed. Phase 4 is the act of completing it, not creating it.

Update the verdict in place to PROVEN, DISPROVEN, or INCONCLUSIVE, fill in any sections still skeletal, and confirm the reproducing artifact section lists every file the spike touched.

Stop conditions (any one of these = land the verdict now, do not keep exploring):

- The outcome question is answered. Interesting new questions discovered during the spike are different spikes; note them in "Next step" and stop.
- The context is visibly getting heavy (long tool result tails, files re-read because earlier reads scrolled out, the harness emits a compaction signal). Set the verdict to whatever the current evidence supports, including INCONCLUSIVE if it is genuinely still open. The live-ledger discipline from Phase 2 means there is always something to land on; an unwritten verdict is a worse outcome than an INCONCLUSIVE one.
- The escalation path in Phase 3 has bottomed out (second-opinion did not unlock it, user does not want to keep going).

The canonical SPIKE.md structure (the stub from Phase 2 grows into this):

````markdown
THROWAWAY SPIKE: production guidelines intentionally suspended. Do not refactor, abstract, harden, test, or document beyond what is needed to answer the spike outcome. Do not promote this code directly to production.

# Spike: <one-line outcome restated>

**Verdict:** PROVEN | DISPROVEN | INCONCLUSIVE
**Date:** YYYY-MM-DD
**Starting branch:** <branch>@<short-sha>
**Spike branch:** spike/<slug>
**Worktree:** <path or "none, same checkout">

## What we tested
One paragraph. The mechanic, the smallest exercising code, what counted as proof (the Y from "I will know X if Y").

## What happened
The actual result. If PROVEN, the observable that decided it. If DISPROVEN, the wall and why it is structural. If INCONCLUSIVE, the blocker sentence from Phase 3 and what would unblock a follow-up.

## Reproducing artifact
Files touched on this branch (paths + one line each). Mark edits to pre-existing files with `EDIT`; new files with `NEW`. The command to run.

## Next step
- PROVEN → invoke `/plan-eng-review` to lock the real execution plan; this spike's findings feed in.
- DISPROVEN → consider `/pm:first-principles` to reframe; the assumed-constraint the spike falsified is now a real one.
- INCONCLUSIVE → narrower follow-up spike. The one-line outcome for that spike goes here.

## Burn
When this writeup is captured (copied into a plan, pasted into a doc, or just absorbed), delete the branch (and worktree if used):
```
git worktree remove <path>      # if a worktree was used
git branch -D spike/<slug>
```
````

## Hand-off

Do NOT auto-invoke the next skill. Suggest it and wait for the user.

- On PROVEN, end with: "Verdict landed. Want me to fire `/plan-eng-review` with this spike's findings as the seed?"
- On DISPROVEN, end with: "Verdict landed. The mechanic does not work because <reason>. Want to `/pm:first-principles` this to find a different angle, or kill the feature?"
- On INCONCLUSIVE, end with: "Verdict landed. Want to run a narrower follow-up spike, escalate to user-side investigation, or shelve?"

## Burn-after-reading

The branch and code are throwaway. `SPIKE.md` is the only thing meant to survive, and even it lives on a throwaway branch so the user has to consciously cherry-pick or copy it to keep it. This is intentional: the spike's value is the *knowledge*, not the code. The code was the experiment; the experiment is over.

Never merge a spike branch to main. If the user asks to "just keep the spike code, it works", that is the moment to push back: the spike code violates karpathy-guidelines on purpose; shipping it is shipping the violations. Suggest a fresh production implementation using the spike as a reference.

## Reference style for the agent running this skill

Keep responses tight. Each phase should produce one short visible update (one or two sentences), then the work, then the next update. The user is watching for the verdict, not for narration. The pm:first-principles skill in this same repo is a good tonal reference for "structured walk, no theatrics".
