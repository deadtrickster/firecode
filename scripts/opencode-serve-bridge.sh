#!/usr/bin/env bash
# Start opencode served + the firecode-chat relay in one command.
#
#   opencode-serve-bridge.sh [--port N]
#
# Brings up a headless opencode server, then the room relay (co-located
# opencode-chat-relay.py) pointed at it. The relay auto-discovers the active
# session and forwards room lines mentioning "glm" to /api/session/.../prompt,
# which wakes the served agent.
#
# opencode serve has no --resume: to resume a session, attach afterwards
# (opencode attach <url>) and resume in the client. This script only brings up
# the server + relay.
#
# The relay is the wake source, so it cannot be started by the agent itself -
# run this script (or otherwise start the relay) before expecting the served
# session to be ringable from the room.
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
FC=$(cd "$DIR/.." && pwd)
PORT=4096

while [ $# -gt 0 ]; do
	case "$1" in
	--port)
		PORT="$2"
		shift 2
		;;
	*)
		echo "unknown arg: $1" >&2
		exit 2
		;;
	esac
done

URL="http://127.0.0.1:$PORT"
SERVE_LOG="$FC/runs/opencode-serve.log"
RELAY_OUT="$FC/runs/opencode-relay.out"
mkdir -p "$FC/runs"

setsid opencode serve --hostname 127.0.0.1 --port "$PORT" >"$SERVE_LOG" 2>&1 &
SERVE_PID=$!

# Wait for the server to bind.
for _ in $(seq 1 60); do
	ss -ltn 2>/dev/null | grep -q ":$PORT " && break
	sleep 0.25
done
if ! ss -ltn 2>/dev/null | grep -q ":$PORT "; then
	echo "serve did not come up on $PORT - see $SERVE_LOG" >&2
	exit 1
fi

OPENSENSE_SERVE="$URL" setsid python3 "$DIR/opencode-chat-relay.py" >"$RELAY_OUT" 2>&1 &
RELAY_PID=$!

echo "serve pid $SERVE_PID at $URL, relay pid $RELAY_PID"
echo "attach:  opencode attach $URL   (resume your session in the client)"
echo "room lines mentioning 'glm' wake the active session"
