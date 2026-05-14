# pr-watcher changelog

## v2 — dispatcher + sensor split

Replace the 9-minute inner-loop Bash poll with a passive sensor subagent that blocks for up to 30 minutes and returns one JSON blob when CodeRabbit posts a settled round of feedback; the main agent now applies fixes, runs tests, commits, pushes, and replies on the PR itself (subagents only sense).

## v1

Initial implementation. Main agent re-invoked a 9-minute polling Bash loop; a single triage subagent applied fixes per batch.
