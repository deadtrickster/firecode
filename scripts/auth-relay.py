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

    auth-relay.py --port 9770 [--provider claude|xai] [--upstream URL]

Point a guest at it - ANTHROPIC_BASE_URL for claude, the provider's baseURL in
opencode's config for xai - and give it no credentials at all.
"""

import argparse
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CREDS = os.path.expanduser("~/.claude/.credentials.json")

# opencode's credential store, and what xAI's device-code flow needs to refresh
# what is in it. Taken from the opencode binary rather than invented: it is that
# client's login being refreshed, so it has to be that client's id.
XAI_CREDS = os.path.expanduser("~/.local/share/opencode/auth.json")
XAI_TOKEN_URL = "https://auth.x.ai/oauth2/token"
XAI_CLIENT_ID = "b1a00492-073a-47ea-816f-4c329264a828"

# One refresh at a time in this process, because a refresh token can be spent
# exactly once: two concurrent refreshes mean the second presents a token the
# first has already used, and xAI answers "invalid_grant: revoked" - which
# revokes the whole family, not just the request that raced.
_refresh_lock = threading.Lock()

# Never forwarded from a guest: the point is that its request is authenticated
# by this process, with this machine's token, and never by anything it chose to
# send. Hop-by-hop headers go too, being meaningless to the upstream.
STRIP = {"authorization", "x-api-key", "host", "connection", "content-length",
         "transfer-encoding", "keep-alive", "proxy-authorization", "te",
         "upgrade", "cookie"}


def claude_token():
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
    if oauth.get("expiresAt") and oauth["expiresAt"] / 1000 < time.time():
        return token, "the host's token has expired - refresh it there"
    return token, None


def xai_token():
    """The host's xAI token, refreshed here when it has expired.

    Unlike claude, this relay does refresh. It has to: opencode refreshes at
    startup and keeps the rotated pair in memory without writing it back, so
    the file on disk holds a refresh token that has already been spent - and
    the next process to read it, on the host or in a VM, is told the token was
    revoked. Somebody has to own the rotation and persist it. Here, that is
    this process, and the write-back is what makes the host's file usable
    again afterwards.
    """
    try:
        with open(XAI_CREDS) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None, f"no opencode credentials at {XAI_CREDS}"
    entry = data.get("xai") or {}
    access, refresh = entry.get("access"), entry.get("refresh")
    if not access:
        return None, "no xAI access token on the host - run: opencode auth login"

    # 60s of slack, so a token that would expire mid-request is renewed before
    # it is handed out rather than after it has failed.
    expires = (entry.get("expires") or 0) / 1000
    if expires and expires - 60 > time.time():
        return access, None
    if not refresh:
        return access, "the host's xAI token has expired and there is nothing to refresh with"

    with _refresh_lock:
        # Re-read under the lock: another thread may have refreshed while this
        # one waited, and spending the old token after that is what revokes the
        # family.
        try:
            with open(XAI_CREDS) as fh:
                fresh = (json.load(fh).get("xai") or {})
        except (OSError, ValueError):
            fresh = {}
        if fresh.get("access") and (fresh.get("expires") or 0) / 1000 - 60 > time.time():
            return fresh["access"], None
        refresh = fresh.get("refresh") or refresh

        body = urllib.parse.urlencode({
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": XAI_CLIENT_ID,
        }).encode()
        req = urllib.request.Request(
            XAI_TOKEN_URL, data=body, method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                got = json.load(resp)
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:200]
            return None, f"xAI refresh failed ({exc.code}): {detail}"
        except (urllib.error.URLError, OSError, ValueError) as exc:
            return None, f"xAI refresh failed: {exc}"

        entry = dict(entry)
        entry["access"] = got.get("access_token") or entry.get("access")
        entry["refresh"] = got.get("refresh_token") or refresh
        entry["expires"] = int((time.time() + (got.get("expires_in") or 3600)) * 1000)
        _write_creds(XAI_CREDS, "xai", entry)
        print("auth-relay: refreshed the host's xAI token", file=sys.stderr)
        return entry["access"], None


def _write_creds(path, key, entry):
    """Update one provider's entry, atomically, leaving the others alone.

    Whole-file replacement through a temp file in the same directory: a reader
    sees either the old file or the new one, never a half-written one, which
    for a credential store is the difference between a login and a re-login.
    """
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        data = {}
    data[key] = entry
    tmp = f"{path}.firecode.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh, indent=2)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except OSError as exc:
        print(f"auth-relay: could not write {path}: {exc}", file=sys.stderr)
        try:
            os.unlink(tmp)
        except OSError:
            pass


#: name -> (token function, default upstream). The guest is pointed at this
#: relay instead of the upstream, and holds no credential for either.
PROVIDERS = {
    "claude": (claude_token, "https://api.anthropic.com"),
    "xai": (xai_token, "https://api.x.ai"),
}


class Relay(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass                                    # one line per token is noise

    def _relay(self, body=None):
        token, why = self.server.token_fn()
        if token is None:
            self.send_error(503, why)
            return

        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in STRIP}
        headers["Authorization"] = f"Bearer {token}"
        if self.server.provider == "claude":
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
    ap.add_argument("--provider", choices=sorted(PROVIDERS), default="claude")
    ap.add_argument("--upstream", default="")
    args = ap.parse_args(argv)

    token_fn, default_upstream = PROVIDERS[args.provider]
    token, why = token_fn()
    if token is None:
        print(f"auth-relay: {why}", file=sys.stderr)
        return 1
    if why:
        print(f"auth-relay: warning: {why}", file=sys.stderr)

    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Relay)
    srv.upstream = args.upstream or default_upstream
    srv.provider = args.provider
    srv.token_fn = token_fn
    print(f"auth-relay: 127.0.0.1:{args.port} -> {srv.upstream} ({args.provider}), "
          "credentials stay here", file=sys.stderr)
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
