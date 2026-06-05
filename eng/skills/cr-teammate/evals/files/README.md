# Eval fixtures

## `pr88-known-bad.diff`

Frozen snapshot of `mujtaba3B/mutwo` PR #88 at commit `21a7ebc` (before the fix
commit `9d21892`). Captured with `git diff <merge-base> 21a7ebc -- <files>`.

Used by `evals.json` eval id 1 as the diff the skill reviews. The file is a
**pure diff on purpose**: it is fed to the model as the PR under review, so it
must not contain any commentary that hints at what's wrong. The ground truth
(what a correct review must catch) lives only in `evals.json` (`expected_output`
and `expectations`), never in this directory, so the eval tests the skill's
verification behavior rather than letting it parrot an answer key. The defects
are present as ordinary diff content and are intentionally not described here.
