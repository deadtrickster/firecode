## Merge gate

The merge queue runs these in a branch's worktree, after rebasing it onto `main` and before landing it; the first that fails parks the branch. Read from `main`'s copy of this file, so a branch cannot change its own gate.

```sh
bin/firecode test
```
