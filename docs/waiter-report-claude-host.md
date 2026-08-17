# The waiter is a workaround for a problem the Stop hook does not have

claude-host, 2026-08-17. Sources: the Claude Code hooks reference at
code.claude.com/docs/en/hooks, and this machine's own hook configuration.

## The finding

**A Stop hook can block for 600 seconds by default, and its stderr on exit 2 is
shown to the agent.** Those two facts together are a complete waiter. We do not
need a background task, a pid file, a fork, a spool, or a re-arm.

Everything we built this week exists to work around a limitation that is not
there.

## What the docs actually say

| | |
|---|---|
| Stop fires | when the agent finishes responding |
| Stop default timeout | **600s** for `command` hooks; only UserPromptSubmit is lowered, to 30s |
| Stop can block | **yes** |
| exit 2 | prevents stopping, **continues the conversation**, and **stderr is shown to the agent** |
| `decision: "block"` + `reason` at exit 0 | also prevents stopping, but the agent NEVER SEES the reason |
| `stop_hook_active` | true while a Stop hook is already running - the documented loop guard |
| SessionStart / UserPromptSubmit stdout | injected into context |
| `hookSpecificOutput.additionalContext` | injects context, capped at 10,000 characters |

Two of those are worth pausing on.

`decision: "block"` looks like the tidy structured way to hold a session open,
and it is the wrong one for us: the reason is internal metadata the agent never
reads. A waiter built on it would keep the session alive and deliver nothing -
which is the exact failure we have been chasing all week wearing different
clothes. **Exit 2 with stderr is the only path where the message reaches the
agent.**

`stop_hook_active` is the loop guard we did not know we had.

## Why our current design keeps failing

The waiter is a background task. A background task **wakes the agent by
completing**. So delivery and continued listening are mutually exclusive: the
moment it delivers, the room is unheard until somebody arms another one. That
somebody is the agent, and the agent is mid-task.

Everything else follows from that one property:

- fork a successor so the room stays covered - but a detached successor is not
  a harness task, so it hears everything and can wake nobody
- so mark waiters tracked vs forked, and let tracked beat forked
- so a pid file, and a claim, and a release, and a trap
- so a spool, because exit 0 is not delivery if nobody reads the output

Six mechanisms, each correct, each fixing a hole made by the last one. The user
has counted the failures out loud roughly a dozen times today, and the most
recent was twenty minutes ago: "no waiter again lol".

The Stop hook has none of that shape. It is called BECAUSE the agent is about to
go idle - exactly when we want to listen - and refusing is how it speaks.

## The proposal

```
Stop hook:
  if stop_hook_active is true -> exit 0          # documented loop guard
  poll the room for up to N seconds              # N < 600, say 300
  something arrived  -> print it on stderr, exit 2   # delivered AND still alive
  nothing arrived    -> exit 0                       # go idle honestly
```

What this deletes: the pid file, the tracked/forked distinction, the handover
fork, the spool, the release trap, and every "re-arm the watcher" message in
this room.

What it costs: an idle turn ends up to N seconds later. For an unattended agent
that is the entire point. For somebody sitting at the terminal it is a delay, so
N should be small when a human is attached and large when one is not.

## What I have NOT verified

- Whether a 300s block in Stop feels acceptable at an interactive terminal. It
  needs one person to try it and say.
- Whether the harness shows the user anything while a Stop hook blocks, or
  whether the session simply looks hung. **This decides the design** - if it
  looks hung, N has to be short and the long block belongs only to headless
  runs.
- Whether repeated exit-2 continuations accumulate context in a way that matters
  over hours.

Those are three experiments, not three opinions, and I would rather we ran them
than argued about them.

## Two things we already know, that the docs confirm

Our Stop hook ALREADY blocks up to 600s: this machine's hook configuration sets
no timeout on it, so it has the default. We have had the capability the whole
time and used it only to print a nag.

And the same hook is where the "answer before you stop" rule lives. It works: it
caught an unanswered message for me twice today. The waiter should live in the
same place, for the same reason - **a Stop hook is the one moment the harness
gives us where the agent is not busy and is still alive.**
