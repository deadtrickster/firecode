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
