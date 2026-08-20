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

# THE WAIT IS THE NODE'S NOW. This loop used to be a poll: read 200 rows, decide
# in jq whether any of them counted as work, sleep, repeat. Both halves of that
# were wrong in the same way - the sleep meant the answer was up to BOARD_EVERY
# seconds old, and the jq was a FIFTH copy of "what counts as work" beside the
# node's, this file's report half, the console's and the drainer's. Four seats
# had already disagreed twice about what `active` means.
#
# GET /api/nag/wait blocks until the counts a seat acts on change and returns at
# once when they do, so the interval below is a ceiling on how long a quiet wait
# lasts rather than a floor on how late the news arrives.
nag_wait() { # cursor, seconds - blocks up to seconds, prints the nag json
	local out
	if out=$(curl -sS --fail -m "$(($2 + 10))" -H "Authorization: Bearer $token" \
		"$FLOWY_ADDR/api/nag/wait?since=$1&window=$2" 2>/dev/null); then
		printf '%s' "$out"
		return 0
	fi
	# A NODE WITHOUT THE DOOR IS NOT A NODE WITHOUT THE ANSWER. /api/nag landed
	# first and answers the same counts, decided in the same place; only the
	# blocking is missing. So an older node degrades to a poll of the node's own
	# arithmetic rather than back to this file deciding for itself - which is
	# the thing that had four seats disagreeing.
	#
	# --fail on both, so a 404 or a 401 is a failure here rather than an error
	# body that parses to zero work and reads as a quiet board.
	sleep "$2"
	curl -sS --fail -m 8 -H "Authorization: Bearer $token" \
		"$FLOWY_ADDR/api/nag" 2>/dev/null
}

if [[ ${1:-} == --watch ]]; then
	waited=0
	cursor=""
	while :; do
		# THE MERGE QUEUE IS ITS OWN QUESTION and it is asked first, because a
		# landable row rots: it stops being landable the moment master moves,
		# and the nag door knows nothing about it.
		queue=$(queue_read)
		ready=$(queue_ready "$queue")
		[[ $ready =~ ^[0-9]+$ ]] && ((ready > 0)) && break

		before=$SECONDS
		nag=$(nag_wait "$cursor" "$BOARD_EVERY")
		# A NODE THAT DID NOT ANSWER IS NOT A QUIET BOARD. Without this the loop
		# spins at curl's failure speed and calls it waiting - and a waiter that
		# burns a core to learn nothing is worse than one that is late.
		if [[ -z $nag ]]; then
			sleep "$BOARD_EVERY"
			waited=$((waited + BOARD_EVERY))
			((waited >= BOARD_DEADLINE)) && exit 1
			continue
		fi
		cursor=$(jq -r '.cursor // ""' <<<"$nag" 2>/dev/null || echo "")
		# WHAT COUNTS AS WORK WAITING FOR THIS SEAT, and every one of these
		# three is the node's count rather than this file's reading of a row:
		# a row nobody is on, a row this seat holds and has not started, and a
		# claim of its own that has gone quiet.
		work=$(jq -r '((.unowned // 0) + (.mine_todo // 0) + (.stale // 0))' \
			<<<"$nag" 2>/dev/null || echo 0)
		[[ $work =~ ^[0-9]+$ ]] && ((work > 0)) && break

		waited=$((waited + SECONDS - before))
		((waited >= BOARD_DEADLINE)) && exit 1 # quiet deadline, like the waiter's
	done
	board=$(board_read)
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

# WHAT THE NODE SAYS, asked once.
#
# The operator, 2026-08-18: "please move the logic of the work nagger to the go
# side and the nagger then will be a simple http call."
#
# Everything below this line used to be computed here: pull 200 rows, decide in
# jq what counts as open, compare `updated` against a threshold this script
# carried, and count assignees. Four seats each held a copy of those rules and
# they had already disagreed twice about what `active` means. GET /api/nag
# answers all of it for the CALLING token, so this asks and prints.
#
# The old jq is not kept as a fallback on purpose. A fallback that computes the
# same thing differently is the disagreement being fixed, waiting for the day
# the door is briefly unreachable.
nag=$(curl -sS -m 8 -H "Authorization: Bearer $token" "$FLOWY_ADDR/api/nag" 2>/dev/null)
if [[ -z $nag ]] || ! jq -e . >/dev/null 2>&1 <<<"$nag"; then
	# A node that cannot be read is not a board with nothing on it, and saying
	# so beats printing zeroes that read as a quiet board.
	printf 'board: the node did not answer /api/nag, so this says nothing about the board\n' >&2
	exit 0
fi
mine=$(jq -r '.mine // 0' <<<"$nag")
free=$(jq -r '.unowned // 0' <<<"$nag")
stale=$(jq -r '.stale // 0' <<<"$nag")
stale_mins=$(jq -r '((.stale_after_seconds // 1200) / 60) | floor' <<<"$nag")
# THE DISTRIBUTION PROBE, printed whenever it is not "ok" - which includes
# "alone" and "empty", because a reader who never sees the line cannot tell a
# balanced board from a probe that is not running.
workload=$(jq -r '
	.workload as $w
	| "board: \($w.open) open, \($w.unowned) with nobody on them"
	+ (if ($w.top // "") != "" then " - most on \($w.top) at \(($w.top_share * 100) | floor)%" else "" end)
	+ (if $w.verdict == "rebalance" then "\nREBALANCE: one seat is past 80% of the open board. The operator asked that this one stop and be spread."
	   elif $w.verdict == "check" then "\ncheck: one seat is past half the open board - worth asking what is going on."
	   elif $w.verdict == "alone" then "\n(one seat carrying all of it, which is the only share it could have)"
	   else "" end)' <<<"$nag")
# ACTIVE IS A CLAIM, NOT AN OBSERVATION - and the node counts it now.
#
# The operator, 2026-08-18: "you did it only after i poked you. so the active
# status is misleading". The rule and the threshold moved into the node with
# everything else (see api_nag.go), which is where they belong: four scripts
# each deciding what `active` means is how two of them came to disagree.
#
# What this file still owns is the WORDING, and it is deliberate. The count
# says a row has had no write, never that nobody is working it - a session
# forty minutes into a gate looks exactly like an abandoned claim from the
# outside, and the honest sentence is the one that says what was seen.

# WHAT THE DRAINER LAST DID, and how long ago.
#
# The operator's ask, 2026-08-18: "then nagger shows last drainer status - thats
# how you catch stalls and errors." The drainer writes one json object at every
# exit (scripts/drain.sh); this reads it and reports the AGE beside the outcome,
# because "landed" from three hours ago and "landed" from a minute ago are the
# same word and different facts.
#
# NO FILE IS ITS OWN ANSWER: a drainer that has never run and one whose status
# file was wiped look identical from here, and both are worth saying out loud
# rather than passing over in silence.
drain_status=""
drain_file=${FLOWY_DRAIN_STATUS:-$HOME/.cache/flowy-drain/status.json}
if [[ -r $drain_file ]]; then
	drain_status=$(jq -r '
		def ago($s): if $s < 90 then "\($s)s ago"
			elif $s < 5400 then "\(($s/60)|floor)m ago"
			else "\(($s/3600)|floor)h ago" end;
		((now - ((.at // "1970-01-01T00:00:00Z") | fromdateiso8601? // 0)) | floor) as $age
		| "drainer: \(.outcome // "?") \(ago($age))"
		+ (if (.row // "") != "" then " on \(.row[0:10])" else "" end)
		+ (if (.branch // "") != "" then " (\(.branch))" else "" end)
		+ (if (.note // "") != "" then " - \((.note|gsub("\n";" "))[0:80])" else "" end)
		+ (if $age > 1800 then "  STALE: nothing has drained in over 30 minutes" else "" end)
		+ (if (.outcome // "") == "deploy-refused" then "  LANDED BUT NOT SERVING: master has moved and the node has not" else "" end)
	' "$drain_file" 2>/dev/null || true)
fi
[[ -n $drain_status ]] || drain_status="drainer: no status file at $drain_file - it has not run, or nothing is running it"

# THE WORKTREES NOBODY REMOVES, pushed rather than pulled - and only when there
# are enough of them to be worth a line.
#
# 01M0E7A4XK asked for the drainer to name landed worktrees in its LANDING
# ANNOUNCEMENT. That puts a list in the room on every land, which is the room
# paying for a fact almost nobody needs at that moment. The nag already runs on
# a schedule and nobody reads it in the middle of something else, so it is the
# right home for a fact that is true all day and urgent on no particular day.
#
# COUNTED, NOT LISTED. The names are one command away, and 61 of them would bury
# everything else this prints. What belongs here is the number and where to look.
#
# THE THRESHOLD IS NOT ZERO. A worktree per branch in flight is how everybody
# here works, so a handful is the system working rather than a leak. This says
# something when the handful has become a habit.
worktree_status=""
if [[ -x $ROOT/scripts/worktrees.sh ]]; then
	wt_landed=$("$ROOT/scripts/worktrees.sh" 2>/dev/null |
		sed -n 's/^LANDED AND CLEAN - \([0-9]*\)\..*/\1/p' | head -1)
	if [[ $wt_landed =~ ^[0-9]+$ ]] && ((wt_landed >= 20)); then
		worktree_status="worktrees: $wt_landed hold a branch already in master with nothing uncommitted."
		worktree_status+=$'\n''            Each is a full checkout and the cost that bites is inodes, not bytes.'
		worktree_status+=$'\n''            Yours are yours to remove: scripts/worktrees.sh names them.'
	fi
fi
[[ $stale =~ ^[0-9]+$ ]] || stale=0
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
	# TERSENESS IS NOT WHERE THE TOKENS GO, MEASURED 2026-08-18: 174 room messages
	# were 54k tokens against 200-350k for a single subagent run, so chat was about
	# 2 percent of a day's spend. The nag used to spend four lines telling people to
	# be brief; that advice was correct, cheap to follow and irrelevant to the bill.
	# What actually costs is a wasted gate and a whole payload pulled into context,
	# so the nag points at those instead.
	printf 'CHEAPEST WINS: gate ONCE - know the host facts and hold the tip first.\n'
	printf 'Read fields, not payloads: scripts/q.sh. Wait, do not poll: scripts/run-wait.sh.\n'
fi

{
	printf 'The room is quiet and the board is not: %d row(s) assigned to %s, %d unowned, all open. %d free VM slot(s).\n' \
		"$mine" "$name" "$free" "$slots"
	printf '%s\n' "$lines"
	[[ -n $qlines ]] && printf 'merge queue (%d landable):\n%s\n' "$ready" "$qlines"
	# The stale line reports WHAT WAS SEEN, never what it means. A session forty
	# minutes into a gate and an abandoned claim are the same row from here.
	if ((stale > 0)); then
		printf '%d of your active row(s) have had no write for over %d minutes - which says nothing about\n' "$stale" "$stale_mins"
		printf 'whether somebody is working them. If one is yours and running, leave a note on it; if it is\n'
		printf 'not, hand it back. A claim nobody can see progress on reads as abandoned to everybody else.\n'
	fi
	printf '%s\n' "$workload"
	printf '%s\n' "$drain_status"
	[[ -n $worktree_status ]] && printf '%s\n' "$worktree_status"
	printf 'Take one, hand one back, or say why not. An idle agent beside an unowned row is the same silence as an unanswered message.\n'
	printf 'Stop this with: touch %s/runs/board-quiet\n' "$ROOT"
} >&2
exit 2
