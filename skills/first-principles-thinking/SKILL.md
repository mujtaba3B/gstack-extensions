---
name: first-principles-thinking
description: Reframe an in-flight plan, spec, or problem from the goal down so the user can spot when they are optimizing inside an inherited frame instead of attacking the actual goal. Use this skill whenever the user wants to "first principles this", "reframe from first principles", "challenge the assumptions", "Musk this", asks "what's the ultimate goal here", "are we sure this is the right approach", "is there a totally different way to think about this", or otherwise signals they want to step back from the current flow and check whether the goal itself, or the constraints they are treating as fixed, are actually load-bearing. Proactively suggest this skill when the user is iterating inside a plan that seems to assume its own framing (e.g. arguing about implementation details while never naming the ultimate goal, or treating a process step as fixed when the goal could be reached without it). Also fires on `/first-principles-thinking`.
---

# First-principles thinking

This skill drives a structured reframe of whatever the user is currently working on. The point is to interrupt momentum-driven optimization inside an inherited frame and let the user notice if they are solving the wrong problem, or solving the right problem the wrong way because they are treating something as fixed that is not.

It is modeled on two reference cases:

- **SpaceX.** "It costs $20M to launch a rocket" became "the raw materials are $7M, so there's a $13M gap, what's eating it?" That reframe led to reusable boosters, vertical integration, and re-thinking which parts of the traditional aerospace supply chain were load-bearing vs habit.
- **Neuralink.** "How do we scale the surgery?" became "there are not enough qualified neurosurgeons on Earth to hit our goal scale, so a human surgeon cannot be in the loop." That reframe led to building a surgical robot instead of recruiting a surgeon army.

Both moves are the same shape: name the ultimate goal, find the real constraints, notice the assumed constraints, then attack the assumed ones across different classes. The methodology below is the generalized version.

## When to use this skill

Fire when the user wants a goal-first reframe of an in-flight piece of work. The work can be:

- (a) An in-flight conversation or plan in the current session,
- (b) A written plan, spec, or design doc they reference,
- (c) A standalone problem statement they type in fresh.

Detect which one is in play from context. If it is genuinely ambiguous, ask once which artifact to reframe. Otherwise just name it and proceed.

## Operating mode

Default to **Light mode**: you (the agent) infer and propose each step from context, and the user corrects. This is the right default because most sessions already have enough context for a credible first draft, and the user can edit a concrete proposal faster than they can generate one from scratch.

Escalate to **Deep mode** (Socratic, one question per turn, user articulates each step themselves) when:

- The user pushes back on your draft and the disagreement is about substance, not phrasing.
- You genuinely do not have enough context to propose a credible goal or current path.
- The user explicitly asks for it ("walk me through it", "let me think it through", "ask me one at a time").

Do not ask a mode-pick gate question at the start. The user does not yet know what they are choosing between. Start Light, escalate when needed.

## The seven-step walk

Each step is one short section of your reframe. In Light mode, propose all seven in one structured response and invite corrections. In Deep mode, do them one at a time.

### 1. Goal

Lock the ultimate goal. Push for a *concrete endpoint*: a number when the goal is naturally quantitative ("10,000 implants", "$5M ARR"), or a binary endpoint when it is not ("humans living on Mars", "a code review experience that engineers actively want to use"). Reject vague targets like "make X better".

Do not fetishize numbers. If the goal is genuinely qualitative (developer experience, trust, learning), force a *crisp endpoint*, not a fake metric. "Better code review" is too vague. "Reviewers leave a review feeling like they learned something" is a real binary endpoint. "Median review latency under 4 hours" is a number that may or may not actually represent the goal.

### 2. Success signal

How would you know you got there? Name the observable outcome. This is the test that separates a real goal from a slogan. If the only success signal is "we did the thing", the goal in step 1 is still too vague; revise it.

### 3. Hard constraints

Real, non-negotiable limits. Physics, regulation, math, biology, money the user actually does not have.

The "floor" pattern from the SpaceX example (raw materials cost as the irreducible minimum) lives here as an *optional subtype*. Include it only when there is a real physical, economic, or mathematical floor you can name with a credible source. If the problem does not have a meaningful theoretical floor, skip it. **Do not invent one.** A made-up floor is worse than no floor: it produces profound-looking gap analysis that goes nowhere.

### 4. Assumed constraints

Things being treated as fixed but actually are not. This is where most dogma hides.

Include the *goal itself* as a candidate assumed constraint. The strongest reframes often come from challenging the goal, not the implementation. Examples:

- "Code review happens after code is written" is an assumption about *sequencing*, not a law of nature.
- "Each surgery requires a human surgeon" is an assumption about *who acts*, not a law of nature.
- "We need to ship this feature" might be an assumption about *which problem matters*, not a fact.

Name as many assumed constraints as you can credibly identify. Three is a usable minimum; more is better here.

### 5. Current path

What is the user actually doing right now, and why? Capture the *stated reasoning* if it is in the context, not just the actions. The "why" is what gets pressure-tested in step 7.

If the current path is "industry standard" or "what we did last time", say so explicitly. That is the dogma signal.

### 6. Constraint-class attacks

Generate **at least three reframes, each attacking a different class of constraint.** This is the most important step and the easiest to do badly.

Classes to draw from:

- **Attack the goal.** Is the stated goal the real goal, or a proxy for something bigger or smaller?
- **Attack a hard constraint.** Sometimes a "hard" constraint is hard at today's price point or technology level, not in principle.
- **Attack an assumed constraint.** Pick one from step 4 and assume the opposite. ("What if there is no human surgeon?")
- **Attack the sequencing.** What if the steps happen in a different order, or in parallel?
- **Attack the actor.** What if a different agent (robot, AI, customer, partner, no one) does the work?
- **Attack the unit.** Solve for one instead of many, or for many instead of one.
- **Attack the boundary.** What if the system includes or excludes something it currently does not?

The test for a good set of three is **constraint-class diversity**, not surface diversity. "Automate the reviews / improve reviewer assignment / summarize the diffs" sound different but all attack the same class (the implementation of the current path). That is a paraphrase trio and counts as one reframe, not three. If you cannot find three classes that produce a real attack, surface that explicitly and offer the two you have.

### 7. Pressure-test

For each reframe in step 6, ask: where does the *current approach* have a real reason to exist, not just dogma? This step is **mandatory**. A first-principles reframe without a real-reason check is just contrarianism, and produces galaxy-brained recommendations (the Neuralink surgical robot is a good reframe; "we do not need pilots because planes mostly fly themselves" is a bad one).

For each reframe, name:

- The strongest concrete reason the current approach exists (insurance, regulation, customer expectation, hidden coordination cost, etc.).
- Whether that reason is tractable under the reframe, or genuinely blocks it.

A reframe that does not survive the pressure-test is a finding too. Mark it rejected and say why. The Neuralink team did this: "lower the goal to 100 elite cases" is a reframe that the pressure-test rejects because it violates the goal scale.

## Artifact behavior

Default to **chat-only**. The reframe is meant to update the user's thinking, not to litter the working tree with speculation.

After the seven-step walk is done, ask the user which artifact behavior they want:

- If a plan file is referenced in the session, offer to append a `## First-principles reframe (YYYY-MM-DD)` section to that file. Wait for explicit yes.
- If no plan file is in scope, offer to save a `FIRST-PRINCIPLES.md` in the current working directory. Wait for explicit yes.
- Otherwise leave the reframe in chat.

Never auto-write. The cost of polluting a plan file with speculative reasoning is higher than the cost of asking once.

## Reference material

Two sidecar files live in `references/` and load on demand:

- **`references/examples.md`**: two worked end-to-end walks (SpaceX rockets, Neuralink surgeons). Read this when you want to see the seven-step flow executed on a concrete problem, especially when calibrating what a "real" hard constraint vs an assumed constraint looks like, or what constraint-class diversity looks like in step 6.
- **`references/anti-patterns.md`**: failure modes this skill is most likely to produce (false floors, numeric fetish, gap theater, reframe homogeneity, dogma misses, skipping pressure-test, artifact overreach, pretending to know). Read this before generating output for steps 3, 6, or 7. If you catch one of these in your own draft, surface it explicitly rather than papering over it.
