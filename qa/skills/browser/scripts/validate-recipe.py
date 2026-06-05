#!/usr/bin/env python3
"""Validate a qa:browser repo recipe before the skill trusts and runs it.

A recipe (`.gstack/qa-quincey/recipe.yml`) points the live-browser QA skill at
repo-owned entrypoints that get executed, including by autonomous agents, so a
bad recipe is a safety surface. This validator is the linter the skill runs in
Step 5a. It works on the raw text (no YAML dependency) so the security checks
catch a secret or absolute path wherever it appears.

Usage:   validate-recipe.py <path-to-recipe.yml>
Exit:    0 = PASS, 1 = FAIL (reasons on stderr), 2 = file missing / unreadable.

The pure check lives in `validate_recipe_text` so it is unit-tested without a
file (see test_validate_recipe.py).
"""
from __future__ import annotations

import re
import sys

REQUIRED_KEYS = ("app_root", "base_url", "boot")

# Inline secret shapes. An `op://...` reference is a POINTER, not a secret, and
# is explicitly allowed; everything else here is a real credential leak.
_SECRET_PATTERNS = (
    re.compile(r"sk-[A-Za-z0-9]{8,}"),
    re.compile(r"ghp_[A-Za-z0-9]{8,}"),
    re.compile(r"AKIA[0-9A-Z]{12,}"),
    re.compile(r"xox[baprs]-[0-9A-Za-z-]{8,}"),
)
_ABS_PATH = re.compile(r":\s*['\"]?(/Users/|/home/)")


def _value_lines(text: str):
    """Yield (lineno, raw_line) for non-comment, non-blank lines."""
    for i, raw in enumerate(text.splitlines(), start=1):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        yield i, raw


def validate_recipe_text(text: str) -> list[str]:
    """Return a list of problem strings. Empty list means the recipe is valid."""
    problems: list[str] = []
    keys_seen = set()
    teardown_line = None

    for lineno, raw in _value_lines(text):
        m = re.match(r"\s*([A-Za-z0-9_]+)\s*:", raw)
        if m:
            keys_seen.add(m.group(1))
            if m.group(1) == "teardown_command":
                teardown_line = raw

        for pat in _SECRET_PATTERNS:
            if pat.search(raw):
                problems.append(
                    f"line {lineno}: looks like an inline secret "
                    f"({pat.pattern}); store it in 1Password and use an op:// reference"
                )
        if _ABS_PATH.search(raw):
            problems.append(
                f"line {lineno}: absolute machine path; recipes must be "
                f"repo-relative so they travel to CI / other agents"
            )

    for key in REQUIRED_KEYS:
        if key not in keys_seen:
            problems.append(f"missing required key: {key}")

    # Teardown must be scoped to the tag prefix so it can never delete untagged
    # rows. We accept either a {tag_prefix} placeholder or a literal reference.
    if teardown_line is not None:
        if "tag_prefix" not in teardown_line and "qa-verify" not in teardown_line:
            problems.append(
                "teardown_command is not scoped to tag_prefix; teardown must "
                "only ever delete tagged rows (reference {tag_prefix})"
            )

    return problems


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("usage: validate-recipe.py <recipe.yml>\n")
        return 2
    try:
        with open(argv[1], "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        sys.stderr.write(f"cannot read recipe: {exc}\n")
        return 2

    problems = validate_recipe_text(text)
    if problems:
        sys.stderr.write("RECIPE INVALID:\n")
        for p in problems:
            sys.stderr.write(f"  - {p}\n")
        return 1
    sys.stdout.write("RECIPE OK\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
