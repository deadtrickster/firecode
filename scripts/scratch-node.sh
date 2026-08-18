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

	local dsn port
	docker rm -f "$NAME-pg" >/dev/null 2>&1 || true
	docker run -d --rm --name "$NAME-pg" \
		-e POSTGRES_PASSWORD=scratch -e POSTGRES_DB=flowy \
		-p "$PGPORT:5432" postgres:17-alpine >/dev/null ||
		die "could not start postgres - is one already on $PGPORT?"
	dsn="postgres://postgres:scratch@127.0.0.1:$PGPORT/flowy?sslmode=disable"

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
		answered=$(curl -sS -m 2 "http://127.0.0.1:$port/healthz" 2>/dev/null |
			sed -n 's/.*"node":"\([^"]*\)".*/\1/p')
		[ -n "$answered" ] && break
		sleep 0.5
	done
	[ -n "$answered" ] || die "nothing answered on $port - node log: $(tail -3 "$STATE/node.log")"
	[ "$answered" = "$NAME" ] ||
		die "the node on $port calls itself $answered, not $NAME - somebody else holds that port"

	printf 'export BASE=http://127.0.0.1:%s\n' "$port"
	sed 's/^/export /' "$STATE/ids"
	say "up on $port, database $PGPORT, logs $STATE/node.log"
}

down() {
	if [ -r "$STATE/node.pid" ]; then
		kill "$(cat "$STATE/node.pid")" 2>/dev/null || true
		rm -f "$STATE/node.pid"
	fi
	docker rm -f "$NAME-pg" >/dev/null 2>&1 || true
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
