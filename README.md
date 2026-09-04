# gstack-extensions

Personal skills layered on top of [gstack](https://github.com/garrytan/gstack), discovered by Claude Code alongside gstack's own skills.

Skills are organized into **persona plugins**: each persona is a Claude Code plugin installed from this repo's own local marketplace, and its skills invoke namespaced as `<persona>:<skill>` (for example `/pm:bug`, `/design:pencil-mockup`).

## Install

```bash
git clone <this-repo> ~/dev/tooling/gstack-extensions
cd ~/dev/tooling/gstack-extensions
./bin/install
```

Then restart your Claude Code session. Skills become invokable as `/pm:bug`, `/qa:browser`, `/eng:cr`, `/design:pencil-mockup`, etc.

## What's included

Five persona plugins (each a top-level dir with a `.claude-plugin/plugin.json`, a `skills/` tree, and usually shared context):

- **PM Penny** (`pm/`): product-manager persona. `/pm:feature`, `/pm:bug`, `/pm:next-issue`, `/pm:first-principles`. Turns ideas, bug reports, and "what next?" into well-structured GitHub issues, and reframes problems from first principles.
- **QA Quincey** (`qa/`): manual-QA persona. `/qa:browser`, `/qa:headless`, `/qa:qa-plan`. Verifies one defined flow against the spec or mockup, in the browser (driving the gstack browse daemon, AI-comparing screenshots against Pencil mockups) or headless (capturing backend side effects), and authors the two-phase QA plan (always publishing a companion Claude artifact of it, on every run at every change size, and linking that page from the approval modal so the human can always read what they are approving). Ships Quincey's enforcement hooks: the QA-plan approval-token minter (a `PostToolUse` hook that turns a real human "Approve" on the QA-plan question into the single-use token the stamp writer requires), the typed-override minter (a `UserPromptSubmit` hook that mints the same token when the human sends `qa-plan: I approve this plan` as a whole message, since `.prompt` is harness-filled and the model cannot submit a user prompt), the QA-plan gates (presentation / build / Bash-build / PR), and the QA-status Stop gate (see `qa/README.md`). The build gate is two hooks: a `PreToolUse` Edit/Write gate that blocks before a write, and (since qa 3.13.0) a `PostToolUse` Bash gate that catches source written through the shell, which the Edit-only matcher never saw at all. The second decides from what the repo observed changing rather than from the command text, because whether arbitrary shell writes source is undecidable from the string (the case that actually escaped was a `python3` heredoc), so it is blind to write mechanism but fires AFTER the write and never reverts anything; `qa/docs/build-gate-coverage.md` states exactly what both do and do not intercept. When a gate blocks and you have already approved, the two routes out are that typed phrase (genuinely unforgeable: nothing an agent does produces a user prompt, but note BOTH minters resolve the repo from the SESSION cwd, so in a linked worktree the typed phrase mints a token keyed to the session's repo and branch, not the worktree you are shipping from, and the stamp writer then reports 'approval token: none'; as of qa 3.12.0 it NAMES the sibling worktree holding the stray token instead of blaming the hook, and every verb takes `--worktree <path>` so the approval can be spent without cd-ing) or `qa-plan-stamp.sh override` run in a real terminal tab (no ordinary tool call has a controlling terminal, though a process can spawn itself one, so that route is an accident-guard rather than a wall and the stamp records the parent process); `qa-plan-stamp.sh doctor` explains any block.
- **Engineer Ernie** (`eng/`): engineering persona. `/eng:cr`, `/eng:cr-teammate`, `/eng:address-pr-feedback`, `/eng:pr-watcher`, `/eng:spike`, `/eng:coderabbit-config`, `/eng:shortcut`. `cr` is his master code-review skill (the single local review path the `~/dev` merge gate keys on); it routes to `cr-teammate` (review others' PRs), `address-pr-feedback` and `pr-watcher` (respond to feedback). Also spikes risky unknowns, configures CodeRabbit, and builds macOS Shortcuts. Ships Ernie's PR-lifecycle enforcement hooks: the ship-PR gate, the merge-clearance gate, the `/ship` sentinel, and the review stamp recorder (see `eng/README.md`).
- **Designer Denise** (`design/`): design persona. `/design:pencil-mockup`, `/design:style-guide`. The Pencil-native counterpart to gstack's HTML design skills: creates and updates `.pen` mockups on the canvas via the Pencil MCP, with a style guide frame as a first-class part of every mockup; `style-guide` owns the from-scratch questionnaire + research + generation flow.
- **Marketing Mindy** (`marketing/`): marketing persona. `/marketing:copywriting`, `/marketing:copy-editing`, `/marketing:stop-slop`, `/marketing:copy-review-wip`. Owns marketing surfaces; today the basket is copywriting (draft new copy, or review existing copy via the `copy-review-wip` front door that edits + de-slops in one pass), with room to grow into the wider marketing toolkit (CRO, ads, email, SEO). Three skills are vendored from third-party MIT repos (Corey Haines' marketingskills, Hardik Pandya's stop-slop) at pinned SHAs and patched for local voice rules; `copy-review-wip` is a first-party orchestrator over them. `marketing/VENDORED.md` carries provenance and the update play.

The persona name (Penny / Quincey / Ernie / Denise / Mindy) lives in each plugin's `description` and README as a memory hook; you invoke by the short role prefix, not the name.

## How it works

`./bin/install` registers this repo as a local Claude Code **marketplace** (the root `.claude-plugin/marketplace.json` lists every plugin) and installs each plugin from it. Claude Code namespaces a plugin's skills as `<name>:<skill>`, where `<name>` is the plugin's manifest `name` (not the directory name). Each skill lives in `<plugin>/skills/<slug>/SKILL.md` and resolves sibling files (`shared/*.md`, `references/`) relative to its plugin root.

A plugin can also ship **hooks** (`<plugin>/hooks/hooks.json`, scripts under `<plugin>/hooks/scripts/`, referenced via `${CLAUDE_PLUGIN_ROOT}`): Claude Code merges them at runtime while the plugin is installed, so a persona's enforcement gates activate and deactivate with the plugin itself, with no `settings.json` surgery. The qa and eng plugins use this for their QA-plan / QA-status and ship / merge-clearance gates. One exception needs a fixed path: `/land-and-deploy` (upstream gstack) calls `merge-clearance.sh` at `~/.claude/scripts/merge-clearance.sh`, so `bin/install` writes a shim there that execs the newest installed eng plugin copy.

Installing **copies** each plugin into `~/.claude/plugins/cache/gstack-extensions/<name>/<version>/`, so the repo is not read live: re-run `./bin/install` (or `bin/gstack-extensions-upgrade`) to refresh the cache from the working tree, then restart the session. Because the plugins live in the plugin cache rather than in `~/.claude/skills/`, they never collide on the filesystem with gstack's own skills: gstack's loose `/qa` and this repo's `/qa:browser` coexist cleanly (the `:` is what separates them).

This repo lives outside `~/.claude/skills/gstack/`, so `gstack-upgrade` never touches it.

> Earlier versions symlinked each plugin dir into `~/.claude/skills/`. That only ever loaded as `<name>@skills-dir` and refused to load when a name collided with an installed plugin, so the marketplace install above replaced it. `bin/install` still sweeps any leftover symlinks from that layout.

## Updating

Each skill checks on invocation whether this clone's `main` is behind `origin/main` (a TTL-gated `git fetch`, so it does not hammer the remote) and, if so, offers to upgrade. Accepting runs:

```bash
~/dev/tooling/gstack-extensions/bin/gstack-extensions-upgrade
```

which fast-forwards `main` and refreshes the installed plugins from the pulled source (uninstall+install, since `claude plugin update` no-ops while a plugin's version is unchanged). It refuses safely (and tells you why) if the clone is not on a clean `main`, so it never disrupts in-progress feature-branch work. Restart the session afterwards to load the refreshed skills. To upgrade by hand at any time:

```bash
cd ~/dev/tooling/gstack-extensions
git pull --ff-only   # must be on a clean main
./bin/install        # idempotent; refreshes the installed plugins
```

`bin/gstack-extensions-update-check` is the read-only check behind the prompt; it prints `UPGRADE_AVAILABLE <n> <range>` when behind and nothing otherwise.

## Uninstall

```bash
./bin/uninstall
```

Uninstalls the five plugins and removes this repo's local marketplace (and sweeps any leftover symlinks from the old installer). Leaves gstack and any other marketplaces alone.

## Adding to the repo

**A new skill in an existing persona:** create `<plugin>/skills/<slug>/SKILL.md` with valid frontmatter (`name`, `description`) and the standard "Update check (run first)" preamble (copy it from any existing skill). Re-run `./bin/install` to refresh the plugin in the cache, then restart the session to register it. It invokes as `/<plugin>:<slug>`.

**A new persona plugin:** create `<persona>/.claude-plugin/plugin.json` (`name` is the only required field), put skills under `<persona>/skills/<slug>/SKILL.md` and shared context under `<persona>/shared/`, add a matching entry to the root `.claude-plugin/marketplace.json` (`name` + `"source": "./<persona>"`), then run `./bin/install` and restart. `bin/install` discovers plugins from their manifests, so no installer edit is needed. It invokes as `/<persona>:<slug>`. Run `claude plugin validate . --strict` to check both manifests before installing.
