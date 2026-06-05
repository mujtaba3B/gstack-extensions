# The per-repo QA recipe (`.gstack/qa-quincey/recipe.yml`)

`qa:browser` needs per-repo knowledge to run: how to boot the app, how to seed and tear down TAGGED test data, where the spec lives, and the known scenarios. That knowledge lives in a committed recipe at the git root: `.gstack/qa-quincey/recipe.yml`.

## Why in-repo and committed (not `~/.gstack`)

Run output (reports, screenshots) stays off-repo under `~/.gstack/projects/<slug>/qa-quincey/`, like the rest of QA Quincey. The RECIPE is different: it is repo-coupled executable knowledge (model names, routes, command names) that must stay in lockstep with the schema it seeds and must be readable by consumers that have no `~/.gstack`:

- **MuTwo agents** run in containers / other machines.
- **CI qa-gate** runs on `ubuntu-latest`.

So the recipe follows the same in-repo carve-out gstack already uses for must-travel, CI-trusted artifacts (test config, golden fixtures). It changes rarely and meaningfully (only when the seed contract or boot changes), so it does not create docs-churn.

## Declarative pointers only (no inline code)

The recipe never carries inline shell/Python. It points at entrypoints the repo OWNS as real, reviewable commands (a Django management command, a rake task, an npm script). This keeps it out of the supply-chain surface: an autonomous agent running the recipe executes only code that already passed review in the repo.

## Schema

```yaml
# .gstack/qa-quincey/recipe.yml
version: 1

# Monorepo-safe: the subdir the app actually lives in, relative to git root.
app_root: user_growth            # "." for a single-app repo

base_url: http://localhost:8000

# How to boot a prod-shaped local app. {email} is substituted with the user's.
boot: ./dev-setup.sh {email}

# Tag prefix that every seeded row carries, so teardown is exact.
tag_prefix: people/qa-verify-

# Repo-OWNED entrypoints. The skill runs these; it never inlines their body.
# Both must scope to tag_prefix.
seed_command: python manage.py qa_seed --tag {tag_prefix}
teardown_command: python manage.py qa_teardown --tag {tag_prefix}

# Where the spec lives, for the walk-the-spec / Spec-compliance pass.
spec_refs:
  docs:
    - spec/eng/*.md
  pencil:
    - path: spec/wireframes/suggest-intros.pen
      frame_map:                 # optional: which frame is which view
        suggest: "Suggest intros"
        preview: "Preview"

# Known scenarios (optional; the skill can also pull these from the issue/spec).
scenarios:
  - name: known-contact-skips-form
    note: contact resolvable by email, company present -> 302 /preview/
  - name: ambiguous-email-declines
    note: shared email, two people -> 302 /complete/ detour, no false merge
```

All fields except `app_root`, `base_url`, and `boot` are optional, but a recipe with no `seed_command` / `teardown_command` means the skill cannot seed; it will say so and fall back to asking the user per run.

## Validation (the skill runs this on load)

A bad recipe is a safety surface because autonomous agents run it. The validator is a best-effort **tripwire for obvious mistakes**, not a guarantee; it rejects and STOPs on:

- **Inline secrets (known shapes):** values matching common vendor-prefixed tokens (`sk-`, `ghp_`, `github_pat_`, `glpat-`, `AKIA`, `AIza`, `xoxb-`). This is not exhaustive: a prefix-less high-entropy secret can still slip past, so the real defense is the `op://` convention (a reference is a pointer, not a secret, and is allowed).
- **Machine-absolute paths:** a `/Users/...` or `/home/...` path in any field (paths should be repo-relative or resolved at runtime).
- **Obviously unscoped teardown:** a `teardown_command` whose command portion does not reference `{tag_prefix}` (inline comments are stripped first, so a bare `# tag_prefix` comment cannot satisfy it). This is a lint, not a proof. The load-bearing teardown safety is that `teardown_command` is a repo-owned reviewed entrypoint and the skill asserts **zero tagged rows remain** after running it (Step 10).

Also confirm the recipe is tracked, not git-ignored:

```bash
git -C "$ROOT" check-ignore -q "$ROOT/.gstack/qa-quincey/recipe.yml" && echo IGNORED
```

If `IGNORED`, the recipe will not reach CI or MuTwo. Warn, and offer to un-ignore `.gstack/qa-quincey/` (add a negation to `.gitignore`, e.g. `!.gstack/qa-quincey/`).

## Scaffolding a missing recipe

If no recipe exists, offer to scaffold one from the template above. Infer what you can:

- `app_root` from where `manage.py` / `package.json` / `go.mod` lives.
- `boot` from a `dev-setup.sh` / `Procfile` / `package.json` scripts if present.
- `base_url` from `.env` / dev-server defaults.

Leave `seed_command` / `teardown_command` as the user's to confirm: never invent a seed command. STOP and have the user name the real entrypoint (or agree to create one) before writing the recipe. If the repo has no seed entrypoint yet, that is a real gap; surface it rather than papering over it with inline code.

## Teardown is harder than tagging

Deleting tagged rows is necessary but not always sufficient: cascades, async workers, denormalized rows, search indexes, sent emails, and cached session state can survive. After running `teardown_command`, re-query for tagged rows and assert zero. If residue remains, report it rather than claiming a clean teardown.
