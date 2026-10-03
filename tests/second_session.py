#!/usr/bin/env python3
"""A second shell into a running VM leaves it running.

`firecode enter` - and fctop's shell key, which uses it - opens another
console session into a VM that already has one. Every session used to
reboot the VM when its shell exited, so leaving that second shell stopped
the VM out from under the first. Only the session that owns the VM - the
one `firecode shell` opened at boot - may end it.

    second_session.py <project> [firecode]

Prints `ok <what>` / `NO <what>: <why>`; exits 1 if anything failed.
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from interactive import Session  # noqa: E402

project = sys.argv[1]
fc = sys.argv[2] if len(sys.argv) > 2 else "firecode"
failed = 0


def check(what, cond, why=""):
    global failed
    print(f"ok {what}" if cond else f"NO {what}: {why}")
    failed += 0 if cond else 1


def running():
    out = subprocess.run([fc, "list", "--ids"], capture_output=True, text=True).stdout
    return any(line.split("\t")[1:2] == [project] for line in out.splitlines())


owner = Session([fc, "shell", "--no-jail", "--no-net"], project)
owner.expect(r"@firecode:[^\r\n]*[$#]", what="the owner's prompt")
second = Session([fc, "enter"], project)
second.expect(r"@firecode:[^\r\n]*[$#]", what="the second session's prompt")
second.send("exit")
second.wait(60)
time.sleep(3)
check("leaving a second shell leaves the VM running", running())
owner.send("echo OWNER-STILL-HERE")
owner.expect(r"OWNER-STILL-HERE", what="the owner's shell still working")
check("the owner's shell still works", True)
owner.send("exit")
owner.expect(r"shutting down", what="the owner's exit stopping the VM")
owner.wait(120)
time.sleep(2)
check("the owner's exit still stops it", not running())
sys.exit(1 if failed else 0)
