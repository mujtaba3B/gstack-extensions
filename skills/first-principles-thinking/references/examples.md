# Worked examples

Read this file when you want to see the seven-step walk executed end-to-end on a concrete problem. Two examples ship: one with a real numeric goal and a real hard-floor (SpaceX), one with a real numeric goal whose binding constraint is a hard-floor on actors rather than materials (Neuralink). Together they cover the two cases the skill is most often used to handle. If you are walking a problem whose shape resembles neither, do the walk anyway; the framework does not require matching a worked example.

## Example 1: SpaceX rockets

1. **Goal.** Humans living on Mars (binary endpoint). The sub-goal that unlocks it: launches cheap enough that round-trip Mars missions are economically feasible.
2. **Success signal.** A booster lands, gets refueled, and launches again the same week; cost per kg to LEO drops by an order of magnitude.
3. **Hard constraints.** Raw materials cost (~$7M at the time). Physics of escape velocity. Regulatory clearance for launches.
4. **Assumed constraints.** (a) Rockets are single-use. (b) Aerospace must be built by traditional contractors. (c) Each part must be sourced from a separate specialty vendor.
5. **Current path.** $20M/launch via traditional aerospace contractors with disposable boosters. "Why" = how the industry has always done it.
6. **Constraint-class attacks.**
   - *Attack the assumed-constraint "single-use"* => reusable boosters that land vertically.
   - *Attack the actor "traditional contractors"* => vertically integrate; build engines, avionics, software in-house.
   - *Attack the unit "one part per vendor"* => mass-produce identical components (Raptor engine commonality).
7. **Pressure-test.** Traditional contractors exist partly for real reasons: certification, insurance, supply-chain redundancy. Those are tractable when you accept upfront investment in your own certification track. Reusable boosters cost more per first launch (heavier, more complex) and need refurb infrastructure, but those costs amortize over flights. Surviving reframes: all three, with phased rollout.

## Example 2: Neuralink surgeons

1. **Goal.** 10,000 implants in living humans (numeric).
2. **Success signal.** 10,000 patients with safely installed, functioning implants within the target timeframe; surgical complication rate at or below baseline neurosurgery norms.
3. **Hard constraints.** Total population of qualified neurosurgeons globally is a small number (low five figures, working other things). Skull anatomy. FDA approval pathway.
4. **Assumed constraints.** (a) Implantation requires a human surgeon. (b) Each implant requires bespoke per-patient planning. (c) The procedure must look like existing neurosurgery.
5. **Current path.** Industry default: a trained neurosurgeon performs each procedure.
6. **Constraint-class attacks.**
   - *Attack the assumed-constraint "human surgeon required"* => build a surgical robot that performs the implantation; surgeon only supervises.
   - *Attack the goal scale (lower to 100 elite cases)* => REJECTED at pressure-test, violates the goal.
   - *Attack the unit "bespoke per-patient planning"* => standardize the procedure to within a narrow envelope so robot software handles the variation.
7. **Pressure-test.** The robot has real risks: training data, regulatory novelty, failure modes that surgeons handle by judgment. But those are tractable engineering problems. The "use more surgeons" path is genuinely not tractable: you cannot manufacture neurosurgeons at the required rate. Surviving reframes: robot + standardized procedure.
