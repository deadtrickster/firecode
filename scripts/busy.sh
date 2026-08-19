#!/usr/bin/env bash
# Is a gate running on this box - asked in the one form that does not answer
# about the asker.
#
#   scripts/busy.sh              exit 0 and print the pids if a suite is running
#   scripts/busy.sh --wait [s]   block until none is, or give up after s (default 3600)
#
# WHY THIS EXISTS. I wrote this wait by hand four times on 2026-08-18, and got
# it wrong twice in the same way: the pattern matched the shell that was doing
# the asking, so the count never reached zero and the wait could not end. It
# looks like a busy machine and it is a busy grep.
#
# The gate stands up its own Postgres and its own node and picks ports by asking
# what is free AT THAT INSTANT, so two suites on one box race for the same port
# and the loser talks to the winner's node - red when it is refused, and GREEN
# when the borrowed node happens to answer the way it expected. That is what
# makes "is anything running" worth a script rather than a habit.
#
# THE ANCHOR IS THE WHOLE POINT. `pgrep -f run-tests.sh` matches this file, the
# editor that has it open, and the shell that typed the command. The argv form
# `^bash \./run-tests\.sh$` matches a suite and nothing else - and the caller's
# own pid is dropped as well, so a suite asking whether a suite is running gets
# an answer about the OTHERS.
set -uo pipefail

DEADLINE=3600
wait=no
case "${1:-}" in
--wait)
	wait=yes
	[ $# -ge 2 ] && DEADLINE=$2
	;;
"") ;;
*)
	printf 'usage: busy.sh [--wait [seconds]]\n' >&2
	exit 2
	;;
esac

# The argv a suite runs as. Overridable ONLY so that both paths of this script
# can be seen to work on a box where a real gate happens to be running - the
# free path is unreachable otherwise, and a waiter nobody has watched return is
# a waiter nobody should arm.
SUITE_ARGV=${FIRECODE_SUITE_ARGV:-bash ./run-tests.sh}

# ps once, filtered here, so the pid and the argv come from the same reading.
# Two ps calls would let a suite start between them and be counted by one.
suites() {
	ps -eo pid=,args= 2>/dev/null |
		awk -v me="$$" -v parent="$PPID" -v want="$SUITE_ARGV" '
			{ pid = $1; $1 = ""; sub(/^ /, "") }
			$0 == want && pid != me && pid != parent { print pid }
		'
}

if [ "$wait" = no ]; then
	found=$(suites)
	if [ -n "$found" ]; then
		printf 'busy: %s\n' "$(printf '%s' "$found" | tr '\n' ' ')"
		exit 0
	fi
	printf 'free\n'
	exit 1
fi

waited=0
while :; do
	found=$(suites)
	[ -z "$found" ] && {
		printf 'free after %ss\n' "$waited"
		exit 0
	}
	# SAY WHAT IS HOLDING IT, once a minute rather than never. A wait that
	# prints nothing for an hour is indistinguishable from a wait that hung,
	# and the second one is the one somebody needs to know about.
	((waited % 60 == 0)) && printf 'waiting on %s (%ss)\n' \
		"$(printf '%s' "$found" | tr '\n' ' ')" "$waited" >&2
	((waited >= DEADLINE)) && {
		printf 'busy: still running after %ss - %s\n' "$waited" \
			"$(printf '%s' "$found" | tr '\n' ' ')" >&2
		exit 1
	}
	sleep 5
	waited=$((waited + 5))
done
