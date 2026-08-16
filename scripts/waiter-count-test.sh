#!/usr/bin/env bash
# Does the hook count WAITERS, or does it count processes?
#
# They are different numbers and the difference is load-bearing in both
# directions. Too few and a session silently leaves the room; too many and
# several waiters share one cursor, whichever polls first advances it, and the
# rest block on a position that moved - messages delivered to a process nobody
# reads, with every check still reporting a healthy room.
#
# Two cases, because a fix has to get both right:
#
#   ONE ARMED WAITER MUST COUNT 1, even though pgrep sees two or three
#   matches: firecode is a bash script that re-execs itself, so a healthy
#   waiter is a parent and a child with identical command lines, and arming it
#   through a harness adds a `bash -c` wrapper carrying the same pattern.
#   Counting matches reports 3 where there is 1 and advises killing two of
#   them, which orphans the child of the one you keep.
#
#   THREE INDEPENDENT WAITERS MUST COUNT 3.
#
# Two traps this test exists to stay out of, both of which produced a
# confident wrong number here first:
#
#   `bash -c 'sleep 20' "some cmdline"` matches NOTHING. Bash optimises a
#   single simple command into a bare exec of sleep and the argv[0] is thrown
#   away. `exec -a` is the form that survives.
#
#   Running the check inline makes pgrep match THE CHECKING SHELL, whose own
#   command line contains the pattern by necessity. Three fakes, count of one,
#   and the one was the test itself. Hence a file.
#
#   usage: scripts/waiter-count-test.sh [real-waiter-name]
set -u

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
HOOK="$ROOT/scripts/chat-hook.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REAL=${1:-claude-host}
rc=0

# The logic under test is lifted out of the hook rather than retyped, so this
# checks what ships instead of a copy that can drift away from it.
counted_for() {
	printf '%s\n' "$1" >"$TMP/self"
	{
		echo "FIRECODE_ROOT=\"$ROOT\""
		echo "SELF_FILE=\"$TMP/self\""
		# shellcheck disable=SC2016  # the $SELF_FILE here is literal text to
		# find in the hook, not a variable this script wants expanded.
		sed -n '/^WAITER=0/,/^done <"\$SELF_FILE"/p' "$HOOK"
		# shellcheck disable=SC2016  # generated code: expands when it runs,
		# which is the point - not here.
		echo 'printf %s "$WAITER_COUNT"'
	} >"$TMP/loop.sh"
	bash "$TMP/loop.sh" 2>/dev/null
}

check() {
	local what=$1 want=$2 got=$3 procs=$4
	if [[ $got == "$want" ]]; then
		echo "ok    $what: $procs process(es), counted $got"
	else
		echo "FAIL  $what: $procs process(es), counted $got, wanted $want"
		rc=1
	fi
}

procs=$(pgrep -f -- "chat --inbox --as $REAL" | wc -l)
if ((procs == 0)); then
	echo "skip  one real waiter: none armed as $REAL"
else
	check "one real waiter" 1 "$(counted_for "$REAL")" "$procs"
fi

for _ in 1 2 3; do
	setsid bash -c 'exec -a "chat --inbox --as fc-counttest" sleep 20' &
done
sleep 1
procs=$(pgrep -f -- "chat --inbox --as fc-counttest" | wc -l)
check "three independent waiters" 3 "$(counted_for fc-counttest)" "$procs"
pkill -f -- "chat --inbox --as fc-counttest" 2>/dev/null || true

exit "$rc"
