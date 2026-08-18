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
			# ACTIVE IS NOT WAITING. A row I hold and am working - or that one of
			# my agents is working - is not work waiting for me, and waking on it
			# is a nag every three minutes for the whole length of the job. Only
			# an unowned row, or one of mine that is still sitting at todo,
			# counts as something to be woken for. The merge queue above is
			# separate and does wake on a landable row, because that one rots.
			has=$(jq -r --arg me "$name" '[.artifacts[]? |
				select((.status // "") != "done") |
				select((.status // "") != "active") |
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
	# flowy_bin is the CLI to tell an agent to use, and it must not be a stale one.
	#
	# This printed flowy-next for hours. That binary is from 00:34 and reports
	# 0.8.0+src: it refuses branch/target/gated_tip on mem_write with `unknown
	# field`, so anybody who followed this text could not file a merge request and
	# had no idea why. The deployed `flowy` beside it tracks the node. So the
	# newest of the two wins, measured rather than assumed, and FLOWY_BIN still
	# overrides for anybody running from a checkout.
	flowy_bin() {
		local dir=${FLOWY_LIVE_DIR:-$HOME/Projects/flowy-dogfood} newest=""
		if [[ -n ${FLOWY_BIN:-} ]]; then
			printf '%s\n' "$FLOWY_BIN"
			return
		fi
		# `-nt` rather than `ls -t | head`, which shellcheck is right about and
		# which also answers "the newest of one file" wrong when the other is
		# missing. Two candidates, one comparison, no parsing.
		newest="$dir/flowy"
		[[ -f "$dir/flowy-next" && "$dir/flowy-next" -nt $newest ]] && newest="$dir/flowy-next"
		printf '%s\n' "$newest"
	}

	# ONE ROW EACH IS THE BOTTLENECK, NOT THE BOARD. Every harness here can spawn
	# subagents and every one of us worked strictly serially all night, so eleven
	# rows sat unowned beside four idle agents and seven free VM slots. The
	# operator had to say it out loud before anybody fanned out.
	#
	# So the instruction scales with the backlog rather than always being "take
	# one". Each agent gets its own worktree, claims its own row, and gates in
	# its own VM - a subagent that skips the claim is how two of us put agents on
	# the same console file within ten minutes tonight.
	if ((free > 0)); then
		printf 'YOU HAVE HELPER SLOTS AND %d UNOWNED ROW(S). SPAWNING IS NOT A SPECIAL\n' "$free"
		printf 'OCCASION. Take one yourself and put an agent on each of the rest -\n'
		printf 'working through them one at a time is the bottleneck, not the board.\n'
		printf '%d free VM slot(s) for their gates.\n\n' "$slots"
		printf 'Each agent, without exception:\n'
		printf '  its OWN git worktree, so two of them cannot write the same file\n'
		printf '  its OWN claim WRITTEN TO THE BOARD before it starts, not said in the room\n'
		printf '  its OWN gate run, and its own row in the merge queue\n\n'
	fi
	# CLAIM ON THE BOARD FIRST, AND SAY IT SECOND. That order is not style: three
	# agents spawned onto one row inside ninety seconds tonight because all three
	# announced in chat and only one wrote the assignee. A hook can read the
	# board; nothing can read a sentence in a room. The message is worth sending
	# so a person knows, but it is the second write, not the first.
	printf 'CLAIM IT ON THE BOARD BEFORE YOU START OR SPAWN - the room does not update the board.\n'
	printf 'One command does the claim, refuses if somebody beat you to it, and prints the\n'
	printf 'brief to paste into the helper (the three rules, the row, the queue state):\n'
	printf '  %s/scripts/claim-row.sh --as %s <row id>   # exit 0 = yours, anything else = do not spawn\n' "$ROOT" "$name"
	printf '  %s/scripts/claim-row.sh --as %s/sub-1 <row id>   # for a helper, under its own name\n\n' "$ROOT" "$name"
	printf 'By hand, if you must - but this door is last-write-wins and cannot refuse:\n'
	# `expect` IS WHAT MAKES THIS A CLAIM RATHER THAN A LAST-WRITE-WINS OVERWRITE.
	# Without it the assignee write always succeeds, so two agents claiming the
	# same row within a minute both "succeed" and the second silently takes the
	# first one's work - that happened six times in one night. With expect, the
	# node compares the holder you expected against the holder it has and refuses
	# with a 409 naming the winner, so the loser finds out immediately and can
	# take something else. Send the empty string: you are claiming a row you
	# believe nobody holds.
	printf '  POST %s/api/todo/<row id>/assignee      {"assignee": "%s", "expect": ""}\n' "$FLOWY_ADDR" "$name"
	printf '  POST %s/api/artifact/<row id>/status    {"status": "active"}\n' "$FLOWY_ADDR"
	printf '  a 409 means somebody claimed it first - it names them. take another row.\n\n'
	printf 'Then say it, so a person sees it too:\n'
	printf '  %s say --url %s --room general "%s: taking <row title>"\n\n' \
		"$(flowy_bin)" "$FLOWY_ADDR" "$name"
	printf '%d free VM slot(s) if it needs one. If you are genuinely mid-task, say so in the room and re-arm this watch.\n\n' "$slots"
	# THE TOKENS ARE SHARED. Two of five seats were rate limited for five hours
	# on 2026-08-17 and the operator has asked for terseness three times since.
	# A long room post costs everybody, so it goes in the nag rather than in
	# somebody's memory of being told.
	# CAVEMAN, AS A COMMAND RATHER THAN AN ADJECTIVE.
	#
	# "Be terse" has been in this nag since 2026-08-17 and the operator has now
	# asked seven times, most recently "yeah caveman doesnt survive, i wonder
	# why". It does not survive because remembering is a step somebody takes
	# before every message, and the cost of forgetting lands on the reader.
	#
	# So the nag stops advising and hands over the thing that refuses: say.sh
	# rejects anything over six lines and prints the count. A rule you can
	# forget is a rule; a wrapper that will not send is a mechanism.
	printf 'SAY IT WITH THIS, NOT WITH flowy say:\n'
	printf '  %s/scripts/say.sh "one measurement, one decision"\n' "$ROOT"
	printf 'It REFUSES over six lines. That is the point - three lines is normal, ten is\n'
	printf 'a report and belongs in the row, where somebody can choose to read it.\n'
fi

{
	printf 'The room is quiet and the board is not: %d row(s) assigned to %s, %d unowned, all open. %d free VM slot(s).\n' \
		"$mine" "$name" "$free" "$slots"
	printf '%s\n' "$lines"
	[[ -n $qlines ]] && printf 'merge queue (%d landable):\n%s\n' "$ready" "$qlines"
	printf 'Take one, hand one back, or say why not. An idle agent beside an unowned row is the same silence as an unanswered message.\n'
	# The nag itself must not teach a long room post. It hands over the wrapper
	# that refuses rather than repeating advice that has been ignored seven times.
	printf 'Say it with %s/scripts/say.sh - it REFUSES over six lines.\n' "$ROOT"
	printf 'Stop this with: touch %s/runs/board-quiet\n' "$ROOT"
} >&2
exit 2
