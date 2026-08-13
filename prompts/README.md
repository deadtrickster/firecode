# Prompt templates

Two things get delegated to a VM often enough to be worth a starting point:
building something, and watching something being built.

- [`coding.md`](coding.md) - a build task with a gate the harness enforces
- [`supervision.md`](supervision.md) - one agent watching another one work

These are starting points, not policy. Copy one, replace the bits in `{{ }}`,
and edit freely - a template that survives contact with your actual task
unchanged is usually a template that was not specific enough.

Neither of them repeats what the harness already tells every agent. The guest
briefing (`guest/firecode-context.md`, delivered as `CLAUDE.md` and
`AGENTS.md`) covers where things are, what survives the VM, that the agent
must load what it delivers in a fresh process, and that no placeholder may
survive into the delivered tree. Say the task, not the standing rules.

## The one thing worth reading before writing your own

**A command a supervisor runs repeatedly has to be complete in its defaults.**

An agent that has to assemble its own polling command writes a different one
every time - `sleep 120`, then a computed deadline, then `--every 150 -n 15`,
each wrapped in its own `cd … && timeout …`. Every variation is a fresh
permission prompt for whoever is approving that agent's commands, and none of
them can be granted once. It makes supervision unusable regardless of how good
the supervisor is.

So the harness offers exactly one command with the defaults already right:

```sh
firecode watch <vm>          # sleeps, says whether it is up, prints the tail
```

and over MCP, `vm_watch`, which does not poll at all - it blocks until the VM
exits, until text you named appears, until the run has been quiet too long, or
until a timeout, then returns with the reason and the tail.

Tell a supervisor to use those verbatim, and say so in the imperative. Left to
itself it will invent something, and what it invents will be unallowable.
