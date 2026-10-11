## Merge gate

The merge queue runs these in a branch's worktree, after rebasing it onto `main` and before landing it; the first that fails parks the branch. Read from `main`'s copy of this file, so a branch cannot change its own gate.

The guest image, its initrd, the kernel and the firecracker binaries are a
per-host cache rather than source: they are gitignored, so no branch owns them
and a branch's worktree - being a separate working directory - has none of them,
and nothing could boot. `FIRECODE_CACHE` points at the checkout that built them.
It is derived from git rather than hardcoded, so it is not this machine's paths:

```sh
FIRECODE_CACHE=$(cd "$(dirname "$(git rev-parse --git-common-dir)")" && pwd) bin/firecode test
```
