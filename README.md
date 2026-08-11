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

Needs Linux with KVM, docker (to build the guest image) and e2fsprogs.

```sh
sudo usermod -aG kvm,docker "$USER"        # then log back in

firecode setup                             # firecracker, jailer, guest kernel
firecode prepare --with "dotnet@10 uv"     # guest image, with a toolchain
firecode doctor                            # check the host is ready
```

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

`FIRECODE=1` and `IS_SANDBOX=1` are in the environment. Commits use the git
identity the project reports on the host, with signing forced off - there is no
key in the guest and nothing there could answer a passphrase.

opencode gets its credentials and provider config carried in, but not the
briefing above: it reads `AGENTS.md`, not `CLAUDE.md`.

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

firecode state list           # per-project drives
firecode state reset          # forget this project's history, tree and layer
```

Per-run drives are deleted when the VM exits unless you pass `--keep`. Console
logs stay. Layers, state and snapshots are never touched by `gc`.

## Limits and caveats

- Your host credentials go into the VM. That is what makes the agent able to
  work. The isolation is of the host filesystem, not of your API keys.
- The result directory is a full copy of the project, not a patch.
- Two runs at once on one project: the second gets a throwaway copy of the state
  drive and its session is not resumable. It says so at the time.
- An OAuth refresh inside a VM rotates the token and that copy is discarded. If
  the provider invalidates the old one, the host needs a re-auth.
- x86_64 only.
- Firecracker snapshots are not wired up. "Resume" means the agent's session,
  tree and layer, not a suspended VM.
