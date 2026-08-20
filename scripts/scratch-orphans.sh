#!/usr/bin/env bash
# The scratch nodes and containers a finished session left behind - NAMED, with
# the evidence, and removed by nobody.
#
# 01M0FFAW9R. Measured 2026-08-20: eleven `flowy serve` processes on the scratch
# ports, the oldest up a day and fifteen hours, ten of them running a binary
# that has since been DELETED from disk - /tmp/flowy-scratch/flowy (deleted) -
# because a later `up` replaced it under them. Plus scratch containers older
# than the sessions that started them.
#
# WHY THEY EXIST. `scratch-node.sh up` used to write node.pid unconditionally,
# so calling it twice orphaned the first node: nothing recorded it, `down`
# stopped only the last, and the first kept its port and its database
# connection. e039b72 fixed the making of new ones. This is about the ones
# already here.
#
# THIS REMOVES NOTHING, and that is the whole design.
#
# Twelve of these are not all one seat's. A program that decides which
# processes belong to whom is how this box lost another agent's postgres this
# morning - by name, matching a pattern that fitted more than it meant. What a
# person needs is the id and the evidence, and that is what this prints:
#
#   pid, port, age, whether its binary still exists, whether its state
#   directory still points at it, and the exact `kill <pid>` for that one.
#
# By PID, never a pattern: `pkill -f 'flowy serve'` matches the shell running
# it, which happened five times on this fleet today, three of them to the
# person doing the repair.
set -uo pipefail

STATE=${SCRATCH_STATE:-${TMPDIR:-/tmp}/flowy-scratch}
recorded=""
[ -r "$STATE/node.pid" ] && recorded=$(cat "$STATE/node.pid" 2>/dev/null)

printf 'scratch nodes on this box\n\n'
found=0
for d in /proc/[0-9]*; do
	pid=${d#/proc/}
	# argv[0] and the -addr flag together: a `flowy serve` on a scratch port.
	# Read from /proc rather than `ps | grep`, which matches its own command
	# line - two wrong readings came from that today.
	cmd=$({ tr '\0' '\n' <"$d/cmdline" | head -1; } 2>/dev/null)
	[ "${cmd##*/}" = "flowy" ] || continue
	args=$({ tr '\0' ' ' <"$d/cmdline"; } 2>/dev/null)
	case "$args" in *"serve -addr"*) ;; *) continue ;; esac

	port=$(printf '%s' "$args" | grep -oE '127\.0\.0\.1:[0-9]+' | head -1)
	age=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
	binary="binary present"
	# /proc/<pid>/exe on a deleted file resolves to "<path> (deleted)"; readlink
	# -f drops that, so ask the link itself.
	case "$(readlink "/proc/$pid/exe" 2>/dev/null)" in
	*"(deleted)") binary="BINARY DELETED - a later up replaced it under this node" ;;
	esac
	mine="not the recorded node"
	[ -n "$recorded" ] && [ "$recorded" = "$pid" ] && mine="the node $STATE currently records"

	found=$((found + 1))
	printf '  %-8s %-22s up %-14s %s\n' "$pid" "${port:-no port}" "${age:-?}" "$mine"
	printf '           %s\n' "$binary"
	printf '           kill %s\n\n' "$pid"
done

if [ "$found" = 0 ]; then
	printf '  none\n\n'
fi

printf 'scratch containers\n\n'
if command -v docker >/dev/null 2>&1; then
	# Names only, and only the scratch ones: this lists what somebody may want
	# to remove, and says the command rather than running it.
	docker ps --format '{{.ID}}\t{{.Names}}\t{{.RunningFor}}' 2>/dev/null |
		grep -iE "scratch|-pg" | while IFS=$'\t' read -r id name since; do
		printf '  %-14s %-28s up %s\n' "$id" "$name" "$since"
		printf '           docker rm -f %s\n\n' "$name"
	done
else
	printf '  no docker on this host\n\n'
fi

printf 'Nothing above has been stopped. The commands are for a person who knows\n'
printf 'which of these is theirs - and after e039b72, up refuses to make more.\n'
