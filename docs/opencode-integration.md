# Running opencode inside firellm

opencode is the CLI agent you are currently using. To run it safely on autopilot:

1. Make sure opencode binary (or its launcher) is available inside the guest.

Because opencode here is a native ELF + node_modules heavy thing, easiest is:

Option A (recommended for now):
- Build a docker image that contains the exact opencode you use.
- Or volume mount the host ~/.opencode and /home/dead/.bun etc carefully (hard because of paths and dynamic).

Option B:
- After VM boots, from host use vsock or serial to run:
  curl -fsSL ... install script inside, or scp your tools.

For quick experiments the rootfs already has node + bun + git + python.

You can copy the opencode binary + its node_modules into the work drive before launch, then from inside guest:

```sh
cd /work
export PATH=... 
./opencode --help
```

## Recommended pattern for autopilot

```sh
# on host, in your project
/home/dead/Projects/firellm/bin/firellm run \
  --workdir "$(pwd)" \
  --task "review the diff and implement the requested changes. be thorough." \
  --id review-123
```

Inside the guest the agent script can do:

```sh
cd /work
git status
# run the actual agent command
# opencode "..." --non-interactive || true
echo "agent finished" > /work/.firellm-done
poweroff   # or just let it idle
```

## Making opencode firellm-aware (future)

You can modify the opencode source (wherever it lives on your machine) to detect the FIRELLM=1 env var and:

- use more conservative file ops
- auto commit to a shadow branch
- stream all tool calls over vsock to host for audit
- refuse destructive ops outside /work

See the CLAUDE.md or opencode instructions in your env for where source lives.

For maximum safety when leaving on autopilot, always:

- use a dedicated workdir that is a git clone you don't mind losing
- use --no-net if the task doesn't need external calls
- set low --mem and --vcpu
- monitor the jailer log
- destroy the jail immediately after
