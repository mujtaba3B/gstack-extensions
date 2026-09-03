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
"""
import os
import pty
import select
import sys

TIMEOUT = 15.0


def main() -> int:
    cmdline, typed = sys.argv[1], sys.argv[2]
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
