---
name: qa-quincey-browser
preamble-tier: 4
version: 1.1.0
description: |
  Launch the gstack visible browser in "QA Quincey" mode. Same Chromium + sidebar as /open-gstack-browser, but every tab title is prefixed with "QA Quincey | ..." via a background poll loop, so you can tell at a glance which window is your QA scratchpad vs. ordinary dogfood browsing.

  Use when the user says "QA browser", "open QA Quincey", "Quincey browser", "open a QA browser", or any variant of "I want a visible browser specifically for QA testing".
allowed-tools:
  - Bash
---

# /qa-quincey-browser — Visible Chromium with "QA Quincey" tab-title branding

Thin wrapper around the same `browse connect` flow that `/open-gstack-browser` uses, plus a background polling loop that rewrites `document.title` to start with `QA Quincey | ` on every page. The prefix surfaces in the macOS dock and window title bar, so the QA window is visually distinct from any other Chromium instance you have open.

## Why a poll loop instead of a CDP init-script

The cleaner approach would be a one-time CDP `Page.addScriptToEvaluateOnNewDocument` call. gstack browse has a deny-default CDP allowlist and that method isn't on it (verified 2026-05-16: `DENIED: Page.addScriptToEvaluateOnNewDocument is not on the CDP allowlist`). Rather than patch gstack core (which `/gstack-upgrade` would overwrite), the skill spawns a tiny bash loop that polls the active tab every 2 seconds and re-applies the prefix via `browse js`. The poll cost is negligible and the loop dies when the browser disconnects.

## When to use

- User explicitly invokes `/qa-quincey-browser` or says "open a QA browser", "Quincey browser", "QA window".
- About to run `/qa`, `/qa-only`, or manual QA passes where conflating tabs with regular gstack browsing would be confusing.
- Pairs with the existing memory rule that bug-fix and major-release verifications happen in a *visible* browser, not headless.

Do NOT use this for routine browsing where there's no QA framing. `/open-gstack-browser` stays the default there.

## Steps

### 1. Pre-flight cleanup

Kill stale browse servers, clear Chromium profile locks, free port 34567, and kill any orphaned QA-title polling loops from a previous run.

```bash
_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$_ROOT" ] && [ -f "$_ROOT/.gstack/browse.json" ]; then
  _OLD_PID=$(grep -o '"pid":[0-9]*' "$_ROOT/.gstack/browse.json" 2>/dev/null | grep -o '[0-9]*')
  [ -n "$_OLD_PID" ] && kill "$_OLD_PID" 2>/dev/null || true
  sleep 1
  [ -n "$_OLD_PID" ] && kill -9 "$_OLD_PID" 2>/dev/null || true
  rm -f "$_ROOT/.gstack/browse.json"
fi
for _LF in SingletonLock SingletonSocket SingletonCookie; do
  rm -f "$HOME/.gstack/chromium-profile/$_LF" 2>/dev/null || true
done
lsof -ti :34567 2>/dev/null | xargs -r kill -9 2>/dev/null || true
# Kill any orphaned QA-Quincey title pollers from a prior session
if [ -f "$HOME/.gstack/qa-quincey-title.pid" ]; then
  _OLD_TITLE_PID=$(cat "$HOME/.gstack/qa-quincey-title.pid" 2>/dev/null)
  [ -n "$_OLD_TITLE_PID" ] && kill "$_OLD_TITLE_PID" 2>/dev/null || true
  rm -f "$HOME/.gstack/qa-quincey-title.pid"
fi
```

### 2. Locate the browse binary and connect

```bash
_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
B=""
[ -n "$_ROOT" ] && [ -x "$_ROOT/.claude/skills/gstack/browse/dist/browse" ] && B="$_ROOT/.claude/skills/gstack/browse/dist/browse"
[ -z "$B" ] && B="$HOME/.claude/skills/gstack/browse/dist/browse"
if [ ! -x "$B" ]; then
  echo "NEEDS_SETUP: gstack browse binary not found at $B. Run 'cd ~/.claude/skills/gstack/browse && ./setup' once."
  exit 1
fi
"$B" connect
```

Confirm the output shows `Mode: headed`. If not, re-run Step 1 cleanup and Step 2 connect once before reporting failure to the user.

### 3. Apply the prefix to the active tab

The browser opens on a welcome page. Set its title immediately so the user sees the QA branding right away.

```bash
"$B" js '(function(){var t=(document.title||"").replace(/^(QA Quincey \|\s*)+/,"");document.title=t?"QA Quincey | "+t:"QA Quincey | (untitled)";})()'
```

### 4. Start the background title-poll loop

The loop runs every 2 seconds, prepending the prefix whenever it's missing. Logged to a tmp file for debugging. PID stored so the disconnect path can clean it up. The loop survives page navigations because `browse js` always targets the active tab, regardless of which document is loaded.

```bash
mkdir -p "$HOME/.gstack"
B_ABS="$B"
(
  while true; do
    "$B_ABS" js '(function(){var t=(document.title||"").replace(/^(QA Quincey \|\s*)+/,"");document.title=t?"QA Quincey | "+t:"QA Quincey | (untitled)";})()' >/dev/null 2>&1 || true
    sleep 2
  done
) >"$HOME/.gstack/qa-quincey-title.log" 2>&1 &
echo $! > "$HOME/.gstack/qa-quincey-title.pid"
```

If the user later runs `$B disconnect`, the poll loop will keep running harmlessly (the `browse js` calls will start failing once the server is gone), but it'll be cleaned up automatically on the next invocation of this skill at Step 1. If the user wants to kill it immediately, they can run:

```bash
[ -f ~/.gstack/qa-quincey-title.pid ] && kill "$(cat ~/.gstack/qa-quincey-title.pid)" 2>/dev/null && rm -f ~/.gstack/qa-quincey-title.pid
```

### 5. Confirm

Tell the user (briefly, since this is a tooling skill not a debugging session):

> QA Quincey browser is up. The visible Chromium window's tabs will show "QA Quincey | <page title>" — easy visual signal that this is the QA window. The prefix re-applies every 2 seconds, so it survives navigations.
>
> Drive it the usual way (`$B goto`, `$B click`, `$B fill`, `$B snapshot`). `$B disconnect` when QA is done; the title-poll loop will get cleaned up next time you run this skill.

Then proceed with whatever QA task the user lined up, or ask what they want to test if context doesn't make it obvious.

## Notes

- Polling interval (2s) is loose enough to be invisible in CPU profiles, tight enough that you'll never see a tab title without the prefix for more than a couple seconds. If a future page-load delay feels jarring, drop the interval to 1s.
- The skill does NOT modify gstack core. If gstack ever upstreams a `browse connect --title <prefix>` flag, retire this skill in favor of that.
- The poll loop runs `browse js` against whichever tab is currently active. If the user opens multiple tabs in the same window, the prefix gets applied to each one as it becomes active. New tabs may briefly show the bare page title before the poller catches up.
- Title rewrites happen at the DOM level. The OS-level Dock/menu-bar app name stays whatever gstack browse ships with — that's a binary-bundling concern, not something this skill touches.
