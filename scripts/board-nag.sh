#!/usr/bin/env bash
# Idle is not done: ask the board, not just the room.
#
# The chat hook nags about messages nobody answered. It cannot see the other two
# ways work stalls here, both measured on 2026-08-17:
#
#   rows sat UNOWNED while four agents were idle, because nothing addressed
#   anybody and silence in the room reads as "nothing to do"
#
#   rows sat OWNED BY AN AGENT THAT COULD NOT ANSWER - two seats were rate
#   limited for five hours holding five open rows, one of them active
#
# SEPARATE SCRIPT ON PURPOSE. The chat hook is stable and carries the message
# loop; a board query that hangs or a jq that dies must not take deliveries with
# it. This one runs as its own Stop hook, and every failure path here exits 0.
#
#   scripts/board-nag.sh          - as a Stop hook, refuses the stop when the
#                                   board has work and the room is quiet
#
# Wire it in as a second Stop hook entry. It never blocks the first one: hooks
# run independently, and this exits 0 unless it has something to say.
set -u

FLOWY_ADDR=${FLOWY_ADDR:-http://192.168.1.55:8787}
AGENTS=${FLOWY_AGENTS:-$HOME/.config/flowy/agents}
ROOT=${FIRECODE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}

# Never twice in a row, and never against the off switch the chat hook already
# honours - two nags arguing with somebody is worse than one.
input=$(timeout 2 cat 2>/dev/null || true)
grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true' <<<"$input" && exit 0
[[ -f "$ROOT/runs/chat-quiet" ]] && exit 0
[[ -f "$ROOT/runs/board-quiet" ]] && exit 0

# Which name is this session. Reuses the memo the chat hook writes, rather than
# guessing: a nag addressed to the wrong agent is worse than no nag.
session=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$input" | head -1)
memo="${FIRECODE_CHAT_MARKS:-$HOME/.cache/firecode}/session-name-$(printf '%s' "${session:-none}" | tr -c 'A-Za-z0-9._-' '-')"
name=$(cat "$memo" 2>/dev/null || echo "")
[[ -n $name && -r "$AGENTS/$name" ]] || exit 0

token=$(cat "$AGENTS/$name" 2>/dev/null) || exit 0
board=$(curl -sS -m 8 -H "Authorization: Bearer $token" \
	"$FLOWY_ADDR/api/artifacts?kind=todo&limit=200" 2>/dev/null) || exit 0
[[ -n $board ]] || exit 0

# open = anything not done. Counted once, so the numbers and the titles below
# cannot disagree with each other.
mine=$(jq -r --arg me "$name" '[.artifacts[]? | select((.status // "") != "done") |
	select((.fields.assignee // "") == $me)] | length' <<<"$board" 2>/dev/null) || exit 0
free=$(jq -r '[.artifacts[]? | select((.status // "") != "done") |
	select(((.fields.assignee // "") | length) == 0)] | length' <<<"$board" 2>/dev/null) || exit 0

[[ $mine =~ ^[0-9]+$ && $free =~ ^[0-9]+$ ]] || exit 0
((mine + free > 0)) || exit 0

lines=$(jq -r --arg me "$name" '[.artifacts[]? | select((.status // "") != "done") |
	select((.fields.assignee // "") == $me or ((.fields.assignee // "") | length) == 0)][0:5][] |
	"  [\(.status // "-")] \(.fields.assignee // "unowned"): \(.title[0:64])"' <<<"$board" 2>/dev/null)

{
	printf 'The room is quiet and the board is not: %d row(s) assigned to %s, %d unowned, all open.\n' \
		"$mine" "$name" "$free"
	printf '%s\n' "$lines"
	printf 'Take one, hand one back, or say why not. An idle agent beside an unowned row is the same silence as an unanswered message.\n'
	printf 'Stop this with: touch %s/runs/board-quiet\n' "$ROOT"
} >&2
exit 2
