# eng:pr-watcher changelog

## Unreleased

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
