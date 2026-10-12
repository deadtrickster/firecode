#!/usr/bin/env python3
"""Bring a running VM's copy of a project up to date with the host's tree.

    vsock-sync.py <uds> <port> <root> <manifest> [--baseline]

One way, host to guest, and only what changed: the tree is listed the way
firecode stages a project (git's own list when it is a repository - tracked
and untracked, minus what is ignored), compared with the manifest of the last
sync, and the difference sent in one connection over the exec channel - the
paths that are gone removed, the ones that changed or appeared untarred in
place. The guest's copy lives at the same path as the host's, so names need
no translating.

--baseline records the tree as it is now without sending anything. It is
taken just before a VM is started, whose copy is made from this tree a moment
later: anything that changes in between differs from the baseline and goes
across on the next sync, so nothing can be missed - only, at worst, sent twice.

Prints nothing unless something goes wrong. Exits 0 when the guest has the
tree, non-zero when it may not.
"""

import base64
import json
import os
import socket
import stat
import subprocess
import sys
import tarfile

TRAILER = b"__firecode_exit "


def listing(root):
    """Relative paths of the files (and links) a copy of root holds."""
    try:
        out = subprocess.run(
            ["git", "-C", root, "ls-files", "-z", "-co", "--exclude-standard"],
            capture_output=True, check=True).stdout
        names = [n for n in out.decode("utf-8", "surrogateescape").split("\0") if n]
    except (OSError, subprocess.CalledProcessError):
        names = []
        for d, dirs, files in os.walk(root):
            dirs[:] = [x for x in dirs if x != ".git"]
            for f in files:
                names.append(os.path.relpath(os.path.join(d, f), root))
    found = {}
    for n in names:
        try:
            st = os.lstat(os.path.join(root, n))
        except OSError:
            continue  # listed, then gone: a deletion, seen as one next time
        if stat.S_ISDIR(st.st_mode):
            continue  # a submodule's directory: its files are not ours
        key = [st.st_mtime_ns, st.st_size, st.st_mode]
        if stat.S_ISLNK(st.st_mode):
            key.append(os.readlink(os.path.join(root, n)))
        found[n] = key
    return found


def connect(uds, port):
    if uds.startswith("cid:"):
        sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        sock.settimeout(15)
        sock.connect((int(uds[4:]), port))
    else:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(15)
        sock.connect(uds)
        sock.sendall(b"CONNECT %d\n" % port)
        reply = b""
        while not reply.endswith(b"\n"):
            chunk = sock.recv(1)
            if not chunk:
                raise SystemExit("vsock-sync: the guest closed the connection during the handshake")
            reply += chunk
        if not reply.startswith(b"OK"):
            raise SystemExit(f"vsock-sync: the guest refused the connection: {reply!r}")
    sock.settimeout(None)
    return sock


def send(uds, port, root, changed, deleted):
    # Deletions first, then the archive on the command's stdin. -m: the files
    # get their extraction time, so a build in the guest sees them as newer
    # than anything it made from the old ones.
    gone = base64.b64encode("\0".join(deleted).encode("utf-8", "surrogateescape")).decode()
    # The connection's first line puts the command in root already.
    command = (
        (f"printf %s {gone} | base64 -d | xargs -0 rm -f -- && " if deleted else "")
        + "tar -x -m -f -"
    )
    sock = connect(uds, port)
    encoded = base64.b64encode(command.encode()).decode()
    sock.sendall(f"{root}\n{encoded}\n".encode())
    with sock.makefile("wb") as w:
        with tarfile.open(fileobj=w, mode="w|", format=tarfile.PAX_FORMAT) as tar:
            for n in changed:
                try:
                    tar.add(os.path.join(root, n), arcname=n, recursive=False)
                except OSError:
                    continue  # changed and then removed: next sync sees it gone
    sock.shutdown(socket.SHUT_WR)
    said = b""
    while True:
        data = sock.recv(65536)
        if not data:
            break
        said += data
    sock.close()
    cut = said.rfind(TRAILER)
    status = 1
    if cut != -1:
        try:
            status = int(said[cut + len(TRAILER):].split(b"\n", 1)[0] or b"1")
        except ValueError:
            status = 1
        said = said[:cut]
    if status != 0:
        sys.stderr.write(said.decode("utf-8", "replace"))
        sys.stderr.write(f"vsock-sync: the guest could not take the changes (status {status})\n")
    return status


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    uds, port, root, manifest = argv[0], int(argv[1]), os.path.abspath(argv[2]), argv[3]
    now = listing(root)
    if "--baseline" in argv:
        with open(manifest + ".new", "w") as fh:
            json.dump(now, fh)
        os.replace(manifest + ".new", manifest)
        return 0
    try:
        with open(manifest) as fh:
            before = json.load(fh)
    except (OSError, ValueError):
        before = {}
    changed = sorted(n for n, k in now.items() if before.get(n) != k)
    deleted = sorted(n for n in before if n not in now)
    if not changed and not deleted:
        return 0
    status = send(uds, port, root, changed, deleted)
    if status == 0:
        with open(manifest + ".new", "w") as fh:
            json.dump(now, fh)
        os.replace(manifest + ".new", manifest)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
