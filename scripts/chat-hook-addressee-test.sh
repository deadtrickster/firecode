#!/usr/bin/env bash
# The "is this addressed to me" predicate, cut out of chat-hook.sh and driven
# with events built here.
#
# WHY IT EXISTS. On 2026-08-22 the operator wrote to @dead-claude, with the
# addressee stamped on the event by the node, and flowy-claude's stop hook told
# them the message was addressed to THEM. They answered it - correctly, because
# silence reads as absence - and in doing so took another seat's work. The
# predicate was `actor_kind == "user"`, which is true of every message a person
# writes, to anybody.
#
# The half that must not regress in fixing it: a person writing "who is here?"
# names nobody, and that used to classify as ambient room traffic that never
# blocked a stop. The operator's words were "my messages are more likely to be
# ignored, you guys talk to each other just fine". An unaddressed message from a
# person still has to reach every seat.
#
# So this asserts BOTH directions, and the pair is the point: addressed-to-them
# must not match, unaddressed must.
#
# THE PREDICATE IS CUT OUT AT RUN TIME rather than copied, so what is tested is
# what ships.
set -uo pipefail
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
SRC=${1:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/chat-hook.sh}

# The jq program, from the first line of the filter to the closing length.
awk '/\[\.\[\] \| select\(\.addressee_name == \$me/{on=1} on{print} on && /length/{exit}' \
	"$SRC" | sed "s/^[[:space:]]*'//; s/' *\\\\$//" >"$d/pred.jq"
grep -q 'addressee_name' "$d/pred.jq" || {
	echo "could not cut the predicate out of $SRC - this asserts nothing until that is fixed"
	exit 1
}

# how many of the events in $2 the predicate calls mine, as $1
mine() { # me events-json
	jq --arg me "$1" -f "$d/pred.jq" <<<"$2" 2>/dev/null
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

# THE CASE THAT WAS WRONG. A person, naming somebody else, both ways the node
# can carry it.
want "a person's message to another seat, by handle, is not mine" 0 \
	"$(mine flowy-claude '[{"addressee_name":"dead-claude","addressee":"01ID","meta":{"actor_kind":"user"}}]')"
want "a person's message to another seat, by id only, is not mine" 0 \
	"$(mine flowy-claude '[{"addressee":"01ID","meta":{"actor_kind":"user"}}]')"

# THE HALF THAT MUST NOT REGRESS.
want "a person's message to nobody reaches me" 1 \
	"$(mine flowy-claude '[{"meta":{"actor_kind":"user"}}]')"
want "empty addressee fields still count as unaddressed" 1 \
	"$(mine flowy-claude '[{"addressee_name":"","addressee":"","meta":{"actor_kind":"user"}}]')"

# ADDRESSED TO ME IS MINE whoever wrote it, which is the original rule.
want "a person's message to me is mine" 1 \
	"$(mine dead-claude '[{"addressee_name":"dead-claude","meta":{"actor_kind":"user"}}]')"
want "an agent's message to me is mine" 1 \
	"$(mine dead-claude '[{"addressee_name":"dead-claude","meta":{"actor_kind":"agent"}}]')"

# AND AN AGENT TALKING TO SOMEBODY ELSE IS NOT MINE, which is what kept the
# room usable before any of this.
want "an agent's message to another seat is not mine" 0 \
	"$(mine dead-claude '[{"addressee_name":"orchestrator","meta":{"actor_kind":"agent"}}]')"

exit $fail
