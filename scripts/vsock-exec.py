#!/usr/bin/env python3
"""Run one command in a VM that is already running, over vsock.

The console is for a person and hands out a pty; this is for a program. It
returns what the command printed and exits with the command's own status, so
a caller can tell a failing test suite from one that never started.

usage: vsock-exec.py <uds> <port> <cwd|-> <command...>
"""

import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from termfilter import Filter  # noqa: E402

BUF = 65536
TRAILER = b"__firecode_exit "


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    uds, port, cwd = argv[0], int(argv[1]), argv[2]
    command = " ".join(argv[3:])

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(15)
    sock.connect(uds)
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

    sock.sendall(f"{cwd}\n{command}\n".encode())

    # The guest's output is filtered like anything else it prints at us.
    scrub = Filter(strict=True)
    out = sys.stdout.buffer
    tail = b""
    status = 1
    while True:
        data = sock.recv(BUF)
        if not data:
            break
        tail += data
        # Hold back the last partial line: the exit status arrives as one, and
        # it belongs to the protocol rather than to the command's output.
        while b"\n" in tail:
            line, tail = tail.split(b"\n", 1)
            if line.startswith(TRAILER):
                try:
                    status = int(line[len(TRAILER):])
                except ValueError:
                    status = 1
                continue
            out.write(scrub.feed(line + b"\n"))
            out.flush()
    if tail:
        out.write(scrub.feed(tail))
        out.flush()
    sock.close()
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
