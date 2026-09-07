# What the QA-plan build gate does and does not intercept

The build gate enforces one rule: **approve the plan, then build.** On a feature
branch in a governed repo, application source must not be written until
`/qa:qa-plan` has produced a human-approved stamp. (That is the registered skill
name. Much of this plugin's older prose, including `qpg_block_advice`'s remedy
strings, still says `/qa:plan`, which does not resolve; fixing that everywhere is
a separate change rather than something to bury in this one.)

It is implemented as **two hooks**, because one event class was never enough.
This page is the exact statement of their combined coverage, including the parts
that are not covered. A gate that claims coverage it does not have is worse than
one whose limits are written down, so where a claim here was found false during
review it has been replaced with the measurement, not softened.

| | Gate 1 | Gate 1b |
|---|---|---|
| Script | `qa-plan-build-gate.sh` | `qa-plan-bash-build-gate.sh` |
| Event | `PreToolUse` on `Edit`, `MultiEdit`, `Write` | `PostToolUse` **and `PostToolUseFailure`** on `Bash` |
| Decides from | the target `file_path` | what the repo observed changing |
| Timing | **before** the write | **after** the write |
| Effect | the write does not happen | an interrupt; the write stands |
| Knows who did it | yes, the tool call names the file | **no**, see limit 2 |

## Why there are two

Gate 1 shipped matching `Edit|MultiEdit|Write` only. Source written through Bash
reached no gate at all: the single Bash-matched hook was `qa-plan-pr-gate.sh`,
which guards `gh pr create`, a completely different moment.

Observed on 2026-09-04 in `~/dev/tooling/local-bin`, branch
`mu-agents-terminal-default`: an agent edited three tracked source files
(`skills/mu-agents/scripts/probe.py`, `inventory.sh`, `render.py`) using
`python3 - <<'PY'` heredocs, and nothing fired. The gate spoke up only on the
fourth edit, which happened to use the `Write` tool, and blocked correctly with
`[wrong-branch]`. Its message was accurate. Its coverage was not.

This is not an exotic route. Under bypass-permissions mode the harness instructs
agents to prefer Bash heredocs and `sed` over the edit tools, so for at least one
live configuration the ungated route was the **default** route.

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

So gate 1b never looks at the command, except to find a leading `cd`. It compares
what the repo reports as dirty against a snapshot from this session's previous
Bash call.

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
- **deletions** of source files, and a **`git mv` out of the source tree**, since
  both sides of a rename are classified
- **a command that writes and then FAILS.** `PostToolUse` fires only for a
  successful tool call, so `sed -i src/app.py && npm test` with a failing test
  wrote source and the gate never ran. `PostToolUseFailure` is registered too;
  verified on CLI 2.1.261 that a non-zero Bash call fires it.

## Not gated, deliberately

- **Docs, config, tests, fixtures, `.git/`.** Both gates share one classifier,
  `qpg_path_needs_plan`, so they cannot drift apart on what "source" means.
- **Data and build artifacts** (`.csv`, `.png`, `.log`, `.db`, `.sqlite3`,
  archives, fonts, media, `.DS_Store`). Nobody builds by writing a PNG, and
  gate 1b's input is every path the tree reports rather than a file the agent
  named. Without this carve-out, measured against the real `~/dev`, a repo whose
  job is scraping had 15 dirty paths that were all `.html`/`.csv`, and
  `make | tee run.log` drew a block. That is the false-positive class that gets a
  gate deleted.
- **Anything the repo ignores.** Gitignored build output is invisible for free.
- **Nested repositories.** A linked worktree (this repo puts them under
  `.claude/worktrees/`), a submodule, or a parked clone arrives as one collapsed
  directory entry that the observation drops. Source inside belongs to that repo
  and is gated by that repo's own hook.
- **Anything outside the repo.** `/tmp`, the session scratchpad, `~/.claude` and
  `~/.gstack` are outside and never seen. Note this is about LOCATION, not about
  being a log: an unignored `server.log` *inside* the repo is seen, and is
  carved out by the artifact rule above rather than by being outside.
- **Base branches** (`main` by default) and **`spike/` branches**, matching gate 1.
- **A branch with a valid approval stamp.**

## Known limits of gate 1b, stated rather than implied

1. **It interrupts; it does not prevent.** `PostToolUse` runs after the tool. The
   write has happened, and the hook never reverts anything. What this buys is an
   immediate interrupt naming the files instead of nothing at all.
2. **It does not know that the command you just ran is what changed the files.**
   It knows the dirty-source set differs from this session's previous
   observation. A human editing in their editor, a background process, a
   `git stash pop`, a `merge` or a `rebase` all surface on the next Bash call,
   including a read-only one. The block message says "changed since this
   session's previous Bash call" for exactly this reason, and warns that a git
   tree operation may be a false alarm, because the earlier "undo it yourself"
   advice destroys work after a stash pop.
3. **A write that is COMMITTED or STASHED inside the same Bash call is not seen.**
   `python3 edit.py && git add -A && git commit` leaves a clean tree, so there is
   no delta, no block, and no later call notices. The gate observes the working
   tree, not the commit graph. This is the largest remaining hole. The backstop
   is that `qa-plan-pr-gate.sh` still refuses `gh pr create` on an unstamped
   branch and merge-clearance still requires a QA posture at merge.
4. **The first call of a session on a branch establishes a baseline and never
   blocks.** Judging absolute dirty state would block every Bash call on an
   already-dirty branch, `ls` included, which is a gate the human removes on day
   one. Only a change observed since this session's own previous call is
   attributable to it. A branch switch, and switching away and back, likewise
   re-baseline.
5. **A write reverted to byte-identical content within one command is invisible.**
   Correct behaviour, not a hole: there is no net change.
6. **Comparison degrades above 200 dirty source paths, or with no sha256 tool.**
   It falls back to comparing path lists rather than content digests, which can
   miss a repeat write to an already-dirty file. It writes
   `delta-degraded(<reason>)` to `~/.claude/qa-plan-gate.log` when it does. The
   mode is recorded in the snapshot header, so crossing the threshold
   re-baselines quietly instead of reporting every dirty path at once, which it
   used to do (a bare `ls` blocking on 200 files).
7. **A leading `cd` retargets the check, and can disable it for that call.**
   `cd /tmp && ...` resolves to a non-repo and the call exits without observing.
   Only the command's FIRST LINE is scanned, so a `cd` inside a heredoc body no
   longer retargets it, which it used to.
8. **Writes through neither Bash nor Edit/Write are covered by neither gate.**
   `NotebookEdit` and MCP filesystem tools are surfaced only later, on the next
   Bash call, and attributed to it per limit 2.
9. **Concurrent sessions.** State is keyed per session, so one session no longer
   eats another's delta (that inversion blocked the innocent session and never
   blocked the writer). Each session is told once about a change any of them
   made, which is intended: a shared checkout is shared. The cost of that keying,
   stated plainly: a NEW session's first Bash call baselines against whatever it
   finds, so a write made in that first call is allowed where a single shared
   snapshot would have caught it. That trade is deliberate (the inversion was
   worse than the window) but it is a widening of limit 4, not free.
10. **An unwritable git dir degrades to a temp-directory snapshot.** If `$GITDIR`
    cannot be written, state moves to `$TMPDIR` so it can still advance. Without
    that, one unwritable directory produced either an infinite block storm (with
    a prior snapshot) or a completely disabled gate (without one), depending on a
    file that may or may not exist. Both were reproduced. Once a fallback exists
    it is preferred until swept, so the gate keeps working; losing `$TMPDIR` on
    reboot costs one baseline.
11. **Neither gate is adversary-proof, and neither claims to be.** Both fail open
    on a missing dependency, and a shell outside Claude Code is invisible to any
    hook. These are accident-guards for agents doing ordinary work. Every
    fail-open path this hook controls is logged, so a gate that has stopped
    gating is visible rather than merely absent. Look in **both**
    `~/.claude/qa-plan-gate.log` (this gate: `FAIL-OPEN(jq-missing)`,
    `(payload-parse)`, `(libs-missing)`, `(status-failed)`,
    `(safe-directory-refusal)`, `(git-missing)`, `(delta-compare-failed)`, plus
    `snapshot-write-failed`, `snapshot-fallback`, `hash-skipped`,
    `stamp-unreadable`) and `~/.claude/gate-policy.log` (policy-level fail-opens,
    which disable every gate at once and are written by `gate-policy-lib.sh`).
    Two exceptions cannot log by construction: a hook killed by its own timeout,
    and a machine with no writable config directory at all.

## Cost

Measured on this laptop, per Bash tool call, at the 2026-09-05 implementation.
**The cost tracks the number of dirty source files, not the stamp**:

| dirty source files | unstamped | stamped |
|---|---|---|
| 0 (clean tree) | ~104 ms | ~115 ms |
| 25 | ~370 ms | (same) |
| 50 | ~633 ms | ~652 ms |
| 200 (the degrade cap) | ~2.3 s | (same) |

An earlier revision was roughly 7x worse (~4.9 s at 50 files, ~14 s at 200)
because the delta forked two processes per dirty path. Do not restore the
per-line `grep`.

**A stamped branch is NOT cheaper, and this page has now been wrong about that
twice.** First it said an approved branch "pays almost nothing per call", which
measurement contradicted. The replacement table then said `clean branch, or
stamped branch | ~100 ms`, which measurement contradicted the same way: the
100 ms figure was a CLEAN tree, and the two were conflated. The short-circuit
that once made a stamped branch cheap was deliberately removed, because skipping
the snapshot left it stale for the whole approved window and an expiring stamp
then dumped that entire window as one block. Keeping the snapshot fresh is worth
the cost; pretending the cost is not there is not.

## Turning it off

If it misfires, the escape hatches in order of blast radius:

- A `spike/` branch bypasses the build gate entirely.
- `~/dev/gate-policy.json` -> the repo's `gates` array, dropping `"build"`. Note
  this also disables gate 1, and that file is tracked, so it is a shared change.
- `~/dev/.gates/local.json` -> `gates_off: ["qa-plan"]` is machine-local, but
  disables the whole qa-plan family including the PR gate.

There is deliberately no way to disable gate 1b alone; if you need one, that is a
change to `gate-policy-lib.sh` rather than an undocumented file to hand-edit.

## Where the decisions live

The classification and comparison are pure functions in `qa-plan-gate-lib.sh`
(`qpg_status_source_paths`, `qpg_unquote_path`, `qpg_snapshot_delta`,
`qpg_bash_build_disposition`), each covered by a truth table in
`hooks/tests/qa-plan-bash-build-gate.bats`.

Being precise, because an earlier version of this page overstated it: the hook
script is **not** pure I/O. Three decisions live inline and are covered by
end-to-end tests rather than truth tables: the baseline header match (branch and
mode), the degrade policy (hasher selection and the 200-path threshold), and the
`cd` workdir resolution.

The suite is mutation-controlled: 21 guards were deleted one at a time and the
suite required to go red. 20 do. The PR that introduced this file carries the
table.

**A warning about the harness itself.** `perl -0pi -e 's/x/y/'` without `/g`
replaces the FIRST match, and in a file whose comments quote the code (this one
does, deliberately) that match is often the COMMENT. Such a run reports a
cheerful GREEN while the code was never touched. It happened here: the `-x` in
`grep -vxF` looked unpinned until the mutation was anchored on the piped code
line, at which point it went red across 25 tests. Same shape as the grep-based
test pin this repo was bitten by twice. Verify that a mutation edited code before
believing its verdict.

Honest exceptions, recorded because a green suite is otherwise misread as proof:

- **`qpg_snapshot_delta`'s grep-error return (`return 2`) is NOT pinned.** No
  test makes `grep` fail, so deleting that arm keeps the suite green. It only
  affects whether `FAIL-OPEN(delta-compare-failed)` is logged, never the
  allow/block decision.

- The **first-line-only `cd` extraction** is enforced twice (the jq `split`, and
  the `read` that stops at a newline anyway), so removing either alone changes
  nothing and no single mutation detects it. Removing both reopens the hole.
- The **degrade policy, the baseline header match, and the workdir resolution**
  are inline in the hook and covered end to end rather than by truth tables, as
  noted above.
