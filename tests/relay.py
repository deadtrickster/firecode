#!/usr/bin/env python3
"""The auth relay sends this machine's token to the upstream and nowhere else.

Hermetic: the relay runs in-process with a stub token, and the "upstream" is a
local server that records what reached it. A request target that is not a path
must be refused before any token is read, and must never reach the upstream.

Prints one line per check, `ok <what>` or `NO <what>: <why>`, and exits 1 if
anything failed.
"""
import http.server
import importlib.util
import os
import socket
import sys
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "auth_relay", os.path.join(ROOT, "scripts", "auth-relay.py"))
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)

failed = 0


def check(what, cond, why=""):
    global failed
    if cond:
        print(f"ok {what}")
    else:
        failed += 1
        print(f"NO {what}: {why}")


# --- the URL rule, alone
U = relay.upstream_url
check("a path is relayed", U("https://api.anthropic.com", "/v1/messages")
      == "https://api.anthropic.com/v1/messages")
check("a path under an upstream with a path stays under it",
      U("https://api.z.ai/api/anthropic", "/v1/messages")
      == "https://api.z.ai/api/anthropic/v1/messages")
for target in (".evil.com/x", "@evil.com/x", ":1@evil.com/x", "//evil.com/x",
               "evil.com", "http://evil.com/x", "/\\evil.com", ""):
    check(f"{target!r} is refused", U("https://api.anthropic.com", target) is None,
          f"built {U('https://api.anthropic.com', target)!r}")


# --- end to end: a fake upstream, the relay in front of it
seen = []


class Upstream(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        seen.append((self.path, self.headers.get("Authorization")))
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *a):
        pass


up = http.server.HTTPServer(("127.0.0.1", 0), Upstream)
threading.Thread(target=up.serve_forever, daemon=True).start()

reads = []


def token_fn():
    reads.append(1)
    return "SECRET", None


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), relay.Relay)
srv.upstream = f"http://127.0.0.1:{up.server_address[1]}"
srv.provider = "test"
srv.token_fn = token_fn
threading.Thread(target=srv.serve_forever, daemon=True).start()


def ask(target):
    c = socket.create_connection(srv.server_address, timeout=5)
    c.sendall(f"GET {target} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
    out = b""
    while chunk := c.recv(4096):
        out += chunk
    c.close()
    return out.split(b" ", 2)[1].decode()


status = ask(".evil.com/x")
check("a host-shaped target is answered 400", status == "400", f"got {status}")
check("a refused target never reaches the upstream", not seen, f"upstream saw {seen}")
check("a refused target never reads the token", not reads)

status = ask("/v1/models")
check("a path is relayed end to end", status == "200", f"got {status}")
check("the upstream gets the host's token, not the guest's",
      seen == [("/v1/models", "Bearer SECRET")], f"upstream saw {seen}")

sys.exit(1 if failed else 0)
