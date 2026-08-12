# Working inside firecode VMs

Guide revision `{{REVISION}}`. This arrives once, with your first tool result.
If a later result carries a different `guide_revision`, the server was upgraded
under you - re-read `firecode://guide` and say so rather than reasoning from
this copy.

## What a VM is here

A real machine: its own kernel, its own root filesystem, its own memory,
running under a hypervisor. Not a container. Nothing you do inside one can
reach the machine hosting it - not `rm -rf /`, not a fork bomb, not a kernel
panic. The isolation is the point, and it is why you are allowed to be root
inside and to skip the caution you would use on someone's workstation.

Two things are *not* isolated, and you should know them:

- **Credentials.** The agent's own API credentials are in the VM, because
  otherwise it could not work. Treat them as you would anywhere.
- **The network.** A VM can reach the internet and can reach services on the
  host that were explicitly relayed to it. It cannot reach the host's
  filesystem.

## Addressing a VM

Projects are **names from the server's config**, never paths. `list_projects`
gives you the names. Ask for a path and you get a refusal - that is the
boundary working, not a bug to route around.

One VM per project at a time. `vm_list` shows what is running.

## The two shapes of work

**A VM you hold.** `vm_up` starts one and leaves it running; `vm_in` runs a
command in it and returns the output *and the command's own exit status*;
`vm_down` stops it. Use this whenever you will run more than one thing - a test
suite you are iterating on, a build, anything where a boot per command would
dominate.

```
vm_up      project=lab
vm_in      project=lab  command="cargo test --release"      → exit 101, output
vm_in      project=lab  command="cargo test --release -- --nocapture"
vm_down    project=lab
```

**Work you hand off.** `spawn` starts a VM that runs an agent on a task
unattended and shuts itself down; `status` and `output` collect it. Use this
for work you do not need to watch. A spawned agent cannot spawn further VMs.

### Exit statuses are the signal

`vm_in` gives you the command's real status. Read it:

- `0` - it worked.
- anything else - it ran and failed. The output tells you how.
- a message about the VM not running - it never started; the output is empty
  for a reason that has nothing to do with your command.

Do not infer success from output text when a number is right there.

## Checkpoints: the thing worth learning

A VM's whole state - memory, processes, filesystem - can be frozen and restored
in about a second.

```
vm_up          project=lab
vm_in          project=lab  command="./generate-fixtures.sh && ./load-db.sh"   # slow, once
vm_checkpoint  project=lab
... wreck it however the work requires ...
vm_reset       project=lab      # back to the loaded fixture, ~1s
```

This changes what is worth doing. Building a *proper* fixture - real data,
loaded, warmed - is normally too expensive to do per test run, so people fake
it. Here you pay once and return to it as often as you like. Generate state
properly, checkpoint it, and reset between runs.

A restored VM is **transient**: it runs on the checkpoint's own copies of every
drive it writes to, so nothing it does touches the real project. That is what
makes resetting safe and repeatable.

A checkpoint goes stale when the project's files or its base images change; the
next start then boots normally and takes a fresh one. Nothing to manage.

## What survives what

| | survives the command | survives the VM stopping | survives a reset |
|---|---|---|---|
| the project directory | yes | yes - copied back out | no |
| installed packages | yes | yes - the project's layer | no |
| files outside the project | yes | no | no |
| a checkpoint | yes | yes | it *is* the reset |

"Copied back out" means the human gets a directory beside their project holding
what changed. Work in the project directory when the work is meant to be kept.

Installing things is fine and it persists - `apt-get install`, a language
toolchain, whatever the job needs. You are root.

## Working against real data

`list_projects` also lists **datasets**. A dataset is a real disk - often a
snapshot of a production volume - handed to the VM whole:

```
vm_up  project=lab  datasets=["tpcc"]
```

Nothing is copied. A five-terabyte dataset attaches as fast as a small one,
because the guest is given the same blocks the host has. This is the only
workable way to debug against real data, and it is why the answer to "can I
have the production database" is yes rather than no.

**A dataset is mounted, not loaded, and that is the part people get wrong.**
The disk appears at a path - say `/data/tpcc` - and nothing else happens. If
you then start the server with its default configuration it will initialise an
empty directory somewhere else, come up perfectly healthy, and tell you
nothing about the data you attached. The two have to be paired:

```
vm_in  project=lab  command="ls /data/tpcc"              # what is actually there
vm_in  project=lab  command="pg_ctl -D /data/tpcc start" # point the server AT it
```

Whatever the server calls it - `data_directory`, `-D`, `--datadir`,
`--store-path` - that setting has to name the mountpoint. Check the server
actually opened it (its log, or the row counts) before drawing a conclusion
from anything it says.

**Writable, and safe because of the snapshot, not because of read-only.** Most
datasets are attached `rw`, and should be: a database has to write to start at
all - recovery, WAL, temp files - and one attached read-only will simply
refuse to come up. What protects the original is that you were given a
snapshot, so your writes land in its copy-on-write space and the real volume
is untouched. Write freely; that is what it is for.

A dataset marked `ro` is one where that is not true, and there the server may
genuinely be unable to start. Say so rather than working around it by copying
the data somewhere writable - at this size that will fill the disk.

**Space is finite even so.** A snapshot has a fixed amount of copy-on-write
space, and a session that writes more than that kills the snapshot and your
VM's view of the data with it. Heavy write tests against a huge dataset are
worth mentioning before you run them, not after.

## Looking inside a running process

Whether this works depends on the kernel the VM booted. Check first:

```
vm_in  command="ls /sys/kernel/tracing/available_tracers 2>/dev/null || echo none"
```

**With the traceable kernel** (`available_tracers` lists `function`), you have
what a workstation has, without the usual permission fights - you are root and
this is a disposable machine:

- `strace -f -p PID` or `strace -f ./thing` - syscalls, the direct way.
- `/sys/kernel/tracing/events/syscalls/` - 726 tracepoints, for tracing
  syscalls without the ptrace stop-per-call cost.
- `kprobe_events` and `uprobe_events` - attach to a kernel function, or to a
  function in *your own binary* without rebuilding it.
- `perf record -e cpu-clock -g -- ./thing` then `perf report` - a sampling
  profile with call stacks. This answers "where is the time going".
- `bpftrace`, if installed - BTF is present, so it works.
- `gdb`, core dumps (`ulimit -c unlimited`), all of it.

**Hardware counters do not exist here.** There is no virtual PMU, so
`perf stat -e cycles,instructions,cache-misses` reports nothing usable. Software
events (`cpu-clock`, `task-clock`, `page-faults`, `context-switches`) work
normally. If you need IPC or cache behaviour, say so - it needs a different
hypervisor and the human has to arrange it.

**With the stock kernel**, none of the tracing machinery is compiled in:
`strace` and `gdb` still work (ptrace is userspace), but ftrace, kprobes,
uprobes and bpftrace do not. Say which you needed rather than concluding the
program is untraceable.

## Long or heavy work

- A command that will take a while is fine - `vm_in` waits, with a timeout you
  can raise. Prefer one long call to polling a background process.
- Serving something: a VM has its own address, so a server it starts is
  reachable from the host. Report the port and let the human open it.
- Memory and CPU are capped per VM. A build killed for memory is a cap, not a
  bug in the build - say so rather than "reducing scope" silently.

## When something goes wrong

A failure from this server comes back as three lines, and they are there to
save you a round trip:

```
why:   what actually happened, in terms of this system
fix:   the next action, if there is one
retry: no | after <something> | only if the output suggests it
```

**`retry: no` means calling the tool again cannot work.** A missing snapshot, a
full disk, a VM that will not boot - none of those change because you asked
twice. Say what happened and stop; the operator can see things you cannot.

`fix` is written for you where you can act, and says so plainly where you
cannot ("only the operator can restore it"). If a failure says that, it is not
a puzzle to solve from inside the VM.

Note the difference between a failing *command* and a failing *call*: `vm_in`
returning `exit status 1` means your command ran and failed, and its output is
the evidence. A `why/fix/retry` block means it never ran.


- **A VM will not start.** Usually the project is already running one - check
  `vm_list`. Two VMs for one project is not allowed.
- **A command returns nothing with status 0.** It really produced no output.
  Do not retry hoping for more.
- **The VM disappeared mid-work.** It hit a resource cap or the host stopped it.
  What was in the project directory was copied out; the rest is gone. Say so
  plainly rather than reconstructing from memory and presenting it as results.
- **You need something the VM does not have.** Install it. That is the point of
  being root in a disposable machine.

## Reporting back

You are working somewhere the human cannot see. What you report is all they
get, so:

- Say what you actually ran and what it actually returned. Paste the failing
  output rather than describing it.
- Distinguish "the test failed" from "the test could not run". The exit status
  tells you which; the human cannot tell from a summary.
- If you checkpointed something expensive, say so and say what it holds - it is
  reusable and they will not know unless you tell them.
- If a VM is still running when you finish, say which and why.
