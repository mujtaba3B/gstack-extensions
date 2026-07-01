# qa:plan CHANGELOG

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
3.1.0 -> 3.2.0, eng plugin 2.5.0 -> 2.5.1 (comment only).

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
