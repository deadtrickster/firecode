#!/usr/bin/env python3
"""What `firecode cp host vm:path` does to the guest's filesystem.

Hermetic: a unix socket stands in for firecracker's vsock (it answers the
CONNECT handshake), and behind it runs the real guest/fileserver.sh against a
temporary directory on this machine. The client is the real
scripts/vsock-cp.py, run as a separate process, so its exit status is what a
caller sees.

The rules being held:
  file -> missing path          a regular file at that path
  file -> existing regular file replaced, atomically (temp + rename), no debris
  file -> path/ (trailing slash) the file goes inside that directory
  file -> existing directory    refused, loudly, directory untouched
  file -> path under a file     refused, nothing created
  dir  -> missing / directory   contents unpacked into it
  dir  -> existing file         refused, file untouched
  a guest that never confirms   the client fails, it does not claim success

Prints `ok <what>` or `NO <what>: <why>` per check; exits 1 if any failed.
"""
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLIENT = os.path.join(ROOT, "scripts", "vsock-cp.py")
SERVER = os.path.join(ROOT, "guest", "fileserver.sh")

failed = 0


def check(what, cond, why=""):
    global failed
    if cond:
        print(f"ok {what}")
    else:
        failed += 1
        print(f"NO {what}: {why}")


def fake_vsock(uds, argv):
    """Accept connections forever; each one gets the handshake and then argv
    with the connection as its stdin and stdout, as socat EXEC does."""
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(uds)
    srv.listen(8)

    def one(conn):
        line = b""
        while not line.endswith(b"\n"):
            c = conn.recv(1)
            if not c:
                conn.close()
                return
            line += c
        conn.sendall(b"OK 1073741824\n")
        subprocess.run(argv, stdin=conn.fileno(), stdout=conn.fileno(),
                       stderr=subprocess.DEVNULL)
        conn.close()

    def loop():
        while True:
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            threading.Thread(target=one, args=(conn,), daemon=True).start()
    threading.Thread(target=loop, daemon=True).start()
    return srv


work = tempfile.mkdtemp(prefix="cpin.")
try:
    uds = os.path.join(work, "v.sock")
    fake_vsock(uds, ["bash", SERVER])
    g = os.path.join(work, "guest")
    os.makedirs(g)
    h = os.path.join(work, "host")
    os.makedirs(h)

    def put(src, dst, sock=uds):
        p = subprocess.run([sys.executable, CLIENT, sock, "1025", "put", src, dst],
                           capture_output=True, text=True, timeout=30)
        return p.returncode, (p.stdout + p.stderr).strip()

    def read(p):
        with open(p) as fh:
            return fh.read()

    src = os.path.join(h, "03-mirror.sh")
    with open(src, "w") as fh:
        fh.write("echo one\n")
    os.chmod(src, 0o755)

    dst = os.path.join(g, "03-mirror.sh")
    rc, out = put(src, dst)
    check("a file onto a missing path exits 0", rc == 0, out)
    check("and is a regular file, not a directory", os.path.isfile(dst) and not os.path.isdir(dst),
          "a directory" if os.path.isdir(dst) else "missing")
    check("with the content sent", os.path.isfile(dst) and read(dst) == "echo one\n",
          os.listdir(dst) if os.path.isdir(dst) else "")
    check("and the mode it had", os.path.isfile(dst) and os.stat(dst).st_mode & 0o777 == 0o755,
          oct(os.stat(dst).st_mode) if os.path.exists(dst) else "missing")

    with open(src, "w") as fh:
        fh.write("echo two, changed\n")
    rc, out = put(src, dst)
    check("a changed file over an existing one exits 0", rc == 0, out)
    check("and the guest has the new content", os.path.isfile(dst) and read(dst) == "echo two, changed\n",
          read(dst) if os.path.isfile(dst) else "not a regular file")
    check("and no temporary file is left beside it", sorted(os.listdir(g)) == ["03-mirror.sh"],
          sorted(os.listdir(g)))

    into = os.path.join(g, "scripts")
    os.makedirs(into)
    rc, out = put(src, into)
    check("a file onto an existing directory is refused", rc != 0, out)
    check("by saying it is a directory", "directory" in out, out)
    check("and the directory is untouched", os.listdir(into) == [], os.listdir(into))

    rc, out = put(src, into + "/")
    check("a file onto dir/ goes inside it", rc == 0 and os.path.isfile(os.path.join(into, "03-mirror.sh")),
          f"{rc} {out} {os.listdir(into)}")

    rc, out = put(src, os.path.join(dst, "inner.sh"))
    check("a path under an existing file is refused", rc != 0, out)
    check("and the file is still a file", os.path.isfile(dst), "replaced by a directory")

    tree = os.path.join(h, "tree")
    os.makedirs(os.path.join(tree, "sub"))
    with open(os.path.join(tree, "sub", "a.txt"), "w") as fh:
        fh.write("a")
    rc, out = put(tree, os.path.join(g, "newtree"))
    check("a directory onto a missing path unpacks into it",
          rc == 0 and read(os.path.join(g, "newtree", "sub", "a.txt")) == "a", out)
    rc, out = put(tree, dst)
    check("a directory onto an existing file is refused", rc != 0, out)
    check("and the file is untouched", os.path.isfile(dst) and read(dst) == "echo two, changed\n", "")

    # A guest that takes the bytes and says nothing - an older fileserver, or
    # one that died - must not be reported as a successful copy.
    mute = os.path.join(work, "mute.sock")
    fake_vsock(mute, ["sh", "-c", "cat >/dev/null"])
    rc, out = put(src, os.path.join(g, "mute.sh"), sock=mute)
    check("a guest that never confirms the write is a failure", rc != 0, out)
finally:
    shutil.rmtree(work, ignore_errors=True)

sys.exit(1 if failed else 0)
