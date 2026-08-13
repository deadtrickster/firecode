# firecode, as a model

What the pieces are and who owns what. Written to be the thing a rewrite is
checked against, so it states rules rather than code: if an implementation
keeps everything here true, `tests/run-tests.sh` should pass against it
whatever it is written in.

## The unit is a run

A **run** is one VM and everything brought into existence for it. Not a
session, not a project - a project can have many runs over time, and two runs
of the same project can be alive at once.

A run owns, and is solely responsible for releasing:

| thing | where it lives |
|---|---|
| the VMM process | a cgroup (below) |
| relay processes | the same cgroup |
| the jail directory | `.jail/firecracker/<id>/root` |
| drive images built for it | `runs/<id>/*.ext4` |
| a tap device and a /30 | `fccode<slot>`, `172.16.<slot>.0/30` |
| a lock on the project's state | `flock` on the state drive |
| its own metadata | `runs/<id>/` |

`runs/<id>/` is the registry entry: `project`, `jail`, `cgroup`, `parent`. It
is a plain directory of plain files on purpose - any process can read it, and
none of it needs the process that wrote it to still exist.

## Lifetime is a cgroup, not a process tree

Every run gets a subtree under the user's delegated slice:

```
firecode.slice/run-<id>/vm          the VMM and its relays
                       /children/   runs started on this one's behalf
```

Processes live only in the leaves, because cgroup v2 refuses a cgroup holding
both processes and child cgroups once a controller is enabled.

This is the whole lifetime mechanism, and it exists because **a process tree
cannot express what a run owns**. firecracker is deliberately detached; socat
gets reparented; and a VM asked for by an agent inside another VM is launched
by an entirely different `firecode` process on the host, with no kinship to
the VM that wanted it. Three unrelated process trees, one owner.

The rules that follow:

- **Stopping a run stops its descendants.** One write to `cgroup.kill` on
  `run-<id>` ends the VMM, the relays, and every VM started on its behalf,
  transitively. No pids to chase, no races with reparenting.
- **Graceful first, then not.** Children are asked to shut down and given a
  few seconds, because a clean guest shutdown is what unmounts its project
  drive and lets its work be copied back. `cgroup.kill` is the backstop for
  whatever ignores the request.
- **Liveness is "is the cgroup populated".** Not a pid file, which goes stale;
  not a socket file, which outlives its process. This is what lets a run whose
  launcher was SIGKILLed still be recognised as dead and cleaned up, instead
  of becoming an orphan that holds a tap slot until someone notices.
- **No cgroup, no crash.** Where cgroup v2 or delegation is unavailable, runs
  still work and lifetime degrades to what it was: each VM tied to its own
  launcher process.

Nothing here needs root. systemd delegates
`user.slice/user-$UID.slice/user@$UID.service` to the user, and `cgroup.kill`
plus the cpu, memory and pids controllers are available inside it.

## Who may say what

The guest is untrusted. Two consequences that are easy to get wrong:

- **Project paths are never taken from the caller.** The spawn server accepts
  named keys from its own config and resolves them itself; otherwise an agent
  could name any directory on the host and have it mounted into a VM it
  controls.
- **Parentage is advisory, and only affects lifetime.** A run's parent is
  determined from the connection - the relay a guest reaches the host through
  is a process inside that guest's cgroup, so the caller is identified rather
  than believed. `--parent-run` may also be passed explicitly, and a guest
  that names the wrong parent can only shorten its own VM's life.

Anything that runs on the *host* on the guest's behalf is a hole in this. In
particular there is deliberately no "seed script" run on the host, because a
guest can write to the project and would then be choosing what the host runs.

## Two hypervisors, one guest

firecracker starts in milliseconds and restores a checkpoint in sixty. What it
cannot do is hand over a PCI device, because it has no PCI bus - so a GPU is
impossible there at any price. libvirt/qemu is the second backend, chosen with
`--vmm libvirt`, and implied by `--gpu`.

Only the boot differs. **The guest image is identical and cannot tell which
hypervisor started it**, because everything above the boot rides on two things
qemu also has:

```
vsock        every channel the agent is reached through
virtio-blk   every drive, in the same order
```

The host side speaks both dialects of vsock: firecracker multiplexes it over a
unix socket and wants `CONNECT <port>` first; qemu gives the host a real
`AF_VSOCK` socket addressed by cid. A run records which it is (`runs/<id>/vsock`
holds a path or `cid:N`), and liveness for a libvirt run is asked of libvirt -
a cid identifies a VM only while that VM exists, and run directories outlive
their VMs.

What is *not* shared: checkpoints are firecracker's (a VFIO device cannot be
saved), and hardware counters are qemu's (firecracker masks CPUID leaf 0xA).

## The root is layers, not a copy

Assembled by the initramfs from kernel arguments, overlayfs:

```
lower   base image         built by prepare, shared by every VM, read-only
lower   imported images    a docker image per digest, read-only
lower   main checkout      the project's toolchains, read-only for worktrees
upper   workspace layer    this directory's own writes
```

A git worktree inherits its main checkout's layer read-only, which is the same
relationship it has to the repository. Nothing is copied per run.

`firecode layer add <image>` imports a docker image as a layer, keyed by its
digest. This is not a second docker: docker is good at building and caching an
image, and what it cannot do is run one behind a kernel boundary or return a
running system in 60ms. So it keeps the job it is good at and its output
becomes an input here. Keyed by digest because a toolchain moves on a different
cadence than the code built with it - the image rarely, the build every commit.
One is a layer, the other is a drive.

Other drives: the project (`src`, writable), the agent's config (`cfg`,
read-only, shared across VMs), this run's parameters (`ctl`, read-only,
per-run), the agent's persistent state, and any `--add-dir` trees (read-only,
content-addressed cache).

### Disks that are not copied

`--disk /dev/vg/snap:/data:rw` attaches a host file or block device whole. Once
a dataset is measured in terabytes, copying it into a VM is not a slow option,
it is no option.

A snapshot is what makes this safe, and it wants `rw`, not `ro`: writes land in
copy-on-write space and the original volume is untouched, while a database has
to write to start at all. Read-only against a *live* device is not the safe
choice either - it changes underneath the guest, and torn metadata is what gets
read. A snapshot that exhausts its copy-on-write space takes the session's view
of the data with it.

Raw devices need `--no-jail`: the jailer chroots, and a device node inside that
chroot has to be made by root.

## Channels

vsock, one socket per port, `socat` forking a handler per connection:

| port | what |
|---|---|
| 1024 | console - a pty, for a person |
| 1025 | files - tar in and out |
| 1026 | exec - one command, its output, its exit status |

The exec channel is what makes a VM programmable: it returns the command's own
exit status, so a failing test suite and a suite that could not start are
distinguishable.

Guest to host goes the other way through relays bound inside the jail
directory (a unix socket path is capped at 108 bytes, and an absolute path to
a run's jail is longer than that).

## Checkpoints

A saved VM is guest memory plus device state plus a copy of every drive the
guest writes to. Restoring maps it back: ~60ms, against a cold boot's seven
seconds, most of which is guest memory allocation rather than booting.

A restored VM is **transient** - it runs on the checkpoint's copies, so
nothing it does touches the live project, layer or state. That is what makes
it resettable arbitrarily often, and why using a checkpoint can never
invalidate it.

A checkpoint is a build artifact. It is stamped with the base image, the
config drive, the project's content and the machine shape; any of those
changing means the next fast start boots normally and takes a new one.

## Seeing in

Three things describe a process, and they cross a VM boundary in three
different ways. Getting this wrong is not loud: a reader that asks the wrong
machine answers confidently.

| | how it crosses |
|---|---|
| a socket | TCP. The VM has an address; nothing special is needed. |
| files - perf captures, dumps | copied out. `firecode mirror` pulls named globs on a tick. |
| `/proc` | not at all. It is the kernel of the machine you read it on. |

`scripts/vmprocfs.py` mounts the guest's `/proc` on the host over the exec
channel, and anything the guest does not have falls through to the host's own -
which is what lets an unmodified tool keep working, since `/proc/self` still
answers. Listing a directory reads names only; contents are fetched on read,
with siblings, because a fifty-thread walk is one round trip that way and fifty
otherwise.

A perf capture is a file and resolves against **any build with a matching
build-id, on any machine** - so a profile taken inside a VM symbolises on the
host from a local build tree. A matching build-id is not enough on its own: a
stripped binary registers successfully and resolves to nothing, silently.

## Kernels

Two, and the difference is what can be seen from inside:

```
stock    from firecracker's CI. No ftrace, kprobes, uprobes, BPF or BTF.
debug    built here (scripts/build-kernel.sh), published by CI, pulled with
         firecode setup --debug-kernel, booted with --kernel debug
```

The debug one adds the tracing machinery, 726 syscall tracepoints, BTF, and -
less obviously - the two things an out-of-tree module needs:

- `CONFIG_TRIM_UNUSED_KSYMS` **off**. It drops every exported symbol nothing
  built-in uses, which is exactly the set a GPU driver needs. The failure
  arrives as "unknown symbol" at load time, long after a clean compile.
- `Module.symvers`, which falls out of `make modules` and not out of
  `make vmlinux`. Without it a module compiles, warns once, and resolves
  nothing.

The build also publishes `perf` (no distribution packages one for a kernel
built here) and the build tree itself, which is what a guest compiles a driver
against.

## Measuring

Facts about the host, not preferences, and both invisible from inside a VM:

- **Hardware counters do not exist in a VM on a hybrid CPU.** KVM refuses to
  virtualise a PMU whose shape changes when a vCPU migrates between P and E
  cores, whatever `enable_pmu` says. Pinning does not unlock it - pinning is a
  prerequisite for an implementation that does not exist. Disabling E-cores in
  firmware is the only lever.
- **Core type changes the number.** Measured here on a 256-bit FMA loop,
  P-cores were ~8% faster than E-cores by minimum-of-twelve. A comparison
  between two implementations is meaningful only within one kind.
- **A busy host dominates everything.** Under a load average of 9 the same
  binary's spread was 17-23%, pinned or not, which is larger than most
  optimisations. Take the minimum of several runs: interference only ever adds
  time.

`--vectorized` pins to performance cores, sizes the VM to them, reports the
host's load, and says which of these measurements are unavailable - because a
benchmark that quietly lost its counters still prints numbers.

## What an agent is told

Two documents, because the client budgets them differently: `mcp/brief.md`
(under 2000 chars, handed over at connect) and `mcp/guide.md` (the real thing,
sent with the first tool result, re-readable at `firecode://guide`). Every
result carries `guide_revision`, so an agent whose context was compacted can
notice it is reasoning from a guide it no longer has.

Failures answer three questions - what happened, why, and whether retrying can
possibly help - because a bare failure makes an agent guess, and the cheapest
guess is to call the same tool again.

## Invariants worth keeping

These are what the tests assert, and what any implementation has to hold:

1. Stopping a VM leaves no VMM, no relay, no tap held, and no run listed.
2. Stopping a VM stops every VM started on its behalf, transitively.
3. A VM whose launcher was killed outright stops being listed as running, and
   nothing of it is left behind.
4. A command run in a VM returns the command's own exit status.
5. Two VMs for different projects never share a tap, a slot or a state lock.
6. The host's project directory is not modified by a run that was not asked to
   write back.
7. A restored VM does not modify the drives its checkpoint was taken from.
8. A result directory costs what the run changed, not what the project weighs -
   and what the run changed is a file of its own, not shared with the project.
9. The guest is identical under either hypervisor, and never learns which one
   started it.
10. A dataset is attached, never copied, and never modified where it is not a
    snapshot.
11. Nothing a VM writes reaches the host except through the project directory
    or a disk explicitly attached writable.
12. A tool pointed at the guest's `/proc` describes the guest; one pointed at
    the host's describes the host; neither silently becomes the other.
13. Whether a run succeeded is decided by something the harness ran, not by
    what the agent said about it. `--verify` runs after the agent has exited,
    in the project as it will be handed over, and its status is the run's.
14. A command meant to be run repeatedly - by a person, or by an agent
    watching another agent - is complete in its defaults. Anything a caller
    has to assemble is a different command line every time, which cannot be
    granted once and so turns supervision into a stream of permission
    prompts. `firecode watch <vm>` takes no flags for a reason.

## Known limits

Stated because each one is quiet rather than loud, and an agent that does not
know them will produce confident wrong answers:

- A VM spawned through the MCP server **by a caller on the host** has no
  parent run, so invariant 2 does not reach it. Ownership is worked out from
  the cgroup the caller's connection came from, and a host process is not in
  one - which is correct, since there is no parent VM to belong to, but it
  means such a VM is not killed transitively by anything. It still cleans up
  after itself when its own run ends. Called from inside a guest, the lineage
  is there and invariant 2 holds.
- No hardware counters in a VM on this hybrid host, by any hypervisor.
- No GPU under firecracker at all; passthrough is exclusive, so one VM has the
  card and the host does not.
- No GPU *sharing* between VMs on consumer silicon: vGPU is fused off, and the
  unlock projects stop at exactly that fuse. Serving a model from the host and
  relaying the port into guests is the arrangement that does work.
- A checkpoint cannot include a passed-through device.
- `perf` inside a guest is a released build unless the debug kernel's own is
  installed; software events are unaffected, hardware ones do not exist here
  anyway.
