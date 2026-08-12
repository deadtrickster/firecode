#!/usr/bin/env python3
"""Credentials stay on the host; VMs get an endpoint.

A VM has to reach the model API, and the obvious way - copy the credentials in
- is wrong twice over.

It puts your token inside every VM, which is the one thing in there that is
worth stealing and the one thing the isolation cannot protect: a VM cannot
touch your filesystem, but it holds your API session.

And it does not survive. OAuth refresh tokens rotate: when a VM refreshes, the
provider invalidates the copy the *host* holds, so a long unattended run
either dies of an expired session or takes your desktop's login down with it.
Two VMs refreshing at once invalidate each other. Refresh is single-writer
state, and a fleet of copies is many writers.

So: one holder of the credentials, and an endpoint for everyone else. This
reads the host's current token per request - so whenever the host refreshes,
guests follow immediately - strips whatever a guest sent, and forwards.

    auth-relay.py --port 9770 [--upstream https://api.anthropic.com]

Point a guest at it with ANTHROPIC_BASE_URL and give it no credentials at all.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CREDS = os.path.expanduser("~/.claude/.credentials.json")

# Never forwarded from a guest: the point is that its request is authenticated
# by this process, with this machine's token, and never by anything it chose to
# send. Hop-by-hop headers go too, being meaningless to the upstream.
STRIP = {"authorization", "x-api-key", "host", "connection", "content-length",
         "transfer-encoding", "keep-alive", "proxy-authorization", "te",
         "upgrade", "cookie"}


def current_token():
    """The host's token, read fresh per request.

    Re-read rather than cached: the host's own client refreshes during normal
    use, and a cached copy would go stale exactly when a long run needed it.
    """
    try:
        with open(CREDS) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None, "no credentials on the host"
    oauth = data.get("claudeAiOauth") or {}
    token = oauth.get("accessToken")
    if not token:
        return None, "no access token in the host's credentials"
    # expiresAt is milliseconds. Reported rather than refreshed here: refreshing
    # is the host client's job, and doing it from two places is what rotates a
    # token out from under the other one.
    import time
    if oauth.get("expiresAt") and oauth["expiresAt"] / 1000 < time.time():
        return token, "the host's token has expired - refresh it there"
    return token, None


class Relay(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass                                    # one line per token is noise

    def _relay(self, body=None):
        token, why = current_token()
        if token is None:
            self.send_error(503, why)
            return

        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in STRIP}
        headers["Authorization"] = f"Bearer {token}"
        headers.setdefault("anthropic-version", "2023-06-01")

        url = self.server.upstream.rstrip("/") + self.path
        req = urllib.request.Request(url, data=body, headers=headers,
                                     method=self.command)
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() in ("transfer-encoding", "connection",
                                     "content-length"):
                        continue
                    self.send_header(k, v)
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                # Chunked, so a streamed response arrives as it is produced
                # rather than at the end - which for a long completion is the
                # difference between watching it work and watching nothing.
                while True:
                    chunk = resp.read(8192)
                    if not chunk:
                        break
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
        except urllib.error.HTTPError as exc:
            payload = exc.read()
            self.send_response(exc.code)
            self.send_header("Content-Type",
                             exc.headers.get("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except (urllib.error.URLError, OSError) as exc:
            self.send_error(502, f"upstream unreachable: {exc}")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self._relay(self.rfile.read(length) if length else None)

    def do_GET(self):
        self._relay()


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9770)
    ap.add_argument("--upstream", default="https://api.anthropic.com")
    args = ap.parse_args(argv)

    token, why = current_token()
    if token is None:
        print(f"auth-relay: {why}", file=sys.stderr)
        return 1
    if why:
        print(f"auth-relay: warning: {why}", file=sys.stderr)

    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Relay)
    srv.upstream = args.upstream
    print(f"auth-relay: 127.0.0.1:{args.port} -> {args.upstream}, "
          "credentials stay here", file=sys.stderr)
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
