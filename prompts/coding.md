# Template: build something, with a gate

For handing a whole job to a VM and getting back something you can use without
reading it first. The shape that matters is the last paragraph: a script the
*harness* runs decides whether the work counts, so "done" is not the agent's
opinion.

```sh
firecode claude \
  --deliver ~/Projects/{{NAME}} \
  --verify './run-tests.sh' --verify-timeout 600 \
  --timeout 10800 \
  -- -p "$(cat task.md)" --dangerously-skip-permissions
```

## task.md

> {{WHAT TO BUILD - be concrete about the subset. Name the specs and expect
> them to be read: "RFC 1459 and RFC 2812", "the CUDA programming guide", "the
> index access method chapter". Name the constraints that are real ones -
> which libraries are allowed, which language version, what may not be pulled
> in - and leave the rest of the design to it.}}
>
> {{WHAT IT MUST NOT DO, if anything. "No quicklisp." "Do not wrap btree."
> "Only sb-bsd-sockets and sb-thread from SBCL itself." One line each, and
> only for constraints you would actually reject the work over.}}
>
> Provide an executable `run-tests.sh` at the project root. It must start a
> fresh {{RUNTIME}}, load the system from the delivered files, {{DO THE THING
> THAT PROVES IT WORKS - start the server and have two clients exchange a
> message; build the extension, load real data and check the rows match; run
> the benchmark and assert the result}}. It exits 0 only if that actually
> happened. This script is what decides whether the work counts - run it
> yourself until it passes.
>
> Leave a README explaining what is implemented and what is not. Be specific
> about the parts you could not make work: that is the most useful thing in
> it.

## Why it is shaped like that

**The gate is a script, not a sentence.** `--verify` runs it inside the VM
after the agent has exited, in the project directory as it will be handed
over, and its exit status becomes the run's. The agent is told the command up
front, so it can aim at it.

**Saying it in the prompt does not arm it.** The prompt is prose for the
agent; `--verify` is a command for the harness. They are separate domains and
neither stands in for the other. A run whose prompt opened with "I run
./run-tests.sh after you exit and its exit status decides this run" - and
which was started without `--verify` - reported success on a script that was
not in the delivered tree. Put it in both places: in the flag so it is
enforced, in the prompt so the work aims at it.

**The gate must load from the delivered files.** That is the whole point. Two
runs in one evening reported success on work that could not be loaded at all -
one shipped an `.asd` naming files that were not there, the other a README
ending in `RESULTS_PLACEHOLDER` over an empty results file. Both had a "test".
Neither test loaded the project from scratch.

**Ask for the failures in the README.** An agent that has been told to write
down what does not work will usually tell you, and the list is worth more than
the prose above it.

**Numbers, if the task has any, need a denominator and a spread.** "Min of at
least 5 runs, report the min and the spread, and name what you compared
against" turns a benchmark from a claim into a measurement. Add it when the
task is about performance, leave it out when it is not.
