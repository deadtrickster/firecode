# PEERDB-FIRECODE-NOTES

What a long PeerDB-in-firecode session cost, written 2026-10-08 by the session that paid it.
Every finding is something that session hit and can quote; every status is checked against
**the tree at `9839c04`** (bin/firecode) and the letibot backend at `de270ca` (`layer inherit`).
Re-read 2026-10-12 at `1a2d349`: the only commits since (`3c7d8cc`, `122ebde`, `1a2d349`) add
the container-runtime story and README material and revert nothing the status column names, so
the column stands. That story now has a file of its own — `HANDOFF-DOCKER-IN-GUEST.md`, and it
is resolved: containers run in a guest (all modules on a read-only drive plus in-guest `depmod`,
docker's state on the workspace layer), which is what made the PeerDB stack and its e2e suite
runnable in the VM.
Companion artifacts — the seven-stage PG->PG recipe, its measured results, and the raw logs —
are on `deadtrickster/peerdb`, branch `firecode-pg2pg`, directory `pg2pg/`.

**Most of this was fixed while it was being written.** The status column below says how each was
verified, because a notes file that still lists repaired things as defects is worse than none —
and the interesting part of these particular findings is that several fixes landed with the same
reasoning that produced them.

## Status

| # | finding | status at `9839c04` |
|---|---|---|
| 1 | `down` returned before the work was out | **fixed** — `cmd_down` now waits on the run's `copy_out` record and prints where the work is; `--no-wait` opts out |
| 2 | `cp` reported success while not overwriting | **fixed** — explicit `PUTFILE`/`PUTDIR` in `scripts/vsock-cp.py`, guest decides, trailing slash means "into this directory" |
| 3 | a shared `up.log` decided a per-run verdict | **fixed** — per-run log, and `grep -aq` so a binary match is no longer a verdict |
| 4 | preconditions checked at spawn, not start-up | **fixed** — `firecode_available()` + `probe()`, with `.inherit` probed and named errors for a missing binary |
| 5 | `up --help` booted a VM; a shared project picked a run silently | **fixed** — `1245747` |
| 6 | a failed spawn leaked its project copy | **fixed** — `remove_dir_all` now reaches the spawn-error path, not only a refused status |
| 7 | a child exiting with work still running in the guest lost it | **no sign of it in the tree** — see below |
| 8 | the seam line claimed the work "comes back as the branch" | **fixed** — `task.rs:58`, and the old text is quoted in the doc comment at `task.rs:2142` |

## The findings, with what they looked like

**1. `down` and the copy-out.**
`firecode down --project P` printed `stopping the VM` / `stopped` and returned; no copy appeared.
Reading `cmd_down` explained it: it rebooted the guest and waited for the socket to go quiet, and
the unmount-and-copy belonged to the `launch` wrapper, which a direct `up` never runs. Where the
copy did happen, it lagged — a child answered, checked for its result directory, and reported
"neither a result directory … nor firecode's record appeared within 10 s"; the directory appeared
about two minutes later. A complete run was one step from being declared lost.

**2. `cp` and the silent non-overwrite.**
`firecode cp host/file vm:/path/file` printed `10K from … into …` and exited 0 while the guest
kept the old contents: with an existing destination it created a *directory* of that name and
wrote inside it. I caught it only because an `md5sum` disagreed, and saw `03-mirror.sh` listed as
a `drwxr-xr-x` directory containing `03-mirror.sh`. Three runs executed a stale script because
of it.

**3. The shared log.**
`up` reported `the VM failed to start:` with
`grep: …/runs/up.log: binary file matches`, then `error: no VM running for … (running: …/ws)`,
while another run was booting. That VM had in fact started — a fresh entry was listed immediately
afterwards. A global append-by-everyone file was deciding a fact about one run, and a `grep` whose
status conflates "binary input" with "no match" was taken as the verdict.

**4. Preconditions at spawn.**
Two refusals, one per attempt:

    placing this session in a firecode VM: io: running firecode: No such file or directory (os error 2)
    io: firecode layer inherit refused (exit status: 1):
      [firecode] error: usage: firecode layer [add <image>|ls|rm <image>] [--project DIR]

The first because the backend resolved `$FIRECODE_BIN` else `firecode` on `PATH`, and the
daemon's `PATH` had neither. The second because `layer inherit` — a real convenience, not a
requirement — was absent, and its absence blocked placement entirely rather than degrading.

**5. `up --help`, and `--project` ambiguity.**
`firecode up --help` ran past a 60-second deadline printing no usage (and, separately, an `up`
that reported failure left a VM running). Meanwhile `cp` refused an ambiguous project by name
(`2 VMs are running - stop all but one`) while `down` silently picked one — and picked a dead one,
printing `stopped` and copying nothing.

**6. Leaked copies.**
The first failed spawn left 286 MB in `~/.cache/letibot/firecode/`; the cleanup reached only a
non-zero *status*, not an error launching the binary. Four such directories had accumulated.

**7. A child's exit does not know about its guest.**
One child backgrounded a ten-minute run, answered "it is running", and its session ending shut the
VM down and killed the run. The harness knows about jobs per session, so the teardown could ask
the guest for its process tree and put "N processes were still running when the VM stopped" into
the child's answer. I found no sign of this in the tree; the copy-out waiting in item 1 covers the
adjacent case (the copy that had not finished), not this one.

## What should not change

- **The boundary, and its honesty about itself.** No virtio-fs, so the host is *unreachable*
  rather than merely not copied; refuse lists applied at any depth, so a parent directory cannot
  smuggle them in; and the README saying plainly that it does not protect your API credits or
  your network, with `--auth-relay` as the way out. Measured inside a guest:
  `firecode-claude on /Users/dead/.claude type overlay` — the agent's own credentials are the
  honest remainder, and they are named as such.
- **Fail closed on placement.** Two spawns failed by name rather than running on the host and
  calling it a VM. That is why the real defects were found instead of a quiet host-side run.
- **The `sudo -n true` guidance.** "You are uid 1000, but sudo never prompts; anything deciding
  between 'ask for privileges' and 'already have them' should ask `sudo -n true`." Non-obvious,
  correct, and it saved real time.
- **`layer inherit`** — the right shape of feature (a copy booting with its source's layers). It
  needed a capability probe so its absence degrades, not a redesign.

## One residue outside firecode

The guest image carries PostgreSQL 18 packages and no cluster — the right default for an image
that should not presume a database; the recipe creates the cluster. The residue is repo metadata:
`apt-get install postgresql` resolves to `postgresql-16`, whose dependency cannot be met from the
configured repos (`postgresql-16 : Depends: libllvm19 but it is not installable`), so a generic
reach for "postgres" returns an "impossible situation" that reads as a broken box rather than a
version pin. Worth a line in the image build; not a firecode defect.

## How this was gathered

Direct CLI: `firecode up --project <copy>`, `firecode in --project <copy> --cwd <copy> '<cmd>'`,
`firecode cp`, `firecode down`, `list`, `ps` — 60-odd commands against one 4 GB and one 8 GB VM.
Placement: three `task(where: "firecode")` spawns — the two refusals above, one interrupted by the
operator, and one that completed and whose artifacts were harvested from the copy-out under
`~/.cache/letibot/firecode/`. Every quoted message is copied from that session's output, not
reconstructed. The measured PeerDB results are in `pg2pg/RESULTS.md` on the branch named above.
