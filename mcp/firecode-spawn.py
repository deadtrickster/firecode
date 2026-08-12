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
import re
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

        # Datasets are named for the same reason projects are: an agent asks
        # for "tpcc", never for a path or a device. Handing a caller-supplied
        # device to a VM would be handing it any disk on the machine.
        #
        # Each carries where it should be mounted and whether it may be
        # written, because those are not the agent's to choose either - and
        # because a dataset attached without a mountpoint is a dataset the
        # server it was fetched for cannot be pointed at.
        self.datasets = {}
        for name, spec in (raw.get("datasets") or {}).items():
            if isinstance(spec, str):
                spec = {"path": spec}
            path = os.path.abspath(os.path.expanduser(spec["path"]))
            self.datasets[name] = {
                "path": path,
                "mount": spec.get("mount") or f"/data/{name}",
                "mode": "ro" if spec.get("mode") == "ro" else "rw",
                "note": spec.get("note") or "",
            }

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
    datasets = sorted(cfg.datasets) or ["(none configured)"]
    return [
        {
            "name": "vm_up",
            "description": (
                "Start a VM for a project and leave it running. Use this when "
                "you will run more than one command: the machine stays warm, "
                "so a toolchain and a build are paid for once rather than per "
                "command. Returns when it is ready to accept commands. "
                "`datasets` attaches real data - see the guide before using "
                "it: the disk is mounted, never loaded, and the server you "
                "start has to be configured to use that path."),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project": {"type": "string", "enum": projects},
                    "datasets": {
                        "type": "array",
                        "items": {"type": "string", "enum": datasets},
                        "description": (
                            "Datasets to attach, by name. Each is a real disk "
                            "given to the VM whole - nothing is copied, so a "
                            "terabyte costs the same as a megabyte."),
                    },
                },
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
        # Running something that does not finish.
        #
        # vm_in waits for a command, which is right for a build or a test and
        # useless for a server: it never returns, so the call blocks until it
        # is killed. Backgrounding it by hand loses the log, the exit status
        # and any way to ask whether it is still alive - the caller ends up
        # polling `tail` and guessing. The guest runs systemd; these are units.
        {
            "name": "vm_serve",
            "description": (
                "Start a long-running process in a VM under a name, and return "
                "immediately. For anything that does not exit on its own: a "
                "server, a watcher, a load generator. Its output is captured "
                "and readable with vm_logs, and it keeps running between your "
                "calls."),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project": {"type": "string", "enum": projects},
                    "name": {"type": "string",
                             "description": "Short name to refer to it by later."},
                    "command": {"type": "string"},
                    "cwd": {"type": "string",
                            "description": "Where to run it. Defaults to the project."},
                },
                "required": ["project", "name", "command"],
            },
        },
        {
            "name": "vm_logs",
            "description": "What a process started by vm_serve has printed.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project": {"type": "string", "enum": projects},
                    "name": {"type": "string"},
                    "lines": {"type": "integer", "description": "Default 50."},
                },
                "required": ["project", "name"],
            },
        },
        {
            "name": "vm_ps",
            "description": (
                "What is running in a VM and what it is doing: the processes "
                "started with vm_serve and whether they are still up, the "
                "ports being listened on and how to reach them from outside, "
                "and the VM's own load and memory. Look here before concluding "
                "anything from a timing."),
            "inputSchema": {
                "type": "object",
                "properties": {"project": {"type": "string", "enum": projects}},
                "required": ["project"],
            },
        },
        {
            "name": "vm_stop",
            "description": "Stop something started by vm_serve. The VM keeps running.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project": {"type": "string", "enum": projects},
                    "name": {"type": "string"},
                },
                "required": ["project", "name"],
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


# What went wrong, why, and whether trying again could possibly help.
#
# A bare failure makes an agent guess, and the cheapest guess is to call the
# same tool again - which is how a broken snapshot or a full disk turns into
# twenty identical calls. This server knows the domain and the caller does
# not, so it owes an answer to all three questions rather than an exit code.
#
# `retry` is the one that stops the loop. "no" means nothing the caller can do
# will change the outcome, and the right move is to say so and stop.
FAILURES = [
    (re.compile(r"no VM is running"),
     ("There is no VM for that project - it was never started, or it stopped.",
      "Call vm_up for this project first, then retry the command.",
      "after vm_up")),
    (re.compile(r"more than one VM is running"),
     ("Several VMs are up and the request did not say which one.",
      "This should not reach you - it means the server did not name a project. "
      "Report it rather than guessing.",
      "no")),
    (re.compile(r"no such file or device|no such directory|does not exist"),
     ("Something the VM was told to attach is not on the host.",
      "A dataset's disk or snapshot has gone - most likely it was removed, or "
      "it was never created. Only the operator can restore it; nothing you can "
      "do from in here will.",
      "no")),
    (re.compile(r"No space left on device|no space left"),
     ("The VM ran out of writable disk.",
      "Its layer holds everything installed and everything written outside the "
      "project. Profiles and captures are large - write them to an attached "
      "dataset if one is mounted, delete what you no longer need, or ask the "
      "operator to grow the layer (firecode grow). Rerunning the same command "
      "will fill it again.",
      "no")),
    (re.compile(r"did not come up|failed to start|Firecracker exiting with error"),
     ("The VM did not finish booting.",
      "Something about this VM's configuration or images is wrong, not "
      "something about your command. The console log named in the output says "
      "what. Calling vm_up again will do the same thing.",
      "no")),
    (re.compile(r"cannot be checkpointed"),
     ("This VM cannot be frozen.",
      "It was started by an older firecode, or restored from a checkpoint "
      "already. Stop it and start a fresh one with vm_up if you need a new "
      "checkpoint.",
      "after vm_down then vm_up")),
    (re.compile(r"needs --no-jail"),
     ("A raw device was attached to a VM that runs jailed.",
      "The server has to be configured to run this project unjailed before "
      "that dataset can be used. Only the operator can change that.",
      "no")),
]


def note(msg):
    """A line for whoever is watching this server run.

    The agent's copy of a failure is written for an agent; this is the other
    half of it. Someone started this on their own machine and is entitled to
    see which VMs were asked for, by whom, against which of their disks, and
    what failed - without reading a transcript to find out.
    """
    print(f"[spawn] {time.strftime('%H:%M:%S')} {msg}", file=sys.stderr, flush=True)


def explain(what, out, rc=None):
    """A failure the caller can act on, or stop acting on."""
    text = out or ""
    for pattern, (why, fix, retry) in FAILURES:
        if pattern.search(text):
            return (f"{what} failed.\n"
                    f"why: {why}\n"
                    f"fix: {fix}\n"
                    f"retry: {retry}\n"
                    f"---\n{text.strip()[:1500]}")
    return (f"{what} failed"
            + (f" (exit {rc})" if rc is not None else "") + ".\n"
            "why: not a failure this server recognises, so the output below is "
            "all there is.\n"
            "fix: read it before retrying - if it names a file, a port or a "
            "path, that is the thing to look at.\n"
            "retry: only if the output suggests something transient.\n"
            f"---\n{text.strip()[:1500]}")


def call_tool(cfg, runs, name, args, caller_run=None):
    # A VM asked for by another VM is nested inside it, so it stops when its
    # parent does instead of outliving it as an orphan nobody is watching.
    parent = ["--parent-run", caller_run] if caller_run else []

    if name == "vm_up":
        path = _project_path(cfg, args["project"])
        disks = []
        chosen = args.get("datasets") or []
        for ds in chosen:
            if ds not in cfg.datasets:
                raise ValueError(
                    f"unknown dataset {ds!r}. Known: "
                    + (", ".join(sorted(cfg.datasets)) or "(none)"))
            d = cfg.datasets[ds]
            disks += ["--disk", f"{d['path']}:{d['mount']}:{d['mode']}"]
        # A raw device cannot be handed to a jailed VMM: the jailer chroots,
        # and making a device node in there needs root.
        if disks and "--no-jail" not in cfg.extra_args:
            disks.append("--no-jail")
        rc, out = _firecode(["up", "--workdir", path] + parent + disks + cfg.extra_args,
                            timeout=600)
        if rc == 0 and chosen:
            where = "; ".join(
                f"{d} at {cfg.datasets[d]['mount']} ({cfg.datasets[d]['mode']})"
                + (f" - {cfg.datasets[d]['note']}" if cfg.datasets[d]["note"] else "")
                for d in chosen)
            return (f"{args['project']} is up with {where}.\n"
                    "The data is mounted, not loaded: point the server's own "
                    "configuration at that path (data_directory, -D, --datadir "
                    "or whatever it calls it) or it will come up empty and tell "
                    "you nothing.")
        if rc != 0:
            return explain(f"Starting a VM for {args['project']}", out, rc)
        return f"{args['project']} is up. Run commands with vm_in."

    if name == "vm_in":
        path = _project_path(cfg, args["project"])
        cmd = ["in", "--project", path]
        if args.get("cwd"):
            cmd += ["--cwd", args["cwd"]]
        cmd.append(args["command"])
        rc, out = _firecode(cmd, timeout=int(args.get("timeout", 600)))

        # A command that ran and failed is a result, not an error: the status
        # is the answer. Only a command that could not run at all needs
        # explaining - and the two look identical if both are just a number.
        if rc != 0 and re.search(r"no VM is running|No space left|"
                                 r"could not connect|Connection refused", out or ""):
            return explain(f"Running a command in {args['project']}", out, rc)
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
            return explain(f"Checkpointing {args['project']}", out, rc)
        return f"{out}\nvm_reset puts the VM back here."

    if name == "vm_reset":
        # Down then up --fast: the restore is what discards everything the VM
        # did after the checkpoint, because it comes back on the checkpoint's
        # own copies of the drives rather than on what it wrote.
        path = _project_path(cfg, args["project"])
        _firecode(["down", "--project", path], timeout=180)
        rc, out = _firecode(["up", "--fast", "--project", path], timeout=600)
        if rc != 0:
            return explain(f"Resetting {args['project']}", out, rc)
        return f"{args['project']} is back at its checkpoint."

    if name in ("vm_serve", "vm_logs", "vm_ps", "vm_stop"):
        path = _project_path(cfg, args["project"])
        unit = "firecode-svc-" + re.sub(r"[^A-Za-z0-9_-]", "-", args.get("name", ""))

        if name == "vm_serve":
            cwd = args.get("cwd") or path
            # A transient unit: supervised, its output in the journal, gone
            # when the VM stops. --collect so a failed one does not linger as
            # a corpse that blocks the same name being used again.
            cmd = (f"sudo systemd-run --unit={shlex.quote(unit)} --collect "
                   f"--working-directory={shlex.quote(cwd)} "
                   f"--property=User=$(id -un) "
                   f"bash -lc {shlex.quote(args['command'])} 2>&1 | tail -2")
            rc, out = _firecode(["in", "--project", path, cmd], timeout=120)
            if rc != 0:
                return explain(f"Starting {args['name']} in {args['project']}", out, rc)
            return (f"{args['name']} is running in {args['project']}.\n"
                    f"It keeps running between calls. vm_logs reads its output, "
                    f"vm_ps says whether it is still up and what it is listening on.")

        if name == "vm_logs":
            n = int(args.get("lines", 50))
            cmd = f"sudo journalctl -u {shlex.quote(unit)} -n {n} --no-pager 2>&1 | tail -{n}"
            rc, out = _firecode(["in", "--project", path, cmd], timeout=120)
            return out or f"(nothing logged by {args['name']} yet)"

        if name == "vm_stop":
            cmd = f"sudo systemctl stop {shlex.quote(unit)} 2>&1 | tail -2; echo stopped"
            rc, out = _firecode(["in", "--project", path, cmd], timeout=120)
            return f"{args['name']} stopped."

        # vm_ps: everything a caller needs before believing anything it sees.
        cmd = (
            "echo '--- services ---'; "
            "systemctl list-units 'firecode-svc-*' --no-legend --no-pager 2>/dev/null "
            "| awk '{print $1, $4}' || true; "
            "echo '--- listening ---'; "
            "ss -ltnp 2>/dev/null | tail -n +2 | awk '{print $4}' | sort -u || true; "
            "echo '--- address ---'; "
            "ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true; "
            "echo '--- load ---'; cut -d' ' -f1-3 /proc/loadavg; "
            "echo '--- memory ---'; free -m | awk '/Mem:/{print $3\" MB used of \"$2\" MB\"}'"
        )
        rc, out = _firecode(["in", "--project", path, cmd], timeout=120)
        if rc != 0:
            return explain(f"Looking at {args['project']}", out, rc)
        return (out or "(nothing)") + (
            "\n\nA port listed above on 0.0.0.0 is reachable from the host at "
            "the address shown - tell the human that address and port rather "
            "than localhost, which for them is a different machine.")

    if name == "vm_list":
        rc, out = _firecode(["list"], timeout=60)
        return out or "(nothing running)"

    if name == "list_projects":
        if not cfg.projects:
            return (f"No projects configured. Add them to {cfg.path} - "
                    "paths are never taken from the caller.")
        out = ["projects:"]
        out += [f"  {n}  {p}" for n, p in sorted(cfg.projects.items())]
        if cfg.datasets:
            out.append("")
            out.append("datasets (attach with vm_up datasets=[...]):")
            for n, d in sorted(cfg.datasets.items()):
                line = f"  {n}  mounts at {d['mount']} ({d['mode']})"
                if d["note"]:
                    line += f" - {d['note']}"
                out.append(line)
            out.append("  a dataset is mounted, not loaded: point the server's")
            out.append("  own config at that path or it comes up empty.")
        return "\n".join(out)

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
            caller = _peer_run_id(self.client_address,
                                  self.server.server_address[1])
            # What was asked for, before it is done. An operator watching this
            # sees a VM being started against one of their disks at the moment
            # it happens, not after it has finished.
            detail = ", ".join(f"{k}={v}" for k, v in sorted(args.items())
                               if k in ("project", "datasets", "command", "task"))
            note(f"{name}({detail[:160]})" + (f" from VM {caller}" if caller else ""))
            try:
                text = call_tool(self.cfg, self.runs, name, args,
                                 caller_run=caller)
                first = str(text).splitlines()[0] if str(text).strip() else "(no output)"
                note(f"  {name}: {first[:120]}")
                return ok({"content": self._wrap(str(text))})
            except Exception as exc:  # reported to the caller, not a crash
                note(f"  {name} failed: {type(exc).__name__}: {exc}")
                # Even an unexpected exception says what it was doing and
                # whether repeating it could help. A caller that gets only a
                # message calls the same tool again, which is the loop this
                # server exists to prevent.
                return ok({"content": self._wrap(
                    f"{name} failed.\n"
                    f"why: {type(exc).__name__}: {exc}\n"
                    "fix: if that names something you chose - a project, a "
                    "dataset, a command - correct it. If it does not, this is "
                    "the server's problem, not yours: report it and move on.\n"
                    "retry: no, unless you change the arguments."),
                    "isError": True})

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
