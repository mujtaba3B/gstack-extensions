# qa:browser evals

Two layers of verifiable behavior for this skill:

## 1. Recipe validation (unit-tested, deterministic)

The safety-critical piece, the recipe linter the skill runs in Step 5a, is a pure
function with real tests:

- `../scripts/validate-recipe.py`: rejects inline secrets, absolute machine
  paths, and an unscoped `teardown_command`; requires `app_root` / `base_url` / `boot`.
- `../scripts/test_validate_recipe.py`: 8 pytest cases.

Run (single file only, per the machine's no-full-suite rule):

```bash
python3 -m pytest qa/skills/browser/scripts/test_validate_recipe.py -q
```

## 2. Triggering classification (description quality)

`triggering.jsonl` holds prompt → `should_trigger` cases that check the
`description` fires `qa:browser` for live defined-flow QA and does NOT fire for a
broad bug sweep (`/qa`), a backend feature (`qa:headless`), test authoring, or
code review. Feed it to skill-creator's eval / benchmark to measure triggering
accuracy and variance after any `description` change.

## Out of scope for automated evals

The end-to-end browser drive (abrowser + a live app + seeded data) is inherently
interactive and is verified by running the skill against a real feature (the
canonical proof is hesco PR #81), not by a headless eval.
