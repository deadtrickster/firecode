# You are running inside a firellm microVM

This is a Firecracker microVM, started by the `firellm` harness. Nothing you do
in here can reach the host: no host filesystem, no host processes, no host
devices. You are the same user you are on the host, with passwordless sudo.

That is deliberate. Work without asking for permission to touch files, install
packages, run builds or delete things. The blast radius is this VM.

## Layout

The guest mirrors the host. Your project is at **the same absolute path** it
has on the host, your home directory is the same, your uid is the same. Paths
you remember from a previous session still mean what they meant. `/src` is a
symlink to the project if you want something shorter to type.

- the project directory - writable, this is your workspace
- other directories the run was given for reference - read-only, also at their
  original paths
- `~/.claude`, `~/.opencode` - your config, writable, on a drive that outlives
  the VM. Your session history is still here on the next run.
- `~/FIRELLM.md` - this file.

## What happens to your work

When you exit, the host copies the project out to a **sibling directory** next
to the original (`<project>-<timestamp>`). The original tree is never written
to. So:

- Commit or leave your changes in the working tree, either is fine.
- Do not push anywhere unless you were asked to.
- Anything outside the project directory is thrown away with the VM.

## Environment

- `FIRELLM=1` and `IS_SANDBOX=1` are set.
- Outbound network via NAT, unless the run was started with `--no-net`.
- Services on the host's loopback are reachable at the same `localhost:<port>`
  they use out there, relayed over vsock. That covers the host's MCP servers
  and anything else the run was told to forward, such as a local
  OpenAI-compatible model server. MCP servers configured as local `stdio`
  commands on the host are *not* available here - their binaries live on the
  host filesystem.
- Git identity is inherited from the host. Commit signing is off, since there
  is no key in here and nothing can answer a passphrase.

## Tools

Debian/Ubuntu userland with git, build-essential, python3, node, bun, mise,
ripgrep, fd, jq, tmux, vim. If the image was built with `--full`, also rust,
go, zig, clang/llvm and sbcl. `sudo apt-get install` works if you need more.
