# Vendored skills: provenance and update play

Every skill in this plugin is vendored from a third-party MIT-licensed repo and patched in place. This file is the **single canonical provenance record** (do not duplicate pins into skill frontmatter).

| Skill | Upstream repo | Upstream path | Pinned SHA | Upstream skill version | License |
|---|---|---|---|---|---|
| copywriting | [coreyhaines31/marketingskills](https://github.com/coreyhaines31/marketingskills) | `skills/copywriting/` | `4b377f289bd37be457a7154626e109ec3affad50` | 2.0.0 (repo 2.4.1) | MIT ([licenses/marketingskills.LICENSE](licenses/marketingskills.LICENSE)) |
| copy-editing | [coreyhaines31/marketingskills](https://github.com/coreyhaines31/marketingskills) | `skills/copy-editing/` | `4b377f289bd37be457a7154626e109ec3affad50` | 2.0.0 (repo 2.4.1) | MIT ([licenses/marketingskills.LICENSE](licenses/marketingskills.LICENSE)) |
| stop-slop | [hardikpandya/stop-slop](https://github.com/hardikpandya/stop-slop) | repo root | `8da1f030185bdfe8471220585162991eaeb970e9` | n/a (upstream is unversioned; date-headed CHANGELOG) | MIT ([licenses/stop-slop.LICENSE](licenses/stop-slop.LICENSE)) |

Imported 2026-06-12. Upstream `evals/` subdirs were omitted (CI fixtures, not needed at runtime).

## Local patches

The verbatim import is its own commit; every local change is a normal commit on top, so `git log marketing/skills/` separates "as imported" from "as patched". Standing patches:

- Em-dash characters stripped throughout (workspace-wide hard rule).
- The repo's `## Update check (run first)` preamble added to each `SKILL.md`.
- Cross-skill references rewritten to vendored reality (pointers to non-vendored upstream skills like cro / emails / popups / ab-testing removed or marked upstream-only).
- No-em-dash rule added to the copywriting style rules and the copy-editing checks.
- Slash-trigger lines (`/marketing:<skill>`) added to descriptions.

When porting an upstream update there are no patch files to re-apply: edit the live file by hand and keep the standing-patch list above current.

## Update play (manual, roughly quarterly)

1. **Drift check** (no clone needed):

   ```bash
   gh api repos/coreyhaines31/marketingskills/compare/4b377f289bd37be457a7154626e109ec3affad50...main \
     --jq '[.files[].filename | select(startswith("skills/copywriting/") or startswith("skills/copy-editing/"))]'
   gh api repos/hardikpandya/stop-slop/compare/8da1f030185bdfe8471220585162991eaeb970e9...main \
     --jq '[.files[].filename]'
   ```

   Empty arrays mean no vendored path changed; done.

2. **Review like a changelog.** If paths changed, read the compare diff (the `html_url` in the same API response renders it) and decide hunk by hunk what is worth taking.

3. **Hand-port** the worthwhile hunks into the live files as normal commits. Never bulk-overwrite a live file; the local patches exist only there.

4. **Bump the pinned SHA** in the table above in the same commit, even if you ported nothing (it records "reviewed up to here").
