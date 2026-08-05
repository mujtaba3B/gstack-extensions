# Gate deploys behind a ceremony, the way merges already are

## Context

**The problem.** Every PreToolUse guard on this machine intercepts a merge-side or ship-side surface. The complete blocking set is two literal strings: `gh pr merge` (`pr-merge-gate.sh`) and `gh pr create` (`ship-pr-gate.sh`, `qa-plan-pr-gate.sh`). Nothing guards a deploy. A grep across `gstack-extensions/*/hooks/scripts/` for `deploy.sh|kickstart|deploy-mini|launchctl|ssh` returns zero files.

So `~/dev/CLAUDE.md`'s rule, "/land-and-deploy is the only way a PR reaches main and production", is one sentence covering two things. The merge half is backed by a hook that hard-refuses. The deploy half is backed by nothing.

**What it cost.** On 2026-07-24 a hand-rolled ssh deploy to `mutwos-mac-mini` skipped the upgrade-marker stamp, tripped the version tripwire in `src/upgrade-state.ts`, and the host crash-looped behind a 900s circuit breaker for 16h46m (72 failed starts, first at 23:38:10, recovery 2026-07-25T16:23:54). Nothing was bypassed, because nothing was in the path. Worse, the agent was *following instructions*: mutwo's own CLAUDE.md documented that bare sequence, and repo CLAUDE.md outranks the `~/dev` rule.

**Why a gate is now tractable.** Two facts discovered while planning:

1. "Self-deploying agents" in `scripts/deploy-lock.sh` means container image self-mods (`src/modules/self-mod/apply.ts`), **not** host code deploys. Host deploys are harness-initiated only, so a laptop PreToolUse hook covers essentially the whole population.
2. Every `~/dev` repo with a `deploy.json` now has a `scripts/deploy.sh` (verified: all 6). There is a real entrypoint to key on, which there was not before the deploy kit landed.

**Intended outcome.** Deploying becomes as gated as merging: it happens through a ceremony that ends in `devops check`, or it does not happen.

## Two decisions already made

- **Matcher scope:** entrypoint **plus** the hand-rolled ssh shape. Entrypoint-only would not have blocked 07-24, which never touched `deploy.sh`.
- **Standalone deploys:** build a `/eng:deploy` ceremony rather than rely on an env override. gstack has **no** `/deploy` command (only `land-and-deploy`, `setup-deploy`, `canary`), and `/land-and-deploy` hard-stops on an already-merged PR (`SKILL.md:945`). Retry-after-failed-deploy, recovery, and `--rebuild-base` reruns are unavoidable and have no path today. An override would become the routine path, which is the ungated state with extra typing.

## Design

Mirror the merge-gate architecture exactly. It is proven, and its primitives are already shared libraries.

```
/land-and-deploy ──┐
                   ├──> arms kind "deploy" ──> deploy-gate.sh allows
/eng:deploy      ──┘                            (else blocks)
```

**One new script, `eng/hooks/scripts/deploy-gate.sh`, is both sentinel and gate**, wired to three events exactly like `land-deploy-sentinel.sh`:

| Event | Branch | Behavior |
|---|---|---|
| PreToolUse / Skill | arm | skill matches `land-and-deploy` or `eng:deploy` (bare, namespaced, or path form) → `ga_arm "deploy"`, exit 0 |
| UserPromptSubmit | arm | prompt starts with `/land-and-deploy` or `/eng:deploy` → `ga_arm "deploy"`, exit 0 |
| PreToolUse / Bash | **gate** | evaluate and block, or slide the arm window |

Self-contained by design: it arms its own kind rather than editing `land-deploy-sentinel.sh`. Kind `"deploy"` is never `"land"`, so `/eng:deploy` can never authorize a `gh pr merge`.

### Gate branch order

1. **Read-only escape.** `deploy.sh check`, `--status`, `--dry-run`, bare `devops check` → allow unconditionally. A retry follows a failure; diagnosing must never be gated.
2. **Resolve target repo** via `sg_workdir_from_cmd` + `sg_dev_repo_gitdir` (`ship-gate-repo-lib.sh`). Not a `~/dev` repo → allow. Using the same resolver as the merge gate is what stops gate and sentinel disagreeing about which repo a command targets.
3. **Opt-in marker.** No `.deploy-gate.json` at the repo root → allow. Fail-open, same posture as every sibling gate.
4. **Deploy-shaped?** Tier 1 or tier 2 below. No match → allow.
5. **Armed?** `ga_armed_fresh "deploy" $SESSION $TMPDIR $(date +%s) 1800` → allow, and slide the arm forward (mirrors `land-deploy-sentinel.sh`, so a long `/land-and-deploy` keeps itself armed through merge → CI wait → deploy).
6. **Break-glass.** `DEPLOY_GATE_OVERRIDE=<non-empty reason>` in the command → allow. Genuine emergencies only; `/eng:deploy` is the routine standalone path.
7. **Block** with a reason naming both ceremonies.

### Tier 1: the entrypoint

From `.deploy-gate.json`'s `deploy_commands` if set, else derived: `deploy.json`'s `.deploy.command` plus `scripts/deploy[a-z-]*\.sh`. Anchored at command position, tolerating `./` and `bash ` prefixes, reusing the anchoring approach in `pr-merge-gate.sh:44`.

### Tier 2: the hand-roll catcher

Fires only when the command contains `ssh <host>` for a host listed in the marker's `hosts` array **and** a mutating verb: `git pull`, `pnpm run build`, `npm run build`, `launchctl kickstart`, `systemctl restart`. Empty `hosts` disables tier 2, so a repo can opt into entrypoint-only.

Hosts are listed explicitly in the marker rather than derived. `deploy.json` carries `"host": "mac-mini"` (a `where-things-run` id), not the ssh hostname `mutwos-mac-mini`; hard-coding the mapping would be fragile.

```
BLOCKS:  ssh mutwos-mac-mini 'cd ~/nanoclaw && git pull && pnpm run build'
         ssh mini 'launchctl kickstart -k gui/501/com.nanoclaw'
ALLOWS:  ssh mutwos-mac-mini 'launchctl list | grep nanoclaw'
         ssh mutwos-mac-mini 'tail -50 ~/nanoclaw/logs/nanoclaw.log'
```

### `/eng:deploy`

New skill at `eng/skills/deploy/SKILL.md`. Deploy-only ceremony for retry, recovery, and rebuild.

1. Standard eng-plugin update-check preamble (copy from `eng/skills/coderabbit-config/SKILL.md`).
2. Assert the repo has a `deploy.json`; refuse otherwise.
3. **Refuse if the current branch has an open unmerged PR.** That is `/land-and-deploy`'s job. This guard is what keeps the new ceremony from becoming a merge-gate bypass.
4. Assert clean tree, on `main`, synced with `origin/main`.
5. Show the delta: running version via `wtr status <id>` (per `~/dev/CLAUDE.md`, deploy state is live-queried, never read from the inventory) vs `main`.
6. Run `deploy.json`'s `.deploy.command`, passing flags through (`--rebuild-base`, `--rederive-all`, `--recycle`, `--force`).
7. Assert `devops check` passed. mutwo's `deploy.sh` already runs it; assert for repos whose script does not.
8. Post-deploy liveness check, then report.

No readiness modal. Per `~/dev/CLAUDE.md`, invoking the ceremony is the consent; stop only when something is red.

## Files

**New (`~/dev/tooling/gstack-extensions`)**
- `eng/hooks/scripts/deploy-gate.sh`
- `eng/hooks/tests/deploy-gate.bats` — mirror `eng/hooks/tests/pr-merge-gate.bats`, whose `setup()` already builds a temp `~/dev` repo and whose `payload()` / `opt_in()` helpers transfer directly
- `eng/skills/deploy/SKILL.md`

**Modified**
- `eng/hooks/hooks.json` — three tuples: `PreToolUse|Bash`, `PreToolUse|Skill`, `UserPromptSubmit`
- `eng/hooks/tests/hooks-json.bats` — golden tuple set at line ~27 grows by three; it also has an orphan check asserting every script in `hooks/scripts/` is wired
- `eng/.claude-plugin/plugin.json` — version bump plus description
- `~/dev/gated-repos.json` — add `.deploy-gate.json` for `~/dev/tooling/mutwo` only. `arm-gates.sh` iterates registry keys generically, so a new marker filename needs **no** code change there
- `~/dev/CLAUDE.md` — the "only paths" section must name `/eng:deploy`, or the doc contradicts the gate *(CLAUDE.md approval gate)*
- `~/dev/tooling/mutwo/CLAUDE.md` — point the retry case at `/eng:deploy` *(CLAUDE.md approval gate)*

**Companion fix (separate, straight to main, no PR)**
- `~/dev/infra/where-things-run/annotations.json:220` — the `mutwo` `deploy_cmd` still spells out the unstamped hand-rolled sequence that caused the outage. `#227` fixed the prose in CLAUDE.md and left this. Repoint at `scripts/deploy.sh`, run `wtr build`. Same stale shape exists on the `sms-hero-backend` entry.

## Reused, not rebuilt

| Primitive | Path |
|---|---|
| `ga_arm` / `ga_armed_fresh` / `ga_arm_file` | `eng/hooks/scripts/ship-gate-arm-lib.sh` |
| `sg_workdir_from_cmd` / `sg_dev_repo_gitdir` | `eng/hooks/scripts/ship-gate-repo-lib.sh` |
| Marker opt-in + registry + drift check | `~/dev/gated-repos.json`, `~/.claude/scripts/arm-gates.sh` |
| Block/allow output protocol | `pr-merge-gate.sh` header comment |
| bats harness shape | `eng/hooks/tests/pr-merge-gate.bats` |

## Known limits, stated honestly

- **The arm slides.** As with the merge gate, an armed session working in `~/dev` keeps the window alive (1800s idle budget). A `/land-and-deploy` at 10am plus continuous activity means a hand-rolled deploy at 5pm passes. Sliding is required, since only Skill and prompt events arm and a real run outlives a fixed window. This is an accident-guard, matching `pr-merge-gate.sh`'s own framing, not a sandbox.
- **A plain terminal is invisible.** A human ssh'ing outside Claude Code is unreachable by any PreToolUse hook.
- **A gate prevents; it does not detect.** The 07-24 loss was 16h46m of *silence*, and this gate buys zero observability. The tripwire already detected the bad state correctly and failed closed. `scripts/checks/nanoclaw.sh` checks 1 and 2 would have caught it within seconds, but run only post-deploy. Wiring that probe into `mini-health.sh` (10-min cadence, existing rate-limited alert path, precedent at its check 8) turns 16h46m into ~10 minutes. **Recommend as a follow-up sidequest**; it is complementary, not covered here.

## Verification

Targeted only. Per the machine rule, no full suites locally; CI covers those.

```bash
cd ~/dev/tooling/gstack-extensions
bats eng/hooks/tests/deploy-gate.bats
bats eng/hooks/tests/hooks-json.bats
```

`deploy-gate.bats` must cover, mirroring `pr-merge-gate.bats`'s allow/block pairs:

- allow: non-deploy command; deploy command in a non-`~/dev` repo; `~/dev` repo with no marker
- allow: `scripts/deploy.sh check` and `--status` even when unarmed
- allow: `ssh <host> 'launchctl list'` (read-only verb)
- block: `scripts/deploy.sh` unarmed in an opted-in repo
- block: `ssh <host> 'cd ~/nanoclaw && git pull && pnpm run build'` unarmed
- block: `ssh <host> 'launchctl kickstart -k gui/501/com.nanoclaw'` unarmed
- allow: each of the above once a `"deploy"` arm marker is fresh
- allow: with `DEPLOY_GATE_OVERRIDE="reason"`
- allow: tier 2 disabled when `hosts` is empty

Manual end-to-end, in order:

1. In mutwo with the marker armed, run `scripts/deploy.sh` cold. Expect a block naming both ceremonies.
2. Invoke `/eng:deploy`. Expect it to arm, show the delta (mini 2.1.54.0 vs main 2.1.54.1), deploy, and pass `devops check`.
3. Confirm liveness the way the incident taught: `launchctl list | grep com.nanoclaw` for a live pid with `lastexit=0`, and `tail -20 logs/nanoclaw.error.log` for tripwire or breaker lines.

The pending 2.1.54.1 mini deploy is the natural first real exercise of `/eng:deploy`.

## Landing

`gstack-extensions` is gated (`.qa-plan-gate.json`, `.ship-gate.json`, `.merge-clearance.json`), and the `plugin.json` version bump counts as a source edit, so the QA-plan build gate fires first.

`/qa:plan` → `/ship` → `/eng:cr` → `/land-and-deploy`. Assign to `mujtaba3B`.

Once approved, this plan file moves to `~/dev/tooling/gstack-extensions/spec/plans/deploy-gate-and-eng-deploy-ceremony.md` and the `~/.claude/plans/` copy is deleted, per the `~/dev` plan-file convention.

---

## What changed during implementation

Recorded because each was found by running the thing rather than reasoning about it.

1. **An empty env assignment bypassed every gate.** The command-position prefix these matchers share required a non-empty value (`[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+`), so `FOO= gh pr merge` matched neither the bare form (no shell separator before `gh`) nor the env-prefixed one, and sailed through. Found via a deploy-gate test, then grepped: the same prefix sat in `pr-merge-gate.sh`, `ship-pr-gate.sh`, `ship-watch-nudge-lib.sh`, and `qa-plan-pr-gate.sh`. The quantifier is now `*` in all five, with a regression test in `pr-merge-gate.bats`. This is why the `qa` plugin also gets a version bump (3.6.1), which the plan did not anticipate.

2. **`/eng:deploy` would have refused to deploy the repo it was built for.** Step 3 originally blocked on any dirty tree. nanoclaw's checkout carries untracked agent state as a matter of course, and untracked files are in no commit, so `git pull` on the host can never receive them. The assert now blocks on TRACKED modifications only (`--untracked-files=no`) and reports untracked files informationally.

3. **The no-merge-authority test was rewritten.** Asserting that `pr-merge-gate.sh` blocks after a deploy-only arm proved nothing: that gate fails OPEN when it cannot resolve a PR, so a fixture repo with no remote returns "allow" for unrelated reasons. It now asserts the mechanism directly, that a deploy arm causes `land-deploy-sentinel.sh` to mint no clearance sentinel.

4. **`wtr` is not on `PATH`.** `/eng:deploy` calls it at `~/dev/infra/where-things-run/wtr`.

5. **The new marker needed a global-gitignore entry.** `.deploy-gate.json` joined its three siblings in `~/.config/git/ignore`; without it the marker would have shown up as untracked in every opted-in repo.
