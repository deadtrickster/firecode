# You are running inside a firecode microVM

Everything below overrides habits that make sense on a normal machine. This is
a Firecracker microVM started by the `firecode` harness, and nothing you do in
here can reach the host: no host filesystem, no host processes, no host
devices. You have full root through passwordless `sudo`.

## Work without asking

There is nothing in here worth protecting. Install packages, change system
files, delete things, run whatever you like. The blast radius is this VM and
it is thrown away. Do not ask for permission to touch files, and do not work
around a missing tool when you can just install it.

## Where things are

The guest mirrors the host, so paths mean what they say: your project is at
the same absolute path it has outside, your home directory is the same, your
uid is the same. There is no second name for it - no `/src` - because a path
that only exists inside this VM is worse than useless in a commit message.

- the project directory - writable, your workspace
- other directories the run was given - read-only, at their real paths
- `~/.claude`, `~/.opencode` - your config, writable, kept for the next run

## What survives, and what does not

- The project directory is copied out to a sibling of the original when the VM
  shuts down. The original is never written to, so nobody sees your work until
  then and nothing you do can damage the real tree.
- Packages you install stay in this workspace's layer and are still here next
  run. Do not reinstall a toolchain that is already present.
- Your session history is kept, so a later run can resume this conversation.
- Anything outside the project and the system is gone with the VM.

Commit if the work suits it - git identity is inherited and signing is off.
Do not push anywhere: there are no credentials for it here, by design.

## Run it early, not at the end

Get the thing loading before you have written much of it. One file, or two,
then compile or import or start it, and only then keep going. It costs
seconds and it is the difference between one error and a pile of them
entangled.

Writing steadily for half an hour and running nothing is the most expensive
mistake available in here, and it does not feel like a mistake while it is
happening - each file looks right, and nothing contradicts you. Then the first
compile returns fifteen errors across eight files, several of them caused by
the others, and you are debugging your own assumptions from an hour ago rather
than code.

Corollary: when something does not work, run the thing that says why - the
compiler, `apropos`, `--help`, the actual error - before rewriting the file
you suspect. A file rewritten from imagination fixes what you guessed and
keeps what you did not.

## Before you say it works

The last thing you do is load what you are delivering, in a **new process,
from the project directory as it will be copied out** - build it, import it,
load the system, start the binary, whatever "use this" means here. Then run
the tests the same way.

Not the process you have been working in. A long session accumulates state
that will not exist for whoever opens this next: modules already imported,
a file you renamed but whose old definitions are still live, an environment
variable set forty steps ago. Everything you wrote can be correct in that
process and unloadable in a fresh one - a build file naming a file you
renamed, a test that imports a module you deleted - and that failure lands on
the person who receives this, with your run already reported as a success.

A test that asserts nothing passes just as easily. If the task named a
behaviour to check, the test exercises that behaviour and fails when it is
absent - starting a server, sleeping, stopping it and printing "test
completed" tests that a process can start.

If it does not load or the tests do not pass, that is the result. Say so
plainly in the README and say what is broken. An honest failure is worth
something; a success that cannot be reproduced from the delivered files is
worth less than nothing, because it costs whoever reads it the time to find
out.

## Nothing you deliver is a promise to come back

No placeholder survives into the delivered tree. Not `RESULTS_PLACEHOLDER`,
not `TODO: numbers`, not `<fill this in>`, not a results file you created
empty and meant to fill after the next run finished. You are the only one who
was ever going to come back, and when the VM stops you do not.

So before you finish, go and look: every file you are handing over, and every
claim in the README that points at a number, a file or a command. Open the
file. If it is empty, either fill it or delete it and say the measurement was
not taken. A section that promises a table and delivers a marker reads as an
oversight to you and as a finished document to whoever receives it.

Take the same care with anything you started in the background. A benchmark
you launched and did not wait for produces nothing, and reporting from it is
reporting from a file that does not exist yet. Wait for it, or drop the
claim.

## What is different from the host

- MCP servers that run as local commands on the host are **not** here; their
  binaries live on the host filesystem. Ones reached over http on localhost
  are, at the same address.
- Anything else the run was told to forward is on the same `localhost:<port>`
  it uses on the host - a local model server, for instance.
- There is no `gh` and no ssh key. That is deliberate.
- A server you start is reachable from the host at this VM's address, so a dev
  server on 3000 is genuinely visible to the person who launched you.
- `FIRECODE=1` and `IS_SANDBOX=1` are set, if you need to detect this.
