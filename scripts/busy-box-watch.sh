#!/usr/bin/env bash
# SAY WHEN THE BOX STOPS BEING QUIET, because that is when two dormant defects
# wake up and neither announces itself.
#
# drain.sh records `busiest_other_suites` on every pass - the highest number of
# OTHER suite roots seen while it ran (b0cb320). It has been 0 since it landed,
# and two things depend on that staying true:
#
#   the stale drain-loop   the running loop holds a deleted inode and still has
#                          suite_running() rather than suite_lock_held(). The old
#                          one counts a suite WAITING for the gate lock like one
#                          running, so waiters make the drainer skip polls. With
#                          no other suites there are no waiters, so it costs
#                          nothing - until there are.
#   the related-rows flake  fired ~30% in an hour with three suites on the box
#                          and ~2% overall. Its fix landed (b5be6e4) and the
#                          honest test of it is a busy pass, which nobody can
#                          arrange and nobody should.
#
# So this watches for the condition rather than asking anybody to remember it.
#
# ONCE PER PASS, NOT ONCE PER POLL. The status file is rewritten by every pass;
# the gate_run in it is the identity of the pass, so a run already reported is
# not reported again. A watcher that repeats itself every minute is one people
# turn off - which is the whole lesson of the nag it sits beside.
set -uo pipefail

STATUS=${FLOWY_DRAIN_STATUS:-$HOME/.cache/flowy-drain/status.json}
EVERY=${BUSY_WATCH_EVERY:-60}
seen=""

# HOW LONG BLINDNESS MAY LAST BEFORE IT IS SAID OUT LOUD.
#
# The first version skipped an unreadable status and printed nothing, with a
# comment claiming that "a file that cannot be read is not a quiet box". The
# comment was right and the OUTPUT WAS NOT: unreadable and zero produced the
# same silence, so a reader watching this could not tell a quiet box from a
# watcher that had been blind since somebody renamed the file. Caught by
# @flowy-claude within minutes of it being armed - the guard was in the code and
# not at the wire, which is where a reader stands.
#
# Not on the first miss: the drainer rewrites the status file, and a poll that
# lands mid-write reads nothing through no fault of anybody's. Five minutes of
# it is a different claim.
BLIND_AFTER=${BUSY_WATCH_BLIND_AFTER:-300}
blind_since=0
blind_said=0

while :; do
	# A FILE THAT CANNOT BE READ IS NOT A QUIET BOX. Silence here would mean the
	# same as "0 other suites", and those are different facts - so an unreadable
	# or unparsable status is skipped rather than reported as calm.
	if [ -r "$STATUS" ] && busy=$(jq -er '.busiest_other_suites // empty' "$STATUS" 2>/dev/null); then
		# READABLE AGAIN IS NEWS TOO, if the blindness was ever reported - a
		# reader told the watcher went blind needs telling when it can see.
		if ((blind_said)); then
			printf 'the drain status is readable again after %ss - what follows is about the box once more.\n' \
				"$(($(date +%s) - blind_since))"
		fi
		blind_since=0
		blind_said=0
		run=$(jq -r '.gate_run // .at // ""' "$STATUS" 2>/dev/null)
		if [[ $busy =~ ^[0-9]+$ ]] && ((busy > 0)) && [ "$run" != "$seen" ]; then
			seen=$run
			printf 'THE BOX IS NOT QUIET: a drain pass saw %s other suite(s) running.\n' "$busy"
			printf '  row %s, outcome %s\n' \
				"$(jq -r '(.row // "?")[0:10]' "$STATUS" 2>/dev/null)" \
				"$(jq -r '.outcome // "?"' "$STATUS" 2>/dev/null)"
			printf '  Two things were parked on this staying 0:\n'
			printf '  - the stale drain-loop (deleted inode, still suite_running) now costs polls\n'
			printf '  - this pass is a countable trial for the related-rows flake fix\n'
		fi
	else
		# SILENCE FROM HERE MUST NOT READ AS CALM. Said once, when it has gone on
		# long enough to be a fact rather than a mid-write read.
		((blind_since)) || blind_since=$(date +%s)
		if ((blind_said == 0)) && (($(date +%s) - blind_since >= BLIND_AFTER)); then
			blind_said=1
			printf 'THIS WATCHER IS BLIND, and has been for %ss: %s cannot be read or does not parse.\n' \
				"$(($(date +%s) - blind_since))" "$STATUS"
			printf '  Everything it has not said since then is about the FILE, not about the box.\n'
			printf '  Point it with FLOWY_DRAIN_STATUS, or check the drainer is writing at all.\n'
		fi
	fi
	sleep "$EVERY"
done
