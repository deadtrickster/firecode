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
# Where this repo is, so the waiter pid file lands where the chat hook looks.
# Resolved from THIS script rather than a caller's cwd: the loop is started by a
# Monitor whose working directory is not guaranteed to be the checkout.
FIRECODE_ROOT=${FIRECODE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}

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

# SAY THAT THIS SEAT IS LISTENING, in the file the chat hook reads as proof.
#
# runs/chat-waiter-<name>.pid, "<pid> <kind>", which is what waiter_pid_for in
# chat-hook.sh opens and kill -0's. The other two seats' waiters write it; this
# loop did not, and that silence had a cost the moment the hook started
# INSISTING on proof: d6d1a77 stopped an unproved name being polled, and this
# listener - running the whole time - could not prove it was mine. The hook then
# correctly refused to read my inbox and told me so.
#
# THE GUARD WAS RIGHT AND THE LISTENER WAS RUDE. A waiter that does not announce
# itself is indistinguishable from one that is not there, and every part of this
# fleet that asks "is anybody hearing this room" - the nag, the hook, the
# listening pane - is asking a question this file can answer for free.
#
# The LOOP's pid rather than the poll's: `flowy inbox` exits and is replaced
# every deadline, so its pid is a fact with a 240-second life. The loop is what
# is actually listening, for as long as this seat is up.
#
# "tracked" because that is what this is - a supervised loop, not a fork a
# delivery left behind. See WaiterTracked in internal/store/inbox.go.
WAITER_PID_FILE=${FLOWY_WAITER_PID_FILE:-$FIRECODE_ROOT/runs/chat-waiter-$NAME.pid}
mkdir -p "$(dirname "$WAITER_PID_FILE")" 2>/dev/null || true
printf '%s tracked\n' "$$" >"$WAITER_PID_FILE.tmp" 2>/dev/null &&
	mv -f "$WAITER_PID_FILE.tmp" "$WAITER_PID_FILE" 2>/dev/null || true
# AND TAKE IT BACK ON THE WAY OUT, so a stopped listener does not keep vouching
# for itself. kill -0 on a dead pid already fails, so this is tidiness rather
# than correctness - but a stale file that happens to name a REUSED pid would
# vouch for a stranger.
trap 'rm -f "$WAITER_PID_FILE" 2>/dev/null' EXIT

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
