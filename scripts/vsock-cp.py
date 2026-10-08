#!/usr/bin/env python3
"""Move files in or out of a running guest, over vsock.

Firecracker cannot mount a host directory into a guest - it has no virtio-fs
and no 9p, on purpose - so the only live channel is vsock. This streams a tar
through it, in either direction.

usage:
  vsock-cp.py <uds> <port> get <guest-path> <host-path> [--limit MB]
  vsock-cp.py <uds> <port> put <host-path> <guest-path>   (guest-path/ = into that directory)
"""

import os
import socket
import subprocess
import sys
import tarfile
import tempfile

BUF = 65536


def connect(uds_path, port):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(15)
    sock.connect(uds_path)
    sock.sendall(b"CONNECT %d\n" % port)
    reply = b""
    while not reply.endswith(b"\n"):
        chunk = sock.recv(1)
        if not chunk:
            raise SystemExit("the guest closed the connection during the handshake")
        reply += chunk
    if not reply.startswith(b"OK"):
        raise SystemExit(f"guest refused the connection: {reply!r}")
    sock.settimeout(None)
    return sock


def get(sock, guest_path, host_path, limit):
    """Unpack what the guest sends. The guest is not trusted, so this does not
    hand the stream to tar and hope: an archive from in there can name
    ../../.ssh, carry a symlink pointing out of the destination, set a setuid
    bit, or simply never end. Python's "data" filter rejects the first three,
    and the byte limit deals with the fourth."""
    sock.sendall(f"GET {guest_path}\n".encode())
    os.makedirs(host_path, exist_ok=True)

    # Buffered to a file first: extraction filters need to seek, and a stream
    # that never ends should hit the limit before it hits the disk.
    n = 0
    with tempfile.TemporaryFile() as spool:
        while True:
            data = sock.recv(BUF)
            if not data:
                break
            n += len(data)
            if n > limit:
                raise SystemExit(
                    f"the guest sent more than {limit // (1024 * 1024)}M - "
                    "refusing it (raise with --limit)")
            spool.write(data)
        if n == 0:
            raise SystemExit(f"the guest has nothing at {guest_path}")
        spool.seek(0)
        # CHECKED WHOLE, THEN EXTRACTED. Streaming extraction wrote every member
        # before the first bad one, so a refusal left a partial tree behind -
        # and only some of the filter's errors were caught, so the rest ended
        # in a traceback. The spool is seekable, so every member goes through
        # the same "data" filter first, nothing is written unless all pass,
        # and the unpacked size is held to the same limit as the bytes sent:
        # "r:*" decompresses, and a small gzip can unpack to anything.
        try:
            with tarfile.open(fileobj=spool, mode="r:*") as tar:
                members, unpacked = [], 0
                for m in tar.getmembers():
                    members.append(tarfile.data_filter(m, host_path))
                    unpacked += m.size
                    if unpacked > limit:
                        raise SystemExit(
                            f"the archive unpacks to more than "
                            f"{limit // (1024 * 1024)}M - refusing it (raise with --limit)")
                tar.extractall(host_path, members=members, filter="data")
        except tarfile.OutsideDestinationError as exc:
            raise SystemExit(f"refused, nothing written: the archive tried to escape - {exc}")
        except tarfile.FilterError as exc:
            raise SystemExit(f"refused, nothing written: {exc}")
        except tarfile.TarError as exc:
            raise SystemExit(f"refused, nothing written: not a readable archive - {exc}")
    print(f"{n // 1024}K from {guest_path} into {host_path}")


def confirmation(sock):
    """The guest's one-line answer to a PUT. Nothing at all is a failure: a
    guest that took the bytes and said nothing - an older file server, or one
    that died - has confirmed nothing, and saying "copied" then is how stale
    files got run."""
    sock.shutdown(socket.SHUT_WR)
    reply = b""
    while not reply.endswith(b"\n"):
        chunk = sock.recv(BUF)
        if not chunk:
            break
        reply += chunk
    line = reply.decode(errors="replace").strip()
    if line == "OK":
        return
    if line.startswith("ERR "):
        raise SystemExit(f"refused by the guest: {line[4:]}")
    raise SystemExit("the guest did not confirm the write - assume nothing was written"
                     + (f" (it said {line!r})" if line else ""))


def put(sock, host_path, guest_path):
    """A file becomes a file and a directory's contents go into a directory.
    The guest decides against what is actually there (see guest/fileserver.sh
    for the rules); a destination ending in a slash means "into this
    directory", the way cp and rsync read it."""
    if os.path.isdir(host_path):
        sock.sendall(f"PUTDIR {guest_path}\n".encode())
        tar = subprocess.Popen(["tar", "-C", host_path, "-cf", "-", "."],
                               stdout=subprocess.PIPE)
        n = 0
        while True:
            data = tar.stdout.read(BUF)
            if not data:
                break
            sock.sendall(data)
            n += len(data)
        tar.stdout.close()
        if tar.wait() != 0:
            raise SystemExit(f"reading {host_path} failed - the guest may hold part of it")
    else:
        if guest_path.endswith("/"):
            guest_path += os.path.basename(host_path)
        st = os.stat(host_path)
        sock.sendall(f"PUTFILE {st.st_size} {st.st_mode & 0o777:o} {guest_path}\n".encode())
        n = 0
        with open(host_path, "rb") as fh:
            while True:
                data = fh.read(BUF)
                if not data:
                    break
                sock.sendall(data)
                n += len(data)
    confirmation(sock)
    print(f"{n // 1024}K from {host_path} into {guest_path}")


def main(argv):
    if len(argv) < 5:
        print(__doc__)
        return 2
    uds, port, verb, a, b = argv[0], int(argv[1]), argv[2], argv[3], argv[4]
    limit = 4096
    if "--limit" in argv:
        limit = int(argv[argv.index("--limit") + 1])
    sock = connect(uds, port)
    try:
        if verb == "get":
            get(sock, a, b, limit * 1024 * 1024)
        elif verb == "put":
            put(sock, a, b)
        else:
            print(__doc__)
            return 2
    finally:
        sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
