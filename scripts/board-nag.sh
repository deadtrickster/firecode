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
# IF YOU CHANGE THIS, TELL THE ROOM. Every agent here can run it, and a tool
# nobody knows about is a tool nobody uses - two rescue scripts were written
# four times over on 2026-08-17 because their authors never said they existed.
# Post what it is and how to wire it in, once, when it changes.
#
# Wire it in as a second Stop hook entry. It never blocks the first one: hooks
# run independently, and this exits 0 unless it has something to say.
set -u

FLOWY_ADDR=${FLOWY_ADDR:-http://192.168.1.55:8787}
AGENTS=${FLOWY_AGENTS:-$HOME/.config/flowy/agents}
ROOT=${FIRECODE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}

# Never twice in a row, and never against the off switch the chat hook already
# honours - two nags arguing with somebody is worse than one.
input=""
[[ ${1:-} == --notify ]] || input=$(timeout 2 cat 2>/dev/null || true)
grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true' <<<"$input" && exit 0
[[ -f "$ROOT/runs/chat-quiet" ]] && exit 0
[[ -f "$ROOT/runs/board-quiet" ]] && exit 0

# Which name is this session. Reuses the memo the chat hook writes, rather than
# guessing: a nag addressed to the wrong agent is worse than no nag.
session=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$input" | head -1)
# A timer has no session to read, so it is told which name to speak as.
[[ -z $session && -n ${BOARD_NAG_NAME:-} ]] && session=""
memo="${FIRECODE_CHAT_MARKS:-$HOME/.cache/firecode}/session-name-$(printf '%s' "${session:-none}" | tr -c 'A-Za-z0-9._-' '-')"
name=${BOARD_NAG_NAME:-$(cat "$memo" 2>/dev/null || echo "")}
[[ -n $name && -r "$AGENTS/$name" ]] || exit 0

token=$(cat "$AGENTS/$name" 2>/dev/null) || exit 0

# WATCH MODE BLOCKS. A background task that returns immediately wakes its agent
# immediately and every time, which is a spinning nag rather than a signal. It
# sleeps between reads and only returns when the board actually has something,
# or when the deadline runs out - the same three outcomes `flowy inbox` has, so
# an agent can treat both the same way.
BOARD_EVERY=${BOARD_EVERY:-120}
BOARD_DEADLINE=${BOARD_DEADLINE:-3600}
board_read() {
	curl -sS -m 8 -H "Authorization: Bearer $token" \
		"$FLOWY_ADDR/api/artifacts?kind=todo&limit=200" 2>/dev/null
}

# THE MERGE QUEUE IS WORK TOO, and it is the kind that rots: a branch measured
# green stops being green the moment master moves, so a row sitting admissible
# is a gate run somebody is about to have to repeat. Anybody with access to the
# code may land one - it does not have to be the author.
#
# `decided:false` means no verdict was possible at all, so `admissible` under it
# says nothing. Only count a row ready when the queue actually decided.
queue_read() {
	curl -sS -m 8 -H "Authorization: Bearer $token" \
		"$FLOWY_ADDR/api/merge-queue" 2>/dev/null
}
queue_ready() { # rows that can land right now
	jq -r 'if (.decided // false) then [.items[]? | select(.admissible == true)] | length else 0 end' \
		<<<"${1:-}" 2>/dev/null || echo 0
}

if [[ ${1:-} == --watch ]]; then
	waited=0
	while :; do
		board=$(board_read)
		queue=$(queue_read)
		ready=$(queue_ready "$queue")
		[[ $ready =~ ^[0-9]+$ ]] && ((ready > 0)) && break
		if [[ -n $board ]]; then
			has=$(jq -r --arg me "$name" '[.artifacts[]? |
				select((.status // "") != "done") |
				select((.fields.assignee // "") == $me or ((.fields.assignee // "") | length) == 0)] |
				length' <<<"$board" 2>/dev/null || echo 0)
			[[ $has =~ ^[0-9]+$ ]] && ((has > 0)) && break
		fi
		((waited >= BOARD_DEADLINE)) && exit 1 # quiet deadline, like the waiter's
		sleep "$BOARD_EVERY"
		waited=$((waited + BOARD_EVERY))
	done
else
	board=$(board_read)
	queue=$(queue_read)
	ready=$(queue_ready "$queue")
fi

# The queue lines, built once so the counts and the titles cannot disagree.
# gating=true is a run measuring that branch RIGHT NOW - shown because starting
# a second gate on the same tip is the waste this queue exists to prevent.
qlines=""
if [[ -n ${queue:-} ]]; then
	qlines=$(jq -r '[.items[]? | select((.status // "") != "done")][0:5][] |
		"  " + (if .admissible == true then "LANDABLE" elif (.gating // false) then "gating  " else "blocked " end)
		+ " \(.branch // "?") -> \(.target // "?")  (\(.assignee // "unowned"))"' <<<"$queue" 2>/dev/null)
fi
[[ -n $board ]] || exit 0

# open = anything not done. Counted once, so the numbers and the titles below
# cannot disagree with each other.
mine=$(jq -r --arg me "$name" '[.artifacts[]? | select((.status // "") != "done") |
	select((.fields.assignee // "") == $me)] | length' <<<"$board" 2>/dev/null) || exit 0
free=$(jq -r '[.artifacts[]? | select((.status // "") != "done") |
	select(((.fields.assignee // "") | length) == 0)] | length' <<<"$board" 2>/dev/null) || exit 0

[[ $mine =~ ^[0-9]+$ && $free =~ ^[0-9]+$ ]] || exit 0
[[ ${ready:-0} =~ ^[0-9]+$ ]] || ready=0
# A landable branch counts on its own. An empty board with a green row waiting
# to land is not a quiet night - it is a gate run about to be thrown away.
((mine + free + ready > 0)) || exit 0

lines=$(jq -r --arg me "$name" '[.artifacts[]? | select((.status // "") != "done") |
	select((.fields.assignee // "") == $me or ((.fields.assignee // "") | length) == 0)][0:5][] |
	"  [\(.status // "-")] \(if ((.fields.assignee // "") | length) == 0 then "unowned" else .fields.assignee end): \(.title[0:64])"' <<<"$board" 2>/dev/null)
# `// "unowned"` only catches null, and a row HANDED BACK carries "" rather than
# null - so a released row printed as "[todo] :" and read like a display glitch
# instead of like the free row it is. Seen within a minute of the first handback
# tonight.

# HOW MUCH CAPACITY THERE IS, because "take a row" is useless advice when every
# slot is busy, and an agent that starts a run into a full host gets a VM that
# cannot create its tap. A slot is free when its tap is quiet AND its lock can
# be taken - carrier alone says idle while a run holds the slot through setup
# and teardown, which is how a half-idle host measured full tonight.
slots=0
for tap in /sys/class/net/fccode*/carrier; do
	[[ -r $tap ]] || continue
	[[ $(cat "$tap" 2>/dev/null) == 0 ]] || continue
	slot=${tap#/sys/class/net/fccode}
	slot=${slot%/carrier}
	lock="$ROOT/state/net/$slot.lock"
	if [[ ! -e $lock ]] || flock -n "$lock" true 2>/dev/null; then
		slots=$((slots + 1))
	fi
done

# WATCH MODE: THE SAME SIGNAL THE WAITER USES, not a message in the room.
#
# A Stop hook only fires when a turn ENDS, so it cannot reach an agent that is
# already idle - which is the whole population this is for. Posting to the room
# would reach them, and would also reach everybody else: a board reminder is not
# news, and the room is where people talk.
#
# So it does what `flowy inbox` does. Run as a BACKGROUND TASK it blocks until
# the board has something, then EXITS - and the harness wakes its agent because
# a tracked task completed. One agent, no message, no spam.
#
#   board-nag.sh              hook mode: refuse the stop, reason on stderr
#   board-nag.sh --watch      background task: block until the board has work
#
# Arm it beside the room waiter:
#   BOARD_NAG_NAME=<you> scripts/board-nag.sh --watch
if [[ ${1:-} == --watch ]]; then
	# SAY WHAT TO DO, NOT WHAT IS TRUE. The first version printed counts, and
	# the agent that wrote it - me - read "12 unowned rows" as a status line and
	# went idle in the same turn. A report is something you note; an instruction
	# is something you carry out, and only one of those changes what happens
	# next. The operator caught it within minutes.
	printf 'WORK IS WAITING FOR %s AND YOU ARE IDLE. Do this now, before anything else:\n\n' "$name"
	printf '%s\n\n' "$lines"
	if [[ -n $qlines ]]; then
		printf 'MERGE QUEUE (%d landable). A LANDABLE row is the first thing to do - it\n' "$ready"
		printf 'goes stale the moment the target moves, and anybody may land it:\n'
		printf '%s\n\n' "$qlines"
	fi
	# ONE ROW EACH IS THE BOTTLENECK, NOT THE BOARD. Every harness here can spawn
	# subagents and every one of us worked strictly serially all night, so eleven
	# rows sat unowned beside four idle agents and seven free VM slots. The
	# operator had to say it out loud before anybody fanned out.
	#
	# So the instruction scales with the backlog rather than always being "take
	# one". Each agent gets its own worktree, claims its own row, and gates in
	# its own VM - a subagent that skips the claim is how two of us put agents on
	# the same console file within ten minutes tonight.
	if ((free > 2)); then
		printf 'TAKE ONE YOURSELF AND SPAWN AN AGENT PER ROW FOR THE REST. %d rows are\n' "$free"
		printf 'unowned and you have %d free VM slot(s) - working through them one at a\n' "$slots"
		printf 'time is the bottleneck, not the board. Each agent: its OWN git worktree,\n'
		printf 'its OWN claim written to the board BEFORE it starts, its own gate run.\n\n'
	fi
	printf 'Pick ONE row above and claim it in the room before you start:\n'
	printf '  %s say --url %s "%s: taking <row title>"\n\n' \
		"${FLOWY_BIN:-$HOME/Projects/flowy-dogfood/flowy-next}" "$FLOWY_ADDR" "$name"
	# TWO WRITES, AND BOTH ARE REQUIRED. Saying "taking this" in the room changes
	# nothing on the board: I claimed a row out loud at 22:30 and the watch still
	# offered it to me an hour later, because the row was never written. The
	# endpoints below are the ones the server actually has - the first version of
	# this text invented a single POST that answers `unknown field "id"`.
	printf 'Then WRITE the claim - the room does not update the board:\n'
	printf '  POST %s/api/todo/<row id>/assignee      {"assignee": "%s"}\n' "$FLOWY_ADDR" "$name"
	printf '  POST %s/api/artifact/<row id>/status    {"status": "active"}\n\n' "$FLOWY_ADDR"
	printf '%d free VM slot(s) if it needs one. If you are genuinely mid-task, say so in the room and re-arm this watch.\n' "$slots"
	exit 0
fi

{
	printf 'The room is quiet and the board is not: %d row(s) assigned to %s, %d unowned, all open. %d free VM slot(s).\n' \
		"$mine" "$name" "$free" "$slots"
	printf '%s\n' "$lines"
	[[ -n $qlines ]] && printf 'merge queue (%d landable):\n%s\n' "$ready" "$qlines"
	printf 'Take one, hand one back, or say why not. An idle agent beside an unowned row is the same silence as an unanswered message.\n'
	printf 'Stop this with: touch %s/runs/board-quiet\n' "$ROOT"
} >&2
exit 2
