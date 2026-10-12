"""Reaching a Unix socket whose PATH is longer than the kernel allows.

A Unix socket path is capped at 108 bytes - the limit counts the path STRING
passed to connect(), not the file it names. firecode builds its vsock socket
from the checkout's absolute path:

    /home/dead/Projects/firecode/.jail/firecracker/<run>/root/firecracker-vsock.sock

That is 107 bytes. It fits, by ONE. The same run in a deeper checkout is:

    /home/dead/.local/share/letibot/landing/firecode-<id>/.jail/firecracker/<run>/root/...

which is 140, and connect() fails with "AF_UNIX path too long" - surfacing as
"could not reach the guest console". The merge queue lands every branch into a
tree of exactly that depth, so console, exec and cp into a guest all failed
there while working perfectly in the checkout it was written in.

Nothing is wrong with the socket or where it lives: firecracker binds it by the
short relative name inside its jail and is never affected. Only this side, which
addresses it by the full path, is. So the DIRECTORY is entered first and the
socket named relative to it - the kernel then resolves a short name, and how
deep the checkout happens to sit stops mattering.
"""

import os
import socket


def connect(path, timeout=None):
    """A connected AF_UNIX socket for `path`, however long the path is."""
    directory = os.path.dirname(os.path.abspath(path))
    name = os.path.basename(path.rstrip("/"))

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    if timeout is not None:
        sock.settimeout(timeout)

    cwd = os.getcwd()
    try:
        os.chdir(directory)
        try:
            sock.connect(name)
        except OSError:
            sock.close()
            raise
    finally:
        # The callers include relays that keep working in their own directory,
        # so this one must not leak into theirs. The connection survives it:
        # the path is only needed to establish it.
        os.chdir(cwd)
    return sock
