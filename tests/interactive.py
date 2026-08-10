#!/usr/bin/env python3
"""Drive an interactive firecode session through a pty.

`firecode shell` hands the guest's serial console to the terminal, so nothing
in the normal test suite touches it - a pipe is not a tty and the whole path
behaves differently. This is the expect script, without needing expect.

usage: interactive.py <project-dir> [firecode-path]
exits 0 if the session behaved, 1 with a reason if not.
"""

import os
import pty
import re
import select
import sys
import time

TIMEOUT = 240

# A real terminal gets escape sequences mixed into the text - bracketed paste
# brackets a shell's output with \x1b[?2004h and \x1b[?2004l, with no newline
# between them and what was printed. Matching on the raw stream means matching
# on those, so strip them before looking.
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\r")


class Session:
    def __init__(self, argv, cwd):
        # Raw, and a stripped view derived from it. Stripping each read on its
        # own loses any escape sequence that straddles a read boundary, which
        # then shows up in the middle of the text being matched.
        self.raw = ""
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            # A terminal the guest's shell will be happy with.
            os.environ["TERM"] = "xterm-256color"
            os.execvp(argv[0], argv)

    def expect(self, pattern, timeout=TIMEOUT, what=None):
        """Read until pattern shows up. Returns the text consumed."""
        rx = re.compile(pattern)
        deadline = time.time() + timeout
        while True:
            if rx.search(self.buf):
                return self.buf
            if time.time() > deadline:
                raise TimeoutError(
                    f"timed out waiting for {what or pattern!r}\n"
                    f"--- last 2000 chars seen ---\n{self.buf[-2000:]}")
            r, _, _ = select.select([self.fd], [], [], 1.0)
            if not r:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:  # the child closed the pty
                if rx.search(self.buf):
                    return self.buf
                raise TimeoutError(
                    f"session ended before {what or pattern!r}\n"
                    f"--- last 2000 chars seen ---\n{self.buf[-2000:]}")
            if not chunk:
                raise TimeoutError(f"eof before {what or pattern!r}")
            self.raw += chunk.decode("utf-8", "replace")

    @property
    def buf(self):
        return ANSI.sub("", self.raw)

    def send(self, line):
        os.write(self.fd, (line + "\n").encode())

    def wait(self, timeout=120):
        deadline = time.time() + timeout
        while time.time() < deadline:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return os.waitstatus_to_exitcode(status)
            # Keep draining, or the guest blocks on a full pty buffer.
            r, _, _ = select.select([self.fd], [], [], 0.5)
            if r:
                try:
                    self.raw += os.read(self.fd, 65536).decode("utf-8", "replace")
                except OSError:
                    pass
        raise TimeoutError("the VM did not shut down after exit")


def main():
    project = sys.argv[1]
    firecode = sys.argv[2] if len(sys.argv) > 2 else "firecode"

    s = Session([firecode, "shell", "--no-jail", "--no-net"], project)

    s.expect(r"firecode microVM", what="the guest banner")
    print("  ok    the banner appears on the console")

    s.expect(r"@firecode:[^\r\n]*[$#]", what="a shell prompt")
    print("  ok    an interactive shell is waiting")

    s.send("id -un; pwd")
    s.expect(r"\ndead\n", what="the shell running as the host user")
    print("  ok    the shell runs as the host user")

    s.expect(re.escape(project), what="the project directory as cwd")
    print("  ok    it starts in the project directory")

    s.send("echo INTERACTIVE-$((6*7))-OK")
    s.expect(r"INTERACTIVE-42-OK", what="a command to run")
    print("  ok    commands run and their output comes back")

    s.send("exit")
    s.expect(r"shutting down", what="the shutdown notice")
    print("  ok    exiting the shell shuts the VM down")

    code = s.wait()
    if code != 0:
        print(f"  FAIL  firecode exited {code}")
        return 1
    print("  ok    firecode exits cleanly")

    if "result:" not in s.buf:
        print("  FAIL  no result directory was reported")
        return 1
    print("  ok    the work is copied back out")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except TimeoutError as exc:
        print(f"  FAIL  {exc}")
        sys.exit(1)
