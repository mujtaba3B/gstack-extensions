---
name: deploy
description: >-
  Deploy what is already on main, as a verified ceremony. Engineer Ernie's deploy-only counterpart to /land-and-deploy, for the PR-less cases that skill structurally cannot serve: retrying after a failed deploy, recovering a wedged host, and re-running with --rebuild-base / --rederive-all. Asserts the tree is clean, on main, and synced; refuses when the branch has an open unmerged PR (that is /land-and-deploy's job); shows the delta between what the host is running and what main holds; runs the repo's declared deploy command from deploy.json; and gates the result on `devops check`. It also arms the deploy gate, which is what makes it a sanctioned path rather than a hand-roll. Trigger on "/eng:deploy", "deploy", "deploy it", "deploy main", "redeploy", "deploy to the mini", "retry the deploy", "the deploy failed, run it again", "rebuild and deploy", "push this live". Use /land-and-deploy instead when there is an open PR to merge first.
---

## Update check (run first)

Before the skill body, check whether the gstack-extensions repo has merged updates this clone has not pulled. Silent unless an upgrade is available; never changes anything:

```bash
~/dev/gstack-extensions/bin/gstack-extensions-update-check 2>/dev/null || true
```

If there is no output, proceed straight to the skill body. If it prints `UPGRADE_AVAILABLE <n> <range>`, tell the user via AskUserQuestion that gstack-extensions is `<n>` commit(s) behind `origin/main` and offer:

- **Upgrade now (recommended)**: run `~/dev/gstack-extensions/bin/gstack-extensions-upgrade`, then continue. It fast-forwards `main` and refreshes the installed plugins, and refuses safely (printing why) if the clone is not on a clean `main`; relay that message and continue without upgrading if so.
- **Skip this time**: run `~/dev/gstack-extensions/bin/gstack-extensions-update-check --snooze` to suppress the prompt for ~8h (so other skills do not re-ask this session), then continue without upgrading.

Do not upgrade without asking. Ask at most once per session: if you have already prompted (or the user skipped) this session, proceed silently.

# eng:deploy

Deploy the code that is already on `main`, through a ceremony that ends in a verification rather than a hopeful "it started".

## Why this exists

`/land-and-deploy` is the merge-and-deploy ceremony, and it hard-stops when there is nothing to merge: no PR for the branch, or a PR already `MERGED` ("nothing to deploy, run `/canary`", which verifies but does not deploy). gstack has no `/deploy`. So three ordinary, PR-less situations had no sanctioned path at all:

- **Retry.** The merge landed, the deploy ran, `devops check` failed. The host is now half-deployed and you must be able to run it again.
- **Recovery.** The host rebooted, a service wedged, containers need recycling.
- **Rebuild.** A baked layer changed and needs `--rebuild-base` / `--rederive-all`, which per-host derivation does not do automatically.

Without this skill the deploy gate (`hooks/scripts/deploy-gate.sh`) would have no path for those, and its break-glass override would become the routine way to deploy, which is just the ungated state with extra typing.

Invoking this skill ARMS the deploy gate for the session. That is what makes it a sanctioned path.

## Step 1: Resolve the repo and its deploy contract

```bash
cd "$(git rev-parse --show-toplevel)"
test -f deploy.json || echo "NO_DEPLOY_JSON"
jq -r '{id:.id, host:.host, cmd:(.deploy.command // "scripts/deploy.sh"), on_merge:(.deploy.on_merge // false)}' deploy.json 2>/dev/null
```

- **No `deploy.json`**: STOP. "This repo has no `deploy.json`, so there is no declared deploy contract to run. Set one up with the `~/dev` deploy kit (`DEPLOY.md` + `deploy.json` + `scripts/deploy.sh`), then re-run." Do not improvise a deploy.
- **`on_merge` is `true`**: STOP. "This app auto-deploys on merge to main; there is nothing to run by hand. Use `/canary <url>` to verify the live result." Deploying such an app manually is how you get two sources of truth.

## Step 2: Refuse when there is a PR to merge

This guard is what keeps this ceremony from becoming a merge-gate bypass.

```bash
gh pr view --json number,state,url 2>/dev/null || echo "NO_PR"
```

If a PR exists for the current branch and its `state` is `OPEN`: **STOP.** Say: "Branch `<branch>` has an open PR (#N). Merging it is `/land-and-deploy`'s job, and it runs the full pre-merge gauntlet before it deploys. Run `/land-and-deploy` instead. `/eng:deploy` is for deploying what is already on main."

Never offer to merge it here.

## Step 3: Assert the tree is deployable

Deploying anything other than committed, pushed `main` means the host runs code that exists nowhere else.

```bash
git status --porcelain --untracked-files=no   # TRACKED modifications only
git status --porcelain --untracked-files=normal | grep '^??' || true   # informational
git branch --show-current
git fetch origin main -q && git rev-parse HEAD origin/main
```

Each failure gets its own message; do not collapse them into a generic "repo not ready":

- **Tracked modifications** (staged or unstaged): STOP, list the files. "Commit or stash these first. They are not going to the host, so a deploy now ships something other than what you are looking at."
- **Untracked files only**: NOT a blocker. Mention them in one line and continue. Untracked files are in no commit, so `git pull` on the host can never receive them; refusing on them would make this skill unusable in exactly the repos that accumulate local scratch (nanoclaw's checkout carries untracked agent state as a matter of course).
- **Not on `main`**: STOP, name the branch. "You are on `<branch>`. `/eng:deploy` deploys `main`. Switch to main, or if this branch needs to ship, `/ship` it and then `/land-and-deploy`."
- **`HEAD` != `origin/main`**: STOP. If HEAD is behind, say so and offer `git pull --ff-only`. If HEAD is ahead, say the local commits are unpushed and must go through `/ship`.

The deploy itself pulls from `origin` on the host, so `origin/main` is what actually ships. These asserts exist to catch the mismatch between that and what the operator believes they are deploying.

## Step 4: Show the delta before touching anything

State plainly what is about to change, so the user can catch a surprise before it ships rather than after.

```bash
WTR=~/dev/infra/where-things-run/wtr
if ! HOST_STATE=$("$WTR" status "$(jq -r .id deploy.json)" 2>&1); then
  RC=$?
  printf 'wtr status FAILED (rc=%s):\n%s\n' "$RC" "$HOST_STATE" >&2
  echo "Cannot read live host state. NOT deploying." >&2
  exit 1
fi
printf '%s\n' "$HOST_STATE"
git log --oneline -1 origin/main
```

`wtr status` live-queries the host (running commit and approximate deploy time); it is never read from the stored inventory, which carries structural data only. It is not on `PATH`, hence the absolute path.

**A failed status query is a STOP, not a shrug.** If `wtr status` exits non-zero, report the captured error and stop before deploying. The whole point of this step is to know what the host is running before changing it; deploying blind is how you discover afterwards that the host was not where you thought. The one case worth offering to continue past is an explicit recovery deploy where the host is known-unreachable, and even then say so out loud and get a yes.

Report it as a two-line delta, then continue:

```
host is running:  <commit> <subject>      (<host id>)
main holds:       <commit> <subject>
```

If they are the SAME commit, say so and ask whether to continue: a same-commit deploy is legitimate for recovery, a rebuild, or a retry, but it is worth naming out loud so a no-op deploy is a decision rather than an accident.

Do not fire a readiness modal otherwise. Invoking the ceremony is the consent; stop only when something is red.

## Step 5: Deploy

Run the repo's declared command, forwarding any flags the user passed to this skill (`--rebuild-base`, `--rederive-all`, `--recycle`, `--force`):

Build an argv array rather than interpolating a placeholder. `<forwarded flags>` is not executable shell (a bare `<` is input redirection), and quoting the whole declared command as `"$CMD"` treats `foo --bar` as one executable named `foo --bar`:

```bash
# The declared command may carry its own arguments, so split it into argv.
read -r -a DEPLOY_CMD <<< "$(jq -r '.deploy.command // "scripts/deploy.sh"' deploy.json)"

# Only the flags this skill declares are forwarded; anything else is refused
# above rather than passed through to the deploy script.
FLAGS=()
for f in "$@"; do
  case "$f" in
    --rebuild-base|--rederive-all|--recycle|--force) FLAGS+=("$f") ;;
    *) echo "refusing unknown flag: $f" >&2; exit 2 ;;
  esac
done

"${DEPLOY_CMD[@]}" "${FLAGS[@]}"
```

Stream the output. If it exits non-zero, STOP and report the failing step verbatim. Do not retry automatically and do not fall back to a hand-rolled sequence: the hand-roll is exactly what skips the host's upgrade-marker stamp, and on nanoclaw that trips a version tripwire which crash-loops the host silently behind a circuit breaker.

## Step 6: Gate on the checks

A deploy is not done because it started. It is done when the declared checks pass.

```bash
devops check
```

Some repos' `scripts/deploy.sh` already ends with `devops check` (nanoclaw's does). Running it again is read-only and idempotent, and it means the guarantee holds for every repo regardless of what its script happens to do. If it fails, the deploy is NOT done: report which check failed and what it asserts, and treat the deploy as incomplete.

## Step 7: Report

State, in this order:

1. What deployed: the commit, its subject, and the host.
2. The `devops check` verdict, per check.
3. The new live state: re-run `wtr status <id>` and show that the running commit now matches `origin/main`.

Then state the QA posture per the QA contract: `QA_STATUS: prod_verified` plus `EVIDENCE:` when the checks passed and you verified the live state, or `QA_STATUS: blocked` plus `REASON:` when they did not.

## What this skill does NOT do

- It does not **merge**. An open PR sends you to `/land-and-deploy` at Step 2.
- It does not **bump versions or write changelogs**. That is `/ship`, before the merge.
- It does not **improvise a deploy**. No `deploy.json` means stop, not a hand-rolled ssh.
- It does not **run QA flows**. Post-deploy browser or endpoint verification is `/canary`.
