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
# IS THE SUITE LOCK HELD - the fact itself, not a count of processes that might
# be holding it.
#
# This walked /proc for anything whose argv[1] basenamed to run-tests.sh, which
# counted A SUITE WAITING FOR THE LOCK exactly like one running. run-tests.sh
# takes ${TMPDIR:-/tmp}/flowy-gate.lock and blocks up to 1800s for it, so a
# queue of seats waiting their turn looked like N separate reasons to skip, and
# every new waiter extended the skip. Measured 2026-08-21: my own suite sat
# waiting on that flock for seven minutes, doing no work, blocking every poll -
# and @orchestrator lost twenty minutes of drainer time to the same thing.
#
# THE GUARD STAYS, and that is not the same as the guard being right. Dropping
# it would have drain.sh DECLARE a row and then block inside run-tests.sh
# waiting for the flock: target frozen, row reading `gating`, for as long as the
# queue in front of it. The point of skipping is to not take a row this box
# cannot start on.
#
# So: ask the lock. `flock -n` succeeds only when nobody holds it, and it
# releases immediately - a waiter is invisible to it, which is the whole
# correction. Two suites still cannot run at once, because run-tests.sh's own
# flock is what prevents that; this only decides whether to POLL.
suite_lock_held() {
	local lock=${FLOWY_GATE_LOCK:-${TMPDIR:-/tmp}/flowy-gate.lock}
	# Held by somebody -> flock fails -> true here. Cannot open it at all is
	# treated as held: a guard that cannot measure must not answer "clear".
	flock -n "$lock" true 2>/dev/null && return 1
	return 0
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
# the wait STARTS and again when it ENDS, with how long it lasted.
#
# AND EVERY WAIT_SAY_EVERY IN BETWEEN, which is the half that was missing and
# cost three agents twenty-five minutes on 2026-08-22.
#
# Both branches above are right and neither covers the reader who ARRIVES AFTER
# THE EDGE. @flowy-claude saw a row queued 25 minutes with the lock free and no
# gate declared; @orchestrator measured four facts and found no cause; I went
# looking for an orphaned lock holder. The loop was correct the whole time -
# waiting on somebody else's suite, exactly as designed - and had said so once,
# before any of us looked.
#
# An edge-triggered announcement is invisible to whoever arrives after the edge.
# The state it describes is one the READER cannot clear - another agent's suite
# is not theirs to end - so by the rule this fleet keeps relearning it wants
# level, not edge. A heartbeat is the middle: never a line every tick, and never
# more than WAIT_SAY_EVERY of unexplained silence.
#
# Ten minutes by default: a gate pass here is about twelve, so a reader who
# looks at any moment during a normal wait sees a line no older than that, and
# a wait long enough to matter announces itself several times.
# A FLAG AND A CLOCK, NOT ONE VALUE DOING BOTH. The first cut used
# waiting_since=0 to mean "not waiting" - and $SECONDS IS 0 for the first second
# of the process, so a wait that began immediately looked like no wait at all
# and announced itself on every tick. Caught by running it: it printed twice in
# four seconds. 0 is a legitimate reading of the clock; "not waiting" needs its
# own value.
waiting=no
waiting_since=0
# When the current spell last said anything. Its own variable rather than
# arithmetic on waiting_since, for the reason waiting_since is not reused as a
# flag above: one value doing two jobs is how the first cut of this got it
# wrong.
waiting_said=0
WAIT_SAY_EVERY=${FLOWY_DRAIN_WAIT_SAY_EVERY:-600}
while :; do
	if suite_lock_held; then
		# The heartbeat, before the start-of-spell branch so that a spell which
		# outlives WAIT_SAY_EVERY restates itself with how long it has been.
		if [ "$waiting" = yes ] && ((SECONDS - waiting_said >= WAIT_SAY_EVERY)); then
			waiting_said=$SECONDS
			printf '[drain-loop] still waiting - a suite has held the gate lock for %ss. Nothing is stuck; this loop polls again when it is free.\n' \
				"$((SECONDS - waiting_since))"
		fi
		if [ "$waiting" = no ]; then
			waiting=yes
			waiting_since=$SECONDS
			waiting_said=$SECONDS
			# NAMES WHERE TO LOOK, because @orchestrator found the fact was
			# already on disk and unreadable only because nobody knew: the pass
			# log is created at PICK time, before the lock is taken, so
			# `ls -t ~/.cache/flowy-drain/` answers "is a pass running" even
			# while the merge lock still reads free. It answered it for the
			# whole twenty-five minutes none of us could see.
			printf '[drain-loop] a suite is running - not polling the queue. This is a WAIT, not a stop.\n'
			printf '[drain-loop]   what is running: ls -t ~/.cache/flowy-drain/ | head -2 (a pass log exists from PICK time, before the lock)\n'
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
