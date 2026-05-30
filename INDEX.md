# gstack-extensions — Project Index

Content catalog. Companion to `LOG.md` (chronological/narrative). This file is the "where do I find X?" lookup; LOG.md is the "what happened and why?" history.

Per `CLAUDE.md`: keep this updated when artifacts are created, renamed, or deprecated. Do NOT catalog every file inside every skill (use `ls` for that). Only list things a future session would benefit from finding without hunting.

---

## Meta / project schema

| Path | What it is |
|---|---|
| `CLAUDE.md` | Project schema. Auto-loaded by Claude Code in any session under this tree. Defines LOG / INDEX / skill conventions. |
| `LOG.md` | Chronological decision log. Updated when a meaningful decision, blocker, or convention change happens. |
| `INDEX.md` | This file. |
| `README.md` | Public-facing install + usage doc. Tagline list of skills lives here. |

## Install scripts

| Path | What it is |
|---|---|
| `install` | Symlinks every directory under `skills/` AND every sub-skill under `<bundle>/skills/` (any top-level dir other than `skills/` that has its own `skills/` tree) into `~/.claude/skills/`. Idempotent: refreshes links and cleans stale ones. |
| `uninstall` | Removes only symlinks that point into this repo. Leaves gstack and other skills alone. |

## Skills (standalone)

| Path | What it does |
|---|---|
| `skills/pr-watcher/` | `/pr-watcher`. Foreground watcher for CodeRabbit feedback on a GitHub PR. Dispatcher (main agent) + sensor (polling subagent). Main applies fixes, runs tests, commits, pushes, replies. v2 architecture (see skill's CHANGELOG.md). |
| `skills/review-agent-pr/` | `/review-agent-pr <PR# \| URL>`. Review-only skill for PRs you did NOT author (use case: autonomous-agent PRs). Resolves the PR, locates the `pr-review-toolkit` agent prompt files on disk (offers to install if absent, else degraded inline review), runs the diff through six toolkit lenses plus a seventh design/blast-radius lens the main agent always applies, verifies blocking findings against the real repo (not the PR's claims), gives a quick chat verdict, then posts ONE structured comment behind a confirm gate. Never merges/pushes/resolves/reassigns. 3 evals (deploy-verdict on a frozen known-bad fixture, plugin-absent handling, merge-guardrail safety assertion). |
| `skills/coderabbit-config/` | `/coderabbit-config`. Generates a tailored `.coderabbit.yaml` for the current repo. Detects languages, monorepo shape, generated/vendored dirs, lifts conventions from CLAUDE.md/AGENTS.md. Wraps the `coderabbit` CLI for optional live validation. |
| `skills/first-principles-thinking/` | `/first-principles-thinking`. Goal-first reframe coaching. Seven-step walk (goal, success signal, hard constraints, assumed constraints, current path, constraint-class attacks, pressure-test). Light mode by default. Modeled on SpaceX (rocket-floor) and Neuralink (no-surgeons) examples. No evals (judgment skill). |
| `skills/feature-spike/` | `/feature-spike`. Pre-plan risk-discovery. Four-phase loop: lock one-line outcome ("I will know X if Y"), prepare isolation (worktree or branch) and open SPIKE.md as a live ledger with a THROWAWAY SPIKE marker, write the leanest falsifier, escalate to `/second-opinion` then user when blocked (blocking-predicate definition, one-sentence blocker required), complete verdict (PROVEN / DISPROVEN / INCONCLUSIVE) in SPIKE.md. Explicitly opts out of `karpathy-guidelines` for spike duration. Sits before `/plan-eng-review`. No evals (judgment skill). |

## Bundles (sub-skills with shared context)

A bundle is a top-level directory (sibling to `skills/`) whose `skills/<sub-skill>/` directories each get symlinked into `~/.claude/skills/`. Sub-skills load `shared/*.md` files from the bundle root; resolution works through the install symlink.

| Path | What it is |
|---|---|
| `pm-penny/` | PM Penny. Three sub-skills (`/pm-penny-feature`, `/pm-penny-bug`, `/pm-penny-next-issue`) share identity + label conventions via `shared/core.md`. `shared/repro-gate.md` is loaded by the bug skill; `shared/scope-gate.md` is loaded by the feature skill; `shared/fast-mode.md` is loaded by both feature and bug skills when invoked with `--fast`. Promoted from `plugins/pm-penny/` to top-level on 2026-05-18 after dropping the plugin-marketplace install path. |
| `feature-frank/` | Feature Frank. One sub-skill (`/feature-frank-pr-feedback`) shares identity + commit style via `shared/core.md`. Promoted from `plugins/feature-frank/` to top-level on 2026-05-18. |
| `qa-quincey/` | QA Quincey. Two sub-skills share identity, deviation vocabulary, plan/report storage, and reconcile-loop conventions via `shared/core.md`. `/qa-quincey-manual-browser-testing` is the flagship: AI-autonomous defined-flow browser QA against Pencil mockups with AI narrative visual diff. `/qa-quincey-manual-headless-testing` is the migrated qa-headless skill: backend-feature QA for crons, workers, notifiers, CLIs, pipelines. Bundle created 2026-05-20; absorbed and replaced the prior standalone `skills/qa-quincey-browser/` (labeled-Chromium-only, now subsumed) and `skills/qa-headless/` (moved in, renamed, version 2.0.0). |

## External references

| Where | What it is |
|---|---|
| `https://github.com/garrytan/gstack` | Upstream gstack repo. These extensions layer on top of it; they do not modify it. `gstack-upgrade` never touches this repo. |
| `~/.claude/skills/` | Flat namespace Claude Code scans at session start. `./install` symlinks into here; gstack and these extensions coexist as peers. |
| `~/.cache/pr-watcher/<owner>__<repo>__<pr>/` | Per-PR state directory used by `/pr-watcher`. Persists across sessions for resumability. |
