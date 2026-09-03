#!/usr/bin/env python3
"""Run a shell command line on a REAL pty, feed it one line, print what it wrote.

Why this exists rather than `script`: bats runs tests with stdin redirected away
from a terminal, and BSD `script` refuses in that situation (it wants to read the
current terminal's window size), so `script` cannot be used to test a
terminal-only code path from a test suite. `pty.fork` has no such requirement and
makes the child a session leader with the pty as its CONTROLLING terminal, which
is exactly the condition `qa-plan-stamp.sh override` requires and an agent's Bash
tool can never have.

Usage: pty-run.py <shell-command-line> <line-to-type>
Exits with the child's status; combined pty output goes to stdout.

REFUSAL, and why it is here. `bin/install` copies this whole directory into the
plugin cache, so this file lands on every machine that installs the plugin. That
turns the TTY override's known weakness into a TURNKEY one: an agent blocked by
the gate would find, inside the plugin itself, a documented helper whose stated
job is to manufacture the controlling terminal the gate asks for. Raised as a
blocker by an adversarial review of this feature, and correctly.

So this refuses to drive `qa-plan-stamp.sh override` unless QA_PLAN_PTY_SELFTEST
is set, which only the bats suite sets. Be clear about what that is worth: it is
a SPEED BUMP, not a boundary. Anyone can set the variable, copy this file, or
write the same fifteen lines from the standard library. What it removes is the
turnkey property, which is the same cost line the rest of this feature is drawn
on: a deliberate, conspicuous act instead of running the tool that was handed to
you. If you are an agent reading this because the gate blocked you: spawning a
terminal to get past it forges a record that a human approved something they did
not, and the resulting stamp records the parent process that did it.
"""
import os
import pty
import re
import select
import sys

TIMEOUT = 15.0

# Matches an invocation of the QA-plan stamp writer's override verb, allowing for
# paths, quoting and a `cd ... &&` prefix. Deliberately broad: a false positive
# here costs a test that sets the opt-in variable anyway.
_OVERRIDE_TARGET = re.compile(r"qa-plan-stamp\.sh['\"]?\s+override\b")


def main() -> int:
    cmdline, typed = sys.argv[1], sys.argv[2]

    if _OVERRIDE_TARGET.search(cmdline) and not os.environ.get("QA_PLAN_PTY_SELFTEST"):
        sys.stderr.write(
            "pty-run.py: refusing to drive `qa-plan-stamp.sh override`.\n\n"
            "That verb requires a controlling terminal because it records that a HUMAN\n"
            "approved a QA plan. Using this helper to manufacture one does not satisfy\n"
            "that requirement, it forges it, and the stamp it writes names the parent\n"
            "process that did it.\n\n"
            "If you are the human: run the command yourself in a terminal tab.\n"
            "If you are the QA-plan test suite: set QA_PLAN_PTY_SELFTEST=1.\n"
        )
        return 2
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("bash", ["bash", "-c", cmdline])
        os._exit(127)

    # The pty buffers, so writing before the child opens /dev/tty is safe. Doing
    # it up front avoids the race that makes a correct confirmation look rejected.
    os.write(fd, (typed + "\n").encode())

    chunks = []
    while True:
        try:
            ready, _, _ = select.select([fd], [], [], TIMEOUT)
        except (OSError, ValueError):
            break
        if not ready:
            break
        try:
            data = os.read(fd, 4096)
        except OSError:      # EIO on macOS when the child closes the slave
            break
        if not data:
            break
        chunks.append(data)

    os.close(fd)
    _, status = os.waitpid(pid, 0)
    sys.stdout.write(b"".join(chunks).decode("utf-8", "replace").replace("\r", ""))
    return os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") \
        else (status >> 8)


if __name__ == "__main__":
    sys.exit(main())
