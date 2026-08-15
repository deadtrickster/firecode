#!/usr/bin/env bash
# A second Flowy node, for the lying-peer scenario.
#
# A real node, not a fake server: the threat being tested is a truthful
# signature over a lying row, so node2 needs its own identity and its own key
# and must serve through its own code. A crafted wire message would fail
# authenticity and prove nothing about the door being tested.
#
# node1 must learn node2's key by TOFU and must NOT operator-pin it. The fix
# refuses a third-party actor only from an unpinned node - pinning means you
# vouched for it - so a pinned node2 would make a working fix look broken.
set -uo pipefail

PGBIN=/usr/lib/postgresql/16/bin
export PATH=$PGBIN:$PATH

PGDATA2=${PGDATA2:-/home/dead/pgdata2}
PORT2=${PORT2:-5434}
NODE2_ADDR=${NODE2_ADDR:-:8788}
FLOWY=/home/dead/flowy-bin
SRC=/home/dead/flowy

say() { printf '\n== %s\n' "$1"; }

say "postgres for node2 on $PORT2"
if [[ ! -d $PGDATA2 ]]; then
	initdb -D "$PGDATA2" -A trust >/dev/null 2>&1 && echo "  initdb ok"
fi
pg_ctl -D "$PGDATA2" -l /home/dead/pg2.log -o "-k /tmp -p $PORT2" -w start >/dev/null 2>&1 || true
psql -h /tmp -p "$PORT2" -d postgres -c 'select 1' >/dev/null 2>&1 && echo "  up on $PORT2"
psql -h /tmp -p "$PORT2" -d postgres -tc \
	"select 1 from pg_database where datname='flowy2'" | grep -q 1 ||
	createdb -h /tmp -p "$PORT2" flowy2
psql -h /tmp -p "$PORT2" -d flowy2 -f "$SRC/schema.sql" >/dev/null 2>&1 && echo "  schema loaded"

export DATABASE_URL="postgres://dead@/flowy2?host=/tmp&port=$PORT2&sslmode=disable"

# A DIFFERENT node name, or this is not a second node at all.
#
# The name defaults to the hostname, so both nodes came up calling themselves
# fc-nested - one identity, two databases. Federation would then be a node
# talking to itself: rows arrive already stamped with the receiver's own
# name, the tie-break by node name is meaningless, and the store even warns
# that two machines sharing a FLOWY_NODE is a misconfiguration. Nothing about
# the lying-peer test would have meant anything.
export FLOWY_NODE=${FLOWY_NODE:-node2}

say "node2 identity"
# Its own key. Node1 will meet this on first contact and remember it.
"$FLOWY" identity keygen --node node2 >/dev/null 2>&1 || true
"$FLOWY" identity show 2>&1 | head -3

say "seed node2 so it has something to serve"
(cd "$SRC" && go run ./cmd/smoke seed >/home/dead/node2-env.sh 2>/dev/null) || true
grep -c '=' /home/dead/node2-env.sh 2>/dev/null | sed 's/^/  vars: /'

say "serve node2"
pkill -f "flowy-bi[n] serve --addr $NODE2_ADDR" 2>/dev/null || true
sleep 1
nohup setsid "$FLOWY" serve --addr "$NODE2_ADDR" </dev/null \
	>/home/dead/node2-serve.log 2>&1 &
disown
sleep 3
curl -s -m 5 "http://127.0.0.1${NODE2_ADDR}/healthz" && echo
echo
echo "node2 database: $DATABASE_URL"
echo "node2 http:     http://127.0.0.1${NODE2_ADDR}"
echo
echo "node1 has NOT pinned it - first contact will be TOFU, which is what the"
echo "scenario needs. Do not operator-pin node2."
