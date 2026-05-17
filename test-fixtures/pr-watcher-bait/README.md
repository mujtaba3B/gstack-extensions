# pr-watcher test fixtures

Deliberate CR-bait files used to validate the /pr-watcher loop end-to-end.

These files are intentionally bad. Do not copy patterns from here.
They exist solely so CodeRabbit has substantive things to flag across
multiple review rounds, exercising the watcher's:

- initial sensor spawn (status already terminal on first review)
- multi-round fix loop (each round addresses CR, push triggers re-review)
- clean exit when CR's final review reports zero actionable findings

The PR containing these files is expected to be closed without merging.
