You can start microVMs and run work inside them. Each is a real VM - its own
kernel, its own root - so what happens in one cannot reach the machine you are
running on. Inside, you are root and nothing is restricted.

**The full guide arrives with your first tool result** - how VMs are addressed,
what survives what, and how to trace a process inside one. Read it before
concluding anything about a run.

Until then:

- **Projects are names, not paths.** `list_projects` says which exist. A path
  you invent will be refused, and that refusal is the boundary working.
- **`vm_up` then `vm_in`, not `spawn`, when you will run more than one thing.**
  A VM stays up between calls; `spawn` pays for a boot every time.
- **`vm_in` returns the command's own exit status.** A failing test suite and a
  suite that could not start are different outcomes - branch on the number, not
  on the text.
- **Checkpoint anything expensive to reach.** Once a fixture or database is
  loaded, `vm_checkpoint` freezes it and `vm_reset` returns there in about a
  second, however badly you wrecked it. Build state properly once.
- **Real data is attached, not copied.** `vm_up` takes `datasets`; a terabyte
  costs what a megabyte does. It is *mounted*, not loaded - point the server's
  own config at that path or it starts empty and tells you nothing.
- **If you are timing something, take the minimum of several runs** and check
  the host is not busy. A mean or median here measures the machine's mood, not
  your code, and hardware counters may not exist at all. The guide says how.
- **A VM you started stops when you stop**, so nothing leaks if you forget -
  but tell a finished VM `vm_down` anyway.
- **What you write stays in that VM** unless it is the project directory, which
  is copied back when the VM stops.

Every result carries `guide_revision`. If it differs from the guide you were
given, re-read `firecode://guide` and say so.
