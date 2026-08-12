#!/usr/bin/env python3
"""firecode-spawn - an MCP server that lets an agent inside a VM start more VMs.

Firecracker exposes no virtualisation extensions to its guests, so a firecode
VM can never run a firecode VM. This runs on the *host* instead: the guest
reaches it over the vsock relay (`--host-port`), and it starts siblings.

    guest agent -> localhost:9770 -> vsock -> this -> firecode claude ...

That inverts the trust direction, so it is deliberately narrow:

  * Projects are named keys from a config file, never paths from the caller.
    An agent that could pass an arbitrary --workdir could pack any directory
    into a VM it controls, and that VM has the network.
  * Children are started with --no-mcp and an empty --mcp-config, so they
    cannot reach this server and spawn in turn. Depth stays flat.
  * Concurrency and total spawns are capped.

Speaks streamable HTTP MCP on 127.0.0.1 and depends on nothing outside the
standard library.
"""

import hashlib
import json
import os
import shlex
import signal
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROTOCOL_VERSION = "2025-06-18"
SERVER_INFO = {"name": "firecode-spawn", "version": "1.0.0"}

GUIDE_URI = "firecode://guide"


def _load(name):
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), name),
                  "rb") as fh:
            return fh.read()
    except OSError:
        return b""


# Two documents, because the client budgets them differently.
#
# The brief is handed over when a client connects, and that slot is small -
# a couple of thousand characters before it is truncated or crowds out the
# work. So it says only what changes behaviour in the first minute.
#
# The guide is the real thing, and it rides along with the first tool result,
# where there is room. An agent that has called a tool has committed to using
# this server and can afford to read how it works.
#
# Both are files rather than string literals: they are read by something that
# cannot ask a follow-up question, so they have to be reviewable in a diff.
GUIDE_RAW = _load("guide.md")
GUIDE_REVISION = hashlib.sha256(GUIDE_RAW).hexdigest()[:12] if GUIDE_RAW else "none"
GUIDE = GUIDE_RAW.decode("utf-8", "replace").replace("{{REVISION}}", GUIDE_REVISION)
BRIEF = _load("brief.md").decode("utf-8", "replace").strip()

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIRECODE = os.path.join(ROOT, "bin", "firecode")


class Config:
    def __init__(self, path):
        self.path = path
        with open(path) as fh:
            raw = json.load(fh)

        self.projects = {}
        for name, p in (raw.get("projects") or {}).items():
            self.projects[name] = os.path.abspath(os.path.expanduser(p))

        self.max_concurrent = int(raw.get("max_concurrent", 2))
        self.max_total = int(raw.get("max_total", 20))
        self.default_timeout = int(raw.get("default_timeout", 3600))
        self.host_ports = [int(p) for p in (raw.get("host_ports") or [])]
        self.agent = raw.get("agent", "claude")
        self.extra_args = list(raw.get("extra_args") or [])

        missing = [n for n, p in self.projects.items() if not os.path.isdir(p)]
        for name in missing:
            print(f"[spawn] warning: project {name} does not exist, dropping",
                  file=sys.stderr)
            del self.projects[name]


class Runs:
    """Everything this server has started, and what became of it."""

    def __init__(self, config):
        self.cfg = config
        self.lock = threading.Lock()
        self.runs = {}
        self.total = 0

    def active(self):
        return [r for r in self.runs.values() if r["state"] == "running"]

    def spawn(self, project, task, timeout=None, resume=None, parent_run=None):
        with self.lock:
            if project not in self.cfg.projects:
                raise ValueError(
                    f"unknown project {project!r}. Known: "
                    + ", ".join(sorted(self.cfg.projects)) or "(none)")
            if len(self.active()) >= self.cfg.max_concurrent:
                raise RuntimeError(
                    f"{self.cfg.max_concurrent} runs already going, wait for one")
            if self.total >= self.cfg.max_total:
                raise RuntimeError(
                    f"this server has started its limit of {self.cfg.max_total} runs")
            self.total += 1

            run_id = uuid.uuid4().hex[:12]
            workdir = self.cfg.projects[project]
            log_dir = os.path.join(ROOT, "runs", "spawn")
            os.makedirs(log_dir, exist_ok=True)
            log_path = os.path.join(log_dir, run_id + ".log")

            cmd = [FIRECODE, self.cfg.agent,
                   "--workdir", workdir,
                   "--timeout", str(int(timeout or self.cfg.default_timeout)),
                   "--no-mcp"]
            # Tied to whoever asked, so it cannot outlive them unnoticed.
            if parent_run:
                cmd += ["--parent-run", parent_run]
            for port in self.cfg.host_ports:
                cmd += ["--host-port", str(port)]
            cmd += self.cfg.extra_args
            cmd += ["--", "-p", task, "--dangerously-skip-permissions",
                    # No MCP of any kind in the child, so it cannot reach this
                    # server and start VMs of its own.
                    "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}']
            if resume:
                cmd += ["--resume", resume]

            log = open(log_path, "wb")
            proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT,
                                    stdin=subprocess.DEVNULL, cwd=workdir,
                                    start_new_session=True)
            run = {
                "id": run_id,
                "project": project,
                "task": task,
                "state": "running",
                "started": time.time(),
                "finished": None,
                "exit_code": None,
                "log": log_path,
                "result_dir": None,
                "proc": proc,
                "_log_fh": log,
            }
            self.runs[run_id] = run

        threading.Thread(target=self._reap, args=(run_id,), daemon=True).start()
        return run_id

    def _reap(self, run_id):
        run = self.runs[run_id]
        code = run["proc"].wait()
        run["_log_fh"].close()
        with self.lock:
            run["exit_code"] = code
            run["finished"] = time.time()
            run["state"] = "finished" if run["state"] == "running" else run["state"]
            run["result_dir"] = self._parse_result_dir(run["log"])

    @staticmethod
    def _parse_result_dir(log_path):
        try:
            with open(log_path, errors="replace") as fh:
                for line in fh:
                    if line.strip().startswith("result:"):
                        return line.split("result:", 1)[1].strip()
        except OSError:
            pass
        return None

    def view(self, run_id):
        run = self.runs.get(run_id)
        if not run:
            raise ValueError(f"no such run {run_id!r}")
        out = {k: v for k, v in run.items() if not k.startswith("_") and k != "proc"}
        if run["finished"]:
            out["seconds"] = round(run["finished"] - run["started"], 1)
        else:
            out["seconds"] = round(time.time() - run["started"], 1)
        return out

    def cancel(self, run_id):
        run = self.runs.get(run_id)
        if not run:
            raise ValueError(f"no such run {run_id!r}")
        if run["state"] != "running":
            return f"run {run_id} already {run['state']}"
        run["state"] = "cancelled"
        try:
            os.killpg(os.getpgid(run["proc"].pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            run["proc"].terminate()
        return f"cancelled {run_id}"

    def tail(self, run_id, lines=60):
        run = self.runs.get(run_id)
        if not run:
            raise ValueError(f"no such run {run_id!r}")
        try:
            with open(run["log"], errors="replace") as fh:
                return "".join(fh.readlines()[-lines:])
        except OSError as exc:
            return f"(cannot read log: {exc})"


def build_tools(cfg):
    projects = sorted(cfg.projects) or ["(none configured)"]
    return [
        {
            "name": "vm_up",
            "description": (
                "Start a VM for a project and leave it running. Use this when "
                "you will run more than one command: the machine stays warm, "
                "so a toolchain and a build are paid for once rather than per "
                "command. Returns when it is ready to accept commands."),
            "inputSchema": {
                "type": "object",
                "properties": {"project": {"type": "string", "enum": projects}},
                "required": ["project"],
            },
        },
        {
            "name": "vm_in",
            "description": (
                "Run one command in a project's running VM and return its "
                "output and exit status. The exit status is the command's own, "
                "so a failing test suite and one that could not start are "
                "distinguishable."),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project": {"type": "string", "enum": projects},
                    "command": {"type": "string"},
                    "cwd": {"type": "string",
                            "description": "Where to run it. Defaults to the project."},
                    "timeout": {"type": "integer",
                                "description": "Seconds before giving up. Default 600."},
                },
                "required": ["project", "command"],
            },
        },
        {
            "name": "vm_down",
            "description": "Stop a project's VM, copying its work back out.",
            "inputSchema": {
                "type": "object",
                "properties": {"project": {"type": "string", "enum": projects}},
                "required": ["project"],
            },
        },
        {
            "name": "vm_checkpoint",
            "description": (
                "Freeze a project's running VM exactly as it is now. Once "
                "frozen, vm_up brings that state back in about a second, "
                "however badly the VM was wrecked in between - so generate "
                "your fixture or load your test data once, checkpoint it, and "
                "reset to it before each run instead of rebuilding it."),
            "inputSchema": {
                "type": "object",
                "properties": {"project": {"type": "string", "enum": projects}},
                "required": ["project"],
            },
        },
        {
            "name": "vm_reset",
            "description": (
                "Throw away what a VM has done and put it back at its "
                "checkpoint. Fails if the project has never been "
                "checkpointed."),
            "inputSchema": {
                "type": "object",
                "properties": {"project": {"type": "string", "enum": projects}},
                "required": ["project"],
            },
        },
        {
            "name": "vm_list",
            "description": "The VMs running now, and which project each is for.",
            "inputSchema": {"type": "object", "properties": {}},
        },
        {
            "name": "list_projects",
            "description": "Projects this server is allowed to start a VM for.",
            "inputSchema": {"type": "object", "properties": {}},
        },
        {
            "name": "spawn",
            "description": (
                "Start a sibling microVM that runs an agent on a project, "
                "unattended, and return its run id. The VM is isolated from "
                "the host and from you. Poll with status, read with output."),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project": {"type": "string", "enum": projects,
                                "description": "One of the configured projects."},
                    "task": {"type": "string",
                             "description": "What the agent should do."},
                    "timeout": {"type": "integer",
                                "description": "Seconds before it is stopped."},
                    "resume": {"type": "string",
                               "description": "Session id to continue."},
                },
                "required": ["project", "task"],
            },
        },
        {
            "name": "status",
            "description": "State, exit code and elapsed time for a run. "
                           "Omit run_id for all of them.",
            "inputSchema": {
                "type": "object",
                "properties": {"run_id": {"type": "string"}},
            },
        },
        {
            "name": "output",
            "description": "Tail of a run's console.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "run_id": {"type": "string"},
                    "lines": {"type": "integer"},
                },
                "required": ["run_id"],
            },
        },
        {
            "name": "cancel",
            "description": "Stop a running VM.",
            "inputSchema": {
                "type": "object",
                "properties": {"run_id": {"type": "string"}},
                "required": ["run_id"],
            },
        },
    ]


def _project_path(cfg, key):
    if key not in cfg.projects:
        raise ValueError(f"unknown project {key!r}. Known: "
                         + (", ".join(sorted(cfg.projects)) or "(none)"))
    return cfg.projects[key]


def _firecode(args, timeout=600):
    """Run the CLI and hand back what it said, with its status."""
    p = subprocess.run([FIRECODE] + args, capture_output=True, text=True,
                       timeout=timeout)
    out = (p.stdout or "") + (p.stderr or "")
    return p.returncode, out.strip()


def call_tool(cfg, runs, name, args, caller_run=None):
    # A VM asked for by another VM is nested inside it, so it stops when its
    # parent does instead of outliving it as an orphan nobody is watching.
    parent = ["--parent-run", caller_run] if caller_run else []

    if name == "vm_up":
        path = _project_path(cfg, args["project"])
        rc, out = _firecode(["up", "--workdir", path] + parent + cfg.extra_args,
                            timeout=300)
        if rc != 0:
            return f"could not start a VM for {args['project']}:\n{out}"
        return f"{args['project']} is up. Run commands with vm_in."

    if name == "vm_in":
        path = _project_path(cfg, args["project"])
        cmd = ["in", "--project", path]
        if args.get("cwd"):
            cmd += ["--cwd", args["cwd"]]
        cmd.append(args["command"])
        rc, out = _firecode(cmd, timeout=int(args.get("timeout", 600)))
        head = f"exit status {rc}"
        return f"{head}\n{out}" if out else head

    if name == "vm_down":
        path = _project_path(cfg, args["project"])
        rc, out = _firecode(["down", "--project", path], timeout=180)
        return out or ("stopped" if rc == 0 else f"exit {rc}")

    if name == "vm_checkpoint":
        path = _project_path(cfg, args["project"])
        rc, out = _firecode(["checkpoint", "--project", path], timeout=600)
        if rc != 0:
            return f"could not checkpoint {args['project']}:\n{out}"
        return f"{out}\nvm_reset puts the VM back here."

    if name == "vm_reset":
        # Down then up --fast: the restore is what discards everything the VM
        # did after the checkpoint, because it comes back on the checkpoint's
        # own copies of the drives rather than on what it wrote.
        path = _project_path(cfg, args["project"])
        _firecode(["down", "--project", path], timeout=180)
        rc, out = _firecode(["up", "--fast", "--project", path], timeout=600)
        if rc != 0:
            return f"could not reset {args['project']}:\n{out}"
        return f"{args['project']} is back at its checkpoint."

    if name == "vm_list":
        rc, out = _firecode(["list"], timeout=60)
        return out or "(nothing running)"

    if name == "list_projects":
        if not cfg.projects:
            return (f"No projects configured. Add them to {cfg.path} - "
                    "paths are never taken from the caller.")
        return "\n".join(f"{n}  {p}" for n, p in sorted(cfg.projects.items()))

    if name == "spawn":
        run_id = runs.spawn(args["project"], args["task"],
                            args.get("timeout"), args.get("resume"),
                            parent_run=caller_run)
        return (f"started {run_id} on {args['project']}. "
                f"It runs unattended and shuts down when done. "
                f"Check with status({run_id}).")

    if name == "status":
        if args.get("run_id"):
            return json.dumps(runs.view(args["run_id"]), indent=2)
        if not runs.runs:
            return "nothing started yet"
        return json.dumps([runs.view(r) for r in runs.runs], indent=2)

    if name == "output":
        return runs.tail(args["run_id"], int(args.get("lines", 60)))

    if name == "cancel":
        return runs.cancel(args["run_id"])

    raise ValueError(f"no such tool {name!r}")


def _peer_run_id(client_address, server_port):
    """Which VM is on the other end of this connection, if any.

    A guest reaches this server through its own relay process, and that relay
    runs inside the VM's cgroup - so the connection itself says who is asking,
    with nothing for the guest to declare and nothing for it to forge. Used
    only to decide what a spawned VM should outlive; never for access.

    Returns a run id, or None when the caller is not inside a firecode VM -
    which is the normal case for an agent running on the host.
    """
    try:
        peer_port = client_address[1]
        want = None
        with open("/proc/net/tcp") as fh:
            next(fh)
            for line in fh:
                f = line.split()
                local, remote = f[1], f[2]
                if (int(local.split(":")[1], 16) == server_port
                        and int(remote.split(":")[1], 16) == peer_port):
                    want = f[9]          # the socket's inode
                    break
        if want is None:
            return None

        target = f"socket:[{want}]"
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                fds = os.listdir(f"/proc/{pid}/fd")
            except OSError:
                continue
            for fd in fds:
                try:
                    if os.readlink(f"/proc/{pid}/fd/{fd}") != target:
                        continue
                    with open(f"/proc/{pid}/cgroup") as fh:
                        cg = fh.read()
                except OSError:
                    continue
                # The innermost one: a nested VM's path holds its parent's run
                # as well as its own, and it is its own that it must be a
                # child of.
                found = [p[len("run-"):] for p in cg.strip().split("/")
                         if p.startswith("run-")]
                return found[-1] if found else None
    except Exception:
        return None
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    cfg = None
    runs = None

    def log_message(self, fmt, *a):  # quieter than the default
        pass

    def _send(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        if body:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        # No server-initiated stream; everything is request/response.
        self._send(405)

    def do_DELETE(self):
        self._send(200, b"{}")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._send(400, b'{"error":"bad json"}')
            return

        # Notifications carry no id and expect no response body.
        if isinstance(req, dict) and "id" not in req:
            self._send(202)
            return

        reply = self._dispatch(req)
        self._send(200, json.dumps(reply).encode())

    # One per server process, and a server process is one client session, so
    # "first call of the session" and "first of the process" are the same.
    _guide_sent = False

    def _wrap(self, text):
        """A tool result, carrying the guide the first time and its revision
        always.

        The revision goes on every result rather than only the first, because
        an agent whose context was compacted has lost the guide without any way
        to notice - a revision that no longer matches the one it remembers is
        that missing signal."""
        blocks = [{"type": "text", "text": f"{text}\n\nguide_revision: {GUIDE_REVISION}"}]
        cls = type(self)
        if GUIDE and not cls._guide_sent:
            cls._guide_sent = True
            blocks.append({"type": "text", "text": GUIDE})
        return blocks

    def _dispatch(self, req):
        rid = req.get("id")
        method = req.get("method", "")
        params = req.get("params") or {}

        def ok(result):
            return {"jsonrpc": "2.0", "id": rid, "result": result}

        def err(code, message):
            return {"jsonrpc": "2.0", "id": rid,
                    "error": {"code": code, "message": message}}

        if method == "initialize":
            return ok({
                "protocolVersion": params.get("protocolVersion", PROTOCOL_VERSION),
                "capabilities": {"tools": {"listChanged": False},
                                 "resources": {"listChanged": False}},
                "serverInfo": SERVER_INFO,
                "instructions": BRIEF,
            })

        # The guide, for a client that wants it again - after a compaction, or
        # when a result's revision stops matching the copy it is reasoning from.
        if method == "resources/list":
            return ok({"resources": [{
                "uri": GUIDE_URI,
                "name": "How to work inside firecode VMs",
                "mimeType": "text/markdown",
            }]})

        if method == "resources/read":
            if params.get("uri") != GUIDE_URI:
                return err(-32602, f"no such resource: {params.get('uri')}")
            return ok({"contents": [{"uri": GUIDE_URI, "mimeType": "text/markdown",
                                     "text": GUIDE}]})

        if method == "ping":
            return ok({})

        if method == "tools/list":
            return ok({"tools": build_tools(self.cfg)})

        if method == "tools/call":
            name = params.get("name", "")
            args = params.get("arguments") or {}
            try:
                text = call_tool(self.cfg, self.runs, name, args,
                                 caller_run=_peer_run_id(
                                     self.client_address,
                                     self.server.server_address[1]))
                return ok({"content": self._wrap(str(text))})
            except Exception as exc:  # reported to the caller, not a crash
                return ok({"content": self._wrap(f"error: {exc}"), "isError": True})

        return err(-32601, f"method not found: {method}")


def main(argv):
    port = 9770
    config_path = os.path.join(ROOT, "spawn.json")

    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--port":
            port = int(args.pop(0))
        elif a == "--config":
            config_path = args.pop(0)
        elif a in ("-h", "--help"):
            print(__doc__)
            print("usage: firecode spawn-server [--port N] [--config FILE]")
            return 0
        else:
            print(f"unknown option: {a}", file=sys.stderr)
            return 2

    if not os.path.exists(config_path):
        print(f"no config at {config_path}", file=sys.stderr)
        print("copy mcp/spawn.example.json and list the projects that may be "
              "spawned for.", file=sys.stderr)
        return 1

    cfg = Config(config_path)
    Handler.cfg = cfg
    Handler.runs = Runs(cfg)

    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"[spawn] listening on http://127.0.0.1:{port}/mcp")
    print(f"[spawn] projects: {', '.join(sorted(cfg.projects)) or '(none)'}")
    print(f"[spawn] at most {cfg.max_concurrent} at once, "
          f"{cfg.max_total} in total")
    print("[spawn] reach it from a guest with: "
          f"firecode claude --host-port {port} ...")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n[spawn] stopping")
        for run in Handler.runs.active():
            print(f"[spawn] leaving {run['id']} running: "
                  f"tail -f {shlex.quote(run['log'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
