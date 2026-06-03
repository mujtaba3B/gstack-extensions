# Fast mode (`--fast`)

Skip the interactive discovery flow and file an issue in one shot, using past issues in the same repo as a style guide and a local learnings log as a memory of past corrections.

## When fast mode is active

Activate when the user invokes the skill with `--fast` followed by a free-text description:

- `/pm:feature --fast <description>`
- `/pm:bug --fast <description>`

If `--fast` is passed with no description, do not silently fall back. Use `AskUserQuestion` with two options: A) "Drop `--fast` and use the normal interactive flow", B) "Cancel; I'll re-invoke with a description in one message". Do not ask this as prose. Then proceed based on the answer.

## What fast mode skips

- All discovery `AskUserQuestion` prompts.
- Scope gate (feature) and reproduction gate (bug).
- Assignee, priority, project board prompts.
- The pre-creation preview and its approval gate.

## What fast mode keeps

- Live collaborator + project board cache lookups, used as silent defaults.
- README startup behavior from `shared/core.md` (still need repo context to draft well).
- Labels, title prefix conventions, issue templates from `shared/core.md` + the per-skill SKILL.md.

## Mockups in fast mode

Fast mode does NOT generate a `.pen` mockup, even for UI features. The normal flow's "Mockups are mandatory for UI changes" rule does not apply here, because mockup generation requires judgment calls (which frame to extend, which patterns to mirror) that the user opted out of by choosing fast mode.

For UI features, the `## Mockup` section in the filed issue contains the literal text:

```
_No mockup attached (filed via --fast). Run /design-shotgun or re-invoke the normal flow if a mockup is needed before implementation._
```

If a mockup is later required, the user can invoke `/design-shotgun` against the issue or ask Penny to add one in a follow-up message.

## Calibration step (run before drafting)

In parallel:

1. **Past issues.** `gh issue list --repo <owner/repo> --state all --limit 30 --json number,title,labels,body,assignees,author --search "sort:created-desc"`. Skim 5-10 recent issues authored or created via Penny to mirror: title casing/prefix style, label set actually used, body section ordering, default assignee, whether `## Mockup` / `## QA instructions` are typically present.
2. **Learnings log.** Read `~/.claude/pm-penny/fast-learnings.md` if it exists. Locate the section for the current `<owner/repo>` (H2 heading like `## owner/repo`). Apply every bullet under it as a hard rule for this draft.
3. **Collaborators + project cache.** Same gh/cache lookups as the normal flow, used as silent defaults (assignee = `mujbadar` if present, else first collaborator; project column = cached `default_column` if `has_project: true`).

If learnings and observed past-issue style conflict, learnings win (they are explicit corrections).

## Defaults to pick without asking

- **Priority:** `medium` unless the description contains words like "urgent", "blocking", "broken in prod", "critical" (high) or "nit", "polish", "minor" (low).
- **Assignee:** `mujbadar` if in collaborator list, else first collaborator, else unassigned.
- **Project column:** cached `default_column` if project exists, else skip.
- **Labels:** the per-skill default (`feature` or `bug`) plus the priority label, plus any label that the learnings log says is standard for this repo.
- **Bug-specific:** mark `## Reproduction evidence` as `Waived: filed via --fast, no first-party reproduction`.

## File and show

1. Draft the full ticket body using the per-skill template.
2. Run `gh issue create` (+ project add if applicable) immediately. No preview.
3. Show the user, in this exact shape:

   ```
   Filed: <issue URL>

   <full rendered issue body as it was submitted>
   ```

   No summary, no "let me know if". Just the URL and the body. The user reads it and either moves on or asks for a change.

## Learning loop (when the user asks for a change)

If the user's next message requests an edit to the filed issue (rewording, label change, assignee change, missing section, wrong priority, anything), do all of the following:

1. **Apply the fix on GitHub** with `gh issue edit <num>` (and `gh issue edit --add-label` / `--remove-label`, `--add-assignee`, etc. as needed).
2. **Append a learning** to `~/.claude/pm-penny/fast-learnings.md`. Format:

   ```markdown
   ## owner/repo

   - YYYY-MM-DD #<issue-num>: <one-line rule learned from the correction>
   ```

   Create the file and the repo H2 section if they don't exist. One bullet per correction. Keep each rule short and imperative ("Always prefix bug titles with the affected screen name", "Use `area:onboarding` label for anything in the FTUE flow", "Never assign to mujbadar on backend-only issues, use felipe"). Do not re-add a bullet that already exists verbatim under the same repo.

3. After applying, confirm in one line: `Updated #<num> and logged the rule for next time.`

Do not ask for permission to log. The log is local, not checked in, and the user's correction *is* the approval. (The memory-write approval gate in `~/.claude/CLAUDE.md` covers the `~/.claude/projects/.../memory/` store; this is a separate skill-local file outside that scope.)

## Log file conventions

- Path: `~/.claude/pm-penny/fast-learnings.md` (absolute path, expanded from `$HOME`). All Penny state lives under `~/.claude/pm-penny/`; never write this file inside a project repo, even if asked.
- Plain markdown, one H2 per `owner/repo`, append-only bullets underneath.
- No frontmatter, no per-entry headings beyond the repo H2.
- If the file grows past ~200 lines for a single repo, surface that once and ask if the user wants to prune or distill it. Do not auto-prune.
