# eng:pr-watcher changelog

## v4 - deterministic sensor script (no more sensor subagent)

The sensor is now `scripts/sensor-poll.sh`, a deterministic bash script the
dispatcher runs in FOREGROUND Bash slices (~9 min each, `continue` outcome +
`sensor-state.json` spanning the 30-minute cycle budget), printing exactly one
JSON object per invocation. The general-purpose sensor subagent is removed.

Why: the subagent contract ("block 30 minutes in one agent turn, end with one
JSON") was structurally unsatisfiable. Foreground sleep is blocked for agents,
so the model reached for background tasks and Monitor, both of which END the
agent's turn, which the dispatcher reads as the final answer. Observed live on
email-hero PR 79 (2026-07-20): the sensor parked twice on monitors whose
conditions fired correctly within ~1 minute of CodeRabbit finishing, with no
agent left to consume them, while the dispatcher waited 10+ minutes. A script
that sleeps internally satisfies the one-JSON contract by construction and
removes the prompt-drift surface entirely.

Also in v4: pure decision logic extracted to `scripts/sensor-poll-lib.sh` with
bats coverage (`tests/sensor-poll.bats`); robust gh/jq resolution under Claude
Code's stripped PATH (the incident's first poll script died on a hardcoded
`/opt/homebrew/bin/jq`); persistent-API-failure ticks surface as a new
`outcome: error` with `error_message` instead of hanging. The v3 protocol
semantics (status-primary polling, comment-stream fallback, init-pass
`already_settled` / `cr_failure` / backlog-drain branches, settle conditions)
are ported unchanged.

Also shipping with v4 (was pending as Unreleased):

- Dropped the test-command gate from the skill contract. The watcher no longer
  asks for or runs a test command before pushing a CR-induced fix. Friction
  against repos without a configured test framework (docs / bash / config-only
  repos) outweighed the protection. Atomic per-finding commits + CR's own
  re-review on the new HEAD provide the remaining safety net.

## v3 — status-driven sensor + clean exit on "CR is done"

Sensor's primary signal is now CodeRabbit's legacy commit status (`context: CodeRabbit`, creator: `coderabbitai[bot]`) on the PR head SHA. The status transitions `pending` → `success`/`failure` exactly once per review pass, giving a clear "review just finished" edge. Polled every 15s (cheap single endpoint) instead of fetching three comment streams every 60s; the three streams are fetched once when the status flips. Comment-stream polling is retained as a fallback every ~60s for repos whose CR setup does not post a commit status.

Three staleness fixes in this version:

1. **Sensor init pass**: before entering the 15s loop, the sensor checks once whether CR's status on the current HEAD is already terminal AND there are no unprocessed CR items. If so it returns a new outcome `already_settled` immediately instead of waiting 30 minutes for a transition that already happened. This fixes the "watcher just sits there for half an hour after starting" failure mode where `last_terminal_status_updated_at = null` made the freshness comparison always false against a pre-existing terminal status.
2. **Post-batch all-clear**: when a batch processes only nitpicks / status pings and we did not push (so HEAD will not move and CR will not re-review), the dispatcher exits the loop instead of spawning a sensor that will idle for 30 minutes. This is the "loop until CR has nothing for us" exit condition.
3. **idle_timeout default flipped to stop**: long silence after watcher start is overwhelmingly "CR is done"; the user can re-invoke /eng:pr-watcher when they push again. Keeping the watcher alive by default just produced more stale sessions.

## v2 — dispatcher + sensor split

Replace the 9-minute inner-loop Bash poll with a passive sensor subagent that blocks for up to 30 minutes and returns one JSON blob when CodeRabbit posts a settled round of feedback; the main agent now applies fixes, runs tests, commits, pushes, and replies on the PR itself (subagents only sense).

## v1

Initial implementation. Main agent re-invoked a 9-minute polling Bash loop; a single triage subagent applied fixes per batch.
