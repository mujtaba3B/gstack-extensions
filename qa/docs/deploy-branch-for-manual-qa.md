# Deploy a feature branch to a test host for manual QA

The `deploy_branch_for_manual_qa` QA posture (full contract:
[`qa-status-postures.md`](qa-status-postures.md), enforced by
`scripts/qa-status-gate.sh`) names
a real, often-skipped QA activity: deploy the unmerged feature branch to the host
where the code is actually exercised, run the real flow against real data, and only
then call it verified. It exists because automated tests pass on plenty of changes
whose actual bug is user-facing or interactive (a blank card in a review loop, a
broken keystroke, a layout that only renders wrong against production-shaped data).
A unit-test-green `verified` does not prove those. Running the real flow does.

Lean toward this path whenever a change is user-facing or interactive and your only
evidence would otherwise be unit tests.

## Who drives QA: the roster

`DRIVER:` names WHO runs the QA, chosen from the QA roster (`claude-hooks/qa-roster.json`).
The agent RECOMMENDS a driver (a best guess), the human approves or refines it, and the
chosen driver is named **in the PR body with their handle** (e.g. `QA driver: @mutwo-ai`)
so it is unambiguous who is on the hook. The roster ids and their handles:

| `DRIVER:` | kind | handle | when to recommend |
|-----------|------|--------|-------------------|
| `mutwo` | Mu clone | `@mutwo-ai` | **default**: a clone deploys the branch to the real host and drives the flow, records `EVIDENCE:` |
| `muthree` | Mu clone | `@muthree-ai` | when MuThree owns the repo / host |
| `mufour` | Mu clone | `@mufour-ai` | when MuFour owns the repo / host |
| `mujtaba` | human | `@mujtaba3B` | when it needs his taste/judgment or only he holds the live session/data; hand him the command, which ENDS the turn, `dev_verified` after his thumbs-up |
| `claude` | agent (this session) | (no GitHub handle) | when the flow is automatable and this session can deploy + drive it now, records `EVIDENCE:` |

`mufive` (`@mufive-ai`) is excluded: GitHub-flagged / parked.

**Best-guess heuristic.** Default to `mutwo`. Lean to a specific clone when that clone
owns the repo/host (a `mutwo-*` repo handed to `mutwo`). Lean to `mujtaba` when only the
human can judge or has the real data. Lean to `claude` when it is fully automatable and
this session can just run it. Whatever you pick, the human gets the final say.

A clone- or agent-driven run (`mutwo` / `muthree` / `mufour` / `claude`) carries
`EVIDENCE:` of what was observed; a human-driven run (`mujtaba`) hands over the exact
command and ENDS the turn, with `dev_verified` recorded after the thumbs-up. Either way
the turn-ending message carries a `DEPLOYED:` line so the deploy is a recorded decision,
not an improvisation, and the PR body names the driver with their handle.

## It ends the turn, it does not clear the merge

`deploy_branch_for_manual_qa` satisfies the build-time Stop hook (any `QA_STATUS:`
line ends the turn), but it is an INTERMEDIATE posture, not a terminal one. Like
`skip_requested`, the strict per-repo CI qa-gate (`.github/workflows/qa-gate.yml`,
where present) does NOT accept it: that gate only greens on `verified`, `blocked`,
or `skip_approved` in the PR body. This is deliberate and does not weaken the merge
gate: a branch deployed for QA but not yet signed off is not proven, so the PR stays
red until `verified` is recorded after the thumbs-up (`DRIVER: mujtaba`) or alongside
the driver's observation (a clone or `claude`). The posture lets you end a working turn
honestly while leaving the merge correctly blocked on actual verification.
(The full intermediate-vs-terminal posture list lives in
[`qa-status-postures.md`](qa-status-postures.md).)

## Mechanics

### 1. Pick the test host

The test host is wherever the human actually exercises the code, because that is where
the real data lives. For `email-hero` (single-mailbox automation) that is the Mac mini
(`ssh mutwos-mac-mini`): the real triage data (`runs/triage-rules.json`,
`runs/triage-decisions.jsonl`) is on the mini, and the laptop checkout has none of it.
A laptop deploy would have nothing to QA against. Generalize: deploy where the data is.

### 2. Deploy the branch on the host checkout

```bash
# on the host, in the repo checkout
git fetch origin <branch>
git checkout <branch>
```

With an **editable install** (`pip install -e .`, `npm link`, or equivalent) the CLI
entry point runs straight from the working tree, so the branch's code is live with no
reinstall. Smoke-test before handing off:

```bash
python -c "import <package>"     # import cleanly?
<cli> --help                     # entry point runs from the branch?
```

### 3. Drive it, or hand it off

- clone / `claude` driver (`mutwo` / `muthree` / `mufour` / `claude`): run the real flow
  (`<cli> <real-subcommand>`), inspect the output or drive the UI, and capture what you
  saw as `EVIDENCE:`.
- `DRIVER: mujtaba`: hand over the one command to run, e.g. `run: email-hero feedback`,
  and end the turn.

### 4. Caveat: shared-checkout long-running daemons

If the same checkout backs a long-running daemon (launchd / systemd), be aware that the
daemon keeps its **old** code in memory until it restarts. A restart it does not control
(a renew kickstart, a crash, a scheduled relaunch) will pick up the branch. On the mini
the `email-hero watch` launchd daemon (`com.emailhero.watch`) runs from the same checkout,
so switching the checkout to a branch means the next watch restart runs branch code. For
`email-hero` PR #27 the branch was a strict improvement, so this was acceptable; call out
the risk explicitly when it is not, and consider a dedicated checkout for branch QA when a
daemon must keep running released code.

### 5. Revert the host to main after merge

This step is mandatory or hosts silently drift onto stale feature branches:

```bash
git checkout main
git pull --ff-only
```

Now the host tracks deployed `main` again. If a daemon was running branch code (step 4),
restart it after the revert so it picks the merged code back up.

## Precedent

`email-hero` PR #27 fixed a blank-card bug in the interactive `email-hero feedback` review
loop. Automated tests passed and one live read-only fetch ran, so the gate was satisfied
with `verified`, yet the only QA that actually proved the fix was a human running
`email-hero feedback` on the mini and eyeballing the cards. The branch was deployed to the
mini for the human to self-test before merging. This posture exists so that path is a
named, offered option rather than an improvisation.
