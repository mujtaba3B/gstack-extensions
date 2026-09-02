---
name: cr
description: >-
  Engineer Ernie's master code-review skill and the single local review path for ~/dev work. Reviews ANY code before merge: your own uncommitted diff, your own PR, or someone else's. Scopes the diff, picks depth by risk (trivial -> light; routine -> one adversarial pass; major/risky like auth, money, migrations, concurrency, cross-host, or large refactors -> full pr-review-toolkit lens set plus a cross-model pass), verifies findings against the real repo, surfaces a bucketed verdict, and mints the merge-clearance gate stamp on the reviewed HEAD. Routes rather than duplicates: someone else's PR -> eng:cr-teammate; existing review comments -> eng:address-pr-feedback or eng:pr-watcher. Trigger on "cr", "cr this", "code review", "review this", "review my diff", "review my PR", "review before merge", "is this ready to merge", "/eng:cr". Prefer it over gstack /review for any ~/dev PR, because it is what mints the gate stamp.
---

## Update check (run first)

Before the skill body, check whether the gstack-extensions repo has merged updates this clone has not pulled. Silent unless an upgrade is available; never changes anything:

```bash
~/dev/tooling/gstack-extensions/bin/gstack-extensions-update-check 2>/dev/null || true
```

If there is no output, proceed straight to the skill body. If it prints `UPGRADE_AVAILABLE <n> <range>`, tell the user via AskUserQuestion that gstack-extensions is `<n>` commit(s) behind `origin/main` and offer:

- **Upgrade now (recommended)**: run `~/dev/tooling/gstack-extensions/bin/gstack-extensions-upgrade`, then continue. It fast-forwards `main` and refreshes the installed plugins, and refuses safely (printing why) if the clone is not on a clean `main`; relay that message and continue without upgrading if so.
- **Skip this time**: run `~/dev/tooling/gstack-extensions/bin/gstack-extensions-update-check --snooze` to suppress the prompt for ~8h (so other skills do not re-ask this session), then continue without upgrading.

Do not upgrade without asking. Ask at most once per session: if you have already prompted (or the user skipped) this session, proceed silently.

# eng:cr

**Read first:** Load `shared/core.md` (Engineer Ernie's identity and how he thinks about review) and `shared/review-engine.md` (the multi-lens review machinery: locate toolkit, depth tiers, lenses, verify-don't-trust). This skill is the *orchestrator*; `review-engine.md` is *how a review runs*.

You are running `/eng:cr`, the **single master code-review path**. The point of this skill is control: there is one place every review goes through, so depth, verification, and the merge-gate stamp are decided in one consistent way instead of scattered across half a dozen look-alike tools. Anything that needs a real local review on `~/dev` runs through here.

**Why this skill mints the gate stamp.** The `~/dev` merge-clearance gate has a "local review recorded" dimension that reads a stamp file `<git-dir>/review-skill-head` and is satisfied when that SHA equals the PR HEAD. `eng:cr` writes that stamp at the end of a genuine review (Step 4). That is what makes `eng:cr` the reviewer the gate keys on. Running a bare reviewer that does not write the stamp is exactly the mismatch this skill exists to prevent: do the review here.

---

## Step 0: Determine the target and route

Figure out what is being reviewed and who authored it.

```bash
# Local branch + PR context (best-effort; any may be empty)
git rev-parse --abbrev-ref HEAD 2>/dev/null
gh pr view --json number,author,headRefName,url -q '{n:.number,author:.author.login,head:.headRefName,url:.url}' 2>/dev/null || true
gh api user --jq .login 2>/dev/null
```

Resolve to one of three cases:

1. **Your own uncommitted diff or your own PR/branch, headed for a merge you will perform** -> review it here and mint the stamp (Steps 1-4). This is the common case and the gated one.
2. **Someone else's PR** (the PR author is not you: another human teammate, or an autonomous agent like a `mu*`/`*-ai` bot) where the job is to give *them* feedback -> this is `eng:cr-teammate`'s job (it runs the same engine and posts one author-tagged comment). Hand off: tell the user you are switching to `/eng:cr-teammate <PR>` and invoke it. Do NOT mint the stamp for a review whose purpose is to comment on another author's work.
   - Exception: if you (in your local checkout) are about to *merge* someone else's PR through the gate, that is case 1 for your checkout, run the review here and stamp the local HEAD; you may also post a comment via `cr-teammate` if you want to notify the author.
3. **There are existing review comments to work through, not fresh code to review** (CodeRabbit flagged things, a reviewer left comments) -> that is responding to a review, not reviewing. Point the user at:
   - `eng:address-pr-feedback` for a manual, one-comment-at-a-time pass with lesson capture, or
   - `eng:pr-watcher` for the autonomous CodeRabbit watch-and-fix loop.

   `cr` reviews; those two respond to reviews. Route, do not reimplement.

If the case is ambiguous (e.g. it is your PR but it already has comments), ask once with `AskUserQuestion`: "Review the code fresh (`cr`), or work through the existing comments (`address-pr-feedback` / `pr-watcher`)?"

---

## Step 1: Pick depth (review-engine Step B)

Follow `shared/review-engine.md` Step B: scope the diff, pick a tier (trivial / routine / major-risky), and apply the **hard escalation** rules (auth, money, migrations, concurrency, cross-host, generated code, dependency upgrades, large refactors force the Major tier regardless of diff size). State the tier and the one-line reason out loud; name any escalation trigger that fired. Never silently downgrade a risky-but-small diff.

---

## Step 2: Run the review (review-engine Steps A, C, D, E)

Run the engine at the chosen depth:

- **Step A**: locate the pr-review-toolkit lenses (offer to install if missing).
- **Step C**: for your own local branch you already have the checkout; no worktree needed. (The worktree dance is for reviewing a separate PR, which is `cr-teammate`'s path.)
- **Step D**: run the selected lenses as parallel `general-purpose` subagents (feed each toolkit prompt file's contents + the diff), then apply the seventh design / blast-radius lens yourself.
- **Step E**: consolidate, verify the sharp findings against the real repo, bucket into Blockers / Important / Nits / Strengths.

For a **trivial** diff, skip the lens fan-out: do a quick sanity read, say why it is trivial, and go to Step 3 with an empty or near-empty finding set.

---

## Step 3: Surface the verdict

Give the user a tight, verdict-first read:

- **Verdict** in one line: clear to merge, or not yet, and why.
- **Blockers** (must fix before merge), each one sentence, verified.
- **Important / Nits** below that.
- **Strengths** worth keeping.
- The **tier** you ran and what you skipped (and why).

If there are Blockers, the code is not ready: the user fixes them (or you do, if asked), which moves HEAD. A new HEAD means the stamp from Step 4 goes stale and `cr` must be re-run on the new HEAD before merge. That staleness is the gate working as intended; do not pre-stamp around it.

---

## Step 4: Mint the merge-clearance stamp

Mint the stamp **only when the review of the current local HEAD is genuinely complete** (case 1 from Step 0). "Complete" means the lenses ran (or the change was judged trivial) and you have surfaced the verdict. The stamp records *that a real review happened on this HEAD*, not that the code is flawless; the human is trusted to fix any Blockers before merging, and fixing them moves HEAD and re-arms the gate.

```bash
GITDIR=$(git rev-parse --absolute-git-dir 2>/dev/null) || { echo "not in a git checkout; no stamp written"; exit 0; }
HEAD=$(git rev-parse HEAD 2>/dev/null) || { echo "eng:cr: could not resolve HEAD; no stamp written"; exit 0; }
if printf '%s\n' "$HEAD" > "$GITDIR/review-skill-head"; then
  echo "eng:cr: stamped review-skill-head=$HEAD (merge-clearance 'local review' dimension satisfied for this HEAD)"
else
  echo "eng:cr: WARNING failed to write $GITDIR/review-skill-head; the gate will report the review as missing"
fi
```

Then tell the user the stamp is written and, if they are ready, the sanctioned merge path is `/land-and-deploy` (which re-checks CI + CodeRabbit + this stamp + QA and posts the required GitHub status).

Do NOT write the stamp when:
- The target was someone else's PR you are only commenting on (Step 0 case 2) -> the terminal act there is `cr-teammate`'s comment.
- You did not actually run a review (the user bailed, the engine could not run and they declined the degraded path).

If a real review happened through some other tool and you are only here to record it, writing the stamp above is the honest "a review did happen" action. The honest "no review happened, override anyway" action is `merge-clearance clear --skip-review`, which is a different thing; do not use the stamp to fake a review that did not occur.

---

## What this skill never does

- Does not merge, push, or open/close PRs. (Merging is `/land-and-deploy`.)
- Does not resolve review threads.
- Does not reimplement `cr-teammate` (someone else's PR), `address-pr-feedback`, or `pr-watcher`; it routes to them.
- Does not write the stamp to paper over an unrun review. The stamp means a review happened on this HEAD.
- Does not silently downgrade a hard-escalation diff to a lighter tier.
