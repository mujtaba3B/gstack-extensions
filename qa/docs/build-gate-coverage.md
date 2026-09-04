# What the QA-plan build gate does and does not intercept

The build gate enforces one rule: **approve the plan, then build.** On a feature
branch in a governed repo, application source must not be written until
`/qa:plan` has produced a human-approved stamp.

It is implemented as **two hooks**, because one event class was never enough.
This page is the exact statement of their combined coverage, including the parts
that are not covered. A gate that claims coverage it does not have is worse than
one whose limits are written down.

| | Gate 1 | Gate 1b |
|---|---|---|
| Script | `qa-plan-build-gate.sh` | `qa-plan-bash-build-gate.sh` |
| Event | `PreToolUse` on `Edit`, `MultiEdit`, `Write` | `PostToolUse` on `Bash` |
| Decides from | the target `file_path` | what the repo observed changing |
| Timing | **before** the write | **after** the write |
| Effect | the write does not happen | an interrupt; the write stands |

## Why there are two

Gate 1 shipped matching `Edit|MultiEdit|Write` only. Source written through Bash
reached no gate at all: the single Bash-matched hook was `qa-plan-pr-gate.sh`,
which guards `gh pr create`, a completely different moment.

Observed on 2026-09-04 in `~/dev/tooling/local-bin`, branch
`mu-agents-terminal-default`: an agent edited three tracked source files
(`skills/mu-agents/scripts/probe.py`, `inventory.sh`, `render.py`) using
`python3 - <<'PY'` heredocs, and nothing fired. The gate spoke up only on the
fourth edit, which happened to use the `Write` tool for a new file, and blocked
correctly with `[wrong-branch]`. Its message was accurate. Its coverage was not.

This is not an exotic route. Under bypass-permissions mode the harness instructs
agents to prefer Bash heredocs and `sed` over the edit tools, so for at least one
live configuration the ungated route was the **default** route. A second session
on this machine independently confirmed it the same evening, having written
source that way all session.

## Why gate 1b observes instead of parsing

The obvious fix, adding `Bash` to gate 1's matcher and pattern-matching the
command, does not work, and the incident is the proof.

To block before the write you must decide, from the command string alone, whether
arbitrary shell writes tracked source. The observed case is precisely the
undecidable one: the write lives inside an interpreter's source text, at a path
that may be computed, read from `argv`, or built in a loop. A shell-shape matcher
catches `sed -i`, `tee`, and `cat > f`, for which there is no incident, and
misses the heredoc, for which there is. It also cannot resolve `"$VAR"`, because
`PreToolUse` receives the raw, unexpanded command string.

So gate 1b never looks at the command. It compares what the repo reports as dirty
against a snapshot from the previous call. That is exact and blind to mechanism.

## Covered (gate 1b), with no special case for any of them

Every one of these lands identically, because none of them is recognised as
itself:

- heredoc-fed interpreters: `python3 - <<'PY'`, `node`, `ruby`, `perl`
- inline interpreters: `python3 -c`, `node -e`, `ruby -e`, `perl -pi -e`
- shell redirection: `cat > f`, `>>`, `tee`, `jq ... > f`
- in-place editors: `sed -i`, `ex`, `patch`, `git apply`
- file movement: `cp`, `mv`, `install`
- indirection: `eval`, `base64 -d | sh`, `xargs`, a `Makefile` target, or any
  script the command merely invoked
- a write by a background process the command started (caught on the next call,
  since the comparison is against stored state rather than against this command)
- **deletions** of source files, which are mutations too

## Not gated, deliberately

- **Reading anything.** Never gated, by either hook. Investigate freely.
- **Docs, config, tests, fixtures, `.git/`.** Both gates share one classifier,
  `qpg_path_needs_plan`, so they cannot drift apart on what "source" means.
- **Anything the repo ignores.** Gitignored build output is invisible to the
  observation, for free.
- **Anything outside the repo.** `/tmp`, the session scratchpad, `~/.claude`,
  `~/.gstack`, and log files are all outside and therefore never seen.
- **Base branches** (`main` by default) and **`spike/` branches**, matching
  gate 1.
- **A branch with a valid approval stamp.** Gate 1b short-circuits before it
  observes anything, so an approved branch pays almost nothing per call.

## Known limits of gate 1b, stated rather than implied

1. **It interrupts; it does not prevent.** `PostToolUse` runs after the tool. The
   write has happened, and the hook never reverts anything on its own. The block
   message says so explicitly. What this buys is an immediate interrupt naming
   the files: on the 2026-09-04 incident, a block at file #1 instead of file #4.
   The hard invariant is unaffected, because `qa-plan-pr-gate.sh` still refuses
   `gh pr create` on an unstamped branch, so nothing reaches a PR unplanned.
2. **One repo per call.** It resolves the repo the same way the PR gate does
   (a leading `cd`, else the session cwd). A single command that writes into a
   *different* repo is not seen.
3. **The first call on a branch establishes a baseline and never blocks.** This
   is required, not a gap: judging absolute dirty state would block every Bash
   call on an already-dirty branch, a status listing and `ls` included, which is
   a gate the human removes on day one. Only a change *this* call introduced is
   attributable to it.
4. **A write reverted to byte-identical content within one command is invisible.**
   Correct behaviour, not a hole: there is no net change.
5. **Degraded comparison is possible and is logged.** With no `sha256` tool, or
   with more than 200 dirty source paths, it falls back to comparing path lists
   rather than content digests, which can miss a repeat write to an
   already-dirty file. It writes `delta-degraded(<reason>)` to
   `~/.claude/qa-plan-gate.log` when it does; it never silently stops checking.
6. **Neither gate is adversary-proof, and neither claims to be.** Both fail open
   on a missing dependency, and a shell outside Claude Code is invisible to any
   hook. These are accident-guards for agents doing ordinary work.

## Where the decisions live

The allow/block decision is three pure functions in `qa-plan-gate-lib.sh`
(`qpg_status_source_paths`, `qpg_snapshot_delta`, `qpg_bash_build_disposition`),
each covered by a truth table in `hooks/tests/qa-plan-bash-build-gate.bats`. The
hook script does I/O only. That split is a repo rule, not a preference: an inline
`&&` chain in an I/O script can only ever be hand-verified, and this repo has
been bitten twice by a guard that quietly stopped guarding.

The suite is mutation-controlled. Deleting any single arm of
`qpg_bash_build_disposition`, the source classification, the already-seen check
in the delta, or the snapshot writer's clean-tree fix makes it go red.
