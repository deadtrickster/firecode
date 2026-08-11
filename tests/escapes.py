#!/usr/bin/env python3
"""What a guest may and may not write to your terminal.

A terminal executes some of what is printed at it, and everything the guest
prints is attacker-controlled. Prints one "ok <name>" or "NO <name>" per check.
"""

import importlib.util
import os
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "termfilter", os.path.join(root, "scripts", "termfilter.py"))
tf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tf)

CHECKS = [
    ("the clipboard is not the guest's to set", b"\x1b]52;c;aGFjaw==\x07", False),
    ("no payload to the terminal (APC)", b"\x1b_Gpayload\x1b\\", False),
    ("no payload to the terminal (DCS)", b"\x1bP+q544\x1b\\", False),
    ("no wiping the screen and scrollback", b"\x1bc", False),
    ("colour still renders", b"\x1b[31mred\x1b[0m", True),
    ("cursor movement still renders", b"\x1b[2J\x1b[H", True),
    ("the window title is still allowed", b"\x1b]0;title\x07", True),
]


def main():
    bad = 0
    for name, data, should_pass in CHECKS:
        passed = tf.Filter().feed(data) == data
        print(("ok " if passed == should_pass else "NO ") + name)
        bad += passed != should_pass

    # Splitting a sequence across reads is the obvious way to walk past a
    # filter that looks at one chunk at a time.
    f = tf.Filter()
    out = f.feed(b"\x1b]52;c;aGFj") + f.feed(b"aw==\x07tail")
    print(("ok " if b"aGFj" not in out else "NO ")
          + "a sequence split across reads is still caught")
    print(("ok " if out == b"tail" else "NO ") + "and what follows it survives")
    bad += b"aGFj" in out or out != b"tail"

    # An unattended run prints logs, so nothing but text needs to get through.
    strict = tf.Filter(strict=True).feed(b"\x1b[31mred\x1b[0m\nplain\ttext\n")
    print(("ok " if strict == b"red\nplain\ttext\n" else "NO ")
          + "unattended output is text only")
    bad += strict != b"red\nplain\ttext\n"

    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
