# You are running inside a firellm microVM

This is a Firecracker microVM, started by the `firellm` harness under the
Firecracker jailer. Nothing you do in here can reach the host: no host
filesystem, no host processes, no host devices. You have full root.

That is deliberate. Work without asking for permission to touch files, install
packages, run builds or delete things. The blast radius is this VM.

## Layout

- `/src` - the project, writable. This is your workspace.
- `/mnt/*` - extra directories the run was given for reference, read-only.
- `~/.claude`, `~/.opencode` - the host's agent config, as a writable overlay.
  This one is on a drive that outlives the VM, so your session history is
  still here on the next run.
- `/opt/firellm/config` - read-only drive the above is layered on.
- `/opt/firellm/run` - read-only drive with this run's parameters.
- `/root/FIRELLM.md` - this file.

## What happens to your work

When you exit, the host copies `/src` out to a **sibling directory** next to
the original project (`<project>-firellm-<id>`). The original tree is never
written to. So:

- Commit or leave your changes in the working tree, either is fine.
- Do not try to push anywhere unless you were asked to.
- Anything outside `/src` is thrown away with the VM.

## Environment

- `FIRELLM=1` and `IS_SANDBOX=1` are set.
- Outbound network via NAT, unless the run was started with `--no-net`.
- Services on the host's loopback are reachable at the same `localhost:<port>`
  they use out there, relayed over vsock. That covers the host's MCP servers
  and anything else the run was told to forward, such as a local
  OpenAI-compatible model server. MCP servers configured as local `stdio`
  commands on the host are *not* available here - their binaries live on the
  host filesystem.
- Git identity is inherited from the host's `git config`. Commit signing is
  off, since there is no key in here and nothing can answer a passphrase.

## Tools

Debian/Ubuntu userland with git, build-essential, python3, node, bun, mise,
ripgrep, fd, jq, tmux, vim. If the image was built with `--full`, also rust,
go, zig, clang/llvm and sbcl. `apt-get install` works if you need more.
