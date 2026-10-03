#!/usr/bin/env python3
"""Who may use the spawn server, and what a VM may do with it.

Hermetic: the server runs in-process on a free port against a throwaway
config, runs directory and token. Who the caller is - a VM or the host - is
normally read from the connection's cgroup; here it is set per request, since
the point is what each kind of caller is then allowed.

Prints `ok <what>` or `NO <what>: <why>` per check; exits 1 if any failed.
"""
import http.client
import importlib.util
import json
import os
import sys
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "spawn", os.path.join(ROOT, "mcp", "firecode-spawn.py"))
spawn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(spawn)

failed = 0


def check(what, cond, why=""):
    global failed
    if cond:
        print(f"ok {what}")
    else:
        failed += 1
        print(f"NO {what}: {why}")


work = tempfile.mkdtemp(prefix="spawn-access.")
own, other, scratch = (os.path.join(work, d) for d in ("own", "other", "scratch"))
for d in (own, other, scratch):
    os.makedirs(d)
runs_dir = os.path.join(work, "runs")
os.makedirs(os.path.join(runs_dir, "orch"))
os.makedirs(os.path.join(runs_dir, "plain"))
for r in ("orch", "plain"):
    with open(os.path.join(runs_dir, r, "project"), "w") as fh:
        fh.write(own + "\n")
open(os.path.join(runs_dir, "orch", "orchestrate"), "w").close()

spawn.RUNS_DIR = runs_dir
spawn.TOKEN_PATH = os.path.join(work, "token")
conf = os.path.join(work, "spawn.json")
with open(conf, "w") as fh:
    json.dump({"projects": {"own": own, "other": other}, "scratch_root": scratch,
               "host_ports": [9770, 18080], "extra_args": ["--orchestrate", "--no-net"]}, fh)

cfg = spawn.Config(conf)
cfg.keep_children_flat(9770)
check("children never get the spawn port", 9770 not in cfg.host_ports
      and 18080 in cfg.host_ports, str(cfg.host_ports))
check("children never get --orchestrate", cfg.extra_args == ["--no-net"], str(cfg.extra_args))


# --- what a VM may do, alone
class Runs:
    runs = {"mine": {"parent_run": "orch", "state": "done"},
            "theirs": {"parent_run": "someone", "state": "done"},
            "hosts": {"parent_run": None, "state": "done"}}


def allowed(name, args, caller="orch"):
    try:
        spawn.authorize(cfg, Runs, name, args, caller)
        return True
    except PermissionError:
        return False


check("the host may do anything", allowed("land", {"run_id": "theirs", "force": True}, None))
check("spawn on its own project", allowed("spawn", {"project": "own"}))
check("not spawn on another project", not allowed("spawn", {"project": "other"}))
check("not vm_in on its own project (the operator's VM may be there)",
      not allowed("vm_in", {"project": "own"}))
key, _ = spawn._workspace_new(cfg, "fanout", "orch")
check("spawn on scratch it made", allowed("spawn", {"project": key}))
check("vm_in on scratch it made", allowed("vm_in", {"project": key}))
check("not vm_in on scratch another made",
      not allowed("vm_in", {"project": key}, caller="plain"))
try:
    spawn._workspace_new(cfg, "own", "orch")
    check("workspace_new cannot claim an operator project by name", False, "it returned one")
except ValueError:
    check("workspace_new cannot claim an operator project by name", True)
check("land a run it spawned", allowed("land", {"run_id": "mine"}))
check("not land with force", not allowed("land", {"run_id": "mine", "force": True}))
check("not land a run it did not spawn", not allowed("land", {"run_id": "theirs"}))
check("not output of the host's run", not allowed("output", {"run_id": "hosts"}))
check("not cancel another's run", not allowed("cancel", {"run_id": "theirs"}))
check("an unknown tool is refused", not allowed("vm_frobnicate", {}))


# --- the door: Host, content type, token, the orchestrator mark
spawn.Handler.cfg = cfg
spawn.Handler.runs = spawn.Runs(cfg)
spawn.Handler.token = spawn.host_token()
check("the token file is private", oct(os.stat(spawn.TOKEN_PATH).st_mode & 0o777) == "0o600")

who = {"peer": ("host", None)}
spawn._peer = lambda addr, port: who["peer"]
srv = spawn.ThreadingHTTPServer(("127.0.0.1", 0), spawn.Handler)
port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()


def post(headers=None, peer=("host", None), body=None):
    who["peer"] = peer
    h = {"Host": f"127.0.0.1:{port}", "Content-Type": "application/json"}
    h.update(headers or {})
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.putrequest("POST", "/mcp", skip_host=True, skip_accept_encoding=True)
    for k, v in h.items():
        if v is not None:
            c.putheader(k, v)
    data = json.dumps(body or {"jsonrpc": "2.0", "id": 1, "method": "ping"}).encode()
    c.putheader("Content-Length", str(len(data)))
    c.endheaders(data)
    r = c.getresponse()
    r.read()
    return r.status


auth = {"Authorization": f"Bearer {spawn.Handler.token}"}
check("the host with the token gets in", post(auth) == 200)
check("the host without it does not", post() == 401)
check("a wrong token does not", post({"Authorization": "Bearer nope"}) == 401)
check("a rebound domain in Host is refused",
      post({**auth, "Host": f"rebind.example:{port}"}) == 403)
check("a form post (text/plain) is refused",
      post({**auth, "Content-Type": "text/plain"}) == 415)
check("an orchestrator VM gets in without a token", post(peer=("vm", "orch")) == 200)
check("a VM not started with --orchestrate does not", post(peer=("vm", "plain")) == 403)
check("a caller that cannot be identified does not", post(auth, peer=(None, None)) == 403)

srv.shutdown()
sys.exit(1 if failed else 0)
