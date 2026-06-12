# Copywriter Cora (`copy` plugin)

Copywriter Cora is the copywriting persona: conversion copy for landing pages and marketing surfaces, written in the workspace voice (high-signal, concrete, no startup fluff, never an em-dash).

This directory is a Claude Code plugin named `copy` (installed from this repo's local marketplace); its skills invoke namespaced as `copy:<skill>`.

Unlike the sibling personas, Cora's skills are **vendored** from third-party MIT repos and patched in place. [VENDORED.md](VENDORED.md) is the canonical provenance record (upstream repos, pinned SHAs, the standing local patches, and the quarterly update play). Upstream LICENSE files live in [licenses/](licenses/).

## Skills

| Invocation | What it does |
|---|---|
| `/copy:copywriting` | Write or rewrite marketing copy for a page: context gathering (reads `.agents/product-marketing.md` when present), page structure framework, headline formulas, CTA guidelines, annotated output with alternatives. Vendored from Corey Haines' marketingskills. |
| `/copy:copy-editing` | Improve existing copy via the Seven Sweeps framework (clarity, voice, persuasion, concision, scannability, error, conversion), plus quick-pass checks and content-refresh editing. Vendored from Corey Haines' marketingskills. |
| `/copy:stop-slop` | Strip predictable AI writing patterns from prose: filler phrases, formulaic structures, em-dashes, metronomic rhythm. Run it on every draft. Vendored from Hardik Pandya's stop-slop. |

The intended flow: draft with `copy:copywriting`, de-slop with `copy:stop-slop`, polish with `copy:copy-editing`.

## How it is wired

`bin/install` installs this `copy/` directory as the `copy` plugin via the repo's local marketplace (a copy lands in `~/.claude/plugins/cache/gstack-extensions/copy/<version>/`). Brand voice does not live in the skills: the copywriting skill reads per-project context files (`.agents/product-marketing.md`), so project voice belongs in the project repo.

## Requirements

- None beyond Claude Code itself (no MCP servers; the skills are pure prompt frameworks).
