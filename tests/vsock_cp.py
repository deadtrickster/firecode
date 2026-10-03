#!/usr/bin/env python3
"""What `firecode cp` accepts from a guest.

Hermetic: a socket pair stands in for the guest, and get() unpacks what it
sends. A refused archive must leave nothing behind and end in a message, not
a traceback; a small compressed archive must not unpack to anything it likes.

Prints `ok <what>` or `NO <what>: <why>` per check; exits 1 if any failed.
"""
import atexit
import importlib.util
import io
import os
import shutil
import socket
import sys
import tarfile
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "vsock_cp", os.path.join(ROOT, "scripts", "vsock-cp.py"))
vcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vcp)

failed = 0


def check(what, cond, why=""):
    global failed
    if cond:
        print(f"ok {what}")
    else:
        failed += 1
        print(f"NO {what}: {why}")


def tar_of(entries, gz=False):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz" if gz else "w") as t:
        for name, data in entries:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def serve(payload, limit=1024 * 1024):
    """Run get() against a fake guest; return (dest, message or None)."""
    a, b = socket.socketpair()

    def guest():
        b.recv(4096)                   # the GET line
        b.sendall(payload)
        b.close()
    threading.Thread(target=guest, daemon=True).start()
    dest = tempfile.mkdtemp(prefix="vcp.")
    atexit.register(shutil.rmtree, dest, True)
    try:
        vcp.get(a, "/x", dest, limit)
        return dest, None
    except SystemExit as exc:
        return dest, str(exc)
    finally:
        a.close()


dest, msg = serve(tar_of([("a.txt", b"hello")]))
check("a plain archive unpacks", msg is None and open(os.path.join(dest, "a.txt")).read() == "hello", msg)

dest, msg = serve(tar_of([("first.txt", b"x"), ("../escape.txt", b"y")]))
check("an escaping member is refused with a message", msg and "refused" in msg, msg)
check("and nothing before it was written", os.listdir(dest) == [], os.listdir(dest))

dest, msg = serve(tar_of([("/tmp/vcp-abs-probe.txt", b"y")]))
check("an absolute member lands inside the destination, not at its path",
      msg is None and os.path.exists(os.path.join(dest, "tmp/vcp-abs-probe.txt"))
      and not os.path.exists("/tmp/vcp-abs-probe.txt"), msg)

bomb = tar_of([("zeros", b"\0" * (8 * 1024 * 1024))], gz=True)
dest, msg = serve(bomb, limit=1024 * 1024)
check("a small gzip that unpacks past the limit is refused",
      len(bomb) < 1024 * 1024 and msg and "unpacks to more" in msg, msg)

dest, msg = serve(b"this is not a tar archive at all" * 40)
check("garbage is refused with a message, not a traceback", msg and "refused" in msg, msg)

sys.exit(1 if failed else 0)
