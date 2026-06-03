# gstack-extensions

Personal skills layered on top of [gstack](https://github.com/garrytan/gstack), discovered by Claude Code alongside gstack's own skills.

Skills are organized into **persona plugins**: each persona is a Claude Code skills-directory plugin, and its skills invoke namespaced as `<persona>:<skill>` (for example `/pm:bug`, `/design:pencil-mockup`).

## Install

```
git clone <this-repo> ~/dev/gstack-extensions
cd ~/dev/gstack-extensions
./bin/install
```

Then restart your Claude Code session. Skills become invokable as `/pm:bug`, `/qa:browser`, `/eng:pr-feedback`, `/design:pencil-mockup`, etc.

## What's included

Four persona plugins (each a top-level dir with a `.claude-plugin/plugin.json`, a `skills/` tree, and shared context):

- **PM Penny** (`pm/`): product-manager persona. `/pm:feature`, `/pm:bug`, `/pm:next-issue`, `/pm:first-principles`. Turns ideas, bug reports, and "what next?" into well-structured GitHub issues, and reframes problems from first principles.
- **QA Quincey** (`qa/`): manual-QA persona. `/qa:browser`, `/qa:headless`. Verifies one defined flow against the spec or mockup, in the browser (driving the gstack browse daemon, AI-comparing screenshots against Pencil mockups) or headless (capturing backend side effects).
- **Engineer Earnie** (`eng/`): engineering persona. `/eng:pr-feedback`, `/eng:review-pr`, `/eng:pr-watcher`, `/eng:spike`, `/eng:coderabbit-config`, `/eng:shortcut`. Works PR feedback, reviews others' PRs, watches CodeRabbit, spikes risky unknowns, configures CodeRabbit, and builds macOS Shortcuts.
- **Designer Denise** (`design/`): design persona. `/design:pencil-mockup`. The Pencil-native counterpart to gstack's HTML design skills: creates and updates `.pen` mockups on the canvas via the Pencil MCP.

The persona name (Penny / Quincey / Earnie / Denise) lives in each plugin's `description` and README as a memory hook; you invoke by the short role prefix, not the name.

## How it works

`./bin/install` symlinks every persona plugin (any top-level dir containing a `.claude-plugin/plugin.json`) into `~/.claude/skills/`. Claude Code loads each as a skills-directory plugin (`<name>@skills-dir`) and namespaces its skills as `<name>:<skill>`. Each skill lives in `<plugin>/skills/<slug>/SKILL.md` and resolves sibling files (`shared/*.md`, `references/`) relative to the plugin root, which works through the symlink.

This repo lives outside `~/.claude/skills/gstack/`, so `gstack-upgrade` never touches it. gstack's skills and these plugins coexist as peers in `~/.claude/skills/`: gstack's are loose (invoked as `/name`), these are namespaced (invoked as `/persona:name`), so they never collide.

A running session picks up edits to a skill's `SKILL.md` live. A brand-new plugin dir, or a change to a `plugin.json` / hook, needs a session restart (or `/reload-plugins` for already-known plugins) to register.

## Updating

Each skill checks on invocation whether this clone's `main` is behind `origin/main` (a TTL-gated `git fetch`, so it does not hammer the remote) and, if so, offers to upgrade. Accepting runs:

```
~/dev/gstack-extensions/bin/gstack-extensions-upgrade
```

which fast-forwards `main` and re-installs the symlinks. It refuses safely (and tells you why) if the clone is not on a clean `main`, so it never disrupts in-progress feature-branch work. To upgrade by hand at any time:

```
cd ~/dev/gstack-extensions
git pull --ff-only   # must be on a clean main
./bin/install        # idempotent; refreshes links and cleans stale ones
```

`bin/gstack-extensions-update-check` is the read-only check behind the prompt; it prints `UPGRADE_AVAILABLE <n> <range>` when behind and nothing otherwise.

## Uninstall

```
./bin/uninstall
```

Removes only symlinks that point into this repo. Leaves gstack and any other skills alone.

## Adding to the repo

**A new skill in an existing persona:** create `<plugin>/skills/<slug>/SKILL.md` with valid frontmatter (`name`, `description`) and the standard "Update check (run first)" preamble (copy it from any existing skill). No new symlink is needed (the plugin dir is already linked); `/reload-plugins` or restart to register it. It invokes as `/<plugin>:<slug>`.

**A new persona plugin:** create `<persona>/.claude-plugin/plugin.json` (`name` is the only required field), put skills under `<persona>/skills/<slug>/SKILL.md` and shared context under `<persona>/shared/`, then run `./bin/install` and restart. It invokes as `/<persona>:<slug>`.
