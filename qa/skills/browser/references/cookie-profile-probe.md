# Chrome profile probe for cookie import

When the QA target is `staging` or `production`, the browse daemon needs cookies from the user's logged-in Chrome session. The default cookie import (`browse cookie-import-browser chrome --domain <site>`) only reads from Chrome's `Default` profile. Most real users have multiple profiles, and their logged-in session is rarely in Default.

This file documents the profile-aware probe that QA Quincey runs in step 5 of the flagship browser-testing skill.

## Why probe before importing

Importing cookies decrypts them via the macOS keychain, which prompts the user. If you import from the wrong profile, you decrypt cookies the user does not actually use for the target site, and then the QA run fails to authenticate. Worse, the user gets a keychain prompt for nothing.

Probing first is read-only on the cookie database (it just counts `sessionid` rows) and does not require keychain unlock. The actual decrypt happens later, only after the right profile is identified.

## The probe

```bash
TARGET_DOMAIN="<the host, e.g. app.example.com>"
CHROME_ROOT="$HOME/Library/Application Support/Google/Chrome"

for db in "$CHROME_ROOT"/{Default,Profile\ *}/Cookies; do
  [ -f "$db" ] || continue

  # Chrome locks the cookies DB while running; copy first.
  cp "$db" /tmp/_qq_cookies.db 2>/dev/null

  # Count cookies for the target domain. We do NOT decrypt values.
  cnt=$(sqlite3 /tmp/_qq_cookies.db \
    "SELECT COUNT(*) FROM cookies WHERE host_key LIKE '%${TARGET_DOMAIN}%' AND name='sessionid';" \
    2>/dev/null)

  if [ "${cnt:-0}" -gt 0 ]; then
    # Also pull the most-recent expiry for ranking when multiple profiles match.
    expires=$(sqlite3 /tmp/_qq_cookies.db \
      "SELECT MAX(expires_utc) FROM cookies WHERE host_key LIKE '%${TARGET_DOMAIN}%' AND name='sessionid';" \
      2>/dev/null)
    printf '%s: has sessionid (expires_utc=%s)\n' "$(basename "$(dirname "$db")")" "${expires:-unknown}"
  fi
done

rm -f /tmp/_qq_cookies.db 2>/dev/null
```

The output is one line per profile that has a `sessionid` cookie for the target domain, ranked by expiry.

## Interpreting results

- **No lines**: the user is not logged in to the target domain in any Chrome profile. Ask them to log in, then re-run.
- **One line**: that profile is the target. Use `--profile "<profile name>"` (quoted because spaces).
- **Multiple lines**: AskUserQuestion which profile to use. Default the recommendation to the highest `expires_utc` (freshest session).

## Invoking browse cookie-import with the chosen profile

```bash
"$B" cookie-import-browser chrome --domain "${TARGET_DOMAIN}" --profile "Profile 3"
```

If the user does not like manual selection, prefer `/setup-browser-cookies`; it carries the picker UI.

## Adjacent profiles

Some Chrome installs have profile directories named `Profile 1`, `Profile 2`, etc. Others have custom display names that map to the same directory pattern. The probe glob `Profile\ *` covers both. If a user has Chrome Beta or Chromium installed alongside, those have separate roots:

- Chrome Beta: `~/Library/Application Support/Google/Chrome Beta`
- Chromium: `~/Library/Application Support/Chromium`
- Brave: `~/Library/Application Support/BraveSoftware/Brave-Browser`

QA Quincey v1 only probes regular Chrome. If the user keeps their QA logins in a non-Chrome Chromium variant, add that root to the loop and call it out.

## Why this is a reference, not in the SKILL.md body

The probe is ~30 lines and the explanation is another ~50. Keeping it in `references/` lets the SKILL.md stay scannable. The skill body loads this file only when step 5 actually runs (i.e. non-local environment).
