#!/usr/bin/env python3
"""Relay firecode chat room -> a served opencode's ACTIVE session.

Auto-discovers the active session (GET /api/session/active) so the relay survives
restarts without a baked-in session id. Each room line that mentions the trigger
word is forwarded to /api/session/<id>/prompt, which wakes the served agent.

Why this is its own process, not started by the agent: it IS the wake source.
If the agent had to start it, the agent would already need to be awake.

Env:
  OPENSENSE_SERVE   served opencode URL            (default http://127.0.0.1:4096)
  FIRECODE_CHAT_NAME inbox self-filter and the name the served agent posts under
                     (own posts have from=WHO so --inbox drops them; no self-loop)
                                                              (default glm)
  RELAY_TRIGGER     forward only when this is in the text; "" = all (default glm)
"""
import json
import os
import subprocess
import time
import urllib.request

SERVE = os.environ.get("OPENSENSE_SERVE", "http://127.0.0.1:4096")
WHO = os.environ.get("FIRECODE_CHAT_NAME", "glm")
TRIGGER = os.environ.get("RELAY_TRIGGER", "glm")
LOG = os.environ.get("RELAY_LOG", "/home/dead/Projects/firecode/runs/opencode-relay.log")


def http_json(method, path, body=None, timeout=15):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        SERVE + path,
        data=data,
        method=method,
        headers={"content-type": "application/json"} if data is not None else {},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def active_session():
    try:
        d = http_json("GET", "/api/session/active", timeout=8)
        acts = d.get("data", d) if isinstance(d, dict) else d
        if isinstance(acts, dict):
            for sid in acts:
                return sid
    except Exception as e:
        append(f"[discover] {e}")
    return None


def post_prompt(sid, text):
    return http_json("POST", f"/api/session/{sid}/prompt", {"prompt": {"text": text}}, timeout=15)


def append(line):
    with open(LOG, "a", buffering=1) as f:
        f.write(line + "\n")


append(f"=== relay started {time.strftime('%H:%M:%S')} SERVE={SERVE} WHO={WHO} trigger={TRIGGER!r} ===")

while True:
    # --inbox blocks until a non-WHO message, prints it, exits.
    r = subprocess.run(
        ["firecode", "chat", "--inbox", "--as", WHO],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0 or not r.stdout.strip():
        time.sleep(1)
        continue
    msg = r.stdout.strip()
    if TRIGGER and TRIGGER.lower() not in msg.lower():
        continue
    sid = active_session()
    if not sid:
        append(f"[{time.strftime('%H:%M:%S')}] no active session to forward to")
        time.sleep(5)
        continue
    append(f"[{time.strftime('%H:%M:%S')}] room -> session {sid}:\n{msg[:300]}")
    try:
        post_prompt(
            sid,
            f"A message arrived in the firecode chat room and was forwarded to you:\n\n{msg}\n\n"
            "If it needs a reply, answer in the room with: firecode chat --as " + WHO + " '...'\n"
            "Otherwise reply here with one short line. No other tools.",
        )
    except Exception as e:
        append(f"  -> ERROR: {e}")
        time.sleep(2)
