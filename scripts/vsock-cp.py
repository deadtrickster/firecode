#!/usr/bin/env python3
"""Move files in or out of a running guest, over vsock.

Firecracker cannot mount a host directory into a guest - it has no virtio-fs
and no 9p, on purpose - so the only live channel is vsock. This streams a tar
through it, in either direction.

usage:
  vsock-cp.py <uds> <port> get <guest-path> <host-path>
  vsock-cp.py <uds> <port> put <host-path> <guest-path>
"""

import os
import socket
import subprocess
import sys

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


def get(sock, guest_path, host_path):
    sock.sendall(f"GET {guest_path}\n".encode())
    os.makedirs(host_path, exist_ok=True)
    tar = subprocess.Popen(["tar", "-C", host_path, "-xf", "-"],
                           stdin=subprocess.PIPE)
    n = 0
    while True:
        data = sock.recv(BUF)
        if not data:
            break
        tar.stdin.write(data)
        n += len(data)
    tar.stdin.close()
    if tar.wait() != 0:
        raise SystemExit("unpacking what the guest sent failed")
    if n == 0:
        raise SystemExit(f"the guest has nothing at {guest_path}")
    print(f"{n // 1024}K from {guest_path} into {host_path}")


def put(sock, host_path, guest_path):
    sock.sendall(f"PUT {guest_path}\n".encode())
    if os.path.isdir(host_path):
        cmd = ["tar", "-C", host_path, "-cf", "-", "."]
    else:
        cmd = ["tar", "-C", os.path.dirname(host_path) or ".", "-cf", "-",
               os.path.basename(host_path)]
    tar = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    n = 0
    while True:
        data = tar.stdout.read(BUF)
        if not data:
            break
        sock.sendall(data)
        n += len(data)
    tar.stdout.close()
    tar.wait()
    # Let the guest finish unpacking before the socket goes away.
    sock.shutdown(socket.SHUT_WR)
    sock.recv(BUF)
    print(f"{n // 1024}K from {host_path} into {guest_path}")


def main(argv):
    if len(argv) < 5:
        print(__doc__)
        return 2
    uds, port, verb, a, b = argv[0], int(argv[1]), argv[2], argv[3], argv[4]
    sock = connect(uds, port)
    try:
        if verb == "get":
            get(sock, a, b)
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
