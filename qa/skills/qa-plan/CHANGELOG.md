# qa:plan CHANGELOG

## v2.6.0 (qa plugin 3.12.0)

`qa-plan-stamp.sh` can address a worktree other than the process cwd, and a
mis-targeted approval now says where it went.

**The bug.** Every verb resolved the git dir and branch from the PROCESS cwd,
with no way to point it elsewhere, while both minters resolve theirs from the
SESSION cwd. On 2026-09-04 those disagreed: an approval given for a plan in a
linked worktree minted a token keyed to the SESSION's repo and branch, carrying
the other plan's question and digest. `write` in the target found nothing, and
its DIAGNOSIS said the hook "saw a question and declined to mint", which was
false in every clause: the hook had minted successfully, just somewhere else.
The only way to spend the approval was a terminal override run from inside the
target, so `cd` was load-bearing and nothing said so. A second session hit the
same thing independently the same night and misdiagnosed it as a total mint
failure.

**`--worktree <path>`** on `write`, `status`, `clear`, `doctor` and `override`.
It changes WHICH checkout is addressed and grants nothing: per-worktree keying is
unchanged (`--absolute-git-dir`, never the common dir, so linked worktrees still
do not share an approval), and `qpt_token_valid` still requires the token's own
`branch` field to equal the resolved branch. A bats test pins that, and it was
mutation-tested: deleting the branch guard turns it red, restoring it turns it
green. So the flag cannot launder an approval from one branch onto another, which
is the only property worth worrying about here.

**The diagnosis, which is arguably the bigger half.** On `no-token`, the writer
scans sibling worktrees and NAMES the one holding a stray token, then prints the
exact `--worktree` command to spend it. A hit SUPPRESSES the liveness paragraph
entirely, because "the hook declined to mint" is false when the token is visible
and printing both put a confident wrong explanation three lines above the right
one. When no stray is found it says plainly that the scan covers only THIS repo's
worktrees, that the minters key off the session cwd which may be a different repo,
and where to look. That limit is real and stated rather than papered over: no
worktree walk can see a token minted into an unrelated repo.

CodeRabbit caught that the first cut was not actually pasteable, which was the
whole point of the change. `qp_stray_token_report` printed the GIT DIR while
`--worktree` takes the WORKTREE path, and the recovery line was a `<placeholder>`
rather than a command, so the output read as actionable and was not. It now names
the worktree, the token file, and a concrete command, all `%q`-quoted so a path
containing a space or shell syntax cannot break or execute something else when
pasted. Verified by extracting the emitted line from a fixture whose path
contains a space and running it verbatim.

**The break-glass command is now copy-pasteable.** The refusal told the human to
"cd to this repo" and run `qa-plan-stamp.sh`, a bare name on no PATH: the only
runnable copies are the source tree and the versioned plugin cache, so following
the advice produced `command not found` at the exact moment they were blocked. It
now prints the absolute path of the running copy plus `--worktree <toplevel>`, and
no cd is needed.

Not fixed here: the minters themselves still key off the session cwd. Making them
target the repo a plan is FOR is a larger change to a hook that must fail closed,
and it is not needed to unblock the case that keeps occurring.

## v2.5.0

Two coupled defects in the approval path, and one fix for both.

**The companion artifact is now REQUIRED.** Step 4b published "when it seemed
worth it", because the skill kept telling the reader the artifact was a companion
that no gate reads. An agent optimizing for what is load-bearing drew the obvious
conclusion: on 2026-09-04 one skipped the artifact on a 7-line docs change as
disproportionate, disclosed the skip, and the human had to ask where it went.
That was not the first time. This machine's transcripts hold at least five
QA-plan approval modals whose recorded ANSWER is the human asking for the missing
artifact ("Where is the artifact for the QA plan?", "where's the artifact link?",
"why do you keep forgetting to do this?"). Step 4b now states it runs on every
run at every change size, separates the two source-of-truth claims that were
being collapsed (the PR body is authoritative for the GATES, the artifact is
authoritative for the HUMAN at approval time), and narrows the escape hatch to a
genuinely headless run where the `Artifact` tool does not exist, which is the same
run that cannot fire `AskUserQuestion` and therefore cannot be approved at all.

**The approval modal now opens in the same turn as the plan.** Step 6 used to
require the plan render to be turn-final with the `AskUserQuestion` on the
following turn. A turn ends by handing control back, so the modal could not open
until the human sent a message: they saw a plan, no picker, and had to type
something to be asked for the approval the skill had just requested.

The two-turn rule was not superstition and its cause is NOT fixed: the terminal
still drops assistant text sitting mid-turn before an in-turn tool call
(`anthropics/claude-code` #67470 and #75182, both still open, re-checked against
CLI 2.1.260 on 2026-09-04). It was removed only because the first fix supplies a
strictly better guarantee. The artifact is now mandatory, so a durable rendered
copy of the plan exists at a URL before the modal opens, and that URL is carried
in the question text, which is modal content and always renders. If the prose
render is swallowed, the human opens the link from the modal. The URL in the
question is therefore load-bearing: dropping it means restoring the two-turn
split, not slimming the modal.

Two hardenings came out of reviewing this change itself. The artifact is now
the copy the human is pointed at, while the digest still hashes the PR body, so
Step 4b states that the two must carry the same rows and that the page is
refreshed BEFORE the digest is recomputed. And a publish that FAILS (as opposed
to a tool that does not exist) is now an explicit blocked run rather than an
undefined state that could fall through to a modal with no URL.

CodeRabbit caught two things in the first cut. The artifact-alignment rule
contradicted the template's own contract (the page carries NO checkboxes by
design, so it could never literally match the digest input); alignment is now
defined as presentation-only normalization with the checkbox differences named,
and everything else called substance. And the frontmatter promised an artifact
on every run while Step 4b permits a headless run to publish nothing, so the
description now carries that exception.

Verified against the mint path rather than assumed: `.tool_response.answers` is
keyed by the question's full text byte for byte, digest marker included, so the
extra URL line does not disturb the PostToolUse token minter
(`qpt_digest_from_question` matches per line; the answer lookup uses the whole
question string, newlines included). `qa-plan-present-gate.sh` has been an
unconditional allow since v1.8.0, so it does not object to the one-turn shape
either. No hook or lib change was needed.

qa plugin 3.10.1 -> 3.11.0.

## v2.4.1

Correct the one place the 3.10.0 honesty sweep missed.

`doctor`'s override-routes footer still read "(neither is reachable by Claude)",
the exact claim v2.4.0 retracted from the block message, the skill body and both
READMEs after `pty.fork` disproved it. It therefore contradicted the build gate
three lines of output away, in the command someone runs precisely when they are
trying to work out what is true. The footer now distinguishes the routes by
strength: the typed phrase is unreachable by an agent (nothing it does produces a
UserPromptSubmit event), while the terminal route is an accident-guard only. A
test asserts `doctor` emits neither "Claude cannot" nor "neither is reachable",
so it cannot regress the way it just did.

## v2.4.0

Two human overrides, an honest diagnosis, and the removal of a live bypass.

The trigger: on 2026-09-03 a session held a real human approval it could not
spend. The AskUserQuestion minter had been added to hooks.json after that
session started, and hook REGISTRATION is read at session start while script
CONTENT is live immediately, so the gate ran the new logic against a dormant
minter. The stamp writer refused, correctly, and the only documented remedy was
"restart Claude Code". The operator, whose approval was the thing being refused,
asked for a way to give it himself.

- **Two human override routes**, each chained to a signal an agent cannot
  produce. `qa-plan-prompt-override.sh` is a `UserPromptSubmit` hook that mints
  the ordinary single-use token when the human sends exactly
  `qa-plan: I approve this plan` as a whole message: `.prompt` is filled in by
  the harness from typed input, and the model cannot submit a user prompt.
  `qa-plan-stamp.sh override` is the break-glass, requiring a real controlling
  terminal; it needs no hook at all, which is what makes it the recovery for a
  dormant-hook session. Override stamps record `approval_source` of
  `human-prompt-override` / `human-tty-override` and carry an expiry
  (`QPG_OVERRIDE_TTL`, 8h), because they bind to no plan digest and would
  otherwise be standing, drift-immune approvals.
- **A plain `!`-typed command was rejected as the override.** It carries no
  signal distinguishing the human from the agent: measured 2026-09-03, the Bash
  tool has no controlling terminal at all, and neither does a `!` command. A
  sanctioned `qa-plan-stamp.sh approve` would have been a one-word bypass any
  agent could run.
- **Per-verdict block advice** (`qpg_block_advice`). Both gates emitted one
  remedy for every verdict. For `unattested` that advice was actively wrong: the
  operator had already run /qa:plan, and re-running it never clears a stale
  stamp. Each verdict now names its own cure, and `unattested` says to clear
  first.
- **Minter liveness** replaces a guess. The minter drops a per-session
  heartbeat, so the refusal reports whether the hook actually ran instead of
  saying it is "probably not registered" and sending the operator to restart for
  a problem a restart cannot fix. The restart advice is also reordered:
  `bin/install` FIRST, then restart, because the hook set is read from the
  installed copy.
- **`doctor`** reports the stamp verdict and its remedy, the token, liveness,
  version skew between source and installed plugin, and any cached writer that
  predates the token guard.
- **Stale unguarded writers are pruned by `bin/install`, and named in the block
  message.** Every shipped version left a copy of `qa-plan-stamp.sh` in the
  plugin cache, and the pre-#71 ones need no token and record
  `git config user.name`. That is not theoretical: on 2026-09-03 an agent
  blocked by the guarded writer ran the cached 3.8.0 copy and it stamped without
  complaint, reproducing the whole #71 defect a day after the fix shipped. The
  warning now appears in the block itself, which is the moment an agent goes
  looking for another writer.

## v2.3.0

The approval stamp now requires a real human approval (gstack-extensions#71).

- `qa-plan-stamp.sh write` refuses unless a single-use approval token is
  present, and consumes it, so one human click yields exactly one stamp. The
  token is minted only by a new `PostToolUse` hook on AskUserQuestion
  (`qa-plan-approval-token.sh`) when a question with header "QA plan" is
  answered "Approve". That answer is filled in by the harness from a real
  click and cannot be emitted by the model, which is what makes it a root of
  trust. There is no environment override and no `--force`.
- `approver` no longer falls back to `git config user.name`. The writer reads
  git config nowhere; the name reaches a stamp only through a token. Before
  this, an agent-written stamp was byte-identical to a human approval and
  recorded under the human's name.
- `write` takes NO arguments. `--approver` and `--digest` were both removed:
  each was an agent-supplied input to a human-attested record. `--approver` let
  an arbitrary name be recorded under a genuine `approval_source`, and
  `--digest` let an agent approve plan A and stamp the digest of plan B, which
  defeated drift detection entirely.
- The approval binds to the PLAN, not just to the click. `/qa:plan` embeds
  `<qa-plan-digest:HEX>` in the approval question, the minting hook copies it
  into the token, and the stamp's `criteria_digest` comes from the token. A new
  `qa-plan-stamp.sh digest` verb computes it, so the skill never hand-rolls a
  hash. The skill used to `shasum` raw text while the gate hashed NORMALIZED
  text, so one stray newline produced a stamp that could never match and a
  `gh pr create` blocked forever with no way to satisfy it.
- The mint decision is one pure `qpt_should_mint` truth table rather than an
  inline guard chain, per this repo's lib rule. That rule earned itself again:
  the inline version's header check diverged from the lib (byte-exact in jq,
  case-insensitive in the comparator), so a modal headed "QA Plan" minted
  nothing while the writer blamed an unregistered hook.
- A qualified approval is no longer an unqualified one. Label normalization
  strips only `(recommended)`/`(default)`, so `Approve (skip Prod QA)` does not
  mint.
- Stamps carry `approval_source` and `approval_nonce`, and the gates require
  `approval_source` to equal the exact literal `AskUserQuestion`. A stamp
  lacking it ("unattested") is REFUSED at both the build and PR gates, with no
  migration allowance. An earlier cut honored such a stamp when its file
  predated the fix; that bound was keyed on mtime, which the same shell that
  writes the stamp can rewrite, so `touch -t` defeated it in one extra command.
  It only ever existed because a pre-fix branch could not obtain a token while
  the minting hook was unregistered. A branch still carrying a pre-fix stamp
  runs `/qa:plan` and approves once; that is the whole migration.
- Drift is evaluated BEFORE the attestation verdict, so the least-attested
  stamps no longer get the fewest checks.
- The PR gate LOGS when the drift check cannot run (`drift-check-skipped`).
  It could not run on the real `/ship` path at all: `/ship` emits
  `--body-file "$PR_BODY_FILE"` and a PreToolUse hook sees the raw string, so
  the file was unreadable and the check silently no-opped while every test
  passed an already-expanded absolute path. Green suite, dead feature. The
  token-bound digest is now the authoritative binding; this is confirmation.
- The PR gate re-derives the digest of the `## QA` section in the body being
  created and blocks when it differs from the approved one, so a plan edited
  after approval must be re-approved. Tick state is normalized out, so a QA
  driver marking rows done does not invalidate the approval.
- Step 6 of the skill documents the enforced contract. `write` takes NO options:
  the plan digest reaches the stamp through the token, carried as a
  `<qa-plan-digest:HEX>` marker in the approval question and computed by the new
  `qa-plan-stamp.sh digest` verb, never by a hand-rolled hash.

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
