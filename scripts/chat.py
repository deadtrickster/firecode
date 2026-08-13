#!/usr/bin/env python3
"""A room every agent on this machine can talk in.

Agents here work in isolation by construction: one per VM, or one per session,
each seeing only its own task. That is the point of the harness and it is also
its blind spot - two of them can spend an hour on the same wrong assumption
without ever finding out, and a person watching has to relay by hand.

So: one room, on a port. Post to it, read from it, from a VM or from the host.
No accounts, no history beyond a file, no delivery guarantees. It is a room,
not a protocol.

    chat.py --port 9760 [--log runs/chat.log]

    POST /say      {"from": "...", "text": "..."}     -> {"id": N}
    GET  /messages?since=N&wait=30                    -> {"messages": [...]}
    GET  /                                            -> the log, as text

`wait` is what makes it usable by an agent: the request blocks until something
is said or the wait runs out, so reading the room costs one call rather than a
poll every few seconds.
"""

import argparse
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

MESSAGES = []
LOCK = threading.Lock()
SPOKE = threading.Condition(LOCK)
LOG_PATH = None


def say(who, text):
    with SPOKE:
        msg = {"id": len(MESSAGES) + 1, "at": time.time(),
               "from": who or "someone", "text": text}
        MESSAGES.append(msg)
        SPOKE.notify_all()
    if LOG_PATH:
        try:
            with open(LOG_PATH, "a") as fh:
                fh.write(json.dumps(msg) + "\n")
        except OSError:
            pass
    return msg


def since(mark, wait):
    """Messages after `mark`, waiting up to `wait` seconds for the first one."""
    deadline = time.time() + max(0.0, wait)
    with SPOKE:
        while True:
            out = [m for m in MESSAGES if m["id"] > mark]
            if out or time.time() >= deadline:
                return out
            SPOKE.wait(timeout=min(5.0, max(0.1, deadline - time.time())))


def as_text(msgs):
    lines = []
    for m in msgs:
        stamp = time.strftime("%H:%M:%S", time.localtime(m["at"]))
        lines.append(f"[{stamp}] {m['from']}: {m['text']}")
    return "\n".join(lines)


class Room(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype="application/json"):
        payload = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        if urlparse(self.path).path != "/say":
            return self._send(404, '{"error":"say to /say"}')
        length = int(self.headers.get("Content-Length") or 0)
        try:
            data = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self._send(400, '{"error":"send json"}')
        text = (data.get("text") or "").strip()
        if not text:
            return self._send(400, '{"error":"nothing to say"}')
        msg = say(data.get("from"), text)
        self._send(200, json.dumps({"id": msg["id"]}))

    def do_GET(self):
        parts = urlparse(self.path)
        query = parse_qs(parts.query)
        if parts.path == "/messages":
            mark = int((query.get("since") or ["0"])[0])
            # Capped: this holds a worker thread, and a caller that wants
            # longer can ask again with the id it already has.
            wait = min(float((query.get("wait") or ["0"])[0]), 120.0)
            msgs = since(mark, wait)
            last = msgs[-1]["id"] if msgs else mark
            return self._send(200, json.dumps({"messages": msgs, "last": last}))
        if parts.path in ("/", "/log"):
            with LOCK:
                body = as_text(MESSAGES) or "(nobody has said anything yet)"
            return self._send(200, body + "\n", "text/plain; charset=utf-8")
        self._send(404, '{"error":"/say, /messages or /"}')


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9760)
    ap.add_argument("--log", default="")
    args = ap.parse_args(argv)

    global LOG_PATH
    if args.log:
        LOG_PATH = args.log
        os.makedirs(os.path.dirname(os.path.abspath(LOG_PATH)) or ".", exist_ok=True)
        # Carry on from what is already there, so a restart does not look to
        # everyone like the room was emptied.
        try:
            with open(LOG_PATH) as fh:
                for line in fh:
                    try:
                        MESSAGES.append(json.loads(line))
                    except ValueError:
                        continue
            for i, m in enumerate(MESSAGES, 1):
                m["id"] = i
        except OSError:
            pass

    srv = ThreadingHTTPServer(("0.0.0.0", args.port), Room)
    print(f"chat: 0.0.0.0:{args.port}, {len(MESSAGES)} message(s) so far",
          file=sys.stderr)
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
