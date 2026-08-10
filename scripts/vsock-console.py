#!/usr/bin/env python3
"""Attach this terminal to the guest's interactive console, over vsock.

Not the serial console. Firecracker's serial input path rewrites CR to LF, so
a full-screen application in the guest never sees Enter: it watches for \\r and
\\r cannot get through. Arrow keys and ordinary characters are untouched, which
is what makes it look like the application's fault rather than the transport's.

This goes around it. Firecracker accepts host-initiated vsock connections on
its unix socket: send "CONNECT <port>", get back "OK <n>", and from then on it
is a clean byte stream to a process in the guest - which socat has given a pty
of its own. The terminal here goes into raw mode and every byte is relayed
exactly as typed.

usage: vsock-console.py <uds-path> <guest-port> [--timeout SECONDS]
"""

import os
import select
import signal
import socket
import sys
import termios
import time
import tty

BUF = 65536


def connect(uds_path, port, timeout):
    """Wait for the guest's listener, then hand back a connected socket."""
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        try:
            sock.connect(uds_path)
            sock.sendall(b"CONNECT %d\n" % port)
            # Firecracker answers "OK <assigned port>\n" once the guest is
            # listening, and closes the connection when it is not.
            reply = b""
            while not reply.endswith(b"\n"):
                chunk = sock.recv(1)
                if not chunk:
                    raise ConnectionError("closed before the handshake finished")
                reply += chunk
            if reply.startswith(b"OK"):
                sock.settimeout(None)
                return sock
            last = reply.decode(errors="replace").strip()
        except (OSError, ConnectionError) as exc:
            last = str(exc)
        sock.close()
        time.sleep(0.25)
    raise SystemExit(f"could not reach the guest console: {last or 'timed out'}")


def relay(sock):
    """stdin -> guest, guest -> stdout, until either end goes away."""
    stdin = sys.stdin.fileno()
    stdout = sys.stdout.fileno()
    saved = None
    if os.isatty(stdin):
        saved = termios.tcgetattr(stdin)
        # Raw, so nothing here touches the bytes on their way through. This is
        # the entire point: the line discipline is what was eating Enter.
        tty.setraw(stdin)
    try:
        while True:
            ready, _, _ = select.select([stdin, sock], [], [])
            if stdin in ready:
                data = os.read(stdin, BUF)
                if not data:
                    break
                sock.sendall(data)
            if sock in ready:
                data = sock.recv(BUF)
                if not data:
                    break
                os.write(stdout, data)
    except (OSError, ConnectionError):
        pass
    finally:
        if saved is not None:
            termios.tcsetattr(stdin, termios.TCSADRAIN, saved)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    uds_path, port = argv[0], int(argv[1])
    timeout = 90.0
    if "--timeout" in argv:
        timeout = float(argv[argv.index("--timeout") + 1])

    # The guest owns the session; a stray Ctrl-C here should reach it as a
    # byte rather than killing the client out from under the terminal.
    signal.signal(signal.SIGINT, signal.SIG_IGN)

    sock = connect(uds_path, port, timeout)
    try:
        relay(sock)
    finally:
        sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
