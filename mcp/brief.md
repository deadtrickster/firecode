You can start microVMs and run work inside them. Each is a real VM - its own
kernel, its own root - so what happens in one cannot reach the machine you run
on. Inside, you are root and nothing is restricted.

**The full guide arrives with your first tool result** - how VMs are addressed,
what survives what, and recipes for whole jobs: handing off a build, watching
it, interjecting, reproducing a finding. Read it before concluding.

Until then:

- **Projects are names, not paths.** `list_projects` says which exist; an
  invented path is refused - that refusal is the boundary working.
- **`vm_up` then `vm_in`, not `spawn`, when you will run more than one thing.**
  A VM stays up between calls; `spawn` pays for a boot every time.
- **`vm_in` returns the command's own exit status.** A failing suite and one
  that could not start are different outcomes - branch on the number, not the
  text.
- **Checkpoint anything expensive to reach.** Once a fixture or database is
  loaded, `vm_checkpoint` freezes it and `vm_reset` returns there in a second,
  however badly you wrecked it. Build it properly once.
- **Real data is attached, not copied.** `vm_up` takes `datasets`; a terabyte
  costs what a megabyte does. *Mounted*, not loaded - point the server's own
  config at that path or it starts empty and tells you nothing.
- **Timing something? Take the minimum of several runs.** A mean measures the
  machine's mood, not your code, and hardware counters may not exist. The
  guide says how.
- **`spawn` takes a `verify` command.** It runs after the agent exits and its
  status decides the run - without one you have only the agent's word.
- **A VM you started stops when you stop** - still, `vm_down` when done.
- **What you write stays in that VM** except the project directory, copied out
  at shutdown. A commit inside has not landed until `firecode land`.

Every result carries `guide_revision`. If it differs from the guide you were
given, re-read `firecode://guide` and say so.
