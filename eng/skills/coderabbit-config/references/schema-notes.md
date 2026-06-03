# CodeRabbit schema notes

Source of truth:
- Docs: https://docs.coderabbit.ai/reference/configuration
- JSON schema: https://coderabbit.ai/integrations/schema.v2.json
- In-PR command: `@coderabbitai configuration` dumps the current effective YAML.

## What's worth setting vs. noise

Worth setting in almost every repo:
- `reviews.profile` (chill vs assertive, biggest behavioral lever)
- `reviews.path_filters` (cuts noise on generated/vendored code immediately)
- `reviews.path_instructions` (the unique-to-your-repo value-add)
- `knowledge_base.code_guidelines.filePatterns` (points CR at your CLAUDE.md/AGENTS.md)
- `tone_instructions` (cheap, sets voice)

Usually leave at default:
- `language` (en-US is fine unless team works in another language)
- `early_access` (false; opt in deliberately)
- All the `*_summary` / `*_status` toggles (defaults are sensible)

Opt-in flags worth knowing:
- `reviews.auto_apply_labels` (false by default, turn on if you trust the labeller)
- `reviews.auto_assign_reviewers` (same)
- `reviews.finishing_touches.docstrings.enabled` (writes docstring suggestions; noisy)
- `reviews.pre_merge_checks` (blocks merge until checks pass; useful but heavy-handed)

## Enums and constraints

- `reviews.profile`: `"chill"` | `"assertive"`
- `language`: ISO codes (`en-US`, `en-GB`, `fr`, `de`, `es`, `pt`, `ja`, `zh`, ...)
- `tone_instructions`: max 250 chars
- `path_filters`: array of glob strings. Exclusion uses leading `!`. Inclusion is bare.
- `path_instructions`: array of `{ path: <glob>, instructions: <string> }`
- `knowledge_base.*.scope`: `"local"` | `"global"` | `"auto"`
- `chat.integrations.*.usage`: `"auto"` | `"enabled"` | `"disabled"`

## Language → tools mapping (for `reviews.tools`)

Enable only what matches detected languages. CodeRabbit's tool list is long; these are the high-signal defaults:

| Language / file type | Tools to enable                         |
|----------------------|------------------------------------------|
| Python               | `ruff`, `pylint` (pick one), `semgrep`   |
| JS / TS              | `eslint` or `biome`                      |
| Go                   | `golangci-lint`                          |
| Ruby                 | `rubocop`                                |
| Shell                | `shellcheck`                             |
| Dockerfile           | `hadolint`                               |
| YAML                 | `yamllint`                               |
| Markdown             | `markdownlint`                           |
| Any (secrets)        | `gitleaks`                               |
| Any (SAST)           | `semgrep`                                |

Don't enable a tool the repo doesn't already use locally. CodeRabbit running ruff on a codebase that's never been ruff-linted will produce a wall of style noise on the first PR.

## Gotchas

1. **path_filters is exclusion-first.** If you add only inclusion patterns, CR will silently exclude everything else. Stick to `!`-prefixed exclusions unless you have a specific include-list use case.

2. **path_instructions globs are matched against the file's full path** from repo root. `apps/web/**/*.tsx` not `**/*.tsx` when you mean "frontend only".

3. **Knowledge base scope `auto` reads from CLAUDE.md-style files automatically** if you point at them via `code_guidelines.filePatterns`. Don't duplicate the same rules in `tone_instructions` and `path_instructions` and `code_guidelines`. Pick one home.

4. **`@coderabbitai configuration` returns the *effective* config** (org defaults merged with repo YAML), not just what's in your file. Useful for snapshotting but expect more keys than you set.

5. **The schema URL above is v2.** If CR ships v3, the URL changes; check docs for the current canonical link before validating.
