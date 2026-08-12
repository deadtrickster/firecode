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

## The root is layers, not a copy

Assembled by the initramfs from kernel arguments, overlayfs:

```
lower   base image         built by prepare, shared by every VM, read-only
lower   main checkout      the project's toolchains, read-only for worktrees
upper   workspace layer    this directory's own writes
```

A git worktree inherits its main checkout's layer read-only, which is the same
relationship it has to the repository. Nothing is copied per run.

Other drives: the project (`src`, writable), the agent's config (`cfg`,
read-only, shared across VMs), this run's parameters (`ctl`, read-only,
per-run), the agent's persistent state, and any `--add-dir` trees (read-only,
content-addressed cache).

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
