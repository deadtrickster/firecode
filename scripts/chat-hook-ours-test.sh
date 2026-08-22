#!/usr/bin/env bash
# shellcheck disable=SC2329  # waiter_pid_for is called by the block cut from chat-hook.sh
# The "may this name go in an instruction" rule, cut out of chat-hook.sh and
# driven with controlled inputs.
#
# 01M0K9YBV5. @orchestrator was told four times in one evening to start a
# listener as flowy-claude. They are orchestrator, their own listener was
# attached and polling throughout, and the hook was reading a memo plus a
# BOX-WIDE pid file: waiter_pid_for answers "is somebody listening as this
# name", never "is this session that name".
#
# So there are two questions and they had one flag:
#
#   may the hook READ this inbox      FLOWY_NAME_PROVED - unchanged here
#   may the hook PUT THE NAME in an   FLOWY_NAME_OURS   - what this tests
#   instruction it hands somebody
#
# The second is stricter and the difference is the whole row. This asserts the
# one case where a name cannot belong to anybody else - exactly one seat on the
# box - and that a live waiter never makes it ours.
set -uo pipefail
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
SRC=${1:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/chat-hook.sh}

awk '/^FLOWY_NAME_OURS=0$/{on=1} on{print} on && /^fi$/{exit}' "$SRC" >"$d/ours.sh"
grep -q 'FLOWY_NAME_OURS=1' "$d/ours.sh" || {
	echo "could not cut the rule out of $SRC - this asserts nothing until that is fixed"
	exit 1
}

# name, and how many seat tokens live on the box
ours() { # name candidate-count
	(
		# shellcheck disable=SC2034  # read by the rule sourced from chat-hook.sh below
		FLOWY_NAME=$1
		flowy_candidates=()
		for ((i = 0; i < $2; i++)); do flowy_candidates+=("seat$i"); done
		# A LIVE WAITER FOR THE NAME, always. If the rule consults this at all
		# the test fails, which is the point: it is what used to be treated as
		# proof and it is the wrong proposition.
		waiter_pid_for() { printf '1'; }
		# shellcheck source=/dev/null  # cut from chat-hook.sh above
		. "$d/ours.sh"
		printf '%s' "$FLOWY_NAME_OURS"
	)
}

fail=0
want() { # name expected got
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
	else
		echo "FAIL  $1: wanted $2, got $3"
		fail=1
	fi
}

# THE CASE THAT WAS WRONG. Eight seats on this box, a memo naming one of them,
# and that seat's waiter up - which is every evening here.
want "a name is not ours just because a waiter runs under it" 0 "$(ours flowy-claude 8)"
want "nor with two seats" 0 "$(ours flowy-claude 2)"

# THE ONE CASE WHERE IT CANNOT BE SOMEBODY ELSE'S.
want "the only seat on the box is ours" 1 "$(ours claude-host 1)"

# AND NO NAME IS NEVER OURS, whatever else is true.
want "an empty name is not ours" 0 "$(ours '' 1)"

exit $fail
