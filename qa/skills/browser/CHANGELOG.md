# qa:browser CHANGELOG

## v2.0.0

Converged from a gstack-browse-daemon mockup-diff skill into a live-browser QA skill. It now drives the user's persistent agent-browser session (`abrowser`, headed) at click/pixel level instead of the browse daemon; walks the spec (`spec/eng` docs + Pencil frames) and reports per-assertion Spec compliance (matches/drifts/missing); boots, seeds, and tears down TAGGED data via a committed `.gstack/qa-quincey/recipe.yml` (declarative pointers only, validated by `scripts/validate-recipe.py`); runs at least one adversarial off-happy-path probe; and ends by stating the `QA_STATUS`/`EVIDENCE` posture that satisfies the build-time Stop hook (`mujtaba3B/dev#32`) and the PR qa-gate CI (hesco `#82`). The cookie-import auth path is removed (the persistent session carries logins); the reconcile-to-`/pm:bug` loop is now optional. Codifies the workflow proven in hesco PR #81.

## v1.0.0

Defined-flow browser QA against Pencil mockups via the gstack browse daemon, with a per-deviation reconcile loop handing bugs to `/pm:bug`.
