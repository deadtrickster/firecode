#!/usr/bin/env bash
# The loop that keeps a drainer running, as a FILE rather than as a shell
# one-liner nobody can lint.
#
# 01M0ER2FHP. The loops driving drain.sh were started as `bash -c 'while :; ...'`
# in sessions that have since ended, and they guarded themselves with
#
#   ps -eo args= | grep -c '^bash \./run-tests\.sh$'
#
# which matches nothing. Measured 2026-08-20 mid-gate: the guard answered 0
# while five suite processes were running, because the suite's argv is
# `bash /home/dead/Projects/wt-drain/run-tests.sh` - absolute, not the relative
# form the pattern anchors on.
#
# WHAT THE DEAD GUARD DID NOT CAUSE, first, because it changes what this is for:
# two suites did not run. The per-machine flock inside drain.sh is what prevents
# that and it works - a second pass exits 3 saying so. What the guard is for is
# the case the flock cannot see: a suite somebody started BY HAND, in a worktree,
# outside the drainer entirely. Two of those on one box fight over ports and
# postgres clusters.
#
# So the guard stays, and it lives here where shellcheck reads it and a fixture
# can prove it fires.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EVERY=${FLOWY_DRAIN_EVERY:-90}
AGENT=${FLOWY_AGENT:-}
[ -n "$AGENT" ] || {
	printf 'drain-loop: set FLOWY_AGENT - a pass with no name files its rows as the operator\n' >&2
	exit 2
}

# A SUITE IS argv[1] ENDING IN run-tests.sh, WHOEVER STARTED IT.
#
# Read from /proc rather than from `ps | grep`, for two reasons measured tonight.
# A grep of the process table matches ITS OWN command line - twice this session
# I read a count of 1 that was the question rather than the answer - and the
# path form varies: relative when a shell runs it, absolute when .flowy-gate
# execs it. The basename of argv[1] is the same either way and cannot match this
# script.
suite_running() {
	local d cmd
	for d in /proc/[0-9]*; do
		[ "$d" = "/proc/$$" ] && continue
		# The redirect is inside the group so a process that exits between the
		# glob and the read is silent, rather than a line of noise per tick: a
		# loop that prints an error every 90 seconds is a loop people stop
		# reading.
		cmd=$({ tr '\0' '\n' <"$d/cmdline" | sed -n 2p; } 2>/dev/null)
		[ -n "$cmd" ] || continue
		[ "${cmd##*/}" = "run-tests.sh" ] || continue
		return 0
	done
	return 1
}

# NOT `while true; do ... done &` FROM A PROMPT. This exists so the loop has a
# name on disk: an orphaned one-liner cannot be read, linted, corrected or found
# by anybody but its author, and the four that are running were started by
# sessions that have ended.
# WAITING IS SAID OUT LOUD, ONCE PER SPELL. A driver that skips silently is
# indistinguishable from a driver that has stopped, and on 2026-08-21 that cost
# @orchestrator ten minutes of diagnosis: six rows ungated, nothing in
# driver.log since a red, and no way from outside to tell "held by a suite"
# from "dead". The whole night was that shape - a silence read as absence.
#
# ONCE, not every tick: a line every 90 seconds for an hour is a log nobody
# reads, which is the same failure wearing the other coat. So it speaks when
# the wait STARTS and again when it ENDS, with how long it lasted, and says
# nothing in between.
# A FLAG AND A CLOCK, NOT ONE VALUE DOING BOTH. The first cut used
# waiting_since=0 to mean "not waiting" - and $SECONDS IS 0 for the first second
# of the process, so a wait that began immediately looked like no wait at all
# and announced itself on every tick. Caught by running it: it printed twice in
# four seconds. 0 is a legitimate reading of the clock; "not waiting" needs its
# own value.
waiting=no
waiting_since=0
while :; do
	if suite_running; then
		if [ "$waiting" = no ]; then
			waiting=yes
			waiting_since=$SECONDS
			printf '[drain-loop] a suite is running - not polling the queue. This is a WAIT, not a stop.\n'
		fi
		sleep "$EVERY"
		continue
	fi
	if [ "$waiting" = yes ]; then
		printf '[drain-loop] the box is free after %ss - polling again\n' \
			"$((SECONDS - waiting_since))"
		waiting=no
	fi
	# drain.sh takes the flock itself and exits 3 when another drainer holds it,
	# so nothing here needs to know about other passes - only about suites.
	(cd "$HERE/.." && FLOWY_AGENT="$AGENT" ./scripts/drain.sh --once --deploy 2>&1 | tail -6)
	sleep "$EVERY"
done
