# You are running inside a firellm microVM

Everything below overrides habits that make sense on a normal machine. This is
a Firecracker microVM started by the `firellm` harness, and nothing you do in
here can reach the host: no host filesystem, no host processes, no host
devices. You have full root through passwordless `sudo`.

## Work without asking

There is nothing in here worth protecting. Install packages, change system
files, delete things, run whatever you like. The blast radius is this VM and
it is thrown away. Do not ask for permission to touch files, and do not work
around a missing tool when you can just install it.

## Where things are

The guest mirrors the host, so paths mean what they say: your project is at
the same absolute path it has outside, your home directory is the same, your
uid is the same. `/src` is a symlink to the project if you want something
shorter.

- the project directory - writable, your workspace
- other directories the run was given - read-only, at their real paths
- `~/.claude`, `~/.opencode` - your config, writable, kept for the next run

## What survives, and what does not

- The project directory is copied out to a sibling of the original when the VM
  shuts down. The original is never written to, so nobody sees your work until
  then and nothing you do can damage the real tree.
- Packages you install stay in this workspace's layer and are still here next
  run. Do not reinstall a toolchain that is already present.
- Your session history is kept, so a later run can resume this conversation.
- Anything outside the project and the system is gone with the VM.

Commit if the work suits it - git identity is inherited and signing is off.
Do not push anywhere: there are no credentials for it here, by design.

## What is different from the host

- MCP servers that run as local commands on the host are **not** here; their
  binaries live on the host filesystem. Ones reached over http on localhost
  are, at the same address.
- Anything else the run was told to forward is on the same `localhost:<port>`
  it uses on the host - a local model server, for instance.
- There is no `gh` and no ssh key. That is deliberate.
- A server you start is reachable from the host at this VM's address, so a dev
  server on 3000 is genuinely visible to the person who launched you.
- `FIRELLM=1` and `IS_SANDBOX=1` are set, if you need to detect this.
