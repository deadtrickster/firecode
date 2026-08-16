#!/usr/bin/env bash
# The flowy half of chat-hook.sh, checked against the live node.
#
# Four things, and the first is the one that would break everything quietly:
#
#   PEEKING MUST NOT CONSUME. The hook polls the same reader the listener is
#   waiting on. If it acked, it would take messages the listener should have
#   returned, on every prompt, and the listener would look like it was sitting
#   in a quiet room. Checked by running the hook twice and confirming the
#   reader's cursor has not moved.
#
#   DELIVERY SURVIVES THE FIRECODE SERVER BEING DOWN. Both firecode guards
#   return 0 early when that server is unreachable, which is exactly when the
#   flowy half still has something to say.
#
#   A STOP WITH NO LISTENER REFUSES (exit 2) AND NAMES THE FLOWY COMMAND.
#
#   A STOP WITH A LISTENER UP DOES NOT REFUSE over flowy.
#
#   usage: scripts/hook-flowy-test.sh [name]
set -u

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
HOOK="$ROOT/scripts/chat-hook.sh"
NAME=${1:-claude-host}
ADDR=${FLOWY_ADDR:-http://192.168.1.55:8787}
AGENTS=${FLOWY_AGENT_DIR:-$HOME/.config/flowy/agents}
TOKEN=$(cat "$AGENTS/$NAME" 2>/dev/null) || TOKEN=""
rc=0

if [[ -z $TOKEN ]]; then
	echo "skip  no flowy token for $NAME"
	exit 0
fi

# The hook takes its name from the self-file for the cwd it is handed, so the
# input names a directory whose self-file has this name in it.
input=$(printf '{"session_id":"hook-flowy-test","cwd":"%s"}' "$ROOT")

# What the reader is still holding, as a list of event ids. Asking the same
# window=0 endpoint the hook uses: if the hook consumed anything, this comes
# back shorter afterwards. No cursor endpoint needed, and no reliance on the
# reader row exposing its position.
held() {
	curl -s -m 5 -H "Authorization: Bearer $TOKEN" \
		"$ADDR/api/inbox/wait?as=$NAME&window=0&limit=20" 2>/dev/null |
		python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print(""); raise SystemExit
print(",".join(e.get("id","") for e in (d.get("events") or [])))' 2>/dev/null
}

say() {
	curl -s -m 10 -X POST -H "Authorization: Bearer $TOKEN" \
		-H 'Content-Type: application/json' -d "{\"body\":\"$1\"}" \
		"$ADDR/api/chat/fc-hooktest/say" >/dev/null 2>&1
}

check() {
	if [[ $2 == "$3" ]]; then
		echo "ok    $1"
	else
		echo "FAIL  $1: got [$3] wanted [$2]"
		rc=1
	fi
}

echo "--- peek must not consume"
say "hook test probe"
before=$(held)
bash "$HOOK" prompt-submit <<<"$input" >/dev/null 2>&1
bash "$HOOK" prompt-submit <<<"$input" >/dev/null 2>&1
after=$(held)
if [[ -z $before ]]; then
	echo "FAIL  the reader held nothing to begin with - this test proves nothing"
	rc=1
else
	check "reader still holds the same events after two hook runs" "$before" "$after"
fi

echo "--- delivery reaches stdout"
out=$(bash "$HOOK" prompt-submit <<<"$input" 2>/dev/null)
if grep -q "flowy room" <<<"$out"; then
	echo "ok    flowy block delivered"
else
	echo "FAIL  no flowy block in output"
	rc=1
fi

echo "--- delivery survives the firecode server being unreachable"
out=$(FIRECODE_CHAT_PORT=9 bash "$HOOK" prompt-submit <<<"$input" 2>/dev/null)
if grep -q "flowy room" <<<"$out"; then
	echo "ok    delivered with firecode down"
else
	echo "FAIL  flowy half lost when firecode is down"
	rc=1
fi

echo "--- stop refuses when no listener is up"
pkill -f "flowy inbox --as $NAME" 2>/dev/null
sleep 1
err=$(FIRECODE_CHAT_PORT=9 bash "$HOOK" stop <<<"$input" 2>&1 >/dev/null)
got=$?
check "exit 2 with no listener" 2 "$got"
if grep -q "inbox --as $NAME" <<<"$err"; then
	echo "ok    names the command to run"
else
	echo "FAIL  refusal did not name the flowy command"
	rc=1
fi

# The discriminating case for that one: it passed while the hook printed a bare
# `flowy`, which is not on PATH here, so the reader got "command not found" and
# read it as the room being broken. Check the binary it names EXISTS.
bin=$(grep -oE '[^ ]*flowy[^ ]* inbox --as' <<<"$err" | head -1 | sed 's/ inbox --as//')
if [[ -n $bin ]] && command -v "$bin" >/dev/null 2>&1; then
	echo "ok    the command it names is runnable: $bin"
else
	echo "FAIL  the refusal names something that will not run: [$bin]"
	rc=1
fi

echo "--- identity: two candidates and no listener means SILENCE, not a guess"
# The self-file lists every name that ever spoke from a directory. Picking the
# first one with a token hands this session somebody else's token and tells it
# to speak as them. With no listener up to say which name is this session, the
# hook must say nothing rather than choose.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/root/runs"
printf '%s\n%s\n' "$NAME" "$NAME-other" >"$tmp/root/runs/chat-self--tmp-hookid"
cp "$AGENTS/$NAME" "$tmp/$NAME" 2>/dev/null
cp "$AGENTS/$NAME" "$tmp/$NAME-other" 2>/dev/null
pkill -f "flowy inbox --as $NAME" 2>/dev/null
sleep 1
out=$(FIRECODE_ROOT="$tmp/root" FLOWY_AGENT_DIR="$tmp" FIRECODE_CHAT_PORT=9 \
	bash "$HOOK" prompt-submit <<<'{"session_id":"t","cwd":"/tmp/hookid"}' 2>/dev/null)
if grep -q "flowy room" <<<"$out"; then
	echo "FAIL  guessed an identity with two candidates and no listener"
	rc=1
else
	echo "ok    silent when it cannot tell which name is this session"
fi

exit "$rc"
