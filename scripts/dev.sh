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
#   dev.sh commit    stage first, put the message in runs/commit-msg.txt,
#                    then run this in the BACKGROUND: it opens the magit
#                    buffer and blocks until C-c C-c or C-c C-k, so the
#                    notification is the answer
#   dev.sh await-commit
#                    the waiting half alone, for a buffer already open
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

# Block until the commit sitting in the editor is finished, or abandoned.
#
# `ecommit` opens a magit buffer and returns straight away, so nothing tells
# an agent when C-c C-c actually lands - it finds out by polling git log,
# which means either asking repeatedly or noticing minutes later. Run this in
# the background instead: it exits when HEAD moves, and a background command
# that exits is a notification.
#
# Exits 0 with the new commit, 1 if nothing happened before the timeout, and
# 2 if the commit was abandoned - the staged changes still sitting there with
# HEAD where it was is what C-c C-k leaves behind.
cmd_await_commit() {
	local start
	start=$(git rev-parse HEAD 2>/dev/null) || return 1
	wait_for_commit "$start"
}

# Stage first, write the message to runs/commit-msg.txt, then run this in the
# background. It captures HEAD before opening the editor, which `await-commit`
# on its own cannot do: called as a separate command it can be started after
# C-c C-c has already landed, and then "HEAD is where I found it and nothing
# is staged" describes a finished commit and an abandoned one identically. It
# reported a successful commit as abandoned exactly once before this existed.
cmd_commit() {
	local msg=${FIRECODE_COMMIT_MSG:-runs/commit-msg.txt} start
	if [[ ! -s $msg ]]; then
		echo "no commit message at $msg - write it there first"
		return 2
	fi
	if git diff --cached --quiet 2>/dev/null; then
		echo "nothing staged - git add what you mean to commit first"
		return 2
	fi
	start=$(git rev-parse HEAD 2>/dev/null) || return 1
	say "opening the commit buffer"
	git diff --cached --stat | tail -1
	ecommit -F "$msg" || true
	wait_for_commit "$start"
}

wait_for_commit() {
	local start=$1 now waited=0 limit=${FIRECODE_AWAIT_COMMIT:-1800}
	while ((waited < limit)); do
		sleep 2
		waited=$((waited + 2))
		now=$(git rev-parse HEAD 2>/dev/null)
		if [[ $now != "$start" ]]; then
			say "committed"
			git log --oneline -1
			say "still uncommitted"
			git status --short
			return 0
		fi
		# Nothing staged any more, HEAD unmoved: the buffer was abandoned
		# and somebody unstaged, or another session committed the index.
		if git diff --cached --quiet 2>/dev/null; then
			say "nothing staged and HEAD did not move"
			echo "the commit was abandoned, or its changes were unstaged"
			return 2
		fi
	done
	say "timeout"
	echo "no commit after ${limit}s - the buffer is probably still open"
	return 1
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
await-commit) cmd_await_commit ;;
commit) cmd_commit ;;
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
