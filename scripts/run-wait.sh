#!/usr/bin/env bash
# Wait for a firecode run to finish, then print what it actually measured.
#
# Two things this exists to stop, both of which cost real time on 2026-08-18.
#
# ONLY COUNT ABSENCE AFTER PRESENCE. A waiter that starts by asking "are any
# processes left" answers "no" during the boot window and reports a run
# finished before it started. So this waits to SEE the run alive, and only then
# waits for it to go. Two loops, in that order. If it never appears within the
# presence timeout it says so rather than claiming the run ended.
#
# AN EXIT STATUS IS NOT A VERDICT. Agents launch gates as
# `bash -c './run-tests.sh 2>&1 | tail -20'`, and a pipeline exits with its
# LAST stage's status - tail's, which is always 0. One run recorded
# `passed: 624 failed: 2` alongside `exit-status: 0`. So this prints the
# suite's own summary line as the verdict and prints the exit status beside it,
# labelled, rather than letting one be mistaken for the other.
#
# usage: run-wait.sh <run-id|run-dir> [--presence-timeout SECONDS]
#        exit 0 the run finished, 3 it never appeared, 2 bad usage
set -euo pipefail

RUNS=${FIRECODE_RUNS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/runs}
presence_timeout=120
run=

while (($#)); do
	case $1 in
	--presence-timeout)
		presence_timeout=${2:?--presence-timeout needs a value}
		shift 2
		;;
	-h | --help)
		sed -n '2,20p' "${BASH_SOURCE[0]}"
		exit 0
		;;
	*)
		run=$1
		shift
		;;
	esac
done

[[ -n $run ]] || {
	echo "run-wait: which run? give a run id or a run directory" >&2
	exit 2
}

# A run id or a path, so it can be handed either the name from `firecode
# status` or a directory straight off the disk.
rundir=$run
[[ -d $rundir ]] || rundir=$RUNS/$run
[[ -d $rundir ]] || {
	echo "run-wait: no such run: $run" >&2
	exit 2
}

cg=$(cat "$rundir/cgroup" 2>/dev/null || true)
[[ -n $cg ]] || {
	echo "run-wait: $run has no cgroup file, so it never started" >&2
	exit 3
}

# cgroup.procs is a kernel pseudo-file: it reports st_size 0 even when it lists
# processes, so it has to be READ rather than tested with -s. The children are
# one level down - firecode makes vm/ and relays/ under the run's own cgroup -
# and the glob is quoted so a cgroup that has not been populated yet fails to
# match rather than erroring out under `set -e`.
procs() {
	cat "$cg/cgroup.procs" "$cg"/*/cgroup.procs 2>/dev/null || true
}

alive() {
	local p
	p=$(procs)
	[[ -n ${p//[[:space:]]/} ]]
}

# A run that already left a completion marker HAS finished, and asking its
# cgroup would only ever say "empty", which is the boot window's answer too.
# So the marker is checked first: it is the fact, where process absence is a
# proxy that reads identically before the start and after the end.
finished() {
	# `result` is a FILE naming the copy-out directory, not the directory - I
	# wrote -d and it was wrong, so a finished run fell through to the presence
	# loop and reported "never showed a process". A completion marker tested the
	# wrong way is not a marker at all.
	[[ -f $rundir/exit-status || -s $rundir/result || -d $rundir/workdir ]]
}

# 1. presence. An empty cgroup here is a boot window, not a finish.
waited=0
until finished || alive; do
	if ((waited >= presence_timeout)); then
		echo "run-wait: $run never showed a process in ${presence_timeout}s - not saying it finished" >&2
		exit 3
	fi
	sleep 2
	waited=$((waited + 2))
done

# 2. absence. Now an empty cgroup means what it looks like.
while ! finished && alive; do
	sleep 10
done

verdict=$(grep -ao 'passed: [0-9]* failed: [0-9]*' "$rundir/console.log" 2>/dev/null | tail -1 || true)
status=$(cat "$rundir/exit-status" 2>/dev/null || true)
cmd=$(grep -ao 'running as dead in [^:]*: .*' "$rundir/console.log" 2>/dev/null | head -1 || true)

echo "run:      $(basename "$rundir")"
echo "project:  $(cat "$rundir/name" 2>/dev/null || echo '-')"
echo "verdict:  ${verdict:-none - the suite printed no summary line}"
echo "exit:     ${status:-none} (NOT the verdict if the command was piped)"

# The warning belongs here rather than in the reader's head: the exit status is
# the field somebody reaches for, and it is the one that lies.
if [[ $cmd == *"|"* ]]; then
	echo "note:     the command contains a pipeline, so 'exit' above is its LAST"
	echo "          stage's status. Believe 'verdict', not 'exit'."
fi
