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
