# QA Quincey (`qa` plugin)

QA Quincey is the manual-QA persona. Where gstack's `/qa` sweeps an app looking for any bugs, QA Quincey verifies that **one specific defined flow** does **what the spec or mockup said it should do**, then walks you through every deviation.

This directory is a Claude Code plugin named `qa` (installed from this repo's local marketplace); its skills are invoked namespaced as `qa:<skill>`. The `qa:` prefix coexists with gstack's own loose `/qa` skill: `/qa` and `/qa:browser` are distinct invocations, so there is no collision.

## Skills

| Invocation | What it does |
|---|---|
| `/qa:browser` | Defined-flow LIVE-browser QA. Drives the real running app through the user's persistent agent-browser session (`abrowser`, headed) at click/pixel level, walks the spec (spec/eng docs + Pencil frames) and reports per-assertion Spec compliance, seeds and tears down TAGGED data via the repo's `.gstack/qa-quincey/recipe.yml`, observes at the real surface with an adversarial probe, and ends by stating the `QA_STATUS` posture that feeds the build-time Stop hook and the PR qa-gate CI. |
| `/qa:headless` | Defined-flow QA for backend features with no UI: cron jobs, queue workers, webhook handlers, notifiers, CLIs, ETL/data pipelines. Captures side effects (Slack messages, emails, DB writes, log lines), renders them readably, compares to expected output. |
| `/qa:qa-plan` | Authors the two-phase QA plan (Development + Production) into the PR body before review, recommends a QA driver from `qa-roster.json`, presents the plan for human approval, and writes the approval stamp the QA-plan gates read. Authored before the PR is reviewed. |

QA Quincey will accrete sibling skills over time (mobile, accessibility, performance regression, and so on). They share one identity file (`shared/core.md`) so the persona, report format, and reconcile loop stay consistent across the family.

## Hooks (Quincey's enforcement arm)

The plugin ships its gates in `hooks/hooks.json`; installing the plugin activates them, uninstalling deactivates them. They are active by DEFAULT for git repos under `~/dev`, resolved from the tracked `~/dev/gate-policy.json`; everything else is untouched. (The per-repo `.qa-plan-gate.json` marker files were retired on 2026-09-02, because a machine-local git-ignored file that ARMS enforcement left fresh worktrees and clones silently un-gated. Machine-local opt-outs live in `~/dev/.gates/local.json`.) The effective config's keys are all optional: `base_branches` (default `["main"]`), `gates` (subset of `build` / `pr` / `deploy`, default all three), and `build_procedure_ref` (a free-text pointer to your own workspace build-procedure doc; when set, the build and PR gate block messages append a one-line "this repo also follows your workspace build procedure: <ref>" note, purely informational and never hardcoded by the plugin). All gates fail open on missing dependencies. Path convention: `hooks.json` commands locate entrypoints via `${CLAUDE_PLUGIN_ROOT}`; inside the scripts, sibling libs resolve via `BASH_SOURCE` so the executing copy always binds its own dependencies (the scripts are dual-use: skills, the shim, and the bats suites invoke them without the hook env).

| Hook | Event | What it enforces |
|---|---|---|
| `qa-plan-present-gate.sh` | PreToolUse AskUserQuestion | Gate 0: a `"QA plan"`-headered approval question must carry the fit-in-box plan summary (both phase headings, <= 20x60, single-select). |
| `qa-plan-build-gate.sh` | PreToolUse Edit/Write | Gate 1: no application-source edits on a feature branch until the branch has a `/qa:qa-plan` approval stamp. Docs/tests/config are carved out; `spike/` branches bypass. |
| `qa-plan-pr-gate.sh` | PreToolUse Bash | Gate 2: no `gh pr create` until the branch has an approval stamp. |
| `qa-status-gate.sh` | Stop | A turn that claims coding work is done on a branch with shippable commits must state a QA posture (`dev_verified` / `prod_verified` / `blocked` / a signed skip) with evidence. |
| `qa-plan-approval-token.sh` | PostToolUse AskUserQuestion | Mints the single-use approval token from a real human click on the `"QA plan"` question, and drops a per-session liveness heartbeat. `.tool_response.answers` is harness-filled, so the model cannot forge it. |
| `qa-plan-prompt-override.sh` | UserPromptSubmit | Mints the same token when the human sends exactly `qa-plan: I approve this plan` as a whole message. `.prompt` is harness-filled too, and this route does not depend on the AskUserQuestion hook, so it survives that hook being dormant. Silent by contract (its stdout would be injected into the model's context). |
| `qa-plan-stamp.sh` | (utility) | `write` (token-gated), `status`, `clear`, `digest`, plus `override` (the break-glass: needs a real controlling terminal, which no Claude session has) and `doctor` (explains a block: stamp verdict and its remedy, token, minter liveness, source-vs-installed version skew, and any cached writer predating the token guard). |

Pure decision logic lives in `qa-plan-gate-lib.sh` / `qa-plan-token-lib.sh` / `qa-status-gate-lib.sh`, unit-tested by the bats suites in `hooks/tests/` (run them as individual files).

**Blocked with an approval you already gave?** The block message names the verdict and its specific cure; `qa-plan-stamp.sh doctor` explains the rest. Two routes out belong to the human and are deliberately unreachable by Claude: send `qa-plan: I approve this plan` as a message on its own, or run `qa-plan-stamp.sh override` in a real terminal tab. The second needs no hooks at all, which is what makes it the recovery when a hook is dormant (hook registration is read at session start, so a hook added mid-session stays inert until `bin/install` and then a restart, in that order). Override stamps carry their own `approval_source` and expire after 8h, because they bind to no plan digest.

**Write assertions with `assert_contains` / `assert_missing`, never a bare `[[ ]]`.** Under bats-core 1.13 a failing `[[ ]]` in any position other than the last line of a test body does not fail the test, so such an assertion is a silent no-op. Found by mutation-testing: a deleted guard left every test green. The QA-driver roster is `qa-roster.json` at the plugin root; the real-host Development QA mechanic is documented in `docs/deploy-branch-for-manual-qa.md`.

## How it is wired

`bin/install` installs this `qa/` directory as the `qa` plugin via the repo's local marketplace (a copy lands in `~/.claude/plugins/cache/gstack-extensions/qa/<version>/`). Each skill lives in `qa/skills/<slug>/SKILL.md` and resolves `shared/core.md` relative to its plugin root (parent's-parent of the skill dir). Because the plugin lives in the plugin cache rather than `~/.claude/skills/`, there is no filesystem collision with gstack's loose `/qa` skill.

## Conventions

See `shared/core.md` for the full identity. Quick facts:

- Reports land in `~/.gstack/projects/<slug>/qa-quincey/reports/<feature>-<date>.md` (the `qa-quincey` artifact path is persona-keyed runtime state and is intentionally unchanged by the plugin rename).
- Confirmed happy paths are saved as plans in `~/.gstack/projects/<slug>/qa-quincey/plans/<feature>.md` and replayable on future runs.
- Deviations are categorized: LAYOUT, COPY, COLOR, TYPOGRAPHY, MISSING, EXTRA, STATE.
- Verdicts are PASS, DEVIATIONS, or FAIL.

## See also

- `~/dev/tooling/gstack-extensions/pm/` (PM Penny: writes the issues QA Quincey verifies against, and receives `/pm:bug` handoffs).
- The `design` plugin's `design/references/wireframes-cross-tool.md` (Designer Denise's cross-tool canvas conventions; left-to-right is the flow order QA Quincey reads).
