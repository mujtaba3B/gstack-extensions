---
name: coderabbit-config
description: Generate or update a tailored .coderabbit.yaml for the current repository. Inspects the repo (languages, monorepo shape, generated/vendored dirs, CLAUDE.md/AGENTS.md conventions) and produces a config with sensible defaults plus repo-specific path_filters and path_instructions. Use when the user says "/coderabbit-config", "coderabbit config", "coderabbit yaml", "set up coderabbit for this repo", "customize coderabbit", "generate .coderabbit.yaml", "tune coderabbit", or otherwise asks to configure CodeRabbit AI code review for a repo. Run from inside the target repo (cwd = repo root). Defaults to inferring from the repo so the user only answers 1-2 questions.
---

# coderabbit-config

Generate a tailored `.coderabbit.yaml` at the root of the current repo. The interesting work is inferring the right `path_filters` and `path_instructions` from what's actually in the repo, then asking the user only the questions that can't be inferred.

## When to run

The cwd should be the repo root. If it isn't, ask the user to `cd` first. The skill writes exactly one file (`.coderabbit.yaml`) at the repo root and does not commit it.

## CLI integration (optional but preferred)

CodeRabbit ships a CLI: `coderabbit` (Homebrew cask `coderabbit`, often at `/opt/homebrew/bin/coderabbit`). When present, use it for validation and snapshot. When absent, the skill still works.

Detect once at the start:
```bash
command -v coderabbit >/dev/null && coderabbit doctor 2>&1 | head -5
```

If installed but not authed: tell the user `coderabbit auth login` is needed for validation (it opens a browser), and proceed without validation. Do NOT run `auth login` for the user.

If installed and authed: enable the validation step in §6.

## Workflow

### 1. Check for existing config

If `.coderabbit.yaml` already exists at repo root: do NOT overwrite blindly. Read it, then ask the user via `AskUserQuestion` whether to (a) extend the existing file (preserve their custom keys, only add what's missing), (b) overwrite from scratch, or (c) abort.

Also surface this hint once if no config exists yet: "If you already have CodeRabbit running on this repo, you can comment `@coderabbitai configuration` on any open PR to get the current effective config dumped as YAML. Want to do that first before I generate?" Don't block on it; if user says no or doesn't have a PR, proceed.

### 2. Detect repo shape

Read `references/detection-heuristics.md` for the full inference rules. The short version:

- Walk top-level dirs and `git ls-files | head -200` to get a feel for languages and layout.
- Identify obvious skip targets for `path_filters`: `node_modules/`, `dist/`, `build/`, `.next/`, `.nuxt/`, `vendor/`, `target/`, `__pycache__/`, `*.lock`, `*.min.js`, `*.min.css`, `*.generated.*`, `coverage/`, generated proto/grpc stubs, migrations if they're auto-generated.
- Identify languages (file extension census) and pick relevant `tools` to enable.
- Read `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, and any `.cursorrules` if present. Lift project conventions (e.g. "no em-dashes", "prefer functional components", "always validate at boundaries") into `path_instructions` entries scoped to the relevant paths.
- Detect monorepo (presence of `packages/`, `apps/`, `services/`, `pnpm-workspace.yaml`, `lerna.json`, `nx.json`) and add path-scoped instructions per package if obvious.

### 3. Ask up to 2 questions (only if not inferable)

Use `AskUserQuestion`. Skip a question entirely if the signal is clear.

**Q1 - Review profile** (`chill` vs `assertive`):
- Skip and default to `chill` if: single-author git log, side project, <50 commits, or CLAUDE.md hints at "move fast" style.
- Skip and default to `assertive` if: multi-author, has CODEOWNERS, has CI with strict gates, or it's a library/SDK with public API.
- Otherwise ask.

**Q2 - Verbose review extras** (sequence diagrams, poem, high-level summary):
- Default all on (CodeRabbit's defaults). Only ask if the user has previously said they prefer minimal/terse output in this session or in CLAUDE.md.

Never ask more than 2 questions. If you're tempted to ask a third, pick the better default and move on.

### 4. Generate the YAML

Start from `templates/base.coderabbit.yaml`. Populate:

- `language`: keep `en-US` unless CLAUDE.md says otherwise.
- `tone_instructions`: lift any tone-relevant convention from CLAUDE.md (e.g. "No em-dashes. Direct, terse feedback."). Keep under 250 chars.
- `reviews.profile`: from Q1 or inference.
- `reviews.path_filters`: detected skip patterns (negation form with leading `!`).
- `reviews.path_instructions`: array of `{path, instructions}` entries, one per meaningful convention or per package in a monorepo.
- `reviews.tools`: enable the linters that match detected languages (see `references/schema-notes.md` for the mapping).
- `knowledge_base.code_guidelines.filePatterns`: include `CLAUDE.md`, `AGENTS.md`, `.cursorrules`, `.github/copilot-instructions.md` if any exist.

Trim any section that's just defaults. A leaner file is easier to maintain.

### 5. Validate

Before writing, do a structural sanity check:
- YAML parses (use `python3 -c "import yaml; yaml.safe_load(open('/tmp/coderabbit-draft.yaml'))"` on a temp file).
- `reviews.profile` is one of `chill` / `assertive`.
- `path_filters` entries are strings; exclusions start with `!`.
- `path_instructions` entries each have `path` and `instructions`.
- `tone_instructions` ≤ 250 chars.

If you want a deeper check, fetch `https://coderabbit.ai/integrations/schema.v2.json` and validate with `jsonschema` (Python). This is optional, the structural checks above catch the common mistakes.

### 6. Write, validate via CLI (if available), summarize

Write `.coderabbit.yaml` at the repo root.

**Live validation (only if `coderabbit` CLI is installed and authed):**

The CLI doesn't have a "validate config" command, but it loads `.coderabbit.yaml` when reviewing. Use that as the validation signal. Pick the cheapest review the repo allows:

```bash
# If there are uncommitted changes, this is fast and free of side effects:
coderabbit review --plain --type uncommitted 2>&1 | tail -20

# If clean tree, skip live validation (CR has nothing to review). Just run:
coderabbit doctor
```

What to look for:
- No "failed to parse `.coderabbit.yaml`" error → schema is valid.
- The review output references your chosen profile and respects path_filters (excluded paths don't appear in findings).
- If the CLI rejects the YAML, surface the exact error, fix the file, retry once. Don't loop.

Heads-up to the user: CLI review on the free tier is 3/hour. Don't burn it; the validation run counts.

**Summary (always print):**

- Profile chosen and why.
- Number of path_filters added, with 3-4 examples.
- Number of path_instructions added, with their paths.
- Tools enabled.
- CLI validation result (passed / skipped / failed).
- Next step: "Commit and push. CodeRabbit will use this on the next PR review. Locally you can run `coderabbit review` before any push to dry-run the same review."

Do not commit. The user commits.

## References

- `templates/base.coderabbit.yaml`: starting template with the keys worth setting and inline comments explaining tradeoffs.
- `references/schema-notes.md`: which fields actually matter, which are noise, language-to-tool mapping, common gotchas.
- `references/detection-heuristics.md`: how to infer profile, path_filters, path_instructions from repo signals.

## Not in scope (v1)

- Committing the file or opening a PR.
- Eval suite (deferred; output is verifiable but "good config" is taste-driven).
- Editing CodeRabbit's UI-level org settings (only the repo-local YAML).
