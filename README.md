# firecode

Run a coding agent inside a Firecracker microVM, so you can walk away from it.

```sh
cd ~/Projects/thing
firecode claude "port the parser to the new AST and make the tests pass"
```

The agent gets root, the network, and your project - at the same path it has
out here. It does not get your host: no host filesystem, no host processes, no
host devices. It runs with permission checks off, because there is nothing in
there worth protecting. When it finishes, the work is copied out to a sibling
directory. Your project directory is never written to.

A run is not a black box, and "done" is not the agent's opinion:

```sh
firecode claude --deliver ~/Projects/thing --verify './run-tests.sh' \
  -- -p 'build the thing, tests and all' --dangerously-skip-permissions
```

`--verify` is run by the harness after the agent exits, in the project as it
will be handed over. Its exit status is the run's. Meanwhile `firecode logs -f`
shows what it is doing, `firecode say` puts another turn into it, and the agent
inside can ask you a question and wait for the answer.

## What it protects against

Wiping your system, and reading things it has no business reading - SSH keys,
GPG keys, browser profiles, cloud credentials. The guest has no path to any of
them: it sees a copy of one project and nothing else of yours. `--add-dir`
refuses outright to carry `.ssh`, `.gnupg`, `.aws`, `.kube`, `.config/gh`,
`.password-store` or a browser profile out of your home directory, and so does
`--workdir`.

It does not protect your API credits or your network. The agent has your Claude
credentials, because otherwise it cannot work.

## Install

Needs Linux with KVM and e2fsprogs. docker is needed once, to build the first
guest image; after that firecode builds its own.

```sh
sudo usermod -aG kvm,docker "$USER"        # then log back in

firecode setup                             # firecracker, jailer, guest kernel
firecode prepare --with "dotnet@10 uv"     # first guest image, via docker
firecode doctor                            # check the host is ready
```

Once you have an image, the next one is built **inside a VM** - no docker, no
export, no copy-out:

```sh
firecode prepare --in-vm --with "dotnet@10 uv"
```

The blank image is attached to the builder as an unmounted disk and written
directly, so the host holds the finished filesystem the moment the VM stops.
It is smaller than the docker path (a package set rather than a container
image carrying its history), it refuses to install a result whose `/sbin/init`
is missing, and it keeps the image it replaces as `.previous`.

It is also the only path that works on a host whose DNS is a loopback DoH
proxy: docker's bridge forwards to the host's resolver address, which inside a
container namespace is the container itself, so nothing resolves. `prepare`
detects that and builds on the host network; `--in-vm` never meets it, because
a guest has its own resolver.

Two things need root, both one-time:

```sh
sudo firecode net-setup --count 4          # persistent taps, owned by you
sudo ./scripts/install-privileged.sh       # passwordless jailer
```

Read the top of that second script first - the jailer execs a binary as a uid
of the caller's choosing, so treat it as passwordless root. Skip it and
`--no-jail` needs nothing at all; you still get a real KVM guest, minus the
chroot and uid drop around the VMM process.

With no controlling terminal - cron, a hook, another agent - sudo cannot
prompt. `SUDO_ASKPASS=/usr/bin/ksshaskpass` makes it ask on the desktop.

## Use

```sh
firecode claude "add tests for the parser"     # unattended, shuts down when done
firecode claude --timeout 3600 "big refactor"  # give up after an hour
firecode claude                                # interactive, in byobu
firecode opencode "fix the failing build"
firecode shell                                 # poke around by hand
firecode exec make -j8                         # any command, in the sandbox
```

**A task means unattended. Flags alone mean a session you drive.** So
`firecode claude --resume <id>` gives you the REPL with that conversation
loaded, and `firecode claude --resume <id> "do X"` runs it without you. For the
unattended case `-p` and `--dangerously-skip-permissions` are added unless you
gave your own (`--no-auto-flags` to stop that). Anything after `--` goes to the
agent untouched.

Results land next to the project:

```
~/Projects/thing                       # untouched
~/Projects/thing-20260810-231500-4711  # what the agent produced
```

Nothing is applied for you. Diff it and take what you want.

## Sessions

Interactive runs live in a byobu session named after the project, which makes
them a singleton: a second `firecode claude` in the same project joins the
running VM instead of starting a rival one.

```sh
firecode claude          # session firecode/thing, ctrl-a d to detach
firecode attach          # back into it, including over ssh
firecode list            # sessions and runs
```

Because the session owns the VM rather than your terminal, closing the terminal
no longer leaves one running. `--no-tmux` opts out.

To get a shell **inside a VM that is already running** - to try the thing the
agent just built, or watch it work - `firecode enter`. The guest serves a pty
per connection, so it does not disturb whatever is on the first one, and
leaving does not stop the VM.

```sh
firecode enter                    # second shell in the running VM
./impersonate-cs/publish/dash     # run what it built
# then open http://172.16.1.2:8080 in your browser
```

## The layers

The guest root is not a disk, it is a stack, assembled by an initramfs before
the guest boots:

| layer | what it is | writable |
| --- | --- | --- |
| base image | what `prepare` built, shared by every VM | no |
| project layer | the main checkout's, where its toolchains live | only from that checkout |
| workspace layer | this directory's own | yes |

A **git worktree** gets its own workspace layer and inherits the main
checkout's read-only - the same relationship it has to the repository. So the
main checkout can be on dotnet 8 and a worktree on dotnet 9, neither disturbing
the other, both sharing one base image.

`--worktree` makes one if it is not there, and runs in it:

```sh
firecode claude --worktree parser-rewrite "port the parser"
firecode claude --worktree docs "update the docs"      # at the same time
```

A worktree's `.git` is a file pointing back into the main checkout, which is
not in the VM, so the copy gets a real `.git` built from the repository's
common directory with git itself setting the branch. History and commits work
in there.

**The work comes back into the worktree itself**, with no timestamped copy
beside it - firecode created that worktree, so firecode may write to it. The
VM's commits are fetched into your repository and the branch moved onto them;
uncommitted edits land in the working tree. Afterwards it is an ordinary
worktree:

```sh
git -C ../thing-parser-rewrite log --oneline
git merge parser-rewrite
git worktree remove ../thing-parser-rewrite
```

Your own checkout is never treated this way - it stays untouched and you get
the sibling copy.

Nothing is copied per run: a VM adds a sparse layer rather than duplicating six
gigabytes of rootfs.

**A toolchain you want everywhere belongs in the base image**, not installed
per workspace:

```sh
firecode prepare --with "dotnet@10 java@temurin-21 uv"
```

mise installs them into `/opt/mise`, readable by every account in the guest,
and the choice is remembered so a later rebuild keeps them. `--with ""` clears
it. `--full` additionally puts rust, go, zig, clang/llvm and sbcl in the image.

## Resuming

Everything a session touched persists per workspace: the conversation, the
working tree, and whatever it installed.

```sh
firecode claude "start the refactor"
firecode claude --continue "now do the tests too"

firecode state sessions                      # ids you can resume
firecode claude --resume 3f9a1c2e "and the docs"
```

`--continue` and `--resume` carry the tree forward too, not just the
conversation - resuming into a pristine checkout would tell the agent it had
made changes that are not there. `--fresh` starts from your tree again,
`--fresh-root` throws away the workspace layer.

A session you started on the host can be moved in:

```sh
firecode claude --import-sessions --resume <id> "carry on without me"
```

Nothing is rewritten in the transcript, because the project has the same path
on both sides - which is the main reason it has the same path. Your host
transcripts are only read, never modified.

## Snapshots

A project's state is three drives - agent home, working tree, workspace layer -
and `snapshot` captures them together.

```sh
firecode snapshot toolchain-installed
firecode snapshot ls
firecode snapshot restore toolchain-installed
firecode snapshot rm toolchain-installed
```

Restoring puts the next run exactly where the snapshot was taken. Sparse
copies, so 13G of drives is about 1.4G on disk. Restore refuses while a run
holds the project.

This is disk state, not a paused VM. Firecracker can snapshot memory too, but
that only helps a VM that is still running.

## Reaching things

**The host, from the guest.** MCP servers exposed over http on `localhost:PORT`
are relayed in and reachable at the same address. Anything else on your
loopback - a local model server, say - goes in `~/.config/firecode/host-ports`,
one per line, or `--host-port 18080` for one run. This runs over vsock, not the
network, so it works under `--no-net` too.

MCP servers configured as local `stdio` commands cannot come along; their
binaries are on the host filesystem, which is the thing being kept out. They
are dropped, and named when the config drive is built.

**The guest, from the host.** Your host is the other end of the guest's link, so
a dev server it starts is directly reachable. A project keeps the same address
across runs - it is picked from the taps that exist by hashing the project path
- so a dashboard stays at a URL you can bookmark. firecode prints it either
way, and falls back to any free tap when that one is busy:

```
[firecode] guest is 172.16.1.2 - a server it starts on PORT is at
[firecode]   http://172.16.1.2:PORT
```

**Files, either way, while it runs.** Firecracker has no virtio-fs and no 9p, so
a host directory cannot be shared into a guest at all. vsock can:

```sh
firecode cp vm:~/Projects/thing/dist ./dist
firecode cp ./logo.png vm:~/Projects/thing/assets
```

Coming out, the archive is written by the guest, and the guest is the thing
being contained - so extraction goes through Python's `data` filter, which
refuses `..`, absolute paths, links pointing outside the destination, device
files and setuid bits by specification rather than by whichever tar is
installed. `--limit` caps a guest that never stops sending.

**Extra context, read-only:**

```sh
firecode claude --add-dir ~/Projects "match the API the sibling repo uses"
```

Mounted at its real path, gitignore-filtered, and cached between runs. Copies:
the guest can read them, nothing written there goes back out.

## What the guest may print at you

A terminal executes some of what is printed at it, and everything the guest
prints is written by the thing being contained. Its output is filtered on the
way to your terminal:

- **dropped**: OSC 52 (setting your clipboard), DCS/APC/PM/SOS payloads - which
  on some terminals include "define this key to type the following", outliving
  the session - and `ESC c`, a full reset that wipes your scrollback
- **kept**: CSI, so cursor movement and colour still work, and OSC 0/1/2 for the
  window title, because without those a TUI cannot draw

An unattended run is stricter still: it prints logs, so nothing but text gets
through. The console log keeps the unfiltered bytes, so the record is complete.
`--raw` on the console turns the filter off.

## What the agent is told

Three things reach the model, and only these:

- your host `~/.claude/CLAUDE.md`, unchanged
- the project's own `CLAUDE.md`, if it has one
- a firecode section appended to the first: that it has root and should stop
  asking, that its work leaves through a sibling directory, that installs
  persist, that stdio MCP servers are absent, that there is no `gh` and no ssh
  key

That section also carries what a delegated run keeps getting wrong, written
down because instruction is cheaper than supervision:

- **run it early** - one or two files, then compile or import or start it. The
  worst run here wrote eight files over 24 minutes before invoking a compiler
  once, and every error after that was entangled with the others.
- **load what you deliver, in a new process**, from the project as it will be
  copied out - a long session accumulates state the recipient will not have.
- **no placeholder survives**: nobody is coming back to fill it in, because
  the only one who was going to is the process about to stop.
- **the room exists**, and reaching it is `firecode-chat`, not a tool.

`FIRECODE=1` and `IS_SANDBOX=1` are in the environment. Commits use the git
identity the project reports on the host, with signing forced off - there is no
key in the guest and nothing there could answer a passphrase.

opencode gets its credentials and provider config carried in - minus the
provider a relay is standing in for, and minus MCP servers whose binaries live
on the host filesystem, which it would otherwise sit trying to start.

## How it works

Drives are found by filesystem label, not device order:

| label | mount | contents |
| --- | --- | --- |
| `firecode-src` | the project's host path | your project, writable, copied back out |
| `firecode-cfg` | `/opt/firecode/config` | read-only: agent binaries and host config |
| `firecode-ctl` | `/opt/firecode/run` | read-only: this run's parameters and guest scripts |
| `firecode-state` | `/var/lib/firecode` | per-project agent home, survives the VM |
| `firecode-x*` | their host paths | read-only: whatever `--add-dir` asked for |

The root layers come first, by device, because the initramfs assembles them
before there is a udev to ask.

Inside, `firecode-mounts.service` mounts those, recreates your account with the
same uid and home, brings up the network, starts the vsock relays, and layers
`~/.claude` and `~/.opencode` as writable overlays on the read-only config
drive. Then `firecode-agent.service` runs the agent, or - for an interactive
run - a pty is served over vsock instead of the serial console.

Images are built and read without root: `mkfs.ext4 -d` writes one straight from
a directory and `debugfs rdump` reads it back, neither needing a mount. The
guest image is built by exporting a Docker container.

The `claude` and `opencode` binaries are not baked in. They are copied from the
host at launch, so the guest runs the version you run.

### Networking

Each VM gets its own tap and its own `/30`, so several run at once without
colliding. NAT is via iptables plus explicit FORWARD rules, because Docker sets
the FORWARD policy to DROP. A slot is taken only if its lock is free *and* the
tap has no carrier - a VM outliving a killed firecode still holds its device.

`--no-net` gives a VM with no network at all; vsock still works, so relays and
`cp` and the console are unaffected.

### Resource limits

`--mem` and `--vcpu` are hard limits - Firecracker will not give the guest more
than it was configured with. `--cgroups` additionally caps the host-side VMM
process through the jailer, which is mostly redundant and off by default.

## Orchestration

A VM that stays up, for when you will run more than one thing in it - a test
suite you are iterating on, a build you do not want to pay for twice:

```sh
firecode up                       # boots and waits until it can take commands
firecode in 'cargo test --release'   # output, and the command's own exit status
firecode in 'python3 bench.py'
firecode down                     # stops it, copying the work back out
```

`in` returns the command's exit status, so a failing suite and a suite that
could not start are different things. Several VMs can be up at once, one per
project; `--project DIR` says which, and asking ambiguously lists them rather
than guessing.

## Delegating a job, and staying in the conversation

An unattended run is not a black box. It says what it is doing as it does it,
it can be spoken to while it works, and what it hands back is checked by the
harness rather than described by the agent.

```sh
firecode claude --deliver ~/Projects/thing \
  --verify './run_tests.sh' \
  -- -p 'build the thing, tests and all' --dangerously-skip-permissions

firecode logs -f thing-vm         # what it is doing, as it happens
firecode say thing-vm 'the spec changed - RFC 2812 rather than 1459'
```

**`--verify CMD`** is the part that makes "done" mean something. The harness
runs `CMD` itself after the agent has exited, inside the VM - where the
toolchain the agent installed actually is - in the project directory as it
will be handed over. Its exit status becomes the run's, its output is
delivered as `.firecode-verify.log`, and the agent is told at the start what
the command will be, so it can aim at it.

This exists because of two runs in one evening. One delivered a Lisp system
whose `.asd` named files that were not there, with a test that started a
server, slept, stopped it and printed "test completed"; the other delivered a
Postgres extension whose README ended a results section with the literal
string `RESULTS_PLACEHOLDER` over an empty file. Both reported success, both
took hours, and in both cases the last thing checked was not the thing being
handed over. An agent asserting success is a claim about a process that is
about to stop, made by the only party who could have checked and did not.

**`firecode say`** posts another turn into a run that is already going, so a
correction that occurs to you in minute ten does not have to wait for the end
and a whole new run. Both agents take it, by different routes: claude reads
further turns from stdin, and opencode is attached to a server of its own so
the message goes into its session.

**`firecode watch <vm>`** waits, then says whether the run is still up and what
it has printed. It takes no flags on purpose. Watching means pausing between
looks, and an agent left to invent its own pause writes a different command
every time - a bare sleep, then a computed deadline, then its own choice of
tail length - so whoever is approving that agent's commands is asked again
every couple of minutes and can never grant it once. Over MCP `vm_watch` goes
further and does not poll at all: it blocks until the VM exits, until text you
named appears, until the run has been quiet too long, or until a timeout.

**The gate has to be armed.** Writing "I run ./run-tests.sh after you exit"
into the prompt arms nothing: the prompt is prose for the agent, `--verify` is
a command for the harness, and neither substitutes for the other. A careful
caller did exactly that and got a green run whose gate had never executed, on
a script that was not in the delivered tree. Say it in both places.

[`prompts/`](prompts/) has starting points for both halves of this - a build
task with a gate, and one agent supervising another.

## The room

Every agent here works alone by construction - one per VM, one per session -
which is the isolation working and also its blind spot: two of them can spend
an hour on the same wrong assumption without ever finding out.

```sh
firecode chat install       # once: a user service, survives sessions and reboots
firecode chat 'text'        # say something
firecode chat --read        # everything so far
firecode chat --inbox       # block until somebody speaks, then print and exit
```

Inside a VM the same room is a command, `firecode-chat`, installed into every
guest. An unattended run gets no MCP servers by design, so three agents in a
row looked for a chat *tool*, found none, and concluded there was no room -
one of them while blocked on something the others could have answered in a
sentence.

```sh
firecode-chat 'blocked: no postgres in the image and apt cannot resolve'
firecode-chat --ask 'install from source, or stop?'
```

`--ask` posts and waits. An unattended agent facing a decision it cannot make
otherwise has two moves - guess, or stop and report that it needed a human -
and both are worse than asking and waiting a few minutes. If nobody answers it
says so and tells the agent to decide and record what it chose.

Two conventions the room needs, learned by getting them wrong:

- **Start listening before you start working**, and start again each time your
  reader returns. A blocking MCP call cannot be a permanent listener - it
  freezes the caller's turn - so the listener is a background shell running
  `firecode chat --inbox`, which exits on each message.
- **Acknowledge before you act.** Silence is indistinguishable from absence:
  an agent here waited three minutes for an answer, concluded nobody was
  coming, and went and fixed the thing itself.

## Checkpoints

Firecracker can save a running VM - guest memory and device state - and map it
back later. A cold boot spends most of its time allocating guest memory (~2.4s
of a 4G VM's 2.9s; the guest itself boots in half a second). A restore skips
all of it and the guest is answering again in about 60ms.

```sh
firecode checkpoint     # freeze the VM running now, exactly as it is
firecode up --fast      # bring that back instead of booting
firecode up --refresh   # throw it away and take a new one
```

What makes this worth having is not the boot time - it is that state a VM
took real work to reach becomes reusable. Generate test data, load a database,
get a fixture into a state worth keeping, checkpoint it once, and from then on
every run starts there:

```sh
firecode claude          # "write a generator for representative data, then use it"
firecode checkpoint      # freeze the loaded fixture
# ... the agent wrecks it, as it should ...
firecode down && firecode up --fast    # back to the loaded fixture, ~1.7s
```

A restored VM is **transient**. It gets the checkpoint's own copies of every
drive it writes to, so nothing it does touches the real project, the workspace
layer or the agent state - which is exactly why it can be reset over and over,
and why the checkpoint never goes stale by being used. The read-only layers are
shared as always, since nothing writes to them.

A checkpoint is a build artifact, not a live thing. It is stamped with the base
image, the agent's config drive and the project's content, and any of those
changing means the next fast start boots normally and takes a new one. What it
does *not* track is a toolchain installed after it was taken - `--refresh` for
that.

This is also the answer to "the agent needs the real database". It does not:
give it a generator and a checkpoint of the loaded result. A seed script that
runs on the *host* would be a way for a VM to run code outside itself, which is
the one thing this is all for.

## Watching something inside a VM from out here

Anything that inspects a running process wants three things, and they cross a
VM boundary in three different ways:

| | how it gets across |
|---|---|
| a socket to connect to | TCP - the VM has an address |
| files, like perf captures | `firecode mirror` copies them out |
| `/proc` | it does not travel at all, so mount the guest's |

That last one is the trap. `/proc` is the kernel of the machine you read it
on, so a tool running here describes *this* machine while the process it is
reporting on runs in a VM - and it looks perfectly healthy doing it.

```sh
eval "$(firecode info --env)"        # FIRECODE_VM_IP, _SOCKET, _RUN ...
firecode mirror --once --out ~/.cache/vm '/tmp/*.perf.data'
scripts/vmprocfs.py "$FIRECODE_VM_SOCKET" 1026 ~/.cache/vm/proc &
```

`firecode info` deliberately reports facts rather than any particular tool's
settings; mapping them is one line each, in your own shell. For serenedash:

```sh
eval "$(firecode info --env)"
export SERENEDB_TARGET=remote SERENEDB_HOST=$FIRECODE_VM_IP SERENEDB_PORT=7891
export SERENEDASH_PERF_DIR=~/.cache/vm/tmp
export SERENEDASH_SYMBOL_PATHS=/path/to/build/bin
serenedash --once
```

Measured against a SereneDB running in a VM: the SQL panels are live, and the
profile panel resolves a capture taken inside the VM against a local build -
`duckdb::dict_fsst::CompressedStringScanState::ReconstructEntry` at 23.7%,
columnar work 79.6% of samples. The panels that read `/proc` describe this
machine until they are pointed at the mount.

Symbols need a build with symbols *and* a matching build-id. A stripped binary
profiles perfectly and resolves to nothing, and nothing says so - which is why
running your own build inside the VM is the shortest path to a readable
profile.

## Spawning more VMs

Firecracker exposes no virtualization extensions to its guests, so a firecode VM
can never run a firecode VM. It can ask the host to start a *sibling*, through
an MCP server reached over the same vsock relay as everything else:

```sh
cp mcp/spawn.example.json spawn.json    # list the projects that may be spawned
firecode spawn-server
firecode claude --host-port 9770 "farm this out across the sub-projects"
```

Projects are named keys from the config, never paths from the caller -
otherwise an agent could ask for any directory and read it in a VM it controls.
Children run with `--no-mcp` and an empty `--mcp-config`, so they cannot reach
the server and spawn in turn.

The tools come in two shapes. `spawn`, `status`, `output` and `cancel` are for
work handed off and collected later. `vm_up`, `vm_in`, `vm_down`, `vm_list`,
`vm_checkpoint` and `vm_reset` are for a VM an agent holds and iterates in -
bring it up once, get a fixture into it, freeze that, and reset to it between
runs instead of rebuilding it. `list_projects` says what it may touch.

A spawned VM is a sibling on the host rather than a child process of the VM
that asked for it - but it does stop when that VM stops. Each run owns a
cgroup, a VM started on another's behalf is nested inside its parent's, and
tearing a run down takes its descendants with it: asked politely first, so
their work still gets copied back, then not. `firecode list` shows what is
running and which VMs are tied to which.

The parent is worked out from the connection - a guest reaches the host
through a relay that runs inside that guest's own cgroup - so nothing has to
be declared by the guest or believed from it. See
[ARCHITECTURE.md](ARCHITECTURE.md) for the ownership model and the invariants
the tests hold to.

## Tests

```sh
firecode test           # everything, boots VMs, ~10 minutes
firecode test --quick   # host-side only, seconds
firecode test denylist  # one by name
```

They run `--no-jail --no-net`, so no privileges are needed; the jailed test
skips itself unless the jailer runs without a password. What they pin down, in
rough order of how much it would hurt to get wrong: host transcripts are
byte-identical after an import; a guest that deletes its whole project leaves
the host tree untouched; the denylist refuses a path as `--workdir`, as a
subdirectory, and as `--add-dir`; gitignored files stay out and git history
comes along; the guest's paths, home and uid match the host's; the agent's home
survives into the next run; work reaches the result directory and does not leak
into the source tree; two concurrent runs take different taps and only one holds
the state drive.

`firecode keys` prints the bytes the guest receives for each keypress, which is
the tool for "this key does nothing in the TUI".

## Housekeeping

```sh
firecode list                 # sessions and runs
firecode extract <id>         # pull a run's project back out (with --keep)
firecode gc                   # drop old run drives, keep the last 5

firecode layer add IMAGE      # a docker image as a read-only layer, by digest
firecode layer ls             # which images this project boots with
firecode --disk DEV:/mnt:rw   # a host disk or snapshot, attached not copied
firecode --vmm libvirt ...    # the other hypervisor: qemu, and PCI devices
firecode --gpu auto ...       # pass the discrete GPU (implies libvirt)
firecode --vectorized ...     # pin to performance cores, and say what cannot
                              # be measured here
firecode --kernel debug       # the traceable kernel: ftrace, kprobes, BTF

firecode state list           # per-project drives
firecode state reset          # forget this project's history, tree and layer
```

Per-run drives are deleted when the VM exits unless you pass `--keep`. Console
logs stay. Layers, state and snapshots are never touched by `gc`.

## Limits and caveats

- Your host credentials go into the VM unless you use `--auth-relay`, which
  authenticates through this host and leaves the VM holding none. The
  isolation is of the host filesystem; without the relay it is not of your
  API keys.
- The result directory looks like a full copy of the project, but the files
  that came back unchanged are hardlinks to the ones already on disk, so it
  costs what the run actually changed. Diff it, read it, delete it freely.
  Editing one of those files *in place* edits the project, since they are the
  same file - editors that save by rename (most, Emacs included) break the
  link first and are safe; `sed -i` and shell appends are not.
- Two runs at once on one project: the second gets throwaway copies of the
  state drive and the workspace layer, so what it installs is not kept and its
  session is not resumable. It says so at the time. (Until recently the layer
  was shared read-write between them, which corrupted it - the symptom was a
  guest whose root went read-only and a run that died saying "mount point is
  not a directory".)
- An OAuth refresh inside a VM rotates the token and that copy is discarded, so
  the host is left holding a spent one and needs a re-auth. `--auth-relay`
  is the way out: the model is reached through this host and the VM holds no
  credential for that provider at all.
- x86_64 only.
