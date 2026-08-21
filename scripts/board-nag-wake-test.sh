#!/usr/bin/env bash
# WHEN THE BOARD NAG IS ALLOWED TO SPEAK.
#
# The nag used to wake on
#
#   work = unowned + mine_todo + stale
#
# and `unowned` is a pile no seat can clear by working: nine rows nobody owns
# stay nine when you take one. So the sum never reached zero, the wait broke on
# its first poll every time, and the nag fired every two minutes for as long as
# the board was not empty. A signal that always fires carries nothing, and it
# got tuned out - the operator: "the fact that nagger was ignored deliberately
# worries me so much". It was ignored because it was noise. Row 01M0H546BA.
#
# THE PREDICATE IS EXTRACTED FROM board-nag.sh AT RUN TIME rather than copied
# here, because a copy is a second renderer of the same fact and drifts from the
# original exactly when it matters. If the cut below stops matching, that is a
# failure worth having: it means the shape of the predicate changed.
#
# Run it directly, or as `firecode test board_nag_wake`.
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
NAG=$ROOT/scripts/board-nag.sh
d=$(mktemp -d /tmp/board-nag-wake.XXXXXX)
trap 'rm -rf "$d"' EXIT
PRED=$d/predicate.sh

awk '/^\t\tclearable=\$\(jq/{on=1} on{print} on && /^\t\t\tbreak$/{seen=1} seen && /^\t\tfi$/{exit}' \
	"$NAG" | sed 's/^\t\t//' >"$PRED"
if ! grep -q 'clearable' "$PRED" || ! grep -q 'break' "$PRED"; then
	printf 'board-nag-wake: could not cut the wake predicate out of %s\n' "$NAG" >&2
	printf 'The test asserts nothing until this is fixed, which is why it fails here.\n' >&2
	exit 1
fi

BOARD_REMIND=3600
export BOARD_REMIND

# run reports WAKE if the predicate would break out of the wait, QUIET if not.
# The loop is how `break` is caught: the predicate is real shell and breaks a
# real loop, so nothing about it is stubbed.
run() { # mine_todo stale unowned last_pile(-=none) remind_age(-=never) last_stale(-=none)
	# shellcheck disable=SC2034  # read by the predicate sourced from board-nag.sh
	nag=$(printf '{"mine_todo":%s,"stale":%s,"unowned":%s}' "$1" "$2" "$3")
	pile_file=$d/pile
	stale_file=$d/stale
	remind_file=$d/remind
	rm -f "$pile_file" "$stale_file" "$remind_file"
	[ "$4" = "-" ] || printf '%s' "$4" >"$pile_file"
	# Defaults to the stale count itself, so a case that says nothing about
	# staleness describes a board where it has not just changed - which is what
	# every case written before stale was edge-triggered meant.
	last_stale=${6:-$2}
	[ "$last_stale" = "-" ] || printf '%s' "$last_stale" >"$stale_file"
	if [ "$5" != "-" ]; then
		: >"$remind_file"
		touch -d "@$(($(date +%s) - $5))" "$remind_file"
	fi
	local woke=WAKE
	while :; do
		# shellcheck source=/dev/null  # cut from board-nag.sh above
		. "$PRED"
		woke=QUIET
		break
	done
	printf '%s' "$woke"
}

fail=0
check() { # want desc mine_todo stale unowned last_pile remind_age [last_stale]
	local want=$1 desc=$2
	shift 2
	local got
	got=$(run "$@")
	if [ "$got" = "$want" ]; then
		printf 'ok    %s\n' "$desc"
	else
		printf 'FAIL  %s: got %s want %s\n' "$desc" "$got" "$want"
		fail=1
	fi
}

# THE ROW ITSELF: a pile the seat cannot clear must not wake it forever.
check QUIET "steady pile, nothing of mine - the bug being fixed" 0 0 9 9 0
check WAKE "the pile GREW - a new unowned row is news" 0 0 10 9 0
check QUIET "the pile SHRANK - somebody took one" 0 0 8 9 0

# WHAT A SEAT CAN CLEAR still wakes it every time, because working turns it off.
# This must keep working: a nag that went quiet about a seat's own unstarted
# rows would be the opposite failure, and the operator asked for the todo list
# to empty.
check WAKE "a row assigned to me and not started" 1 0 9 9 0
check WAKE "two of them" 2 0 9 9 0

# STALE IS EDGE-TRIGGERED TOO, and this is the half that was wrong when the
# split first landed. A note does not move `Updated` (api_nag.go:156), so
# writing on a stale row does not clear it - measured, 2 stale to 6 on this seat
# in three hours of doing exactly what the board asks. Level-triggering it made
# the nag fire every cycle about work that was in hand. 01M0HRZM3N.
check QUIET "six stale rows, unchanged since the morning" 0 6 9 9 0
check WAKE "a NEW row has gone quiet" 0 7 9 9 0 6
check QUIET "one stale row was picked back up" 0 5 9 9 0 6
check WAKE "first contact, and something is stale" 0 3 0 - - -

# The floor under both, so a full board that stopped changing is not forgotten.
check WAKE "steady pile, but not reminded for an hour" 0 0 9 9 3600
check QUIET "steady pile, reminded ten minutes ago" 0 0 9 9 600
check WAKE "no pile, stale rows, and an hour of silence" 0 4 0 0 3600
check QUIET "nothing at all and nothing of mine - truly quiet" 0 0 0 0 99999

# FIRST CONTACT is not an empty board. A seat with no file has never been told
# anything, which is why the absent count is -1 and not 0 - but 0 unowned rows
# must still be silent, and reading absent as "it grew from nothing" made an
# empty board nag. Caught by this test before it shipped.
check WAKE "no previous count on disk, and a pile" 0 0 9 - -
check QUIET "no previous count, and an empty board" 0 0 0 - -

exit "$fail"
