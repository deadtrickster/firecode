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
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROTOCOL_VERSION = "2025-06-18"


def _source_stamp():
    """When this process's code and config were read off disk.

    Everything here is loaded once at startup: the module, and the config in
    main(). Edit either and the running server keeps doing what it was doing,
    silently - so an agent can read the fix in the file, call the tool, get
    the old behaviour, and have nothing to tell it why. The file on disk lies
    about the running system, which is worse than the file being wrong.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        newest = max(os.path.getmtime(os.path.join(here, f))
                     for f in os.listdir(here) if f.endswith((".py", ".md")))
    except (OSError, ValueError):
        newest = 0
    return {"loaded_at": time.time(), "source_mtime": newest}


STAMP = _source_stamp()
SERVER_INFO = {
    "name": "firecode-spawn",
    "version": "1.0.0",
    "loaded": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(STAMP["loaded_at"])),
}


def staleness_note(config_path=None):
    """Whether this process is still the code and config on disk.

    Checked per call rather than at startup, because the interesting moment is
    the one where someone has just edited a file and is about to test it.
    """
    stale = []
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        newest = max(os.path.getmtime(os.path.join(here, f))
                     for f in os.listdir(here) if f.endswith((".py", ".md")))
        if newest > STAMP["loaded_at"]:
            stale.append("its own source")
    except (OSError, ValueError):
        pass
    if config_path:
        try:
            if os.path.getmtime(config_path) > STAMP["loaded_at"]:
                stale.append("its config")
        except OSError:
            pass
    if not stale:
        return ""
    return ("\n\nNOTE: this server has been running since "
            + SERVER_INFO["loaded"] + " and " + " and ".join(stale)
            + " changed on disk after that. It is still running the old "
            "version - what you read in the files is not what answered you. "
            "Restart it (firecode spawn-server) before concluding anything "
            "about a fix.")

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

        # Somewhere an agent may make a workspace of its own.
        #
        # Every project here is a name the operator registered, which is the
        # boundary that stops a caller packing an arbitrary directory into a
        # VM it controls. But it also meant an agent that wanted a scratch box
        # had to borrow whichever project existed - building over somebody
        # else's tree, and over the next agent's - because the alternative was
        # asking a human to edit a config file. A directory it may create
        # inside, and only inside, keeps the boundary and removes the silly
        # part.
        scratch = raw.get("scratch_root") or ""
        self.scratch_root = os.path.abspath(os.path.expanduser(scratch)) if scratch else ""

        # The scratch directory is the registry.
        #
        # workspace_new used to register a name in this process only, which
        # meant a restart forgot every workspace while leaving the directories
        # on disk - so an agent that made one, and a run that was still using
        # it, both found it missing from list_projects with the work sitting
        # right there. What exists on disk is the truth; read it at startup.
        if self.scratch_root and os.path.isdir(self.scratch_root):
            for entry in sorted(os.listdir(self.scratch_root)):
                path = os.path.join(self.scratch_root, entry)
                if os.path.isdir(path) and entry not in self.projects:
                    self.projects[entry] = path

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

    def spawn(self, project, task, timeout=None, resume=None, parent_run=None,
              verify=None, agent=None, model=None, land_on_pass=False):
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

            # Which agent, and through it which provider. opencode speaks
            # several, so the choice is a per-call one: the same task can go to
            # the subscription model, to grok, or to something local, and
            # comparing them is the point of being able to say.
            which = (agent or self.cfg.agent).strip()
            if which not in ("claude", "opencode"):
                raise ValueError(f"unknown agent {which!r} - claude or opencode")

            cmd = [FIRECODE, which,
                   "--workdir", workdir,
                   "--timeout", str(int(timeout or self.cfg.default_timeout)),
                   # Credentials stay on this machine whichever agent runs.
                   # For a subscription login it is not a preference: a copy
                   # inside a VM refreshes, rotates, and leaves the host
                   # holding a token that has already been spent.
                   "--auth-relay",
                   "--no-mcp"]
            # Tied to whoever asked, so it cannot outlive them unnoticed.
            if parent_run:
                cmd += ["--parent-run", parent_run]
            # The gate, if the caller set one: run by the harness after the
            # agent exits, and its status becomes the run's. Without it the
            # only report on a run is the report of the thing being reported
            # on.
            if verify:
                cmd += ["--verify", verify]
            for port in self.cfg.host_ports:
                cmd += ["--host-port", str(port)]
            # The room, so an agent in a VM is not the only one who cannot
            # hear what everyone else has worked out. Costs nothing when the
            # room is not running: the relay simply has nothing to connect to.
            chat_port = os.environ.get("FIRECODE_CHAT_PORT", "9761")
            if chat_port not in [str(p) for p in self.cfg.host_ports]:
                cmd += ["--host-port", chat_port]
            cmd += self.cfg.extra_args
            if which == "opencode":
                # opencode's own shape: a subcommand and provider/model, and
                # no claude flags at all. Its model must be given or it picks
                # from the provider's list - which is how a run once went to a
                # video generation model and died in eleven seconds.
                cmd += ["--", "run"]
                if model:
                    cmd += ["-m", model]
                cmd += [task]
            else:
                cmd += ["--", "-p", task, "--dangerously-skip-permissions",
                        # No MCP of any kind in the child, so it cannot reach
                        # this server and start VMs of its own.
                        "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}']
                if model:
                    cmd += ["--model", model]
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
                "land_on_pass": bool(land_on_pass),
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
            # "finished" for a run that failed is a lie a caller has to catch
            # by noticing exit_code separately - and one that read "finished,
            # result_dir: null" and moved on is how a failure gets reported
            # upwards as a success.
            if run["state"] == "running":
                run["state"] = "finished" if code == 0 else "failed"
            run["result_dir"] = self._parse_result_dir(run["log"])
            # The harness's own run id, which is not this server's - two
            # namespaces again, and `land` speaks the harness's one.
            run["firecode_run"] = self._parse_firecode_run(run["log"])

        # Land it, if that was asked for and it earned it.
        #
        # Outside the lock: landing shells out to git and there is no reason
        # to hold every other caller while it does. Only on a clean exit -
        # the harness has already refused to report a failed gate as success,
        # and this must not undo that by folding a failure into the workspace.
        if run.get("land_on_pass") and code == 0 and not run.get("firecode_run"):
            # Asked to land, earned the landing, and no id to land with.
            # Recorded rather than skipped: the caller asked for a fold and
            # is entitled to find out it did not get one from the same place
            # it reads everything else about the run.
            run["landed"] = False
            run["land_output"] = (
                "no harness run id could be read from the log, so nothing was "
                "landed. Fold by hand with `firecode land <run>` - `firecode "
                "list` shows the ids.")
            print(f"[spawn] land skipped for {run_id}: no run id in log",
                  file=sys.stderr)
        elif run.get("land_on_pass") and code == 0 and run.get("firecode_run"):
            rc, out = _firecode(["land", run["firecode_run"]], timeout=180)
            run["landed"] = (rc == 0)
            run["land_output"] = out
            if rc != 0:
                # Said loudly rather than swallowed: an automatic step that
                # quietly did not happen is the same class of bug as a gate
                # that was never armed. The usual cause is somebody editing
                # the workspace while the phase ran.
                print(f"[spawn] land failed for {run_id}: {out}", file=sys.stderr)

    @staticmethod
    def _parse_firecode_run(log_path):
        """The harness's run id, from the line it prints when a run starts."""
        try:
            with open(log_path, errors="replace") as fh:
                for line in fh:
                    # date-time-pid, all three. Matching only two of them
                    # still matches - the pattern is not anchored - and
                    # returns a truncated id that every later command
                    # rejects as "no run ... here". land_on_pass silently
                    # did nothing for its first real user because of it.
                    m = re.search(r"\brun (firecode-[0-9]+-[0-9]+-[0-9]+)", line)
                    if m:
                        return m.group(1)
        except OSError:
            pass
        return None

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
            # It may still have happened. Runs live in this process's memory,
            # so a restart forgets every one of them while their logs sit on
            # disk - and a caller polling a run it started ten minutes ago
            # gets "no such run", which reads as "you invented that id" rather
            # than "the server was restarted underneath you".
            log = os.path.join(ROOT, "runs", "spawn", f"{run_id}.log")
            if os.path.isfile(log):
                tail = ""
                try:
                    with open(log, errors="replace") as fh:
                        tail = fh.read()[-1500:]
                except OSError:
                    pass
                return {
                    "id": run_id,
                    "state": "unknown - started by an earlier server process",
                    "why": "this server was restarted after that run began, so "
                           "its bookkeeping is gone. The log survives.",
                    "log": log,
                    "log_tail": tail,
                    "fix": "read the log, or vm_list to see whether its VM is "
                           "still up. A run that finished has its result "
                           "directory beside the project either way.",
                }
            raise ValueError(f"no such run {run_id!r}")
        out = {k: v for k, v in run.items() if not k.startswith("_") and k != "proc"}
        if run["finished"]:
            out["seconds"] = round(run["finished"] - run["started"], 1)
        else:
            out["seconds"] = round(time.time() - run["started"], 1)
        if run["state"] == "failed":
            out.update(self._why_failed(run))
        return out

    @staticmethod
    def _why_failed(run):
        """A reason, and whether trying the same thing again could work.

        A caller told only "failed, exit 1" has to go and read a log on a
        machine it may not be on. These are the failures this server actually
        produces, so it can say which one happened.
        """
        tail = ""
        try:
            with open(run["log"], errors="replace") as fh:
                tail = fh.read()[-4000:]
        except OSError:
            pass

        if "no way to reach a model" in tail:
            return {"why": "the VM had no route to a model - offline, and no relay",
                    "fix": "the spawn server passes --auth-relay itself; if you see "
                           "this, the running server predates that and needs a restart",
                    "retry": "not until that is fixed"}
        if "VERIFICATION FAILED" in tail:
            return {"why": "the agent finished, and the verify command failed",
                    "fix": "read .firecode-verify.log in the result directory - the "
                           "work exists, it just does not pass",
                    "retry": "yes, with a task that says what failed"}
        if "hit the" in tail and "timeout" in tail:
            return {"why": "the agent ran out of time",
                    "fix": "a larger timeout, or a smaller task",
                    "retry": "yes"}
        if "another run holds this project's state drive" in tail:
            return {"why": "another run had this project, so this one got a private "
                           "copy and could not resume anything",
                    "fix": "wait for the other run, or use a different project",
                    "retry": "yes, once the other one is done"}
        return {"why": f"exit {run['exit_code']} - see the log",
                "fix": f"read {run['log']}",
                "retry": "unknown"}

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
    # Named in the description, not fixed as an enum.
    #
    # An enum is computed once, when this server starts, and a client caches
    # the tool list from the same moment - so a project made later (or one the
    # operator adds) cannot be named by a caller whose schema validator
    # rejects it before the server is even asked. The server checks the name
    # anyway, which is where the boundary actually lives; this only decides
    # whether a caller can express it.
    known = ", ".join(sorted(cfg.projects)) or "(none configured)"
    project_field = {
        "type": "string",
        "description": (f"A project name. Configured now: {known}. "
                        "list_projects is authoritative"
                        + (", and workspace_new makes a new one."
                           if cfg.scratch_root else ".")),
    }
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
                    "project": dict(project_field),
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
                "distinguishable.\n\n"
                "This blocks until the command finishes, and your client will "
                "give up on the call long before the VM does - a slow command "
                "here comes back to you as a transport timeout while it keeps "
                "running inside, which reads like a hang and is not one. For "
                "anything that may take minutes: vm_serve to start it and "
                "vm_logs to read it, or spawn if what you want is an agent "
                "doing the work rather than a command."),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project": dict(project_field),
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
                "properties": {"project": dict(project_field)},
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
                "properties": {"project": dict(project_field)},
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
                "properties": {"project": dict(project_field)},
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
                    "project": dict(project_field),
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
                    "project": dict(project_field),
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
                "properties": {"project": dict(project_field)},
                "required": ["project"],
            },
        },
        {
            "name": "vm_watch",
            "description": (
                "Wait for a run to do something, then return what it did. "
                "This call blocks until one of: the VM exits, the text in "
                "`until` appears in its output, it has printed nothing for "
                "`quiet_for` seconds, or `timeout` is reached - and it hands "
                "back why it returned plus the tail of the console.\n\n"
                "Use this instead of polling. A loop that sleeps and checks "
                "burns a call every interval, gets slower news, and - when a "
                "person is approving your commands - asks them to approve "
                "another almost-identical one every time. One blocking call "
                "per look is the whole interface."),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project": dict(project_field),
                    "timeout": {"type": "integer",
                                "description": "Seconds to wait. Default 300, max 900."},
                    "quiet_for": {"type": "integer",
                                  "description": ("Return early if nothing has been "
                                                  "printed for this long - which is how "
                                                  "a stuck run looks.")},
                    "until": {"type": "string",
                              "description": "Return early when this text appears."},
                    "lines": {"type": "integer", "description": "Tail to return. Default 60."},
                },
                "required": ["project"],
            },
        },
        {
            "name": "land",
            "description": (
                "Put a finished run's committed work back into the workspace "
                "it came from, so the next run builds on it.\n\n"
                "A run never writes to its project: it works on a copy and "
                "delivers beside it. For one run that is the safety; for a "
                "sequence it is a trap, because phase two starts from the "
                "original tree while phase one's work sits in a directory "
                "nobody read, and its gate fails on files that exist a few "
                "inches away.\n\n"
                "It refuses rather than guesses: a run whose gate failed is "
                "not landed (pass force to override), work that was never "
                "committed is named and left behind, and a workspace that has "
                "moved since the run started is a merge for a person, not a "
                "mechanical fast-forward. Landing twice is harmless."),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "run_id": {"type": "string",
                               "description": "The run to land - the id spawn returned."},
                    "force": {"type": "boolean",
                              "description": "Land even though the gate failed."},
                },
                "required": ["run_id"],
            },
        },
        {
            "name": "workspace_new",
            "description": (
                "Make a fresh, empty project of your own and get its name "
                "back, usable anywhere a project is asked for.\n\n"
                "Use it whenever the work is yours rather than an existing "
                "project's - a build from scratch, an experiment, anything you "
                "would otherwise put in somebody else's directory. The "
                "alternative is what happens now: every agent borrows the one "
                "configured project, builds over what the last one left, and "
                "the copy-out mixes both.\n\n"
                "It lives inside the operator's scratch directory and cannot "
                "be made anywhere else. If this server has no scratch "
                "directory the call says so, and the answer is a configured "
                "project, not a path."),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string",
                             "description": "What to call it - letters, digits, dot, dash."},
                },
                "required": ["name"],
            },
        },
        {
            "name": "chat_say",
            "description": (
                "Say something in the room every agent on this machine shares. "
                "Use it when you learn something the others would act on: a "
                "verified defect, a run's verdict, a wrong assumption you just "
                "corrected. Not for narration - the room is small and read by "
                "working agents.\n\n"
                "Pick a name and keep it. The default is the host user, which "
                "everyone shares, so unnamed posters are indistinguishable."),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                    "name": {"type": "string",
                             "description": "Who is speaking, e.g. 'glm', 'reviewer'."},
                    "to": {"type": "string",
                           "description":
                               "Who it is for. Without this the message goes "
                               "to the room, which nobody is woken for - it is "
                               "read later, among everything else. Name a "
                               "recipient when you want an answer."},
                },
                "required": ["text"],
            },
        },
        {
            "name": "chat_wait",
            "description": (
                "Block until somebody else says something in the room, then "
                "return it. Your own messages do not wake you, and where you "
                "had read up to is remembered here under your name - so this "
                "takes no cursor and can be called repeatedly with the same "
                "arguments.\n\n"
                "This is the one tailer. Do not write your own: three of them "
                "existed for a while and one filtered the wrong name, hiding "
                "the messages it was supposed to deliver.\n\n"
                "THIS BLOCKS YOUR TURN. It is for a deliberate short wait - "
                "you have asked something and want the answer now. It is NOT "
                "how to stay in the room: a call that blocks cannot also be "
                "permanent, and a fifteen-minute one freezes you for fifteen "
                "minutes.\n\n"
                "To listen permanently, run this in a BACKGROUND SHELL "
                "instead, and start it again each time it returns:\n"
                "    firecode chat --inbox --as <your-name>\n"
                "It blocks out there rather than in here, prints what was "
                "said, and exits - which most harnesses turn into a "
                "notification. Do not tail the log file: the room is a "
                "service, the log is its record, and a tail gives you no "
                "cursor and no filtering of your own messages.\n\n"
                "Whichever you use: when a message asks you something, "
                "chat_say a one-line acknowledgement BEFORE doing the work. "
                "Silence is indistinguishable from absence - an agent here "
                "waited three minutes for an answer, decided nobody was "
                "coming, and went and fixed the thing itself."),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string",
                             "description": "Your name in the room. Keep it stable."},
                    "timeout": {"type": "integer",
                                "description": "Seconds to wait. Default 300, max 900."},
                },
            },
        },
        {
            "name": "vm_say",
            "description": (
                "Say something to a run that is already going - a correction, "
                "a constraint you forgot, a fact it is missing. It arrives as "
                "another user turn at the end of whatever the agent is doing "
                "now, and appears in the run's own log next to what it did "
                "with it.\n\n"
                "Use it sparingly and concretely. Every message is a turn the "
                "run spends reading you instead of working, and 'keep going' "
                "costs the same as a fact. Name the thing: which function does "
                "not exist, which file it has rewritten three times, which "
                "command to run."),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project": dict(project_field),
                    "message": {"type": "string"},
                },
                "required": ["project", "message"],
            },
        },
        {
            "name": "vm_stop",
            "description": "Stop something started by vm_serve. The VM keeps running.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project": dict(project_field),
                    "name": {"type": "string"},
                },
                "required": ["project", "name"],
            },
        },
        {
            "name": "vm_list",
            "description": ("The VMs running now, which project each is for, "
                            "and which of them are yours - the rest belong to "
                            "other runs and are working on something."),
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
                "the host and from you. Poll with status, read with output.\n\n"
                "A spawned agent gets NO MCP servers - not an oversight, but "
                "the flat-depth boundary: one that could reach this server "
                "would start VMs of its own and the concurrency caps would "
                "stop meaning anything. It can still talk: firecode-chat is on "
                "PATH in every guest, so it can report being blocked and ask a "
                "question while it works. Voice and fan-out are different "
                "powers.\n\n"
                "A run started from the command line instead (firecode claude) "
                "does get MCP, split by transport: http servers on the host's "
                "localhost are relayed over vsock and work unchanged; stdio "
                "servers are dropped, because their binaries are host paths "
                "that do not exist in a guest."),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project": dict(project_field),
                    "task": {"type": "string",
                             "description": "What the agent should do."},
                    "timeout": {"type": "integer",
                                "description": "Seconds before it is stopped."},
                    "resume": {
                        "type": "string",
                        "description": (
                            "An AGENT SESSION id to continue - not a run id "
                            "from this server. They are different namespaces "
                            "and passing the wrong one fails instantly: the "
                            "agent exits with 'requires a valid session ID' "
                            "having taken zero turns, and the verify command "
                            "then fails on a tree nobody touched, which reads "
                            "as a broken build rather than a bad argument.\n\n"
                            "If you only have a run id, do not pass this - "
                            "spawn again with a task that says what is already "
                            "there and what to change. The project directory "
                            "is where the last run left it."),
                    },
                    "agent": {
                        "type": "string",
                        "enum": ["claude", "opencode"],
                        "description": (
                            "Which agent runs the task. Defaults to this "
                            "server's configured one. opencode is the way to "
                            "reach another provider - grok, a local model - "
                            "so use it when the point is to compare, or when "
                            "the task suits a different model."),
                    },
                    "model": {
                        "type": "string",
                        "description": (
                            "Model for that agent. For opencode it is "
                            "provider/model, e.g. 'xai/grok-build-0.1', and "
                            "giving one matters: with no model it picks from "
                            "the provider's list and may choose something "
                            "that cannot write code at all."),
                    },
                    "land_on_pass": {
                        "type": "boolean",
                        "description": (
                            "When the run exits cleanly, put its committed "
                            "work back into the workspace so the next phase "
                            "builds on it. Without this the result sits in a "
                            "sibling directory and the next run starts from "
                            "the tree as it was - which is the trap every "
                            "multi-phase build falls into once. Refused, "
                            "loudly, if the workspace has moved meanwhile."),
                    },
                    "verify": {
                        "type": "string",
                        "description": (
                            "A command that decides whether the work counts - "
                            "'./run-tests.sh', 'cargo test', 'make "
                            "installcheck'. Run by the harness inside the VM "
                            "after the agent exits, in the project as it will "
                            "be handed back, and its exit status becomes the "
                            "run's.\n\n"
                            "WRITING IT IN `task` DOES NOT ARM IT. The task is "
                            "prose for the agent; this is a command for the "
                            "harness. They are different domains and neither "
                            "substitutes for the other - a run whose task said "
                            "'I run ./run-tests.sh after you exit' and whose "
                            "verify was empty reported success on a script "
                            "that was not even in the delivered tree. Say it "
                            "in both: here so it is enforced, in `task` so the "
                            "agent knows what it is aiming at.\n\n"
                            "Without this you are taking the agent's word for "
                            "its own work, which is the one thing it cannot be "
                            "relied on for."),
                    },
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
                         + (", ".join(sorted(cfg.projects)) or "(none)")
                         + (". workspace_new makes a fresh one."
                            if cfg.scratch_root else ""))
    return cfg.projects[key]


def _offline_note(cfg):
    """Say when a VM has no network, before somebody discovers it by probing.

    An agent that finds only loopback, no interface to bring up and nothing
    installed concludes the VM is broken - it has no way to see that this was
    configured. One did exactly that, spent a while trying eth0, ens1, enp0s1,
    then handed a build that needed a Go toolchain to another VM with the same
    setting, because nothing said so there either.
    """
    if "--no-net" not in cfg.extra_args:
        return ""
    return ("\n\nThis VM has NO NETWORK - that is this server's configuration, "
            "not a fault, so do not go looking for an interface to bring up. "
            "Nothing can be downloaded in there: no apt, no pip, no go mod, no "
            "cloning. Whatever the task needs must already be in the image, or "
            "the operator has to drop --no-net from this server's config. The "
            "model API still works: it comes over a relay on localhost, not "
            "over a network.")


def _workspace_new(cfg, name):
    """A project of the caller's own, inside the scratch directory.

    The name is sanitised and joined to scratch_root, and the result has to
    still be under scratch_root afterwards - that check is the whole security
    of this, since a name is the one thing the caller controls. It is
    registered for this process only; nothing is written to the config file,
    so a restart forgets it and the operator's list is still the operator's.
    """
    if not cfg.scratch_root:
        raise ValueError(
            "this server has no scratch_root, so new workspaces are not "
            "available - the operator sets one in its config, or registers "
            "projects by hand. list_projects says what exists.")
    safe = re.sub(r"[^A-Za-z0-9._-]", "-", (name or "").strip())[:48].strip("-.")
    if not safe:
        raise ValueError("a workspace needs a name made of letters or digits")
    if safe in cfg.projects:
        return safe, cfg.projects[safe]

    path = os.path.abspath(os.path.join(cfg.scratch_root, safe))
    if os.path.commonpath([path, cfg.scratch_root]) != cfg.scratch_root:
        raise ValueError("a workspace name cannot climb out of the scratch directory")

    os.makedirs(path, exist_ok=True)
    # A git repo, because the harness returns work by fetching what the guest
    # committed as well as by copying files, and an empty directory with no
    # .git quietly loses the first of those.
    if not os.path.isdir(os.path.join(path, ".git")):
        subprocess.run(["git", "init", "-q", path], check=False, timeout=60)
    cfg.projects[safe] = path
    return safe, path


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
        return f"{args['project']} is up. Run commands with vm_in." + _offline_note(cfg)

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
        # With the same flags it was brought up on.
        #
        # These were dropped here, which made a reset a different VM from the
        # one being reset: a project configured --no-net came back with a
        # network, and the checkpoint could never match because the stamp
        # covers that shape - so every reset was a cold boot as well as a
        # policy change. The config is the trust boundary; a reset does not
        # get to leave it.
        rc, out = _firecode(["up", "--fast", "--project", path] + cfg.extra_args,
                            timeout=600)
        if rc != 0:
            return explain(f"Resetting {args['project']}", out, rc)
        # Restored, or merely started? These are different machines, and this
        # used to report the first whatever happened - so a caller that asked
        # for a fixture back was told it had one when it had a fresh boot, and
        # the only clue was that the call took twenty seconds rather than two.
        if "restoring from a checkpoint" in out:
            return f"{args['project']} is back at its checkpoint."
        return (f"{args['project']} was restarted, but NOT from its checkpoint - "
                f"there was none that matched, so this is a fresh boot and "
                f"whatever state the checkpoint held is not here. The VM is "
                f"usable; anything you were relying on from the fixture is not. "
                f"vm_checkpoint after setting it up again, or take it on a VM "
                f"started without --fast.")

    if name == "land":
        run = runs.runs.get(args["run_id"])
        if not run:
            return (f"no run {args['run_id']!r} in this server's memory. If it "
                    f"was started before a restart, land it from a shell: "
                    f"firecode land <the harness run id from its log>.")
        if run["state"] == "running":
            return (f"{args['run_id']} is still going - nothing to land yet. "
                    f"vm_watch or status until it is done.")
        fc_run = run.get("firecode_run")
        if not fc_run:
            return (f"could not work out which harness run {args['run_id']} was "
                    f"- its log is at {run['log']}, and `firecode land <id>` "
                    f"takes the id from the 'run firecode-...' line in it.")
        rc, out = _firecode(["land"] + (["--force"] if args.get("force") else [])
                            + [fc_run], timeout=180)
        if rc != 0:
            return explain(f"Landing {args['run_id']}", out, rc)
        return out or "landed."

    if name == "workspace_new":
        key, path = _workspace_new(cfg, args["name"])
        return (f"{key} is yours, at {path} - empty, a git repo, and usable as "
                f"a project anywhere one is asked for: vm_up, spawn, vm_in.\n"
                f"It lasts as long as this server runs; the operator's own "
                f"projects are untouched by anything you do in it."
                + _offline_note(cfg))

    if name in ("chat_say", "chat_wait"):
        port = int(os.environ.get("FIRECODE_CHAT_PORT", "9761"))
        base = f"http://127.0.0.1:{port}"
        who = args.get("name") or (f"run-{caller_run}" if caller_run else "agent")

        if name == "chat_say":
            # Said rather than raised. A missing field used to come back as
            # KeyError: 'text' with a traceback, and this is the tool agents
            # fall back to when the CLI is broken - the one moment it must
            # explain itself instead of failing like an internal error.
            text = args.get("text") or args.get("message") or ""
            if not str(text).strip():
                return ("nothing to say - chat_say takes text, e.g. "
                        "{\"text\": \"gate green at abc123\", \"name\": "
                        "\"reviewer\", \"to\": \"orchestrator\"}")
            payload = {"from": who, "text": text}
            if args.get("to"):
                payload["to"] = args["to"]
            body = json.dumps(payload).encode()
            try:
                req = urllib.request.Request(
                    base + "/say", data=body,
                    headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=15) as resp:
                    got = json.load(resp)
            except Exception as exc:
                return (f"the room is not answering on {base} ({exc}). "
                        f"Start it with: firecode chat serve")
            return f"said it as {who} (#{got.get('id')})."

        # chat_wait: the mark lives beside the room's log, keyed by name, so
        # the call takes no cursor and two readers do not consume each other's
        # messages.
        #
        # On disk rather than in this process, because this process gets
        # restarted - and when it did, every reader silently resumed "from
        # now", so anything said while it was down was behind the new mark and
        # never arrived. A caller then waits its full timeout and concludes it
        # is being ignored, which is exactly what happened.
        limit = min(int(args.get("timeout", 300)), 900)
        mark_dir = os.path.join(ROOT, "runs")
        mark_file = os.path.join(
            mark_dir, "chat-mark-mcp-" + re.sub(r"[^A-Za-z0-9._-]", "-", who))

        def read_mark():
            try:
                return int(open(mark_file).read().strip())
            except (OSError, ValueError):
                return None

        def write_mark(value):
            try:
                os.makedirs(mark_dir, exist_ok=True)
                with open(mark_file, "w") as fh:
                    fh.write(str(value))
            except OSError:
                pass

        mark = read_mark()
        started = time.time()
        while True:
            left = max(1, int(limit - (time.time() - started)))
            try:
                with urllib.request.urlopen(
                        f"{base}/messages?since={mark or 0}&wait={min(left, 60)}",
                        timeout=left + 30) as resp:
                    got = json.load(resp)
            except Exception as exc:
                return (f"the room is not answering on {base} ({exc}). "
                        f"Start it with: firecode chat serve")
            msgs = got.get("messages") or []
            if mark is None:
                # First call: start from now rather than replaying the whole
                # room, which is history the caller did not ask for.
                mark = got.get("last", 0)
                write_mark(mark)
                if time.time() - started >= limit:
                    return "nothing said yet (you are now listening from here on)."
                continue
            if msgs:
                mark = got.get("last", mark)
                write_mark(mark)
            fresh = [m for m in msgs if m.get("from") != who]
            if fresh:
                return "\n".join(
                    "[%s] %s: %s" % (time.strftime("%H:%M:%S", time.localtime(m["at"])),
                                     m["from"], m["text"]) for m in fresh)
            if time.time() - started >= limit:
                return f"nobody said anything in {limit}s."

    if name == "vm_say":
        path = _project_path(cfg, args["project"])
        rc, out = _firecode(["say", "--project", path, args["message"]], timeout=120)
        if rc != 0:
            return explain(f"Saying something to {args['project']}", out, rc)
        return (f"Said it. {args['project']} takes it at the end of its "
                f"current turn; vm_watch until it has, and read what it did "
                f"rather than assuming it complied.")

    if name == "vm_watch":
        path = _project_path(cfg, args["project"])
        # Capped, because this holds a request open: a caller that asks for an
        # hour gets fifteen minutes and can ask again.
        limit = min(int(args.get("timeout", 300)), 900)
        quiet_for = int(args.get("quiet_for", 0))
        until = args.get("until") or ""
        lines = int(args.get("lines", 60))

        def tail():
            return _firecode(["logs", "--project", path, "-n", str(lines)],
                             timeout=60)[1] or ""

        started = time.time()
        seen = tail()
        last_change = started
        while time.time() - started < limit:
            time.sleep(5)
            now = tail()
            running = path in (_firecode(["list", "--ids"], timeout=60)[1] or "")
            if not running:
                return f"{args['project']}: the VM has exited.\n\n{now}"
            if until and until in now and until not in seen:
                return (f"{args['project']}: saw {until!r} after "
                        f"{int(time.time() - started)}s.\n\n{now}")
            if now != seen:
                seen, last_change = now, time.time()
            elif quiet_for and time.time() - last_change >= quiet_for:
                return (f"{args['project']}: nothing printed for "
                        f"{int(time.time() - last_change)}s - it may be stuck, or "
                        f"thinking, or waiting on something. vm_ps says which.\n\n{now}")
        return (f"{args['project']}: still going after {limit}s.\n\n{tail()}")

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
        if not out:
            return "(nothing running)"
        return out + _ownership_note(caller_run)

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
                            parent_run=caller_run, verify=args.get("verify"),
                            agent=args.get("agent"), model=args.get("model"),
                            land_on_pass=args.get("land_on_pass"))
        gate = args.get("verify")
        return (f"started {run_id} on {args['project']}. "
                f"It runs unattended and shuts down when done. "
                f"Check with status({run_id})." + _offline_note(cfg) + "\n"
                + (f"Its work is judged by `{gate}`, which this harness runs "
                   f"after the agent exits - so status() tells you whether the "
                   f"work passed, not whether the agent thought so."
                   if gate else
                   "No verify command was given, so the only report on this run "
                   "will be the agent's own. If there is any way to check the "
                   "work by running it, pass it as `verify` next time."))

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


def _ownership_note(caller_run):
    """Who each VM belongs to, said plainly rather than enforced.

    Stopping another project's VM is allowed: an agent may legitimately be
    orchestrating across projects, and a rule that forbade it would break that
    for the sake of a mistake that is better prevented by knowing. So this
    says which of these are yours and which are somebody else's work, and
    leaves the decision where it belongs.
    """
    if not caller_run:
        return ("\n\nYou are on the host, so all of these are yours to stop. "
                "A VM in this list may still be working - vm_ps before "
                "stopping one.")
    mine, others = [], []
    for line in _firecode(["list", "--ids"], timeout=60)[1].splitlines():
        fields = line.split("\t")
        if len(fields) < 2:
            continue
        run_id, project = fields[0], fields[1]
        # Yours by descent as well as by identity: a VM you spawned carries
        # your run in its cgroup path, and it is still yours two levels down.
        (mine if run_id == caller_run or caller_run in run_id
         else others).append(f"{run_id} ({project})")
    note = ["", "", f"You are {caller_run}."]
    note.append("  yours:  " + (", ".join(mine) if mine else "none"))
    note.append("  others: " + (", ".join(others) if others else "none"))
    note.append("Stopping another's VM is permitted - you may be orchestrating "
                "across projects - but it is somebody's work in progress, so "
                "read vm_ps first and say what you stopped.")
    return "\n".join(note)


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
        stale = staleness_note(getattr(type(self).cfg, "path", None))
        blocks = [{"type": "text",
                   "text": f"{text}{stale}\n\nguide_revision: {GUIDE_REVISION}"}]
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
