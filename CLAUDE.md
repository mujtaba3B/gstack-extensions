# gstack-extensions — Project Schema (Claude instructions)

This file is the schema for the `gstack-extensions` repo. It applies to every Claude Code session started under `/Users/mujtaba/dev/gstack-extensions/`.

The pattern is borrowed from [Karpathy's LLM Wiki gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) and the cross-project schema at `/Users/mujtaba/dev/CLAUDE.md`.

---

## What this repo is

Personal Claude Code skills layered on top of [gstack](https://github.com/garrytan/gstack). Each subdirectory under `skills/` ships one skill discoverable by Claude Code at session start (via the symlinks `./install` creates into `~/.claude/skills/`).

The repo deliberately lives outside `~/.claude/skills/gstack/` so `gstack-upgrade` never touches it. gstack and these extensions coexist as peers in the flat `~/.claude/skills/` namespace.

---

## Repo layout

```
/Users/mujtaba/dev/gstack-extensions/
├── CLAUDE.md          ← this file
├── LOG.md             ← chronological decision log (update on meaningful decisions)
├── INDEX.md           ← content catalog (update when artifacts are created/renamed/deprecated)
├── README.md          ← public-facing install + usage
├── install            ← symlinks every skills/<name>/ into ~/.claude/skills/
├── uninstall          ← removes only symlinks pointing into this repo
└── skills/
    ├── pr-watcher/
    │   ├── SKILL.md
    │   └── CHANGELOG.md
    └── qa-headless/
        ├── SKILL.md
        └── references/
```

A skill is any directory under `skills/` that contains a `SKILL.md` with valid frontmatter (`name`, `description`).

---

## Skill conventions

- **`SKILL.md` is the entry point.** Frontmatter must include `name` (matches the directory) and `description` (the triggering blurb shown in the skills list). Body is the executable contract Claude follows when the skill is invoked.
- **`description` is load-bearing.** It is the only text Claude sees when deciding whether to trigger the skill from a user message. Rewrite it whenever the skill's architecture or trigger surface changes.
- **`CHANGELOG.md` (optional, per skill).** Add one when a skill undergoes a non-trivial architecture change. Keep entries terse: a `## vN` heading and a one-sentence summary. Bump the version on breaking contract changes.
- **`references/` (optional, per skill).** Long-form reference material the skill loads on demand. Keep `SKILL.md` itself terse.
- **Never edit gstack's own skills from this repo.** If you find yourself wanting to, the right move is either upstreaming to gstack or forking the skill into this repo under a new name.

---

## LOG.md — when to update

`LOG.md` is a **narrative / decision log**, not a technical changelog. It captures *why* and *what was decided*, not every commit.

### Triggers (append an entry when):
- A skill is added, renamed, or deprecated.
- A skill's architecture changes (e.g., pr-watcher's dispatcher/sensor split).
- A repo-wide convention is established or revised (this file, install/uninstall behavior, naming).
- A new external dependency is taken on (a new gstack-internal API, a new MCP server, etc.).
- A user preference about how this repo is maintained is captured.

### Anti-triggers (do NOT log):
- Every commit (git log already has it).
- Routine typo fixes / formatting passes inside a skill body.
- Anything well-captured in commit messages, PR descriptions, or the skill's own CHANGELOG.

### Format
- Top of file: short preamble explaining what the log is.
- One date-headed section per day: `## YYYY-MM-DD`.
- Inside each day, entries as `### \`[topic][subtopic]\` Short title`, then 1-4 lines of body.
- Topic tags: `[meta]`, `[skill]`, `[infra]`, `[ops]`. Subtopics are freeform (typically the skill name: `[skill][pr-watcher]`).
- Grep-ability target: `grep '^### \`\[' LOG.md` lists every entry.
- Convert relative dates to absolute (the user's "today" is in their session context).

---

## INDEX.md — when to update

`INDEX.md` is the "where do I find X?" lookup. Companion to LOG.md's chronological view.

Update when:
- A new skill is added (new row under "Skills").
- A skill is renamed, deprecated, or its trigger surface changes meaningfully.
- A new project-level artifact is created (a shared doc, a script, a reference file).
- An external reference becomes load-bearing (the gstack upstream repo, a relevant MCP server, etc.).

Do NOT catalog every file inside every skill (`ls` covers that). Only list things a future session would benefit from finding without hunting.

---

## When this file should be updated

If you make a repo-wide convention change (new top-level file, new skill layout, new install behavior), update this file AND log the change in LOG.md. Convention drift is the #1 reason schema files become useless.
