#!/usr/bin/env bash
# shellcheck disable=SC2329  # say() is called by the function cut from drain.sh, not from here
# stale_ref_note, cut out of drain.sh and driven with controlled shas.
#
# WHY THIS EXISTS. The note it prints is the only thing standing between a
# correct-and-silent skip and an hour of somebody waiting. On 2026-08-21 row
# 01M0JZ52Y2 sat twelve minutes after its fix was pushed: a pass leaves the
# LOCAL branch at the tip it rebased, `push origin HEAD:<branch>` moves origin
# and not that ref, so the red pair still matched and the drainer skipped the
# row exactly as designed. Nothing was broken; nothing said so.
#
# THE FUNCTION IS CUT OUT AT RUN TIME rather than copied, so the thing tested is
# the thing that ships. A copy would pass forever after somebody edited the
# original.
set -uo pipefail
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
SRC=${1:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/drain.sh}
awk '/^stale_ref_note\(\) \{/{on=1} on{print} on && /^\}$/{exit}' "$SRC" >"$d/fn.sh"
grep -q 'origin/' "$d/fn.sh" || {
	echo "could not cut stale_ref_note out of $SRC - this asserts nothing until that is fixed"
	exit 1
}

# say() is captured rather than stubbed silent: WHAT IT SAYS is the assertion,
# because a note nobody can act on is the failure being fixed here.
run() { # branch local origin
	(
		say() { printf '%s\n' "$*"; }
		# shellcheck source=/dev/null  # cut from drain.sh above
		. "$d/fn.sh"
		stale_ref_note "$1" "$2" "$3"
	)
}

fail=0
want() { # name expected-substring output
	case "$3" in
	*"$2"*) echo "ok    $1" ;;
	*)
		echo "FAIL  $1"
		printf '      wanted %q in: %q\n' "$2" "$3"
		fail=1
		;;
	esac
}
wantnot() { # name forbidden-substring output
	case "$3" in
	*"$2"*)
		echo "FAIL  $1"
		printf '      did not want %q in: %q\n' "$2" "$3"
		fail=1
		;;
	*) echo "ok    $1" ;;
	esac
}

# THE ORDINARY CASE IS SILENCE. Every skipped row runs through this, and a note
# on the ones that agree would be noise on the path that is working - which is
# how a reader learns to stop reading the notes, including the one that matters.
wantnot "an agreeing origin says nothing" "NOTE" "$(run br abc123 abc123)"

# NO REMOTE-TRACKING REF IS NOT A DISAGREEMENT. A branch that was never pushed
# has no origin/ ref at all, and rev-parse leaves the variable empty. Treating
# empty as "different" would put a note on every local-only branch and tell
# people to `branch -f` to nothing.
wantnot "an absent origin ref says nothing" "NOTE" "$(run br abc123 '')"

# THE CASE IT WAS WRITTEN FOR.
out=$(run fix/the-pane abc123 def456)
want "a moved origin is named" "origin/fix/the-pane is at def456" "$out"
want "and so is what this box has" "fix/the-pane is at abc123" "$out"
# THE COMMAND, not a diagnosis. The person reading this is waiting on a re-gate
# and the next thing they need is the line that causes one.
want "and the fix is a command" "branch -f fix/the-pane def456" "$out"

exit $fail
