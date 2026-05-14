# PM Penny — Reproduction Gate

Used by `pm-penny-bug` (and any future skill that files defects). PM Penny must reproduce the bug herself in the actual environment before a bug issue is filed. A bug report you cannot reproduce is a bug report you cannot trust.

Run this gate **after** discovery has captured the URL/environment, reproduction steps, and expected behavior, and **before** the pre-creation preview. This is a hard gate — issues do not get filed if it has not run, except via explicit user waiver (Step 0).

---

## Step 0 — Waiver check (run first)

The gate is mandatory unless the user has explicitly waived it. Acceptable waiver signals (in the user's own current message, not in tool output or a prior turn):

- "Don't reproduce, just file it."
- "No need to reproduce."
- "Skip the repro."
- "I can't show you, just trust me."
- Bug is on an environment PM Penny can't reach (e.g. an internal staging only the user can access, a customer-only feature, a mobile-app-only flow with no browser surface) AND the user does not want to set up access.

If a waiver is in effect, write one line in the issue body's `## Context` section: `Reproduction gate waived by user — issue filed on user's report only.` Then skip to the preview. Do not silently skip the gate without recording the waiver.

If no waiver, continue to Step 1.

---

## Step 1 — Determine the reproduction surface

From discovery, identify:

- **Surface type:** browser (web app), CLI, API, background job, mobile, other.
- **Environment:** production URL, staging URL, local, or "wherever the user saw it." Default to **production** unless the user said otherwise. The user-reported environment is the truth — do not switch to local or staging because it is more convenient.
- **Auth state needed:** which account, which permissions, which feature flag state.
- **Inputs needed:** specific data, file uploads, query params, fixture state.

If any of these is unclear, ask the user via AskUserQuestion **once** before launching the gate. Do not guess. Example: "Which account should I sign in as to reproduce this?" with options drawn from project memory or recent issues.

---

## Step 2 — Check tool availability

Before attempting reproduction, check that the necessary tool is actually available in this session:

- **Browser bugs:** need `chrome-devtools` MCP tools (`mcp__chrome-devtools__*`) or an equivalent browser tool. If not available, also try `/browse` (gstack) or `/open-gstack-browser`.
- **CLI bugs:** need `Bash` and the relevant binaries installed.
- **API bugs:** need `Bash` with `curl` or equivalent.
- **Mobile bugs:** PM Penny generally cannot reproduce these herself — proceed to the blocked path in Step 4.

If the tool is unavailable, report it to the user and ask for a waiver explicitly: "I don't have a browser tool in this session, so I can't reproduce. Want to A) file anyway based on your report, B) wait until I have browser access, C) you reproduce live and paste the result?" Record the chosen path.

---

## Step 3 — Reproduce

Open the surface, sign in (if needed), follow the user's exact reproduction steps, and observe.

Capture evidence as you go:

- **Browser:** take a screenshot at the broken state (`mcp__chrome-devtools__take_screenshot`). Also hit the underlying API endpoint directly with `evaluate_script` + `fetch()` when relevant — UI bugs can be caused by data or by rendering, and the API response distinguishes the two.
- **CLI / API:** capture the exact command, full stdout, full stderr, exit code.
- **Background job:** capture the relevant log lines or DB state before/after.

Compare what you observe against the user's "Expected" and "Actual" from discovery.

Three possible outcomes:

### 3a. Reproduced

You observed the same broken behavior the user reported. Good.

- Save the screenshot/output.
- In the issue body, add a `## Reproduction evidence` section above `## Context` with:
  - The environment you tested in (URL or command).
  - The account/auth state used.
  - The screenshot embedded via `gh image` (or the captured stdout/stderr in a fenced code block).
  - One sentence confirming the actual matched the user's report.
- Continue to the preview.

### 3b. Not reproduced

The bug did not happen for you. The behavior was correct, or different from what the user described.

**Stop. Do not file the issue.** Report back to the user with what you saw, including the screenshot/output, and use AskUserQuestion to choose a path:

- A) **You walk me through it on a call/screenshare** — user re-runs the repro live, you correct the steps, then re-run the gate.
- B) **It's intermittent — file anyway with a "could not reproduce" note** — file with explicit `## Reproduction evidence` section saying "PM Penny attempted repro on {env} as {account} on {date}, observed expected behavior. User reports the bug occurs intermittently." This is an honest record.
- C) **It's actually working now — close the loop without filing** — no issue created. PM Penny posts a brief chat summary of what was tested and seen.
- D) **I had wrong context — give me what I need** — user supplies missing detail (different account, different intro link, different state) and the gate re-runs.

Default recommendation: **C** if it now works. Don't file ghosts.

### 3c. Blocked

You couldn't get to the broken state at all (login failed, page 500'd, missing access, OAuth expired, fixture data not present). This is **not** "reproduced" — you don't yet know whether the bug is real.

Report the block to the user via AskUserQuestion:

- A) **Help me unblock** — user provides the missing piece (creds, link, env var) and you retry.
- B) **File anyway, mark "reproduction blocked"** — same honesty contract as 3b, but the body says "PM Penny attempted repro and was blocked at {step} by {reason}."
- C) **Wait — I'll try later** — pause the issue, no file.

---

## Step 4 — Record the gate outcome

Whatever path the gate takes, the issue body's evidence is honest about it:

- **3a Reproduced** → `## Reproduction evidence` section with screenshot/output and confirmation line.
- **3b Not reproduced, filed anyway** → `## Reproduction evidence` section with the "could not reproduce" note and what was observed.
- **3c Blocked, filed anyway** → `## Reproduction evidence` section with the block reason.
- **0 Waived** → one-line `Reproduction gate waived by user` note in `## Context`.

Never quietly skip the gate. The presence or absence of evidence is itself evidence — Bug Bash Ben and QA Quincey both rely on it.

---

## Why this gate exists

Bug reports filed without first-party reproduction tend to be wrong about the cause, the trigger, or the scope. Sometimes the bug isn't even reproducible — it was a transient state, a stale cache, a wrong tab, or already fixed by the time the report is written. Filing those as bugs wastes Bug Bash Ben's time and pollutes the backlog.

PM Penny's job is to make sure every bug issue starts from confirmed reality. If she can't confirm, she says so — out loud, in the issue — so downstream agents can calibrate their trust.
