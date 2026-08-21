#!/usr/bin/env bash
# The room listener as a FILE, so the thing that wakes an agent can be linted,
# corrected and found by somebody other than its author.
#
# WHY THIS EXISTS. Every seat's listener is an inline shell loop typed into a
# Monitor, and one of them dropped the thread id for a whole night:
#
#   flowy inbox --as NAME --deadline 240 \
#     | jq -R -r 'fromjson? | "\(.meta.actor_name): \(.body)"'
#
# `flowy inbox` prints the WHOLE event as one line of JSON - thread included -
# and that jq keeps two fields and throws the rest away. So a threaded question
# reached the agent as bare words, the agent answered in the room, and it read
# as an agent ignoring the thread rather than never having been told which one.
# The operator noticed within a day of threads landing: 01M0HH6ANG.
#
# It is the same defect as the drain driver's, one surface over: a loop nobody
# can lint, started by a session that has ended, wrong in a way only the person
# who typed it could see. That one took two days to fix because it had no name
# on disk. This one has one.
#
# THE LINE CARRIES ITS ADDRESS. Author, room, thread, then the body - so an
# agent woken by this can reply where it was asked without a second lookup:
#
#   claude-host [general 01M0HHCFME4V7HAP2Y3CCXA0V1]: @deadtrickster ...
#
# "-" for a message with no thread, rather than an empty field that would shift
# every column after it.
set -uo pipefail

NAME=${FLOWY_AGENT:-}
[ -n "$NAME" ] || {
	printf 'room-listen-loop: set FLOWY_AGENT - a listener with no name cannot ask for its own mail\n' >&2
	exit 2
}
ADDR=${FLOWY_ADDR:-http://192.168.1.55:8787}
BIN=${FLOWY_BIN:-$HOME/Projects/flowy-dogfood/flowy}
TOKFILE=${FLOWY_TOKFILE:-$HOME/.config/flowy/agents/$NAME}
DEADLINE=${FLOWY_LISTEN_DEADLINE:-240}
BODY=${FLOWY_LISTEN_BODY:-400}

[ -r "$TOKFILE" ] || {
	printf 'room-listen-loop: no token for %s at %s\n' "$NAME" "$TOKFILE" >&2
	exit 2
}
FLOWY_TOKEN=$(cat "$TOKFILE")
export FLOWY_TOKEN

# ONE INVOCATION PER MESSAGE, and the loop is what re-arms it. `flowy inbox`
# delivers one and exits, so something has to ask again - and when that
# something is an agent's memory, it is forgotten. See the header of
# flowy-dogfood/flowy-listen-loop.sh, which learned this first.
while :; do
	"$BIN" inbox --as "$NAME" --url "$ADDR" --deadline "$DEADLINE" 2>/dev/null |
		jq -R -r --unbuffered --argjson n "$BODY" '
			fromjson?
			| "\(.meta.actor_name // "?") [\(.room // "-") \(.thread // "-")]: "
			  + ((.body // "") | gsub("\n"; " ") | .[0:$n])
		' || true
	rc=${PIPESTATUS[0]}
	# 0 delivered, 1 the deadline passed quietly. Anything else is the listener
	# failing to listen, which must not look like a quiet room.
	case $rc in
	0 | 1) : ;;
	2)
		printf 'LISTENER REFUSED (exit 2): another waiter holds the reader for %s\n' "$NAME"
		sleep 30
		;;
	*)
		printf 'LISTENER ERROR (exit %s) - backing off 30s\n' "$rc"
		sleep 30
		;;
	esac
	sleep 3
done
