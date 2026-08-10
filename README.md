# firellm

Run a coding agent inside a Firecracker microVM, so you can walk away from it.

```sh
firellm claude "port the parser to the new AST and make the tests pass"
```

The agent gets root, the network, and your project at `/src`. It does not get
your host: no host filesystem, no host processes, no host devices. It runs with
permission checks off, because there is nothing in there worth protecting.
When it finishes, the VM powers off and the work is copied out to a sibling
directory. Your project directory is never written to.

## Install

Needs Linux with KVM, docker (for building the guest image), and e2fsprogs.

```sh
sudo usermod -aG kvm,docker "$USER"   # then log back in
git clone ... firellm && cd firellm

./bin/firellm setup      # firecracker + jailer + guest kernel, no root
./bin/firellm prepare    # build the guest rootfs via docker, no root
./bin/firellm doctor     # check everything is in place
```

Two things need root. Networking needs it once:

```sh
sudo ./bin/firellm net-setup --count 4
```

That leaves persistent tap devices behind that belong to you, so no run needs
privileges for the network again. The jailer cannot be made one-time, since it
has to be root to chroot and drop privileges. Either let it prompt, or:

```sh
sudo ./scripts/install-privileged.sh
```

Read the top of that script first - the jailer execs a binary as a uid of the
caller's choosing, so treat it as passwordless root. If you would rather not,
`--no-jail` needs nothing at all.

With no controlling terminal - cron, a hook, another agent - sudo cannot
prompt. Set `SUDO_ASKPASS` to an askpass helper and it will ask on the desktop
instead:

```sh
SUDO_ASKPASS=/usr/bin/ksshaskpass firellm claude "..."
```

## What it protects against

Wiping your system, and reading things it has no business reading - SSH keys,
GPG keys, browser profiles, cloud credentials. The guest has no path to any of
them: it sees a copy of one project and nothing else of yours. `--add-dir`
refuses outright to carry `.ssh`, `.gnupg`, `.aws`, `.kube`, `.config/gh`,
`.password-store` or a browser profile out of your home directory, whatever you
ask it to.

It does not protect your API credits or your network. The agent has your Claude
credentials, because otherwise it cannot work.

## Use

```sh
cd ~/Projects/thing

firellm claude "add tests for the parser"        # unattended, shuts down when done
firellm claude --timeout 3600 "big refactor"     # give up after an hour
firellm opencode "fix the failing build"
firellm shell                                    # poke around inside by hand
firellm exec make -j8                            # run any command in the sandbox
```

Anything after `--` goes to the agent untouched:

```sh
firellm claude -- -p "review the diff" --model opus --output-format stream-json
```

Results land next to the project:

```
~/Projects/thing                       # untouched
~/Projects/thing-20260809-231500-4711  # what the agent produced
```

Nothing is applied for you. Diff it and take what you want.

## Resuming

The agent's home directory lives on a per-project drive that outlives the VM,
so a second run can pick up where the first stopped:

```sh
firellm claude "start the refactor"
firellm claude --continue "now do the tests too"

firellm state sessions                       # session ids you can resume
firellm claude --resume 3f9a1c2e "and the docs"
```

`--continue` and `--resume` also carry the **working tree** forward, not just
the conversation. Resuming a conversation into a pristine checkout would tell
the agent it had already made changes that were not there. `--fresh` opts out.

A session you started on the host can be moved in and continued unattended:

```sh
firellm claude --import-sessions --resume <session-id> "carry on without me"
```

That copies this project's host transcripts onto the state drive and rewrites
every reference to the host path to `/src`, which is where the project lives in
the guest. Your host transcripts are only read, never modified. It happens
automatically the first time you continue a project in a VM.

## Reaching things on the host

MCP servers the host exposes over http/sse on `localhost:PORT` are relayed in
and reachable at the same `localhost:PORT`. Anything else on the host's
loopback needs naming:

```sh
# local llama-server on 127.0.0.1:18080, OpenAI-compatible
firellm claude --host-port 18080 "..."
```

Inside the guest that is `http://localhost:18080/v1`, with no config rewriting
on either side. This runs over vsock rather than the network, so it works under
`--no-net` too: a VM with no route to anything except the one host port you
named.

Extra context that is not the project itself goes in read-only:

```sh
firellm claude --add-dir ~/Projects "match the API the sibling repo uses"
```

Those are copies. The guest can read them; nothing written there goes back out.
The only thing that ever comes back is `/src`.

## Reaching a server the agent started

Your host is the other end of the guest's link, so anything it serves is
reachable directly - no forwarding, no configuration. firellm prints the
address when the VM starts:

```
[firellm] guest is 172.16.1.2 - a server it starts on PORT is at
[firellm]   http://172.16.1.2:PORT
```

So a dev server on 3000 inside is `http://172.16.1.2:3000` in your browser.
Not under `--no-net`, which leaves the guest with no network at all.

## Moving files in and out

Firecracker cannot mount a host directory into a guest - it has no virtio-fs
and no 9p, deliberately - so there is no shared folder to be had. What there
is, is vsock:

```sh
firellm cp vm:/src/dist ./dist        # out of a running VM
firellm cp ./logo.png vm:/src/assets  # into one
```

Files and directories, in either direction, while the VM is running. Ordinary
runs still copy the whole project out to a sibling directory when they finish;
this is for when you want something sooner, or want to hand something in.

## Snapshots

A project's VM state is three drives: the agent's home (sessions), the working
tree, and the rootfs. `snapshot` captures all three together.

```sh
firellm snapshot before-the-refactor
firellm snapshot ls
firellm snapshot restore before-the-refactor
firellm snapshot rm before-the-refactor
```

Restoring puts the next run back exactly where the snapshot was taken: same
conversation, same working tree, same installed packages. They are sparse
copies, so a snapshot of a 13G set of drives is more like 1.4G on disk.

This is disk state, not a paused VM. Firecracker can snapshot memory too, but
that only helps for a VM that is still running - and a session you ended with
Ctrl-C is not.

## Keeping what the agent installs

The guest rootfs is thrown away after every run, so an SDK or a set of apt
packages the agent installed has to be downloaded again next time. For a
project that needs a toolchain the image does not carry:

```sh
firellm claude --keep-root "build and test it"
```

That keeps this project's rootfs between runs, so the second run starts with
whatever the first one installed. `firellm state reset` throws it away again,
and a run without the flag still gets a clean one.

For something you want in every project, put it in the image instead - edit
`guest/Dockerfile` and `firellm prepare --force`. `--full` already adds rust,
go, zig, clang/llvm and sbcl.

## Commits

Commits inside the VM use the `user.name` and `user.email` git reports for the
project on the host, so they are in your name. Signing is forced off: there is
no key in the guest, and nothing in there could answer a passphrase prompt.

## How it works

Four drives are attached to the VM, found by filesystem label rather than
device order:

| label | mount | contents |
| --- | --- | --- |
| `firellm-root` | `/` | per-run sparse copy of the guest image, thrown away after |
| `firellm-src` | the project's host path | your project, writable, copied back out |
| `firellm-cfg` | `/opt/firellm/config` | read-only: agent binaries and host config |
| `firellm-ctl` | `/opt/firellm/run` | read-only: this run's parameters and guest scripts |
| `firellm-state` | `/var/lib/firellm` | per-project agent home, survives the VM |
| `firellm-x*` | their host paths | read-only: whatever `--add-dir` asked for |

Inside the guest, `firellm-mounts.service` mounts those, brings up the network,
starts the MCP relays and layers `~/.claude` and `~/.opencode` as writable
overlays on the read-only config drive. Then `firellm-agent.service` runs the
agent on the serial console and powers off when it returns.

Images are built and read without root: `mkfs.ext4 -d` writes an image straight
from a directory, and `debugfs rdump` reads one back, neither of which needs a
mount. The guest rootfs is built by exporting a Docker container, so `prepare`
needs no privileges either.

### Agents

The `claude` and `opencode` binaries are not baked into the image. They are
copied from the host onto the config drive at launch, so the guest always runs
the version you run. Credentials, `CLAUDE.md`, agents, commands, skills and
plugins come along; 1.6G of session history does not.

For an unattended run, `-p` and `--dangerously-skip-permissions` are added for
you when you have not specified them (`--no-auto-flags` turns that off). Claude
Code refuses to skip permissions as root unless it can see it is sandboxed, so
the guest sets `IS_SANDBOX=1`.

### MCP

MCP servers the host exposes over http/sse on `localhost:PORT` are relayed into
the guest, and reachable at the same `localhost:PORT` there. Firecracker maps a
guest vsock connection to CID 2 port N onto a unix socket on the host, where a
`socat` forwards it to `127.0.0.1:N`. The host servers see an ordinary local
connection and need no changes.

MCP servers configured as local `stdio` commands cannot come along - their
binaries live on the host filesystem, which is the thing being kept out. Those
are dropped from the guest config, and named when the config drive is built.

### Networking

Each VM gets its own tap device and its own `/30`, so several can run at once
without colliding. NAT is via iptables, plus explicit FORWARD rules, because
Docker sets the FORWARD policy to DROP and masquerading alone would not be
enough. `--no-net` gives you a VM with no network at all; MCP still works,
since vsock is not networking.

DNS in the guest is 1.1.1.1 and 8.8.8.8. If you need a private resolver, edit
`FIRELLM_DNS` in `bin/firellm`.

### Resource limits

`--mem` and `--vcpu` are hard limits: Firecracker will not give the guest more
than it was configured with, whatever happens inside. `--cgroups` additionally
caps the host-side VMM process through the jailer, which is mostly redundant
and off by default because cgroup delegation is fiddly on systemd hosts.

## Spawning more VMs

Firecracker exposes no virtualization extensions to its guests, so a firellm
VM can never run a firellm VM. What it can do is ask the host to start a
*sibling*, through an MCP server that runs on the host and is reached over the
same vsock relay as everything else:

```sh
cp mcp/spawn.example.json spawn.json    # list the projects that may be spawned for
firellm spawn-server                    # host side, listens on 127.0.0.1:9770
firellm claude --host-port 9770 "farm this out across the sub-projects"
```

Tools: `list_projects`, `spawn`, `status`, `output`, `cancel`.

This inverts the trust direction, so it is deliberately narrow. Projects are
named keys from the config, never paths from the caller - otherwise an agent
could ask for any directory it liked and read it in a VM it controls. Children
are started with `--no-mcp` and an empty `--mcp-config`, so they cannot reach
the server and spawn in turn. Concurrency and total runs are capped.

## Tests

```sh
firellm test           # everything, boots VMs, a few minutes
firellm test --quick   # host-side only, seconds
firellm test denylist  # one by name
```

They run with `--no-jail --no-net`, so no privileges are needed. What they pin
down, in rough order of how much it would hurt to get wrong:

- your host transcripts are byte-identical after an import, checked against the
  real `~/.claude` because that is the thing that would hurt
- a guest that deletes its entire project leaves the host tree untouched - and
  the guest really can delete it, or the test proves nothing
- the denylist refuses a path as `--workdir`, as a subdirectory of a listed
  entry, and as `--add-dir`, and credential directories are refused with no
  config at all
- gitignored files stay out, git history comes along
- the guest's project path, home and uid match the host's
- the agent's home survives into the next run
- an imported transcript lands under the same project key with its paths intact
- work reaches the result directory and does not leak into the source tree
- an unchanged reference tree is not re-imaged, a changed one is

## Housekeeping

```sh
firellm list             # what has run
firellm extract <id>     # pull a run's /src back out (if --keep was used)
firellm gc               # drop old run drives, keep the last 5

firellm state list       # per-project agent state drives
firellm state sessions   # resumable session ids for this project
firellm state reset      # forget this project's agent history and tree
```

Per-run drives are deleted when the VM exits unless you pass `--keep`. Console
logs stay. State drives are never touched by `gc` - `state reset` is the only
thing that removes them.

The guest scripts ride in on the control drive and take precedence over the
copies baked into the image, so changing the harness does not mean rebuilding a
6G rootfs. Only the systemd units and the installed packages need a rebuild.

## Without root

`setup`, `prepare`, building every drive and reading results back all work
unprivileged. Only two things need root: the jailer, and creating the tap
device. `--no-jail` skips the first and `--no-net` removes the second, so

```sh
firellm claude --no-jail --no-net --host-port 18080 "..."
```

needs no privileges at all. That is still a real KVM guest with its own kernel
and no view of the host filesystem - what you give up is the jailer's chroot,
uid drop and pid namespace around the VMM process itself, which is hardening
against a Firecracker escape rather than against the agent.

## Limits and caveats

- Your host credentials go into the VM. That is what makes the agent able to
  work. The isolation is of the host filesystem, not of your API keys - an
  agent in here can spend your tokens and reach the network.
- The result directory is a full copy of the project, not a patch. Big repos
  mean big copies.
- Two runs on the same project at once: the second gets a throwaway copy of the
  state drive and its session is not resumable. Said so at the time.
- x86_64 only.
- Firecracker snapshots are not wired up. Resume means the agent's session and
  working tree, not a suspended VM.
