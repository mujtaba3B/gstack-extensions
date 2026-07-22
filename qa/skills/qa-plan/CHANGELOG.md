# qa:plan CHANGELOG

## v2.2.0

Checkbox-free, skimmable companion artifact.

- Template restructure (Mujtaba's 2026-07-22 feedback): terse "Story" /
  "Solution" headings; the Solution and Production-artifacts blocks are bullet
  lists, never paragraphs; the Story block ends with a muted "Linked issue:"
  line (the GitHub issue when one exists, else "none" + provenance); and the
  artifact carries NO checkboxes at all (no Dev-table column, plain-bullet
  Definition of Done). Checkbox state lives only in the PR body's ## QA
  section, which the merge gates read. Step 4b instructions updated to match.

## v2.1.0

Story-first companion artifact.

- The artifact template now opens with three context blocks above the
  Development section: **The story** (the change's user story plus the observed
  problem), **The solution being built**, and **How this plan proves it**
  (numbered bullets mapping the plan's rows to the story's outcome), each with
  its own FILL marker (`STORY` / `SOLUTION` / `PROOF`). Step 4b documents how to
  fill them from the Step 2 success criteria (never invented). Driven by
  Mujtaba's 2026-07-20 feedback: a QA artifact should say what problem is being
  solved and what the solution is before showing any test rows.

## v2.0.0

Readability overhaul + a pointable companion artifact.

- **Split-by-phase layout (replaces the single Template B table).** The `## QA`
  section is now two small tables under `### 🖥️ Development` and `### 🚀 Production`,
  so what gates the merge and what is checked after deploy read apart at a glance.
  Development columns: `✓ | Tester | Check | Expect | Notes` (the `✓` cell is the
  merge-gating `[ ]` checkbox). Production columns: `Tester | Check | Expect | Notes`
  (no `✓` column, no bracket, never gates the merge). Gate-safe: the merge-clearance
  section runs to the next `##`, so the two `###` sub-tables stay inside and the
  checkbox counting is unchanged.
- **ELI5 per phase.** A plain-language `_italic_` line under each phase heading
  explains, jargon-free, how that phase tests the change (Development = proven in a
  safe / preview copy before merge; Production = confirmed live after deploy).
- **Companion Claude artifact (new Step 4b).** /qa:plan now publishes a rendered,
  self-contained, theme-aware view of the plan as a Claude artifact and links it
  from a `📄 Plan view:` line at the top of the PR-body section. Idempotent: re-runs
  update the same artifact in place (via the stored URL). The PR body stays the
  single source of truth the gates read; the artifact is a snapshot companion.
  Template: `references/artifact-template.html`. Added `Artifact` to allowed-tools.
- **Driver avatars in the artifact.** The companion's `Tester` column shows a
  logo-only avatar (name on hover), not a text label: a hand-drawn inline-SVG Claude
  burst on Anthropic clay for `claude`, and inlined GitHub photos for `mutwo` /
  `muthree` / `mufour` / `mujtaba`, with an initials fallback for any other driver.
  The artifact is the leaner view: it drops the QA-driver line, the `Standard (all
  green)` line, and the QA-posture line (all kept in the PR body). Images are inlined
  as data URIs (the artifact CSP blocks external image loads); the PR-body markdown
  keeps plain-text tester names.

## v1.9.0

Readability pass on the Template B table, so the plan reads at a glance:

- **Simple tester names.** The `Tester` column now uses the roster `id` (`claude`,
  `mutwo`, `mujtaba`, `muthree`, `mufour`) instead of labels or handle strings. The
  handle still appears once, in the `**QA driver:**` line above the table.
- **One-line Flow + Expect, plus a Notes column.** `Flow` and `Expect` are each held
  to a single plain-language line; a new **`Notes`** column (six columns total:
  `Phase | Status | Tester | Flow | Expect | Notes`) carries any longer detail and may
  be blank. The literal-`[ ]` prohibition now explicitly covers the Notes cell so the
  merge-clearance QA gate is not tripped by text there.

## v1.8.0

Template B: the `## QA` section is now a compact **table** (one row per acceptance
criterion, a `Phase` column tagging each `DEV` or `PROD`) instead of the old
Development-QA / Production-QA checkbox LISTS. DEV rows carry a `[ ]` checkbox in
their Status cell (merge-gating, flipped to `[x]` when the check passes); PROD rows
carry a `-` hyphen (verified post-deploy, never gates the merge). Routine automated
checks (unit tests, lint/types, CI, `/eng:cr`) collapse into a one-line
`Standard (all green)` header rather than being listed as rows. Definition of Done
stays `- [ ]` bullets.

Presentation changed too: Step 6 now RENDERS the full plan (table + footer)
full-width as a turn-final chat message, THEN fires a slim `AskUserQuestion`
(Approve / Rework it / Skip the gate) with no plan crammed into an option preview.
The approval stamp is still written only on an explicit Approve.

Gate updates: `qa-plan-present-gate.sh` is relaxed to an allow (it no longer
requires a fit-in-box plan summary, the literal DEVELOPMENT QA / PRODUCTION QA
headings, single-select, or a 20x60 size cap in the preview, since the plan lives
in chat now). The eng plugin's `mc_qa_state` (merge-clearance) now reads BOTH the
Definition-of-Done `- [ ]` bullets AND the DEV-row `| [ ] |` table-cell checkboxes
(matches any `[ ]`/`[x]`/`[X]` bracket in the fence-stripped QA section); PROD-row
`-` cells correctly do not count. Old `- [ ]`-list PR bodies still classify
correctly (backward compatible). qa plugin 3.2.0 -> 3.3.0, eng plugin 2.6.1 ->
2.6.2.

## v1.7.0

Decouple the qa plugin (and the eng merge-clearance comment) from the repo
owner's private `~/dev/BUILD-PROCEDURE.md` path, which broke on any other
machine. The two-phase QA-plan approval policy is the plugin's OWN rule, so
every gate comment, gate REASON string, and skill/doc reference now states it
self-containedly instead of citing an external file. For workspaces that DO
keep their own build-procedure doc, a new OPTIONAL `build_procedure_ref` key in
the per-repo `.qa-plan-gate.json` marker lets the build/PR gate REASON append
"(This repo also follows your workspace build procedure: <ref>.)" when set;
unset by default, so the plugin never hardcodes an external pointer. New
`qpg_build_procedure_ref` helper in `qa-plan-gate-lib.sh` (+ 2 bats). qa plugin
3.1.0 -> 3.2.0, eng plugin 2.6.0 -> 2.6.1 (comment only; 2.6.0 landed the
ship-watch-nudge on main first).

## v1.6.0

Bookkeeping fast lane through the ship gates. A new pure classifier
(`qpg_is_bookkeeping`, twinned as `mc_is_bookkeeping` in the eng plugin) lets a
PR whose entire diff is docs (`*.md/.mdx/.markdown/.txt/.rst`) or the cross-host
inventory `where-things-run.json` skip the approved-plan requirement at
`gh pr create` time, and auto-satisfy the `/eng:cr` + QA dimensions at merge
(`merge-clearance` internally forces `--skip-review`/`--skip-qa`). CI and
CodeRabbit stay hard gates; the fast lane is recorded in the clearance checklist,
stamp evidence, and commit status. Fails closed: any one non-allowlisted path
(including app config like `*.json`/`buckets.yaml`) means full ceremony.
Agent-instruction markdown (`SKILL.md` / `CLAUDE.md` / `AGENTS.md`) is excluded
from the allowlist despite ending in `.md`: editing one is a behavior change, not
inert prose, so it must get the full review.

## v1.5.0

The QA-plan gates and the stamp script now ship inside this plugin (`hooks/`), not claude-hooks. The skill writes the approval stamp via the plugin's own `hooks/scripts/qa-plan-stamp.sh` (resolved relative to the skill's base directory) and reads the QA-driver roster from `qa-roster.json` at the plugin root.

## v1.4.0

Step 6 approval presentation is now a contract: the plan is presented inside the `AskUserQuestion` modal as the Approve option's `preview`, a summary hard-capped at 20 lines x 60 chars (change-under-test in 1-2 lines, one line per QA item, literal `DEVELOPMENT QA` / `PRODUCTION QA` headings, QA driver line). The full plan still lives in the PR body. Machine-enforced by the `qa-plan-present-gate.sh` PreToolUse hook (claude-hooks), which blocks a `"QA plan"`-headered question whose preview is missing, oversized, or multiSelect.

## v1.3.0

Two-phase QA plan written into the PR body, ending with human approval and the per-branch approval stamp the QA-plan gates (build / PR / deploy) read.
