# Engineer Earnie: Shared Review Engine

The multi-lens adversarial review machinery shared by `eng:cr` (review your own
work before merge) and `eng:cr-teammate` (review another author's PR and comment).
Both skills load this file; it owns *how* a review runs. Each skill owns its own
*terminal act* (cr mints the merge-gate stamp; cr-teammate posts a comment).

The discipline below is the same one a careful human reviewer applies: pick depth
by risk, run independent lenses, then verify the sharp findings against the real
repo instead of trusting any description.

---

## Step A: Locate the review engine (the pr-review-toolkit lenses)

This engine uses the prompts from the **`pr-review-toolkit`** plugin's review
agents. It does not vendor them and does not depend on the plugin being
"enabled": plugin subagents are **not** reliably invocable through the Agent
tool's `subagent_type` (in many harnesses the Agent tool only exposes
`general-purpose` and a few built-ins). What is reliable is that the agent prompt
files ship in the plugin cache and can be read directly.

```bash
find ~/.claude/plugins -path '*pr-review-toolkit/agents/*.md' 2>/dev/null
```

- **Files found**: note the directory; in Step D you pass each file's contents as
  the prompt to a `general-purpose` subagent.
- **Nothing found** (plugin not downloaded): do NOT silently skip the lenses. Use
  `AskUserQuestion` to offer:
  - **Install it (recommended)**: `claude plugin install pr-review-toolkit@claude-plugins-official`, then re-run the `find`.
  - **Degraded inline review**: you (the main agent) apply the lenses yourself in one pass (the lens table is in Step D).
  - **Cancel**: stop.

---

## Step B: Choose the review depth (risk-tiered)

Scope the diff against the base branch, then pick a depth. Size is the weak
signal; **blast radius is the strong one**.

```bash
gh pr diff <N> --repo <owner/name> --name-only   # for a PR
git diff --name-only <base>...HEAD                # for a local branch
```

Three tiers:

- **Trivial** (docs-only, formatting, a comment, a config one-liner, a string
  change): no deep lens pass. Do a quick sanity read, state that it is trivial,
  and record that decision. Do not spend lenses.
- **Routine** (ordinary feature/bugfix code with no high-risk surface): one Claude
  adversarial pass. Run the `code-reviewer` lens, plus `silent-failure-hunter`
  when there is error handling or fallback logic in the diff.
- **Major / risky**: the full lens set (all six in Step D) **plus** a cross-model
  pass (`/codex review` or `/second-opinion codex`, optionally Gemini) and the
  specialized siblings that have surface on this diff.

### Hard escalation (overrides the size signal)

If the diff touches ANY of these, escalate to **Major / risky** regardless of how
small it looks. A three-line auth change is a Major review.

- Access control, auth, sessions, permissions, secrets, crypto
- Money, billing, payments, pricing, quotas
- Data loss surface: migrations, destructive/irreversible operations, deletes, default flips
- Concurrency, races, locking, retries, idempotency
- Cross-host / cross-repo behavior, shared config other actors inherit
- Generated code, lockfile / dependency upgrades
- Large refactors (broad rename/move touching many call sites)

State the tier you picked and the one-line reason. If an escalation trigger
fired, name it. Never silently downgrade.

---

## Step C: Get surrounding-code context (detached worktree, optional)

The lenses are sharper with the surrounding code, not just the diff. For your own
local branch you already have the checkout. For *someone else's PR*, check it out
into a **dedicated detached git worktree**, never by switching the current
checkout's branch (a `git checkout` / `gh pr checkout` in cwd moves HEAD out from
under any parallel work sharing this clone and clobbers it).

Only when cwd is a clone of the PR's repo (`git remote get-url origin` resolves to
`owner/name`). If it is not, skip the worktree and review from `gh pr diff` plus
`gh api` raw file reads.

```bash
git fetch origin "pull/<N>/head"
WT="$(mktemp -d -t review-<N>-XXXXXX)/wt"
git worktree add --detach "$WT" FETCH_HEAD
```

`mktemp -d` reserves a unique parent; `git worktree add` creates `$WT` itself
(the path must not already exist, hence the `/wt` suffix). Record `$WT`; the
lenses read surrounding files from there. Tear it down after the review (and on
any early exit): `git worktree remove --force "$WT"`, then `rm -rf` the mktemp
parent. This never touches the current branch because the branch was never
switched.

---

## Step D: Run the lenses

For each selected lens, spawn a `general-purpose` subagent via the Agent tool, in
parallel, giving it (a) the contents of the matching agent prompt file from Step A
as its instructions, and (b) **the actual diff** as the review target, plus the
changed-file list and base branch. The diff is the primary input, so the lenses
work whether or not you made a worktree. If you DID make a worktree, also pass
`$WT` and tell the subagent to read surrounding files from there for context.

**Do not pass `subagent_type: pr-review-toolkit:...`.** Those plugin-namespaced
agents are not invocable via the Agent tool here; feeding their prompt text to a
`general-purpose` agent is what works.

The six toolkit lenses (filenames under the `agents/` dir from Step A):

| Agent prompt file | Lens |
|---|---|
| `code-reviewer.md` | Bugs + CLAUDE.md compliance (confidence-scored; only the strong findings) |
| `silent-failure-hunter.md` | Swallowed errors, bad fallbacks, missing logging |
| `pr-test-analyzer.md` | Behavioral test-coverage gaps |
| `type-design-analyzer.md` | Type encapsulation / invariants |
| `comment-analyzer.md` | Comment rot / doc accuracy |
| `code-simplifier.md` | Clarity / simplification (lowest priority) |

Skip any lens with no surface on this diff (e.g. type-design or tests on a
docs-only change); say which you skipped. On the degraded inline path, or for any
lens whose file is missing, review the diff yourself against that lens in one pass.

**Then apply a seventh lens yourself, always: the design / blast-radius lens.**
The six toolkit lenses are tuned for code-level defects; none owns the question a
human reviewer cares about most: *who and what else does this change affect?* Ask,
against the actual diff:

- **Scope / blast radius.** Does this change shared or checked-in config (a
  repo-root `.claude/settings.json`, a CI file, shared env) that other people,
  agents, or repos inherit? Could it block, break, or surprise an actor other
  than the author?
- **Hardcoded identifiers in shared surfaces.** A name, ID, path, or assignee
  baked into something other actors run.
- **Reversibility.** A migration, one-way data change, delete, or default flip
  that is hard to undo?
- **Right altitude.** Is this solving the stated problem at the right layer, or a
  narrow patch where a structural fix belongs (or vice versa)?

This is the lens where a careful human out-reviews a naive pass. Weight it
accordingly.

---

## Step E: Consolidate and verify (verify, don't trust)

PR bodies and self-reviews are **claims, not evidence**. Agent PRs especially come
with confident descriptions that are often wrong about their own code (a body
claims "fail-open" while the code fails closed; a hook claims to "block" while
emitting the wrong schema).

- Collect all findings; dedupe overlaps (the lenses overlap on error handling and bugs).
- For every **blocking or high-confidence** finding: verify it against the actual
  diff and repo before you act on it. Read the real file, the sibling code, or the
  authoritative doc. When a finding depends on framework/tool behavior (hook
  schemas, API contracts, CLI flags), verify the real contract rather than
  asserting from memory. Discard anything you cannot substantiate; downgrade style
  nits.
- Cross-check the change's own claims: does the code actually do what the
  description says? Mismatches are themselves findings.
- Bucket survivors into **Blockers** (must fix), **Important** (should fix),
  **Nits / Suggestions**, and **Strengths**.
- Do not let a clean code-level review bury a design-level problem. A blast-radius
  or scope finding (Step D's seventh lens) often outranks every line-level nit:
  surface it as a Blocker or Important item, not a footnote, even when the code
  itself is correct.

The consuming skill (`eng:cr` or `eng:cr-teammate`) takes these buckets and does
its terminal act.
