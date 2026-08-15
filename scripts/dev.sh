#!/usr/bin/env bash
# The checks this repo gets asked for over and over, in one command.
#
# Not a convenience wrapper. Every check here used to be typed as a fresh
# shell one-liner - a slightly different grep, another curl with another
# timeout, an awk written on the spot - and a command that is never the same
# twice cannot be permitted once. The person behind the agent ends up
# approving near-identical commands all day, which is both tedious and the
# fastest way to train somebody to approve without reading.
#
# So: fixed subcommands, fixed shapes, no arguments that change the string.
# Grant it once.
#
#   dev.sh lint      shellcheck + shfmt + parse every script, compile python
#   dev.sh status    branch, last commits, what is uncommitted
#   dev.sh push      push the current branch
#   dev.sh room      chat server, cursors, identities, who is listening
#   dev.sh server    spawn server pid, runs in flight, recent log
#   dev.sh all       every read-only check above
#
# Anything that changes state is its own subcommand and says what it did.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1

PORT=${FIRECODE_CHAT_PORT:-9761}
SPAWN_PORT=${FIRECODE_SPAWN_PORT:-9770}

say() { printf '\n=== %s ===\n' "$1"; }

# Every shell script that ships, so a new one cannot be forgotten.
scripts() {
	printf '%s\n' bin/firecode
	find guest scripts tests -name '*.sh' -type f 2>/dev/null | sort
	[[ -f guest/initramfs/init ]] && printf '%s\n' guest/initramfs/init
	return 0
}

cmd_lint() {
	# Each section reports its own result. Sharing one status across all of
	# them means a shellcheck warning silences the parse and compile lines,
	# and "no output" then reads as "did not run" - which is the opposite of
	# what a check should ever be ambiguous about.
	local rc=0 sec f
	say "shellcheck"
	sec=0
	while read -r f; do
		shellcheck "$f" || sec=1
	done < <(scripts)
	((sec == 0)) && echo "clean" || rc=1

	say "shfmt"
	sec=0
	while read -r f; do
		shfmt -w "$f" || sec=1
	done < <(scripts)
	((sec == 0)) && echo "formatted" || rc=1

	# After formatting, not before: shfmt rewrites the file, and a formatter
	# that breaks a script it just reformatted is exactly the failure this
	# catches. bin/firecode embeds python in single quotes in a dozen places,
	# and an apostrophe in a comment there has taken the whole CLI down for
	# every session on this machine three times in one day.
	say "parse"
	sec=0
	while read -r f; do
		bash -n "$f" || {
			echo "!! $f does not parse"
			sec=1
		}
	done < <(scripts)
	((sec == 0)) && echo "all parse" || rc=1

	say "python"
	sec=0
	local p
	for p in mcp/*.py scripts/*.py; do
		[[ -f $p ]] || continue
		python3 -m py_compile "$p" || sec=1
	done
	((sec == 0)) && echo "compile" || rc=1
	return $rc
}

cmd_status() {
	say "branch"
	git rev-parse --abbrev-ref HEAD
	say "recent"
	git log --oneline -5
	say "uncommitted"
	git status --short || true
	say "unpushed"
	git log --oneline '@{u}..HEAD' 2>/dev/null || echo "(no upstream)"
}

cmd_push() {
	say "push"
	git push
}

cmd_room() {
	say "chat server"
	if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
		echo "up on $PORT"
	else
		echo "DOWN on $PORT - firecode chat serve"
	fi

	say "identities (who each directory speaks as)"
	local f
	for f in runs/chat-self-*; do
		[[ -f $f ]] || continue
		printf '%-52s %s\n' "${f#runs/chat-self-}" "$(tr '\n' ' ' <"$f")"
	done

	say "cursors (how far each reader has read)"
	for f in runs/chat-mark-*; do
		[[ -f $f ]] || continue
		printf '%-52s %s\n' "${f#runs/chat-mark-}" "$(cat "$f")"
	done

	# The one that matters when a message goes unanswered: a waiter is what
	# wakes an idle session, and it has to be restarted after every fire.
	say "waiters (what is listening right now)"
	pgrep -af -- "chat --inbo[x]" || echo "none - nobody would be woken"
}

cmd_server() {
	say "spawn server"
	local pid
	pid=$(ss -lntp 2>/dev/null |
		sed -n "s/.*:$SPAWN_PORT .*pid=\([0-9]*\).*/\1/p" | head -1)
	if [[ -z $pid ]]; then
		echo "DOWN on $SPAWN_PORT - firecode spawn-server restart"
		return 0
	fi
	echo "up on $SPAWN_PORT (pid $pid)"

	# Children are runs. Restarting the server forgets them, so this is the
	# number to look at before bouncing it.
	say "runs in flight"
	pgrep -P "$pid" >/dev/null 2>&1 &&
		pgrep -aP "$pid" || echo "none - safe to restart"

	say "recent log"
	tail -12 runs/spawn-server.log 2>/dev/null || echo "(no log yet)"
}

case "${1:-all}" in
lint) cmd_lint ;;
status) cmd_status ;;
push) cmd_push ;;
room) cmd_room ;;
server) cmd_server ;;
all)
	cmd_status
	cmd_room
	cmd_server
	;;
*)
	sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
	;;
esac
