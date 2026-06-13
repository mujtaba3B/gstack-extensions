# Marketing Mindy (`marketing` plugin)

Marketing Mindy is the marketing persona: she owns marketing surfaces, written in the workspace voice (high-signal, concrete, no startup fluff, never an em-dash). Today the basket is copywriting (draft, de-slop, polish); it grows as more of the marketing toolkit (CRO, ads, email, SEO) is vendored.

This directory is a Claude Code plugin named `marketing` (installed from this repo's local marketplace); its skills invoke namespaced as `marketing:<skill>`.

Unlike the sibling personas, Mindy's skills are **vendored** from third-party MIT repos and patched in place. [VENDORED.md](VENDORED.md) is the canonical provenance record (upstream repos, pinned SHAs, the standing local patches, and the quarterly update play). Upstream LICENSE files live in [licenses/](licenses/).

## Skills

| Invocation | What it does |
|---|---|
| `/marketing:copywriting` | Write or rewrite marketing copy for a page: context gathering (reads `.agents/product-marketing.md` when present), page structure framework, headline formulas, CTA guidelines, annotated output with alternatives. Vendored from Corey Haines' marketingskills. |
| `/marketing:copy-editing` | Improve existing copy via the Seven Sweeps framework (Clarity; Voice and Tone; So What; Prove It; Specificity; Heightened Emotion; Zero Risk), plus quick-pass checks and content-refresh editing. Vendored from Corey Haines' marketingskills. |
| `/marketing:stop-slop` | Strip predictable AI writing patterns from prose: filler phrases, formulaic structures, em-dashes, metronomic rhythm. Run it on every draft. Vendored from Hardik Pandya's stop-slop. |

The intended flow: draft with `marketing:copywriting`, de-slop with `marketing:stop-slop`, polish with `marketing:copy-editing`.

## How it is wired

`bin/install` installs this `marketing/` directory as the `marketing` plugin via the repo's local marketplace (a copy lands in `~/.claude/plugins/cache/gstack-extensions/marketing/<version>/`). Brand voice does not live in the skills: the copywriting skill reads per-project context files (`.agents/product-marketing.md`), so project voice belongs in the project repo.

## Requirements

- None beyond Claude Code itself (no MCP servers; the skills are pure prompt frameworks).
