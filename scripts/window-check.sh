#!/usr/bin/env bash
# Is somebody else's gate window open right now?
#
# A HELPER CANNOT SEE A WINDOW DECLARED AFTER IT WAS SPAWNED. That is the whole
# reason this exists. An agent is given the room's state in its brief and never
# again: it declares, checks the queue, sees master unmoved, gates and lands -
# every step correct - while a window opened in the room forty seconds after it
# started. That happened on 2026-08-18 and cost a ten-minute gate run; the
# holds on both sides missed by 40 seconds and 4 seconds respectively, which is
# how you tell a livelock from carelessness.
#
# So the room becomes something a script can ask, rather than something an
# agent had to have been listening for.
#
#   scripts/window-check.sh              - exit 0 clear, 3 somebody holds it
#   scripts/window-check.sh --quiet      - same, no output
#   WINDOW_MINUTES=15                    - how long a declaration is believed
#
# WHAT IT IS NOT: a lock. It reads two signals that are both claims about the
# PAST - the queue's gating flag and what the room said - so a window can open
# in the gap between this answering and the caller acting. It narrows that gap
# from "since I was spawned" to "since a second ago", which is worth having and
# is not the same as being safe. The real fix is a lock on the node, and
# flowy-glm is building one.
#
# IF YOU CHANGE THIS, TELL THE ROOM.
set -u

FLOWY_ADDR=${FLOWY_ADDR:-http://192.168.1.55:8787}
AGENTS=${FLOWY_AGENTS:-$HOME/.config/flowy/agents}
NAME=${BOARD_NAG_NAME:-${FLOWY_AGENT:-claude-host}}
MINUTES=${WINDOW_MINUTES:-15}
QUIET=0
[[ ${1:-} == --quiet ]] && QUIET=1

say() { ((QUIET)) || printf '%s\n' "$*"; }

token=$(cat "$AGENTS/$NAME" 2>/dev/null) || token=""
if [[ -z $token ]]; then
	# NO TOKEN IS NOT A CLEAR WINDOW. Answering 0 here would turn a missing
	# credential into permission to land, which is the failure mode this file
	# is about. Refuse instead.
	say "window-check: no token for $NAME, so nothing can be checked - treat the window as CLOSED"
	exit 3
fi

# THE QUEUE FIRST, because a declared gate is the fleet's own record of one.
# `gating` cannot be trusted alone - a re-gate never sets it, which is a landed
# fix that has not deployed - so the room below is asked as well.
queue=$(curl -sS -m 8 -H "Authorization: Bearer $token" "$FLOWY_ADDR/api/merge-queue" 2>/dev/null) || queue=""
gating=""
if [[ -n $queue ]]; then
	gating=$(jq -r '[.items[]? | select(.gating == true) |
		"\(.branch) (\(.assignee // "unowned"))"] | join(", ")' <<<"$queue" 2>/dev/null) || gating=""
fi

# THEN THE ROOM, which is where a window is actually declared. Matched on the
# word the fleet converged on rather than on a format nobody agreed: DECLARING,
# gating, holding, "nobody ff", "nobody land".
#
# Anything older than WINDOW_MINUTES is ignored: a declaration is a promise
# about the next few minutes, and one from an hour ago is a run that finished
# without anybody saying so.
cutoff=$(date -u -d "-$MINUTES minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || cutoff=""

# THE LOCAL SPOOL, NOT THE ROOM READ. `GET /api/chat/{room}` pages OLDEST
# FIRST, so asking it for forty messages in a room with seven hundred returns
# yesterday morning - the first version of this check read 2026-08-16 and
# reported the window clear, which is the exact failure it exists to prevent.
# A check that answers "clear" from stale data is worse than no check.
#
# The waiter already writes every delivery to a spool, newest last, precisely
# so a message survives being consumed - see `flowy inbox replay`. That file is
# local, cheap, and current to the last poll.
spool="${XDG_RUNTIME_DIR:-$HOME/.cache}/flowy/inbox-spool-$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._-' '-').jsonl"
declared=""
if [[ -r $spool && -n $cutoff ]]; then
	# A WINDOW CAN BE CLOSED, AND THE CLOSE IS THE SAME KIND OF MESSAGE AS THE
	# OPEN. The first version only looked for declarations, so a speaker who
	# declared and then LANDED still read as holding the tip for fifteen
	# minutes - it held the window against everybody for the whole of the time
	# after it had actually been released. A hold that outlives its holder is
	# the stale-gating field one level up, and it is the reason nobody trusts
	# that field.
	#
	# So each speaker is folded to their LAST word: whoever declared and then
	# said they landed, reported, released or stood down is not holding
	# anything. slurped rather than streamed, because that fold needs every
	# message from a speaker at once.
	declared=$(tail -n 200 "$spool" 2>/dev/null | jq -rs --arg me "$NAME" --arg cut "$cutoff" '
		[ .[]
		| select(type == "object")
		| select((.created // "") > $cut)
		| select((.meta.actor_name // "") != $me)
		# AN ACT, NOT A TOPIC. The first version matched any message CONTAINING
		# the word gating, so it fired on "read feat/land-door - NOT a
		# collision", which is the opposite of a declaration. In a room where
		# most messages discuss gating, matching the subject means firing
		# always - and a checker that always fires is one everybody learns to
		# ignore, which is worse than not having it.
		#
		# So: the message must OPEN with a declaration, or contain an explicit
		# hold on landing. A sentence about somebody else declaring does not
		# count, and neither does a report that a gate finished.
		| . as $m
		| ((.body // "")
			| if test("(^|\\n)\\s*(\\w[\\w-]*:\\s*)?(LANDED|RELEASED)\\b"; "i")
			     or test("window released|standing down|hold released|master (is )?now [0-9a-f]{7}"; "i")
			  then "close"
			  elif test("(^|\\n)\\s*(\\w[\\w-]*:\\s*)?(DECLARING|TAKING THE WINDOW|GATE DECLARED)\\b"; "i")
			     or test("nobody (ff|land|lands)|no ff until|hold(ing)? (master|the tip)"; "i")
			  then "open"
			  else "" end) as $kind
		| select($kind != "")
		| {who: ($m.meta.actor_name // "?"), kind: $kind,
		   line: "  \($m.meta.actor_name // "?"): \(($m.body // "") | gsub("\n"; " ") | .[0:110])"} ]
		| group_by(.who) | map(last) | map(select(.kind == "open") | .line) | .[-4:] | join("\n")' 2>/dev/null) || declared=""
fi

if [[ -z ${gating//[[:space:]]/} && -z ${declared//[[:space:]]/} ]]; then
	say "window-check: clear - nothing gating, nothing declared in the last ${MINUTES}m"
	exit 0
fi

say "WINDOW IS NOT YOURS. Somebody else is measuring or has declared one:"
[[ -n ${gating//[[:space:]]/} ]] && say "  queue says gating: $gating"
[[ -n ${declared//[[:space:]]/} ]] && say "$declared"
say ""
say "Do NOT gate or land into this. Wait for their sha, rebase onto it, then go."
say "A verdict measured against a tip that is about to move is worth nothing, and"
say "the run costs ten minutes of somebody's slot."
exit 3
