#!/usr/bin/env bash
# A flowy node of your own, in about ninety seconds, so that ONE browser check
# does not cost a thirty-five minute gate.
#
#   eval "$(scripts/scratch-node.sh up)"     # exports BASE, TOKEN_A, PROJECT_A, ...
#   scripts/scratch-node.sh down             # takes it all away again
#
# WHY THIS EXISTS. Three times on 2026-08-18 I needed a live node to run a
# single check against - the finding-runs door, the repro proxy, the findings
# selection panel - and each time I assembled the same five steps by hand:
# a postgres in docker, schema.sql, cmd/smoke seed, `flowy serve`, then the
# check. The third time it went wrong in the way this fleet keeps going wrong:
# the node did not start because something already held the port, and the check
# talked to a STRANGER'S NODE and answered 401. I read that as a broken check
# for several minutes.
#
# So the two things this does that a person doing it by hand forgets:
#
#   IT PICKS A PORT NOTHING HOLDS, and then proves the node answering on it is
#   the one it started - by node name, not by "something answered". The gate
#   learned the same lesson tonight (run-tests.sh's own port check) after two
#   suites spent an evening reading each other's answers.
#
#   IT NEVER TOUCHES THE FLEET'S DATABASE. A container it started, on a port it
#   chose, dropped on `down`. The operator's rule: all testing inside docker,
#   never the live node.
#
# What it prints on `up` is shell you eval, because the whole point is to get
# BASE and a token into your hand in one line:
#
#   export BASE=http://127.0.0.1:18841
#   export TOKEN_A=tA-01M0...  PROJECT_A=pa  HANDLE_B=bob-01M0...
set -euo pipefail

REPO=${FLOWY_REPO:-$HOME/Projects/flowy}
NAME=${SCRATCH_NAME:-flowy-scratch}
PGPORT=${SCRATCH_PGPORT:-15610}
STATE=${SCRATCH_STATE:-${TMPDIR:-/tmp}/flowy-scratch}
PGBIN=${PGBIN:-$HOME/.local/pg17-bin}
PGLIBS=${PGLIBS:-$HOME/.local/pg17-libs}

say() { printf 'scratch: %s\n' "$*" >&2; }
die() {
	printf 'scratch: %s\n' "$*" >&2
	exit 1
}

# A PORT NOTHING IS LISTENING ON, asked as late as possible and then PROVED by
# who answers. free-at-this-instant is what two suites raced over all evening.
free_port() {
	local p=$1
	while ss -ltn 2>/dev/null | grep -q ":$p "; do p=$((p + 1)); done
	printf '%s' "$p"
}

up() {
	[ -d "$REPO" ] || die "no checkout at $REPO"
	mkdir -p "$STATE"

	# A NODE THIS STATE DIRECTORY ALREADY STARTED IS STILL ITS NODE.
	#
	# `up` used to write node.pid unconditionally. Calling it twice therefore
	# ORPHANED the first node: nothing recorded it any more, `down` stopped only
	# the last one and reported success, and the first kept listening and kept a
	# database connection open. Measured 2026-08-20 by doing it to myself three
	# times in one command - 18856 and 18857 were still up after `down` said
	# "down", and there were fifteen more of these on the box from earlier days.
	#
	# It also matters beyond the waste: free_port answers about an instant, so
	# every orphan pushes the next node one port along, and an orphan is a second
	# writer on the same database as its replacement.
	#
	# THE PID IT RECORDED, NOT A NAME. `pkill -f flowy` would find other seats'
	# nodes, which is how this fleet lost another seat's postgres this morning.
	# d821a12 taught the container half of exactly this lesson; the node half was
	# left as it was.
	#
	# REFUSES RATHER THAN REPLACING, because a running node is somebody's - very
	# possibly this caller's, two commands ago - and taking it down to be helpful
	# is the thing that keeps going wrong here. `down` first is one word.
	if [ -r "$STATE/node.pid" ] && kill -0 "$(cat "$STATE/node.pid")" 2>/dev/null; then
		local live
		live=$(cat "$STATE/node.pid")
		die "a node from this state directory is still running (pid $live$(
			ss -ltnp 2>/dev/null | sed -n "s/.*127.0.0.1:\([0-9]*\).*pid=$live,.*/, port \1/p" | head -1
		)).
       Take it down first - scripts/scratch-node.sh down - or it becomes an
       orphan nothing knows about: this file is the only record of it."
	fi

	local dsn port
	docker rm -f "$NAME-pg" >/dev/null 2>&1 || true
	docker run -d --rm --name "$NAME-pg" \
		-e POSTGRES_PASSWORD=scratch -e POSTGRES_DB=flowy \
		-p "$PGPORT:5432" postgres:17-alpine >/dev/null ||
		die "could not start postgres - is one already on $PGPORT?"
	dsn="postgres://postgres:scratch@127.0.0.1:$PGPORT/flowy?sslmode=disable"
	# WHOSE CONTAINER THIS IS, written down at the moment it is started.
	#
	# `down` used to remove any container matching $NAME-pg, and $NAME defaults
	# to flowy-scratch - so a `scratch-node.sh down` typed with no environment
	# removes whatever is answering to the default name, which on a box four
	# agents share is usually somebody else's. Measured on 2026-08-19: I swept
	# what I thought were my own leftovers and killed a scratch database that had
	# been up 24 minutes and was not mine.
	#
	# The id rather than the name, because the name is what collides. A container
	# recreated by somebody else has a different id, so a stale state file cannot
	# authorise removing theirs.
	docker inspect -f '{{.Id}}' "$NAME-pg" >"$STATE/container.id" 2>/dev/null || true

	export PATH="$PGBIN:$PATH" LD_LIBRARY_PATH="$PGLIBS"
	local i
	for i in $(seq 1 60); do
		psql "$dsn" -c 'select 1' >/dev/null 2>&1 && break
		[ "$i" = 60 ] && die "postgres never answered on $PGPORT"
		sleep 1
	done
	psql "$dsn" -q -f "$REPO/schema.sql" >/dev/null 2>&1 || die "schema.sql would not load"

	(cd "$REPO" && go build -o "$STATE/flowy" . && go build -o "$STATE/smoke" ./cmd/smoke) ||
		die "the checkout does not build"

	DATABASE_URL="$dsn" "$STATE/smoke" seed >"$STATE/ids" 2>"$STATE/seed.err" ||
		die "seeding failed: $(head -3 "$STATE/seed.err")"

	port=$(free_port "${SCRATCH_PORT:-18841}")
	DATABASE_URL="$dsn" FLOWY_NODE="$NAME" \
		"$STATE/flowy" serve -addr "127.0.0.1:$port" >"$STATE/node.log" 2>&1 &
	echo $! >"$STATE/node.pid"

	# THE NODE ON OUR PORT IS THE ONE WE STARTED, or this is worthless. Its own
	# name is the discriminator: "something answered" is what sent a check at
	# another suite's node for five minutes tonight.
	local answered=""
	for i in $(seq 1 40); do
		# `|| true` because the FIRST ask always fails - the node is not
		# listening yet - and under `set -e` with pipefail a failed curl in a
		# pipeline kills the very loop that exists to wait for it. Found by
		# running this script for the first time on somebody else's worktree:
		# it exited 7, silently, which is curl's connection-refused.
		answered=$(curl -sS -m 2 "http://127.0.0.1:$port/healthz" 2>/dev/null |
			sed -n 's/.*"node":"\([^"]*\)".*/\1/p' || true)
		[ -n "$answered" ] && break
		sleep 0.5
	done
	[ -n "$answered" ] || die "nothing answered on $port - node log: $(tail -3 "$STATE/node.log")"
	[ "$answered" = "$NAME" ] ||
		die "the node on $port calls itself $answered, not $NAME - somebody else holds that port"

	printf 'export BASE=http://127.0.0.1:%s\n' "$port"
	sed 's/^/export /' "$STATE/ids"
	# THE PID AS WELL AS THE PORT. A caller whose state file has moved on has no
	# other way to name the node it started, which is how the orphans above went
	# unnoticed - `down` knew, and nobody else could.
	say "up on $port (pid $(cat "$STATE/node.pid")), database $PGPORT, logs $STATE/node.log"
}

down() {
	if [ -r "$STATE/node.pid" ]; then
		kill "$(cat "$STATE/node.pid")" 2>/dev/null || true
		rm -f "$STATE/node.pid"
	fi
	# ONLY THE CONTAINER THIS STATE DIRECTORY STARTED.
	#
	# This used to be `docker rm -f "$NAME-pg"`, and $NAME defaults to
	# flowy-scratch, so a `down` typed with no environment removed whatever was
	# answering to the default name. On a box four agents share that is usually
	# somebody else's node. Measured on 2026-08-19: I swept what I believed were
	# my own leftovers and killed a scratch database that had been up for 24
	# minutes and belonged to another seat, which from inside their check looks
	# like the store falling over.
	#
	# The recorded id is the authority, not the name: the name is the thing that
	# collides, and a container somebody else recreated under the same name has a
	# different id. No state file means this shell never started one, and the
	# honest answer to "remove the container you started" is then that there
	# isn't one.
	want=$(cat "$STATE/container.id" 2>/dev/null || true)
	have=$(docker inspect -f '{{.Id}}' "$NAME-pg" 2>/dev/null || true)
	case "$want" in
	"")
		[ -n "$have" ] && say "$NAME-pg is running and this state directory did not start it - left alone"
		say "down (nothing of mine to remove)"
		return 0
		;;
	esac
	if [ -n "$have" ] && [ "$have" != "$want" ]; then
		say "$NAME-pg is a DIFFERENT container from the one started here - left alone"
		say "   started: $(printf '%.12s' "$want")  running: $(printf '%.12s' "$have")"
		rm -f "$STATE/container.id"
		return 0
	fi
	docker rm -f "$NAME-pg" >/dev/null 2>&1 || true
	rm -f "$STATE/container.id"
	say "down"
}

case "${1:-}" in
up) up ;;
down) down ;;
*)
	printf 'usage: scratch-node.sh up|down\n' >&2
	exit 2
	;;
esac
