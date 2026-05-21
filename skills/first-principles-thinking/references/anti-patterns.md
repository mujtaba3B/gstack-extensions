# Anti-patterns

Read this file before generating output for steps 3 (hard constraints), 6 (constraint-class attacks), or 7 (pressure-test). These are the failure modes this skill is most likely to produce. If you catch one in your own output, surface it explicitly rather than papering over it.

- **False floors.** Inventing a clean-sounding baseline ("minimum reviewer time is 30 seconds") when the real constraint is trust, attention, coordination, or incentives. If you cannot name the actual physics / economics / math of the floor, do not include one. Step 3 is optional for a reason.
- **Numeric fetish.** Distorting a qualitative goal ("a code review experience reviewers actively want to use") into a shallow metric ("median review latency") just to get a number into step 1. The number is not the point; the crisp endpoint is.
- **Gap theater.** Calling out a floor-vs-current gap that has no concrete attack on it. A profound-looking delta that does not produce a reframe is just rhetorical theater. If step 3 does not feed step 6, drop step 3.
- **Reframe homogeneity.** Three reframes that are all the same constraint class (paraphrases) is a *failed step 6*, not a successful one. Surface it as a failure ("I can only find one real class of attack here") rather than padding the list.
- **Dogma misses.** The most common dogma is the *goal itself*, not the implementation. Always check whether step 1's goal is an assumption inherited from the current frame. If you skip this, the reframe will be cosmetic.
- **Skipping pressure-test.** Step 7 is mandatory. A reframe without a real-reason check is contrarianism, not first-principles thinking. The pressure-test is what separates the Neuralink robot from "we do not need pilots".
- **Artifact overreach.** Do not auto-write to any file. Chat first; ask before writing. Even an "obviously useful" appendix to a plan doc is a write the user did not approve.
- **Pretending to know.** If you do not have enough context to propose a credible goal or current path, say so and switch to Deep mode (one question at a time). A confidently wrong reframe wastes more time than the question would have.
