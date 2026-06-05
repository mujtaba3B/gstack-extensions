# Driving the persistent browser session (`abrowser`)

`qa:browser` drives the user's real, logged-in browser through `~/.local/bin/abrowser`, the launcher for the persistent `mujtaba` agent-browser session (Vercel Labs `agent-browser`, Chrome for Testing over CDP). This is NOT the gstack browse daemon and NOT chrome-mcp. It operates on a session whose logins survive across runs, so there is no cookie-import or re-login dance.

## The one rule that matters: batch to avoid the 1Password prompt storm

Each separate `abrowser` invocation re-reads the session encryption key from 1Password via `op`, because the Claude Code Bash tool runs a fresh non-interactive shell with no env persistence between calls. Every `op` read touches the 1Password app container, which fires the macOS TCC prompt "iTerm would like to access data from other apps." A sequence of one `abrowser` call per Bash call therefore spams the user with one prompt per call.

**Fetch the key ONCE at the top of a single Bash block, then run every browser command for that step in the same block.**

```bash
export AGENT_BROWSER_ENCRYPTION_KEY="$(source ~/.config/op-access/token.env && /opt/homebrew/bin/op read 'op://AI CLI/agent-browser session encryption key/password')"

abrowser open "http://localhost:8000/suggest-intros/"
abrowser eval "location.pathname"          # confirm app, not authwall
abrowser snapshot -i                        # interactive @e refs
abrowser click @e15
abrowser eval "location.pathname"           # observe the redirect
abrowser screenshot --path /tmp/qa/step1-live.png
```

Re-export the key at the top of each new Bash block (env does not carry between Claude tool calls). Within a block you can run as many `abrowser` commands as you need with no extra prompts.

## Command surface

| Command | Use |
|---|---|
| `abrowser open <url>` | Headed launch (default), session restored. `--headless` to opt out. |
| `abrowser snapshot -i` | Dump interactive elements with `@eN` refs. Re-run after every navigation; refs go stale. |
| `abrowser click @eN` | Click the element at that ref. |
| `abrowser type @eN "text"` | Type into the element at that ref. |
| `abrowser eval "<js>"` | Evaluate JS in the page. Use for real-surface observation: `location.pathname`, `document.body.innerText.includes('...')`. |
| `abrowser screenshot --path <p>` | Save a screenshot as evidence. |
| `abrowser close` | Save + encrypt state. **Do not call this from QA** (see below). |

## Headed by default

Launch headed (visible) so the user can watch the run, per the user's standing preference. Only go headless on explicit request.

## Login state

- Drive sites you are already logged into; the persistent session carries the cookies.
- Do NOT diagnose login via `document.cookie` (auth cookies are HttpOnly and invisible to JS). The reliable signal is the URL: did the page land on the app route, or redirect to a login / authwall / checkpoint URL? Use `abrowser eval "location.pathname"`.

## Why this skill never calls `abrowser close`

`close` saves whatever page state the browser is on AND re-invokes `op` (another prompt). Worse, closing while on a login/authwall page overwrites the good logged-in state with a logged-out one. QA leaves the daemon running so the next run reuses it and the user is never prompted on teardown. The launcher guards `close` against authwall pages, but the simplest correct behavior is: do not close.

## If the session is logged out

If `location.pathname` shows a login/authwall after `open`, the session needs a human login (browser-only step). Surface it: ask the user to run `abrowser open <login-url>`, sign in, then `abrowser close` once to save state, and re-run the skill. Do not try to script the password entry.
