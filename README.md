# firellm

Firecracker + Jailer harness for running LLM agents on autopilot safely.

## Why

Running autonomous agents directly on host is risky: they can delete files, install malware, exfiltrate data, run cryptominers, etc.

firellm runs each agent session inside its own Firecracker microVM, further isolated by the official `jailer`.

- Strong filesystem isolation (chroot + separate rootfs per VM)
- Resource limits via cgroups
- Dropped privileges
- Optional no-network or tightly controlled network
- Easy to snapshot / destroy / audit

## Goals

- One-command: `firellm run "fix the bug in src/"`
- Agents see a normal Linux env (with their tools preinstalled)
- Host sees nothing but a contained process
- Designed so you can walk away and let the agent work

## Prerequisites

- Linux with KVM (`/dev/kvm` writable, user in kvm group)
- `sudo` access (jailer needs it)
- curl, wget, tar, etc.
- (recommended) docker for easy custom rootfs builds

Your user must be in `kvm` group:

```sh
sudo usermod -aG kvm $USER
# re-login
```

## Quick Start

```sh
git clone ... firellm
cd firellm

# 1. Install firecracker + jailer + assets (downloads ~150MB)
sudo ./scripts/setup.sh

# 2. Prepare a bootable agent rootfs (includes common dev tools + node/bun skeleton)
./scripts/prepare-rootfs.sh

# 3. Run an agent task (example uses opencode if present on host PATH inside guest)
./bin/firellm run --task "implement feature X" --workdir ./myproject
```

The VM is started via:

```
sudo jailer \
  --id "agent-$$" \
  --exec-file /usr/local/bin/firecracker \
  --uid 1000 --gid 1000 \
  --cgroup ... \
  --chroot-base-dir /srv/jailer/firellm \
  -- \
  --config-file /path/to/inside-jail/config.json
```

All resources (kernel, rootfs, work disk) are hard-linked/copied inside the jail root as required by jailer.

## Layout

```
bin/firellm          # main CLI wrapper
scripts/
  setup.sh           # download firecracker, jailer, kernel
  prepare-rootfs.sh  # build or customize ext4 rootfs
  launch.sh          # low level jailed firecracker starter
configs/
  vm-config.json     # firecracker config template
images/              # downloaded kernels + base rootfs (gitignored)
guest/               # files injected into guest (agent wrappers, etc)
```

## Networking

Default: TAP device + NAT for outbound (so agents can call OpenAI/Anthropic/etc).

For stronger isolation you can run with `--no-net` (only vsock for control).

## Communication

- Control via Firecracker API socket (inside jail)
- Task injection: workdir is bind-mounted as second drive (rw)
- Agent entrypoint: `/opt/firellm/agent-run` (you can override)
- Output / logs captured on host via serial or vsock

## Modifying opencode for firellm

See docs/opencode-integration.md

You can run the opencode binary (or any agent) inside the guest by placing it in the rootfs or mounting the host binary (careful with dynamic libs - prefer static or container-built).

## Safety Notes

- Never trust the guest. Treat its output.
- Use read-only base rootfs + overlay or separate rw drive for /home/work.
- Set cpu/mem limits.
- Consider running the jailer inside its own restricted user namespace if possible.
- Regularly destroy old jails: `sudo rm -rf /srv/jailer/firellm/*`

## Status

Early. Works on Ubuntu 24.04+/26.04 with KVM.

Contributions welcome.
