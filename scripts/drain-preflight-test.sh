#!/usr/bin/env bash
# shellcheck disable=SC2034  # rowtarget/row/note are read by the block sourced from drain.sh
# shellcheck disable=SC2329  # blocked/record/say are called by that block, not from here
# The pre-flight tree check, cut out of drain.sh and driven with controlled
# values. blocked/record/say are stubbed, so nothing reaches the node: what is
# asserted is WHICH ACTIONS FIRE and with what exit code.
set -uo pipefail
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
SRC=${1:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/drain.sh}
awk '/^on=\$\(git -C "\$REPO" rev-parse/{on=1} on{print} on && /^fi$/{exit}' "$SRC" >"$d/pre.sh"
grep -q 'rev-parse' "$d/pre.sh" || {
	echo "could not cut the pre-flight out of $SRC - it asserts nothing until that is fixed"
	exit 1
}

# Everything happens in a subshell, because the block EXITS on the refusal path
# and a test that sourced it in its own shell would exit with it. The results
# come back on stdout for the same reason.
run() { # branch-the-repo-is-on target
	(
		REPO=$d/repo rowtarget=$2 row=ROW acted=""
		rm -rf "$REPO"
		git init -q -b "$1" "$REPO" >/dev/null 2>&1
		git -C "$REPO" -c commit.gpgsign=false -c user.email=t@t -c user.name=t \
			commit -q --allow-empty -m x >/dev/null 2>&1
		blocked() { acted="$acted blocked"; }
		record() { printf 'rc=EXIT outcome=%s acted=%s record\n' "$outcome" "${acted# }"; }
		say() { :; }
		outcome="" note=""
		# shellcheck source=/dev/null  # cut from drain.sh above
		. "$d/pre.sh"
		printf 'rc=0 outcome=%s acted=%s\n' "${outcome:-none}" "${acted:-none}"
	)
	printf 'exit=%s' "$?"
}

fail=0
got=$(run other master)
case "$got" in
*"outcome=refused acted=blocked record"*"exit=1"*)
	echo "ok    a parked tree refuses before the gate, tells the row, and records"
	;;
*)
	echo "FAIL  parked tree: $got"
	fail=1
	;;
esac
got=$(run master master)
case "$got" in
*"rc=0 outcome=none acted=none"*"exit=0"*)
	echo "ok    a tree already on the target passes through silently"
	;;
*)
	echo "FAIL  correct tree: $got"
	fail=1
	;;
esac
exit "$fail"
