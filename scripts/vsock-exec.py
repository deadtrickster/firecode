#!/usr/bin/env python3
"""Run one command in a VM that is already running, over vsock.

The console is for a person and hands out a pty; this is for a program. It
returns what the command printed and exits with the command's own status, so
a caller can tell a failing test suite from one that never started.

usage: vsock-exec.py <uds> <port> <cwd|-> <command...>
"""

import base64
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

    # Two ways to reach the same guest listener, because the two hypervisors
    # expose vsock differently. firecracker multiplexes it over a unix socket
    # and wants "CONNECT <port>" first; qemu gives the host a real AF_VSOCK
    # socket and the guest is addressed by cid. The guest side is identical
    # either way, which is what makes one guest image serve both.
    if uds.startswith("cid:"):
        sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        sock.settimeout(15)
        sock.connect((int(uds[4:]), port))
        sock.settimeout(None)
    else:
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

    # base64, because a command is not a line: sent raw, anything containing a
    # newline was cut at the first one and the remainder ran anyway.
    encoded = base64.b64encode(command.encode()).decode()
    sock.sendall(f"{cwd}\n{encoded}\n".encode())

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
            # Anywhere in the line, not only at the start of one. The trailer
            # is written after the command's own output, so it shares a line
            # with it whenever that output did not end in a newline - which
            # `printf hi` and `base64 -w0` both do. Looked for only at the
            # start, the status was never read (every such command "failed"
            # with 1) and the sentinel was handed back as if it were output.
            cut = line.rfind(TRAILER)
            if cut != -1:
                try:
                    status = int(line[cut + len(TRAILER):] or b"1")
                except ValueError:
                    status = 1
                line = line[:cut]
                if line:
                    out.write(scrub.feed(line))
                    out.flush()
                continue
            out.write(scrub.feed(line + b"\n"))
            out.flush()
    # Whatever is left when the guest hangs up. The trailer is only on a line
    # of its own when the command's output happened to end with a newline -
    # `printf hi` or `base64 -w0` leaves it welded to the last line, and
    # looking for it only at the start of one meant the status was never read
    # (so every such command "failed" with 1) and the trailer was handed back
    # as part of the output.
    if tail:
        cut = tail.rfind(TRAILER)
        if cut != -1:
            rest = tail[cut + len(TRAILER):]
            try:
                status = int(rest.split(b"\n", 1)[0] or b"1")
            except ValueError:
                status = 1
            tail = tail[:cut]
        if tail:
            out.write(scrub.feed(tail))
            out.flush()
    sock.close()
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
