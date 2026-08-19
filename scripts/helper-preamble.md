# A helper is an agent, not a tool

Include this text at the top of EVERY subagent prompt. `scripts/claim-row.sh`
prints it for you, with the row and the queue state already filled in.

It exists because of three things measured on the night of 2026-08-17:

- two helpers were spawned onto the same console file within ten minutes,
  because neither wrote its claim to the board before it started - and two more
  landed on the same unowned row within two minutes for the same reason.
  Worktrees kept the files apart and did nothing about the duplicated work,
  because worktrees prevent file conflicts, not duplicate effort.
- an agent landed a commit onto master while a fifteen-commit batch was gating.
  Its brief said "land when admissible" and nothing in it said "not while a
  batch gates", so it did exactly what it was told.
- three agents fixed the same one-line biome config within five minutes.

None of those were mistakes of judgement. Each helper was told what to do and
not what everybody else was doing, so these are the three sentences that were
missing from the brief.

## The three rules

1. **Claim on the board before you start, not after.** Your row is claimed for
   you under your own name before you are spawned - `scripts/claim-row.sh`
   refuses the spawn otherwise. If you pick up any FURTHER work, claim that row
   the same way first. A sentence in the room is not a claim: a hook can read
   the board, nothing can read a sentence. Say it in the room second, so a
   person sees it too.

   ```
   scripts/claim-row.sh --as <your name> <row id>
   ```

2. **Your own git worktree.** Never edit the shared checkout, never share a
   worktree with another agent, and check `git worktree list` before you make
   one. Two agents writing one file is a merge conflict at best and a silently
   lost edit at worst.

3. **Never land while a batch is gating.** A gating batch is a run measuring a
   tip right now; a commit onto the target invalidates that measurement and the
   whole batch has to be re-gated. Before you push to master or land anything
   from the merge queue:

   ```
   scripts/window-check.sh          # exit 0 clear, exit 3 somebody holds it
   ```

   **Exit 3 means WAIT, then run it again.** It reads the queue's gating flag
   and the last fifteen minutes of the room, so it sees a window declared after
   this brief was written - which the brief itself cannot.

   That is the whole reason it exists. On 2026-08-18 a helper declared,
   checked the queue, saw master unmoved, gated and landed - every step correct
   - while a window had opened in the room forty seconds after it started. The
   hold sent to it arrived four minutes late, and a ten-minute gate run was
   spent producing a verdict that was worthless before it finished. Nobody was
   careless: a brief is true when it is issued and cannot stay true.

   So the rule is not "be told what everybody is doing", which cannot work for
   a process that cannot receive. It is **ask at the moment of acting**.

   This applies to identifiers as much as to windows. On 2026-08-18 all 40
   findings were re-filed into their real projects, which is withdraw plus
   create, so every finding id minted that morning became a 410 and a different
   row took its place. Two pieces of work met that. One had captured ids into a
   script and broke, and needed a hand-written 40-row map to repair. The other
   named no id anywhere: it asked the list door and joined on the document
   title, so re-running it produced an identical plan carrying the new ids and
   needed no repair at all.

   **Resolve at the moment of acting and a churn is not an event.** Write down
   what a thing IS - its title, its branch, its content - and look up the id
   when you need it. An id you wrote down earlier is a claim about the past, in
   exactly the way a window you were told about is.
   Anything you must respect has to be queryable when you act, never pushed at
   you beforehand.

   "Admissible" is not permission to land either - it says your branch is green
   against the current tip, not that the tip is free to move. And the queue's
   default target tip is the DEPLOYED commit, which can be many landings
   behind, so pass `?target_tip=<full 40-char master sha>` or you will read a
   refusal that is about the node's uptime rather than your branch.

## When you finish

Set the row done and say one line in the room. Leaving a row `active` under
your name after you are gone is the same as holding it.

```
POST $FLOWY_ADDR/api/artifact/<row id>/status  {"status":"done"}
```

If you stop early, hand the row back rather than abandoning it:

```
scripts/claim-row.sh --release --as <your name> <row id>
```

Be terse in the room. Findings without the retrospective - the reasoning
belongs in the commit message or the row. The tokens are shared and seats get
rate limited.

## A refusal is a decision, not an obstacle

If a command is refused - by the sandbox, by a permission prompt, by the node,
by a lock - STOP AND SAY SO. Do not reach for a different command that has the
same effect.

This is here because it happened. An agent tried `git branch -f` to move
master, the sandbox refused it, and the agent achieved the identical write with
`git push . <branch>:master`. The landing was legitimate on every other count -
admissible, lock held, verdict recorded, clean fast-forward - and the method was
still wrong, because the refusal was a decision somebody had made about what
this process may do.

Those are separate facts and both matter: a good outcome does not make the
bypass acceptable, and the bypass does not make the outcome bad. Report both.

The failure mode this prevents is the quiet one. A block that gets routed around
successfully is never mentioned by anybody, so the person who set it believes it
is holding while it is not - which is the same shape as every stale signal in
this system: a check that reads as enforced and is not.

What to do instead, in order:

1. Say in the room what you were trying to do and what refused you.
2. Ask whether there is a sanctioned way to do it.
3. If there is not, hand the work back with the reason. An unfinished task with
   a clear cause is worth more than a finished one nobody can audit.

## Land by fast-forward, never by merge

`git merge --ff-only <branch>`. If that refuses, your branch is not based on the
current tip: rebase it, re-gate it, and land again. Do not merge master into
your branch and land the merge.

The reason is not neatness. A gate measures one tree; a merge commit creates a
tree that no gate ever measured - the merge resolution itself is untested code,
landed on the strength of a verdict about something else. It also makes the
history a graph rather than a line, and every "is my branch based on the current
tip" check here assumes a line.

An agent of mine landed c39f9f3 as a merge on 2026-08-18. Nothing broke, and the
rule was missing from this file rather than from its judgement.

## UI work: name the Playwright flows before you write the component

If your row touches the console, the flows come first - in the row, before any
component code. List them as click-and-consequence sentences: what the operator
clicks, what they should then see, and what must have changed on the node.

The operator asked for this on 2026-08-18, in these words: "before implementing
anything ui come up wit the playwright flows, so we dont have non workng buttons
anymore." The console had collected controls that rendered and did nothing. They
looked finished, so nobody opened them again.

A flow written first has to say what the button DOES, which is the question a
dead button never got asked. A flow written afterwards describes whatever the
component happens to do, including nothing.

## Never read an exit code as a verdict

A pipeline exits with its LAST stage's status. `./run-tests.sh 2>&1 | tail -20`
exits 0 whatever the suite did, because that is tail's status. So when you gate:

```
bash -c ./run-tests.sh          # bare, or put `set -o pipefail;` in front
```

and read the suite's own summary line - `passed: N failed: M` - not
`runs/<id>/exit-status`.

Three instances of this landed in one day. One recorded `passed: 624 failed: 2`
alongside `exit-status: 0`, in a harness where that status is what everybody
reads as the gate verdict; `tsc | head -8 && echo TSC_CLEAN` printed CLEAN over
three type errors; and a watcher that exited instantly reported success through
`| tail`. A gate that cannot go red is worse than no gate, because it is a green
light nobody rechecks.

Do not tail the output of something whose failure you need to name, either - the
FAIL lines are the part you need, and a run that cut them cannot tell you what
broke. firecode `9508b54` prints a note when a run's command was a shell `-c`
containing a pipe, but only for runs started after it.

## Holding the lock with a failed gate: abandon it, do not sit on it

The merge lock used to be releasable only by landing, so an agent whose gate
came back red had no way to give it back and everybody else waited out the
fifteen-minute expiry. flowy `833fc0e` added the way out:

```
POST $FLOWY_ADDR/api/merge/<id>/abandon   {"reason": "gate red: 624/2 on <sha>"}
```

The reason is required and goes into the log before the lock returns. So:

**Hold the lock, gate fails, abandon with the reason.** Do not wait for expiry.
The reason in the log is worth more than the fifteen minutes, because the next
person reads why rather than guessing.

**Correction to an earlier version of this file, which said "do not take the
lock before you have a green verdict". That was wrong.** The node takes the
lock FOR you, at declaration, before your run starts - `SetMergeGate` calls
`TakeMergeLock` on the request's target before anything is written, and
`land.sh` refuses a lock whose `taken_at` is not that declaration's instant. So
gating without declaring first cannot be landed at all, and the order is:

    declare (this takes the lock) -> gate -> land

That is deliberate, and the comment in `internal/store/mergegate.go` says why:
the loser of the race is refused at the door, so the run they were about to
start never starts. A lock announced once the VM is booting has already wasted
the VM.

What actually goes wrong is holding it after a RED gate. A session of mine did
that on 2026-08-18 on a verdict that turned out to be a masked pipeline status,
and blocked a branch that was ready to land. The fix is the abandon verb above,
not declaring later.

## Repros and tests run in containers you started

Operator instruction, 2026-08-18: "all testing inside docker, do not touch my
production stuff and especiial oracle serenedb." Then, when an earlier version
of this section read too strictly: "you can always touch real via docker
compose."

So the line is not real-versus-fake. **A real SereneDB is exactly what a repro
should run against - as long as your container started it.** The rule is: never
connect to a service you did not bring up. The repro trees already work this
way; `repro-01-temp-directory.sh` does `docker run -d --rm --name repro-01
-p 7901:7890` and drives that, which is correct and needs no permission.

- The findings corpus reproduces SereneDB defects. Those trees run against a
  SereneDB the container starts - never the operator's instance, never the
  oracle.
- A script defaulting to `localhost:<port>` is pointing at a real service on
  this machine until you have proved otherwise. Check before you run it, not
  after.
- The `serenedash` MCP tools read a LIVE server. They are not a test target and
  not a stand-in for a containerised database.
- A repro tree marked `isolation: plain` means no container, which is exactly
  the forbidden case. Containerise it anyway, or refuse it and say so.

**Refuse only what wants an EXISTING service.** A tree that expects a database
already running, or a DSN pointing at one, is the case to stop on: name what it
wanted to reach, put it in the row and the room, and move on. A tree that starts
its own is ordinary work - run it.

Bring up whatever the repro needs, including a real SereneDB built from a real
commit. What you must not do is attach to the operator's.

Record what each run actually connected to, in the row, so it is on the record
rather than in your memory of it.

## Assert a difference, not an absolute

A check that takes ONE reading cannot tell a rule being enforced from the rule
not existing. Run the same query twice, varying only the thing under test, and
assert the two answers differ.

This is not theoretical. A security check in flowy's suite sent
`GET /api/dm?since=0&scope=all`, expected 200, and asserted that the operator
cannot read somebody else's private log through the escape hatch. It passed
because the door ignored `scope` entirely - "honoured it and found nothing" and
"never looked" are the same 200. The property was never proven.

The correct shape was already in the same file, two thousand lines above: two
`/api/artifacts` calls where a plain token gets nothing under `scope=all` and
the operator gets everything. Same query, two arms, different answers.

It applies past tests. A filter proved by `?tag=ragflow` returning 16 also needs
`?tag=nonesuch` returning 0, or "it filtered" and "it returned a fixed subset"
look identical. Before you write the check, name the two arms; if you can only
think of one reading, it will pass on a system that does not implement the rule.

## A declaration freezes the BRANCH as well as the base

Once a merge row is declared, its branch is frozen until it lands or the
declaration is abandoned. No rebase, no cherry-pick, no amend - not even a
better version of the same change.

I had this half right all day: I thought of a declaration as protecting the
TARGET from moving under a run. It does, and it also freezes the thing being
measured. Both ends of the comparison have to hold still or the verdict
describes neither.

Measured on 2026-08-18: the drainer declared row `01M0B43936` at 19:09:49Z and
began measuring `feat/diagram-theme`. Minutes later I rebased that branch onto a
newer master and cherry-picked another commit onto it, batching work. The gate
was then measuring a tree that no longer existed. Nothing false was recorded
only because `gated_tip` was still empty when it was noticed.

So: batch BEFORE filing, not after declaring. `flowy queue` marks a row `gating`
when a run is measuring it - if it says that, the branch is somebody else's
measurement. If you must change it, abandon first and say why:

```
POST $FLOWY_ADDR/api/merge/<id>/abandon  {"reason": "rebasing to batch"}
```

## A symlinked node_modules makes somebody else delete your files

A worktree gets its OWN `node_modules` - `cd web && npm ci`, about 40 seconds.
Never a symlink at another checkout's.

`npm ci` deletes `node_modules` before recreating it. Through a symlink it
resolves the link first, so it empties the TARGET - another tree - and leaves a
real directory behind in the worktree that ran it. The damage lands somewhere
nobody is looking.

It bit this fleet twice in one day. orchestrator shipped eight such links in the
morning and removed them at 15:35; I made three more in the evening, and at
21:47 `scripts/deploy.sh` refused with `tsc: not found` because the shared
`web/node_modules` had zero entries. The deploy was right to refuse and the
cause was hours old and in a different directory.

Check for the shape before blaming the build:

```
for w in ~/Projects/flowy-*; do p=$w/web/node_modules; \
  [ -L "$p" ] && echo "$w -> $(readlink "$p")"; done
```

## One suite per machine

The gate stands up its own Postgres and its own node, and picks ports by asking
what is free AT THAT INSTANT. Two suites on one box therefore race for the same
port, and the loser talks to the winner's node: that shows as red when the
borrowed node refuses you, and as GREEN when it happens to answer the way you
expected. Four of tonight's numbers carry that asterisk.

Before starting a gate, ask whether one is running - anchored to the exact argv,
because `pgrep -f 'run-tests.sh'` matches your own shell and answers "yes,
somebody is running one" when nobody is:

```
ps -eo args= | grep -c '^bash \./run-tests\.sh$'
```

## The stale scratch remote in ~/Projects/flowy, and why this section stays

**Fixed mechanically on 2026-08-19**: that remote is now called
`stale-scratch-DO-NOT-FETCH`, so `origin/master` does not resolve at all -
`fatal: Needed a single revision` instead of a checkout. Verified after the
rename.

The section stays because the SEQUENCE is the lesson, not the trap. `origin` in
that checkout was `/tmp/firecode-scratch/flowy`, a scratch clone 227 commits
behind. `git checkout -b work origin/master` there rewrote the shared working
tree to that old state - 355 staged changes, 247 files gone from disk, among
them `scripts/land-guard.sh`, which `.git/hooks/reference-transaction` execs. So
for the four minutes it was missing, EVERY ref update in the repository was
refused, in every worktree, for every agent, with

```
fatal: ref updates aborted by hook
```

which names neither the file nor the directory.

It bit me at 12:22. I wrote this section and a memory the same hour. It bit
orchestrator at 16:40 anyway, as a fresh discovery, and only then did anybody
rename the remote.

**That is the finding, and it generalises past this repo**: a paragraph is not a
mechanism. Three of us quoted rules we had written that day and broke them
within the hour - a container removed by name, a file written without reading
it, a script overwritten with `cp` while a process was reading it. Every one had
a rule already. What worked was making the wrong thing unavailable: a renamed
remote, `mv` instead of `cp`, a recorded id compared before a delete.

If it has bitten twice, stop writing about it and change what is reachable.

Recovery, if some other checkout still has the old name and it happens again -
`git restore` rather than `git reset --hard`, because reset writes a ref and the
hook that would refuse it is the thing that is broken:

```
git restore --source=HEAD --staged --worktree .
```

## When a fix does not appear to work, ask when that process loaded its code

Three long-lived surfaces here load code at different times, and none of them
used to say so:

- **the node** restarts on deploy. It sat 32 commits behind for a night, so
  every fix landed in that window was inert - including the merge lock built to
  stop the collisions that kept happening while it sat there.
- **the spawn server** loads its source ONCE at start. On 2026-08-19 it had been
  up since 17 Aug 10:37 - two days - so a warning written into `chat_say` that
  morning did not exist for any caller.
- **`bin/firecode`** is re-read per invocation, so it is never stale. It is on
  this list because it is the one that makes the other two surprising.

The failure looks like somebody ignoring you. An agent reads the fix in the
file, calls the tool, gets the old behaviour, and has nothing to tell it why -
so the conclusion reached three times in twelve hours was "they are not doing
what I asked", and once it was "the deploy failed".

Ask the process, not the file:

```
curl -sS $FLOWY_ADDR/healthz            # version + uptime_ms
firecode spawn-server                   # refuses, and says since when and whether its source moved
```

And when the answer is "stale", `firecode spawn-server restart` - not
`firecode spawn-server`, which is a refusal, and never `pkill -f`, which matches
the shell running the server as well and leaves the old one holding the port.

## What is already in scripts/, so you do not write it again

This file's own rule, applied to itself: a tool nobody knows about is a tool
nobody uses. Two rescue scripts were written four times over on 2026-08-17
because their authors never said they existed, and three of the entries below
exist only because somebody hand-rolled the same loop four times in one night.

Every one takes `FLOWY_AGENT=<you>` and refuses rather than speaking as the
operator.

```
say.sh          say something in the room; refuses a message over six lines
board-nag.sh    what work is waiting for you; --watch BLOCKS on the node's
                /api/nag/wait until the counts you act on change
q.sh            the board, findings, one row, and what the target is
                (queue and lock are retired - `flowy queue` does both better)
claim-row.sh    win a row or do not spawn: a claim you can lose, and be told
drain.sh --once one landing chain: pick, declare, rebase, pre-gate, gate,
                record, land. One at a time per box, held by a flock
pre-gate.sh     is this gate run worth its 35 minutes. --row <id> asks the node
                the queue's half instead of guessing at it
land.sh         land a gated branch, refusing every way it can be wrong
run-wait.sh     wait for a firecode run and print what it MEASURED, not its exit
busy.sh         is a gate running on this box, asked in the one form that does
                not answer about the asker. --wait blocks until the box is free
bundle.sh       fetch the bundle the node is SERVING and refuse the SPA
                fallback, which answers 200 with html and greps to zero
scratch-node.sh a flowy node of your own in ninety seconds, on a port nothing
                holds, proved by node name. `down` removes only what it started
```

If you add one, put it here in the same breath. If you retire a verb, grep for
it first - this file pointed at `q.sh queue` for hours after that verb started
answering "retired", which is a preamble sending people to a refusal.
