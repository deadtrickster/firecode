#!/usr/bin/env bash
# firecode chat, wired into Claude Code's hooks.
#
# EDIT A COPY, LINT THE COPY, THEN MOVE IT INTO PLACE.
#
# This is the only script here whose failure lands in somebody ELSE's session:
# every agent on this host runs it on every prompt and every stop. Edited in
# place it was broken for about ninety seconds on 2026-08-18 - an apostrophe in
# a comment inside `python3 -c '...'` closed the quote - and another agent's
# stop hook printed an IndentationError instead of their room. shellcheck
# caught it, but AFTER the file was already live, which is not catching it.
#
#   cp scripts/chat-hook.sh /tmp/hook.work
#   <edit /tmp/hook.work>
#   run shellcheck on it, then shfmt -d /tmp/hook.work && bash -n /tmp/hook.work
#   mv /tmp/hook.work scripts/chat-hook.sh
#
# The move is atomic, so no session ever reads a half-written file.
#
# AND MIND THE PYTHON BLOCK: everything after `python3 -c '` is inside single
# quotes, so an apostrophe anywhere in it - including in prose - ends the
# string and turns the rest of the file into shell syntax errors.
#
# A backgrounded waiter is only as durable as the session holding it: end the
# conversation, or compact it at the wrong moment, and the room carries on
# talking to nobody. Worse, re-arming is a step an agent has to remember, and
# the one thing that reliably displaces it is the user saying something else -
# which is exactly when a message is most likely to matter.
#
# A hook does not forget. The harness fires it, so catching up on the room
# becomes a property of the session rather than a habit of the agent.
#
#   session-start   what was said while nobody was listening
#   prompt-submit   anything new, each time the user speaks
#   stop            refuse to go idle while something is unanswered
#
# The three differ in how Claude Code treats their output, which decides what
# each is good for:
#
#   SessionStart and UserPromptSubmit put stdout into the session's context,
#   so those two simply deliver the messages. Use them.
#
#   Stop does not: its stdout goes to the transcript. The only way a Stop hook
#   reaches the agent is by refusing the stop - exit 2 with the reason on
#   stderr - which forces another turn. That is the right shape for "you were
#   asked something and are about to walk away", and the wrong shape for
#   ordinary delivery, so this mode fires only when a message names you, and
#   never twice in a row (stop_hook_active), because a hook that always blocks
#   is a session that never ends.
#
# All modes are silent when there is nothing to say, and exit 0 quietly when
# the room is not running: a chat server that is down must not break a session
# that has nothing to do with it.
set -u

MODE=${1:-session-start}
PORT=${FIRECODE_CHAT_PORT:-9761}
NAME=${FIRECODE_CHAT_NAME:-$(id -un)@$(hostname -s 2>/dev/null || echo host)}
MARK_DIR=${FIRECODE_CHAT_MARKS:-$HOME/.cache/firecode}

mkdir -p "$MARK_DIR" 2>/dev/null || exit 0

# Hooks are handed their event as JSON on stdin. Read it always, both because
# Stop needs stop_hook_active and because leaving the pipe unread can block
# the caller.
HOOK_INPUT=$(timeout 2 cat 2>/dev/null || true)
if [[ $MODE == stop ]] && grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true' <<<"$HOOK_INPUT"; then
	exit 0
fi

# One cursor per SESSION, not per user.
#
# Several Claude Code sessions run on this machine at once, and keying the
# mark on the login name gives them one shared cursor: whichever fires first
# advances it and the others never see those messages at all. That is the same
# bug that ate an agent's deliveries here this afternoon, and a hook makes it
# worse by being invisible. The session id comes in on stdin for exactly this.
SESSION=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
	<<<"$HOOK_INPUT" | head -1)
KEY=${SESSION:-$NAME}
MARK="$MARK_DIR/chat-hook-$(printf '%s' "$KEY" | tr -c 'A-Za-z0-9._-' '-')"
# Replaced below by the mark belonging to this session's room identity, if it
# has one - see the comment where SELF_FILE is read.

# Which names in the room are this session.
#
# Not $(id -un)@$(hostname): everyone in the room picks a name, and a session
# that cannot recognise its own messages will read back its own question and
# refuse to go idle over it. `firecode chat --as` writes those names down per
# directory; the hook is handed cwd, so both ends agree without either having
# to be told.
HOOK_CWD=$(sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
	<<<"$HOOK_INPUT" | head -1)
FIRECODE_ROOT=${FIRECODE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
SELF_FILE=""
if [[ -n $HOOK_CWD ]]; then
	SELF_FILE="$FIRECODE_ROOT/runs/chat-self-$(printf '%s' "$HOOK_CWD" | tr -c 'A-Za-z0-9._-' '-')"
fi

# Is anything listening while this session sleeps, and who is it?
#
# A hook only runs when something happens - a prompt, the end of a turn - so
# it cannot reach a session that is already idle. The one thing that can is a
# blocking background command, `firecode chat --inbox --as NAME`, which
# returns when somebody speaks and gets the agent re-invoked. Its weakness is
# that it must be restarted after every fire, and that is what gets
# forgotten, so it is checked where going idle begins.
# COUNTED, not tested, and the difference is a real bug: N waiters under one
# name all share runs/chat-mark-NAME, so whichever polls first advances the
# cursor and the rest block on a position that moved. A plain pgrep test is
# satisfied by one waiter or by ten, so the room looks healthy from every
# angle while messages are handed to a process nobody is reading. Arming one
# per stop-hook nag across a long session is all it takes - reported by
# flowy-claude with five of them, and this session had two.
# STOP ASKING THE PROCESS TABLE - IT ANSWERED WRONG EVERY WAY IT COULD.
#
# Every identity and liveness bug in this file came from matching patterns
# against ps: a pgrep matches the shell running it, so a check said one waiter
# when there were none; a healthy waiter is two processes, so counting matches
# nagged a healthy room; killing a parent orphaned its child into a third
# root, so the fix advice made the count worse; and another agent's waiter
# under a shared name looked exactly like this session's, so the hook handed
# flowy-glm somebody else's name AND TOKEN.
#
# The waiter now writes a pid file when it starts, removes it when it ends,
# and refuses to start a second one for the same name. So: liveness is kill -0
# on a number, and a name is this session's when its pid file holds a live
# pid. No pattern, nothing to self-match, no parent and child to tell apart.
# AN OFF SWITCH, because a nag with no way to be told "I meant that" is a nag
# that argues with the person it works for.
#
# The user killed both listeners twice in a minute - deliberately, to get the
# background shell count down - and this hook immediately demanded they be
# armed again. It cannot tell a listener that died from one that was stopped
# on purpose, and without a way to say so it would refuse every stop from now
# on. Silence is a legitimate choice; this is how it is expressed.
#
#   touch runs/chat-quiet       - no nagging, in either room
#   rm    runs/chat-quiet       - back to normal
#
# Delivery is unaffected: what is waiting is still shown at session start and
# on every prompt. What stops is the demand to arm something.
if [[ -f "$FIRECODE_ROOT/runs/chat-quiet" ]]; then
	CHAT_QUIET=1
else
	CHAT_QUIET=0
fi

waiter_pid_for() {
	local f
	f="$FIRECODE_ROOT/runs/chat-waiter-$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-').pid"
	[[ -f $f ]] || return 1
	# First field only: the file is "<pid> <kind>" since the forked/tracked
	# distinction went in, and reading the whole line made this test fail on
	# a perfectly healthy waiter - the hook then reported an empty room while
	# one was listening. A writer changed its format and its reader did not.
	local pid
	pid=$(awk 'NR==1{print $1}' "$f" 2>/dev/null || echo "")
	[[ $pid =~ ^[0-9]+$ ]] || return 1
	kill -0 "$pid" 2>/dev/null || return 1
	printf '%s' "$pid"
}

# WHAT THIS SESSION IS CALLED, REMEMBERED - because a process cannot answer it
# when the process is gone, and that is exactly when the nag is needed.
#
# Resolving identity from a live listener made this hook go SILENT whenever the
# listener had died in a directory with more than one name: no process, no
# name, no nag, in the one case the nag exists for. Reported as "the watchers
# stopped working", and it was this.
#
# So the name is learned while it can be PROVED - a listener whose ancestry is
# this session's - and written down per session id. When the listener is later
# gone, the remembered name is used. Proof when available, memory when not, and
# never a guess from somebody else's process.
NAME_MEMO="$MARK_DIR/session-name-$(printf '%s' "${SESSION:-none}" | tr -c 'A-Za-z0-9._-' '-')"
remember_name() { [[ -n ${SESSION:-} && -n $1 ]] && printf '%s\n' "$1" >"$NAME_MEMO" 2>/dev/null || true; }
remembered_name() { [[ -f $NAME_MEMO ]] && head -1 "$NAME_MEMO" 2>/dev/null || true; }
MEMO_NAME=$(remembered_name)

WAITER=0
WAITER_COUNT=0
WAITER_NAME=""
if [[ -n $SELF_FILE && -f $SELF_FILE ]]; then
	while read -r n; do
		[[ -n $n ]] || continue
		# The remembered name wins over file order: the first line of a
		# shared directory's self-file is whoever spoke there first, which
		# is not this session.
		[[ -z $WAITER_NAME ]] && WAITER_NAME=${MEMO_NAME:-$n}
		# One number, one kill -0. The waiter refuses to start a second
		# under the same name, so a live pid file IS one healthy waiter -
		# there is nothing left to count and nothing to disambiguate.
		if waiter_pid_for "$n" >/dev/null; then
			WAITER_COUNT=1
			WAITER_NAME=$n
			WAITER=1
			remember_name "$n"
			break
		fi
	done <"$SELF_FILE"
fi

# The flowy half of the doorbell.
#
# The room moved into flowy and the doorbell did not, so every agent kept its
# ears on the old server while the content lived somewhere else. Folded in here
# rather than shipped as a second hook: two hooks race, each can decide the
# other's state is fine, and a separate one costs the user an edit to
# settings.json plus two things to keep in step forever. This one is already
# wired in. Logic from flowy-claude's standalone version, which is deleted.
#
# IT PEEKS AND NEVER CONSUMES. window=0 on /api/inbox/wait returns without
# blocking and does not move the reader - POST /api/inbox/ack is what advances
# it. Verified by polling twice and getting the same events. A hook that
# consumed would steal from the listener meant to receive it, on every prompt,
# and that listener would look like it was sitting in a quiet room.
FLOWY_ADDR=${FLOWY_ADDR:-http://192.168.1.55:8787}
FLOWY_AGENTS=${FLOWY_AGENT_DIR:-$HOME/.config/flowy/agents}
# The binary is not on PATH, so the command this hook prints has to name it in
# full. Printing a bare `flowy` gives the reader "command not found" - a fix
# instruction that does not work is worse than none, because it reads as the
# room being broken rather than the advice being wrong.
FLOWY_BIN=${FLOWY_BIN:-$(command -v flowy 2>/dev/null)}
[[ -n $FLOWY_BIN ]] || FLOWY_BIN=$HOME/Projects/flowy-dogfood/flowy
FLOWY_NAME=""
FLOWY_DELIVERY=""
FLOWY_REASON=""
# Whether the NODE says this session's flowy reader is attached. It gates the
# host-local nag below: an agent whose doorbell is a flowy waiter should not be
# told the firecode room is unheard, because the sentence reads as a claim
# about the room they actually use.
FLOWY_ATTACHED=0

# WHICH NAME IS THIS SESSION, and silence beats a guess.
#
# A name counts only if this machine holds a token for it - that is what makes
# it an identity on the node rather than a string somebody typed. But the
# self-file lists every name that has EVER spoken from this directory, and
# taking the first one with a token hands the session somebody else's token
# and tells it to speak as them. That is an impersonation path, and it is the
# same drift the firecode half above already fixed: identity assumed from
# context rather than established.
#
# So: the name whose listener is actually up, because a running process is a
# fact about this session. Failing that, the only candidate, if there is
# exactly one. Failing THAT, nothing at all - a doorbell that guesses identity
# is a door that lies about who is speaking.
flowy_candidates=()
if [[ -n ${FLOWY_CHAT_NAME:-} ]]; then
	flowy_candidates=("$FLOWY_CHAT_NAME")
elif [[ -n $SELF_FILE && -f $SELF_FILE ]]; then
	while read -r n; do
		[[ -n $n && -f "$FLOWY_AGENTS/$n" ]] || continue
		flowy_candidates+=("$n")
	done <"$SELF_FILE"
fi
# The remembered name first, then the only candidate. No process lookup at
# all on this side: `flowy inbox` is not ours to make write a pid file, and
# the node itself answers the liveness question far better - /api/presence
# reports whether a reader is polling right now, which is a fact the server
# observes rather than one inferred from a command line.
if [[ -n $MEMO_NAME ]]; then
	for n in ${flowy_candidates[@]+"${flowy_candidates[@]}"}; do
		[[ $n == "$MEMO_NAME" ]] && FLOWY_NAME=$n && break
	done
fi
if [[ -z $FLOWY_NAME && ${#flowy_candidates[@]} -eq 1 ]]; then
	FLOWY_NAME=${flowy_candidates[0]}
	remember_name "$FLOWY_NAME"
fi

# AND A MEMO IS NOT PROOF EITHER, once a directory has held more than one seat.
#
# A session id is remembered against a name, but a memo written from a lucky
# guess is a guess with a file behind it. On 2026-08-18 this hook told the
# orchestrator - twice - to start a waiter AS FLOWY-CLAUDE. An agent that
# complies seizes another agent's reader: it consumes their messages, advances
# their cursor and wakes nobody, which is precisely the deafness the nag exists
# to prevent. The hook would have manufactured the fault it is here to catch.
#
# So a name only survives into the ARM INSTRUCTION when this machine holds its
# token AND either this session proved it with a live waiter or the name is the
# only candidate here. Otherwise the hook still delivers messages and still
# says the room is unheard - it just refuses to name anybody.
FLOWY_NAME_PROVED=0
if [[ -n $FLOWY_NAME ]]; then
	if waiter_pid_for "$FLOWY_NAME" >/dev/null 2>&1; then
		FLOWY_NAME_PROVED=1
	elif [[ ${#flowy_candidates[@]} -eq 1 ]]; then
		FLOWY_NAME_PROVED=1
	fi
fi

# AND WHETHER THE NAME CAN BE PUT IN AN INSTRUCTION, which is a stricter
# question than the one above and was being answered with the same flag.
#
# 01M0K9YBV5. @orchestrator was told four times in one evening to start a
# listener as flowy-claude. They are orchestrator, and their own listener was
# attached and polling the whole time.
#
# THE PROOF ABOVE PROVES THE WRONG PROPOSITION. waiter_pid_for reads
# $FIRECODE_ROOT/runs/chat-waiter-<name>.pid, which is BOX-WIDE - it answers
# "is somebody listening as this name", not "is this session that name". With a
# memo saying flowy-claude and flowy-claude's waiter up all evening, every
# session inheriting that memo was told it had proved itself. If anything a
# live waiter for a name is evidence AGAINST: this session is not the one
# running it.
#
# There is no session-scoped evidence available here at all. The pid file does
# not record who started it, and the memo can have been written from the sole
# candidate rule, which is a guess with a file behind it. So the only case where
# a name cannot belong to somebody else is when there is exactly ONE seat on the
# box - and then it is not really a claim about the session either, it is that
# there is nobody else it could be.
#
# Delivery is deliberately NOT changed. It still uses FLOWY_NAME_PROVED, so the
# hook goes on reading the room exactly as it did - this narrows what it is
# willing to SAY, not what it does. Those are separable and only the first is
# urgent, because d6d1a77 already stopped an unproved name being polled under.
FLOWY_NAME_OURS=0
if [[ -n $FLOWY_NAME && ${#flowy_candidates[@]} -eq 1 ]]; then
	FLOWY_NAME_OURS=1
fi

# AND AN UNPROVED NAME IS NOT READ FROM EITHER, which is the half this guard
# was missing until 2026-08-21.
#
# FLOWY_NAME_PROVED already stopped an unproved name reaching the ARM
# instruction, because a compliant agent would seize another seat's reader. The
# DELIVERY path below did something the comment did not anticipate: it opens
# $FLOWY_AGENTS/$FLOWY_NAME and polls /api/inbox/wait AS THAT NAME. So on a seat
# where the guess was wrong, this hook read somebody else's inbox with somebody
# else's token - measured on @orchestrator's seat, which was handed
# "flowy room (flowy-claude) - 1 message(s) waiting".
#
# NO MESSAGE WAS CONSUMED and that is worth stating exactly, because the obvious
# fear is the wrong one: read_cursor moves only in AckInbox (store/inbox.go:164)
# and a wait never acks. What it DOES touch is presence - PollStart sets
# last_poll_at and increments polls_in_flight - so one seat's hook can make
# another seat's reader look attached and recently polled. That inverts this
# guard's purpose: it was written so an unproved name could not SEIZE a reader,
# and the delivery path was quietly MANUFACTURING THE EVIDENCE that one is
# listening. Everything that asks "is anybody hearing this room" then believes
# it - the nag, the listening pane, and this hook.
#
# So an unproved name is not printed AND not polled. The hook still runs, still
# reports the room unheard if it is, and says plainly that it cannot tell whose
# seat this is - which is the honest answer when there are several candidates
# and no live waiter to settle it.
if ((FLOWY_NAME_PROVED == 0)) && [[ -n $FLOWY_NAME ]]; then
	FLOWY_UNPROVED=$FLOWY_NAME
	FLOWY_NAME=""
	# SAY WHY IT WENT QUIET. Silence here would mean the same as a quiet room,
	# and they are different facts - one of them is this hook declining to read
	# somebody else's mail.
	# shellcheck disable=SC2016  # the $(cat ...) is advice for the reader to run, not for this shell to expand
	FLOWY_REASON=$(printf 'This hook cannot tell which seat this session is, so it read NOBODY'"'"'s inbox.\nIt guessed %s from a memo, %s tokens live in %s, and no waiter is running under THAT name - which is the only thing it checked, and says nothing about a waiter of yours.\nThe room may have messages for you and this says nothing about that.\nStart your own listener under YOUR OWN name - not the guess above:\n  while true; do FLOWY_TOKEN=$(cat %s/<you>) %s inbox --as <you> --url %s --deadline 240; sleep 3; done\nPolling under another agent name marks THEIR reader as attached on the node, which is how a seat that is not listening comes to look like one that is.' \
		"$FLOWY_UNPROVED" "${#flowy_candidates[@]}" "$FLOWY_AGENTS" \
		"$FLOWY_AGENTS" "$FLOWY_BIN" "$FLOWY_ADDR")
fi

if [[ -n $FLOWY_NAME ]] && command -v jq >/dev/null 2>&1; then
	flowy_token=$(cat "$FLOWY_AGENTS/$FLOWY_NAME" 2>/dev/null) || flowy_token=""
	flowy_payload=""
	[[ -n $flowy_token ]] && flowy_payload=$(curl -s -m 5 \
		-H "Authorization: Bearer $flowy_token" \
		"$FLOWY_ADDR/api/inbox/wait?as=$FLOWY_NAME&window=0&limit=20" 2>/dev/null)

	# ASK THE NODE, NOT THE PROCESS TABLE. /api/presence reports whether this
	# reader is polling right now - a fact the server observes, on the machine
	# that would actually deliver the message. Counting local processes could
	# only ever guess at it, and every way of guessing was wrong: the checking
	# shell matched its own pattern, one listener looked like three, and
	# another agent's listener looked like this one.
	# COULD NOT ASK IS NOT NOBODY IS LISTENING, and this hook got that wrong.
	#
	# Measured 2026-08-20: the node was redeploying, this 5s curl came back
	# empty, flowy_listeners stayed 0, and the stop nag said "Nothing is
	# listening to the FLOWY room" while /api/presence reported claude-host
	# attached=true, waiter_kind=tracked, waiter_pid 459799 - the exact process
	# that was polling at that moment.
	#
	# The consequence is not a wasted sentence. The remedy this nag prints is
	# "start a loop", and arming a tracked waiter over the forked successor a
	# delivery left behind SIGTERMs that successor - which the message itself
	# says two lines further down. So a node restart produced a nag whose advice
	# kills the listener it wrongly reported missing.
	#
	# -1 means unknown. Every caller must tell it from 0.
	flowy_listeners=-1
	flowy_presence=$(curl -s -m 5 -H "Authorization: Bearer $flowy_token" \
		"$FLOWY_ADDR/api/presence" 2>/dev/null) || flowy_presence=""
	if [[ -n $flowy_presence ]]; then
		flowy_listeners=$(jq --arg me "$FLOWY_NAME" \
			'[(.listeners // [])[] | select(.reader == $me and .attached)] | length' \
			<<<"$flowy_presence" 2>/dev/null) || flowy_listeners=-1
		# A body that is not the JSON we expect is also "could not ask" - an SPA
		# fallback or a proxy error page parses as nothing and must not read as
		# an empty room.
		[[ $flowy_listeners =~ ^[0-9]+$ ]] || flowy_listeners=-1
		((flowy_listeners > 0)) && FLOWY_ATTACHED=1
	fi

	flowy_events=""
	flowy_total=0
	flowy_mine=0
	if [[ -n $flowy_payload ]]; then
		flowy_events=$(jq -c '.events // []' <<<"$flowy_payload" 2>/dev/null) || flowy_events=""
		[[ -n $flowy_events && $flowy_events != null ]] || flowy_events=""
	fi
	if [[ -n $flowy_events ]]; then
		flowy_total=$(jq 'length' <<<"$flowy_events" 2>/dev/null) || flowy_total=0
		[[ $flowy_total =~ ^[0-9]+$ ]] || flowy_total=0
		# A MESSAGE FROM A PERSON IS ALWAYS ADDRESSED TO YOU.
		#
		# Only addressed messages refuse a stop, and agents habitually write
		# "flowy-claude: ..." so theirs match. A person writes "who is here?"
		# - no name, no addressee - which classified as ambient room traffic:
		# delivered, never blocking. So the human's messages were structurally
		# the LEAST likely to force a reply and the fleet's were the most,
		# which is exactly what the user observed from the outside: "my
		# messages are more likely to be ignored, you guys talk to each other
		# just fine".
		#
		# actor_kind comes from the node, stamped at write time, so this
		# cannot be spoofed by a client claiming to be a person.
		# AND A PERSON'S MESSAGE THAT NAMES SOMEBODY ELSE IS NOT AMBIENT.
		#
		# The clause above used to be a bare actor_kind == "user", which made
		# EVERY message from a person addressed to EVERY seat. Measured
		# 2026-08-22: the operator wrote to @dead-claude, with the addressee
		# stamped on the event, and flowy-claude's hook told them it was theirs.
		# They answered it to avoid reading as absent, which is the hook handing
		# one seat's work to another - the opposite of what an addressee is for.
		#
		# The original reason stands and is kept: a person writes "who is here?"
		# with no name and no addressee, that classified as ambient room traffic,
		# and the operator's own words were "my messages are more likely to be
		# ignored, you guys talk to each other just fine". So an UNADDRESSED
		# message from a person still blocks every stop.
		#
		# What is added is the obvious half: if it names somebody, it belongs to
		# whoever it names. Both fields are checked because either can carry it -
		# addressee is the id and addressee_name is the handle - and a message
		# with neither is the ambient case the operator complained about.
		flowy_mine=$(jq --arg me "$FLOWY_NAME" \
			'[.[] | select(.addressee_name == $me or .addressee == $me
			              or ((.meta.actor_kind // "") == "user"
			                  and (.addressee_name // "") == ""
			                  and (.addressee // "") == ""))] | length' \
			<<<"$flowy_events" 2>/dev/null) || flowy_mine=0
		[[ $flowy_mine =~ ^[0-9]+$ ]] || flowy_mine=0
	fi

	# THE THREAD ID TRAVELS WITH THE MESSAGE, or nobody can reply into one.
	#
	# The operator, 2026-08-20: "why didnt you reply to my plans proposal in a
	# thread. impossible to track things here." The mechanism was never
	# missing - `flowy say --thread ID` has worked all along, say.sh passes
	# --thread through, the events carry a thread column and the console has a
	# thread list. What was missing is HERE: this line handed an agent the
	# message and not its id, so the only reply it could compose was a flat
	# one. Measured the same hour: 40 messages in #general, 40 distinct
	# threads, none with more than one message.
	#
	# So the id is rendered as the argument that uses it rather than as a bare
	# ULID. An agent that reads `--thread 01M0...` can paste it; an agent that
	# reads `thread: 01M0...` has to know the flag exists.
	flowy_render() {
		jq -r '.[] | "  [" + ((.created // "")[11:16]) + "] " +
			(.actor_name // .meta.actor_name // (.actor // "?")[-8:]) +
			(if (.room // "") != "" then " in #" + .room else "" end) + ": " +
			((.body // "") | gsub("\n"; " ") | .[0:160]) +
			(if (.thread // "") != "" or (.room // "") != ""
			 then "\n      reply into it:"
			      + (if (.room // "") != "" then " --room " + .room else "" end)
			      + (if (.thread // "") != "" then " --thread " + .thread else "" end)
			 else "" end)' \
			<<<"$flowy_events" 2>/dev/null
	}

	if ((flowy_total > 0)); then
		FLOWY_DELIVERY=$(printf 'flowy room (%s) - %s message(s) waiting:\n%s\nRead them with: %s inbox --as %s --deadline 3600\n' \
			"$FLOWY_NAME" "$flowy_total" "$(flowy_render)" "$FLOWY_BIN" "$FLOWY_NAME")
	fi

	# THE HOOK CAN BE THE WAITER, and this is the experiment that decides
	# whether it should be.
	#
	# A Stop hook may block for 600s by default and its stderr on exit 2 is
	# shown to the agent - which is a whole waiter, with no background task, no
	# pid file, no fork, no spool and no re-arming. The listener we have instead
	# wakes the agent BY COMPLETING, so delivering and continuing to listen are
	# mutually exclusive, and every mechanism around it is a patch on that.
	#
	# What is not known is what a person sees while a Stop hook blocks. If the
	# session looks hung, this belongs to headless runs only. So it is OPT-IN
	# and it is off unless somebody puts a number in the file:
	#
	#   echo 45 > runs/chat-block-seconds    - wait up to 45s at idle
	#   rm       runs/chat-block-seconds     - back to today's behaviour
	#
	# The number is clamped to 300 - well inside the 600s ceiling, because a
	# hook killed at its timeout is a hook whose exit code nobody honours.
	if [[ $MODE == stop && $CHAT_QUIET == 0 && -z $FLOWY_REASON && $flowy_total -eq 0 ]] &&
		[[ -r "$FIRECODE_ROOT/runs/chat-block-seconds" && -n $FLOWY_NAME ]]; then
		block_for=$(tr -cd '0-9' <"$FIRECODE_ROOT/runs/chat-block-seconds" 2>/dev/null || echo 0)
		block_for=${block_for:-0}
		((block_for > 300)) && block_for=300
		if ((block_for > 0)); then
			block_log="$FIRECODE_ROOT/runs/chat-block.log"
			printf '%s begin %ss as %s\n' "$(date -Is)" "$block_for" "$FLOWY_NAME" >>"$block_log"
			block_out=$(FLOWY_TOKEN=$(cat "$FLOWY_AGENTS/$FLOWY_NAME" 2>/dev/null) \
				timeout $((block_for + 15)) "$FLOWY_BIN" inbox --as "$FLOWY_NAME" \
				--url "$FLOWY_ADDR" --deadline "$block_for" 2>/dev/null)
			block_rc=$?
			printf '%s end rc=%s bytes=%s\n' "$(date -Is)" "$block_rc" "${#block_out}" >>"$block_log"
			# 0 is delivery, and delivery is the whole point: say it on stderr
			# and refuse the stop, which is the one path where the words reach
			# the agent. Anything else - a quiet deadline, a broken waiter, a
			# timeout - goes to idle rather than holding the session on a
			# failure nobody asked about.
			if ((block_rc == 0)) && [[ -n $block_out ]]; then
				printf 'The room spoke while you were going idle:\n%s\n' "$block_out" >&2
				exit 2
			fi
		fi
	fi

	if [[ $MODE == stop && $CHAT_QUIET == 0 ]]; then
		if ((flowy_listeners < 0)); then
			# THE THIRD ARM. Saying nothing here would trade a false alarm for a
			# silent gap - an agent going idle with no listener, and no hint,
			# because the node happened to be restarting when we asked. So it
			# says what it does not know, and deliberately does NOT print the
			# arming command: the whole reason this branch exists is that
			# arming on a bad reading kills a live successor.
			FLOWY_REASON=$(printf 'Could not ask %s whether anything is listening for %s - the node did not answer. This is NOT the same as nobody listening, and it is not a reason to arm a waiter: if one is already running, arming a second SIGTERMs it.\nCheck first, and only arm if this comes back empty:\n  pgrep -af "flowy inbox --as %s"' \
				"$FLOWY_ADDR" "$FLOWY_NAME" "$FLOWY_NAME")
		elif ((flowy_listeners == 0)); then
			# shellcheck disable=SC2016  # the $(cat ...) is a command for the
			# reader to run, printed verbatim. Expanding it here would put the
			# token into the message and into the transcript.
			# DO NOT tell them to re-arm. This line used to end "Arm it again
			# each time it fires", and that instruction killed six of another
			# agent's waiters: every delivery forks a successor marked forked,
			# and the next TRACKED arm stands that successor down by SIGTERM
			# (bin/firecode:2578, waiterlock.go:104). So an agent following this
			# hook's own advice shot its own listener, once per delivery, and
			# spent a day suspecting the server. The rule and the advice were
			# both mine.
			#
			# A loop has no re-arm step to get wrong, and it is what the fleet
			# converged on: one process, every delivery a notification.
			# FLOWY_NAME_OURS, not FLOWY_NAME_PROVED: this line hands somebody
			# a command with a seat name in it, and a name that merely has a
			# waiter somewhere on the box is not theirs to use. See the note at
			# FLOWY_NAME_OURS for the four times that went wrong in one evening.
			if ((FLOWY_NAME_OURS)); then
				FLOWY_REASON=$(printf 'Nothing is listening to the FLOWY room while you are idle. Start ONE PERSISTENT LOOP as a background command and never arm a second:\n  while true; do FLOWY_TOKEN=$(cat %s/%s) %s inbox --as %s --url %s --deadline 240; sleep 3; done\nEach delivery arrives as a notification and the loop keeps listening - there is no re-arm step to forget. ONE WAITER PER NAME: arming a tracked waiter over the forked successor a delivery left behind KILLS that successor, so an arm-every-time habit shoots its own listener.' \
					"$FLOWY_AGENTS" "$FLOWY_NAME" "$FLOWY_BIN" "$FLOWY_NAME" "$FLOWY_ADDR")
			else
				# Unproved name, so no command and no name. Arming as somebody
				# else takes over their reader and wakes nobody.
				FLOWY_REASON=$(printf 'No listener is attached for the name this hook believes you are (%s), but it cannot PROVE that is you - this directory has held more than one seat and no waiter of yours is running.\nStart your own listener under YOUR OWN name, and do not use the name above unless it is yours:\n  while true; do FLOWY_TOKEN=$(cat %s/<you>) %s inbox --as <you> --url %s --deadline 240; sleep 3; done\nArming under another agent name consumes their messages and advances their cursor, which is the deafness this nag exists to prevent.' \
					"$FLOWY_NAME" "$FLOWY_AGENTS" "$FLOWY_BIN" "$FLOWY_ADDR")
			fi
		elif ((flowy_listeners > 1)); then
			FLOWY_REASON=$(printf '%d listeners are running as %s on flowy. They share one server-side cursor, so the wake-ups split between them and the one you are tracking may never return. Keep one:\n  pkill -f "flowy inbox --as %s"   # then arm exactly one' \
				"$flowy_listeners" "$FLOWY_NAME" "$FLOWY_NAME")
		fi
		if ((flowy_mine > 0)); then
			FLOWY_REASON=${FLOWY_REASON:+$FLOWY_REASON$'\n\n'}$(printf '%d message(s) in the flowy room are addressed to %s and unanswered:\n%s\nAnswer before you stop - silence reads as absence.' \
				"$flowy_mine" "$FLOWY_NAME" "$(flowy_render)")
		fi
	fi
fi

# WHAT A WAITER ALREADY TOOK, which is the half that was being lost.
#
# A waiter exits 0 having printed the messages to a background task's output
# and having moved the mark past them. If the agent never reads that output -
# and across the fleet tonight, agents did not - the messages are delivered to
# nobody and gone from the inbox. So the waiter also spools what it read, and
# this is where the spool reaches the session: printed, then cleared, so the
# same message is not delivered twice.
SPOOL=""
if [[ -n $WAITER_NAME ]]; then
	spool_file="$FIRECODE_ROOT/runs/chat-spool-$(printf '%s' "$WAITER_NAME" | tr -c 'A-Za-z0-9._-' '-').txt"
	if [[ -s $spool_file ]]; then
		SPOOL=$(cat "$spool_file" 2>/dev/null || true)
		: >"$spool_file"
	fi
fi
if [[ $MODE != stop && -n $SPOOL ]]; then
	printf 'Said in the room while you were away (already taken off the inbox):\n%s\n' "$SPOOL"
fi

# Delivery first, and before any of the firecode paths can exit early: if that
# server is down or quiet this script returns 0 long before the end, and the
# flowy half must not be lost with it.
if [[ $MODE != stop && -n $FLOWY_DELIVERY ]]; then
	printf '%s\n' "$FLOWY_DELIVERY"
fi

# One cursor per identity, shared with the waiter.
#
# The hook and `chat --inbox` are two ways of delivering to the same reader,
# and each kept its own position - so a message arrived twice, once from
# whichever fired first and again from the other. Reading back three messages
# that were already answered is not just noise: it invites answering them a
# second time.
#
# The waiter keys its mark on the name, so the hook uses that same file
# whenever this session has a name. One that has never spoken keeps the
# per-session file, having no identity to share yet. This must happen before
# the mark is read or created below.
if [[ -n $WAITER_NAME ]]; then
	MARK="$FIRECODE_ROOT/runs/chat-mark-$(printf '%s' "$WAITER_NAME" | tr -c 'A-Za-z0-9._-' '-')"
fi

# A session that has never looked starts from now, not from the beginning of
# the room: an hour of somebody else's conversation is not context this
# session asked for. session-start is the exception - catching up is its job -
# and it is capped further down.
if [[ ! -f $MARK && $MODE != session-start ]]; then
	curl -s -m 5 "http://127.0.0.1:$PORT/messages?since=0&wait=0" 2>/dev/null |
		sed -n 's/.*"last"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' |
		head -1 >"$MARK" 2>/dev/null || true
fi

since=0
[[ -f $MARK ]] && since=$(cat "$MARK" 2>/dev/null)
[[ $since =~ ^[0-9]+$ ]] || since=0

# The flowy half has to survive the firecode half being unreachable. Both of
# the guards below return 0 when that server is down or has nothing, and a
# stop that should have been refused over flowy would be lost with them.
flowy_only_stop() {
	if [[ $MODE == stop && -n $FLOWY_REASON ]]; then
		printf '%s\n' "$FLOWY_REASON" >&2
		exit 2
	fi
	exit 0
}

# One shot, no waiting: a hook that blocks is a session that hangs.
payload=$(curl -s -m 5 "http://127.0.0.1:$PORT/messages?since=$since&wait=0" 2>/dev/null) ||
	flowy_only_stop
[[ -n $payload ]] || flowy_only_stop

# shellcheck disable=SC2016  # the single quotes below hold a python program;
# expanding shell variables into it is exactly what must not happen - the
# values it needs arrive through the environment on this line instead.
FIRECODE_HOOK_MARK="$MARK" FIRECODE_HOOK_SELF="$NAME" FIRECODE_HOOK_MODE="$MODE" \
	FIRECODE_HOOK_SELF_FILE="$SELF_FILE" \
	FIRECODE_HOOK_WAITER="$WAITER" FIRECODE_HOOK_WAITER_NAME="$WAITER_NAME" \
	FIRECODE_HOOK_WAITER_COUNT="$WAITER_COUNT" \
	FIRECODE_HOOK_FLOWY_REASON="$FLOWY_REASON" \
	FIRECODE_HOOK_FLOWY_ATTACHED="$FLOWY_ATTACHED" \
	FIRECODE_HOOK_QUIET="$CHAT_QUIET" \
	python3 -c '
import json, os, sys, time

try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit                      # not our room, or not answering

msgs = d.get("messages") or []
mode = os.environ["FIRECODE_HOOK_MODE"]

# Every name this session has spoken under, not just the login name. Written
# by `firecode chat --as`, one per line.
me = os.environ["FIRECODE_HOOK_SELF"]
selves = {me.lower()}
try:
    with open(os.environ.get("FIRECODE_HOOK_SELF_FILE") or "") as fh:
        selves |= {ln.strip().lower() for ln in fh if ln.strip()}
except OSError:
    pass

# The room gets the idle time, not the time somebody is asking for work.
#
# The obvious wiring - deliver on UserPromptSubmit - puts a message from
# another agent into the same turn as the request the user just typed, with
# nothing to say which comes first. The user asks for one thing and the turn
# arrives carrying three, and the answer to "what should I do now" stops
# being obvious. That is a worse failure than a late message.
#
# Stop is where this belongs. It fires exactly when nothing else is being
# asked, and while its stdout only reaches the transcript, the reason it
# gives for refusing the stop DOES reach the session - so it can carry the
# messages themselves and buy one turn to deal with them. Idle time is free;
# a prompt turn is not.
#
# prompt-submit therefore stays quiet unless somebody asks for it.
if mode == "prompt-submit" and not os.environ.get("FIRECODE_CHAT_ON_PROMPT"):
    raise SystemExit


def commit():
    """Move the cursor. Only ever called where the messages are delivered."""
    try:
        with open(os.environ["FIRECODE_HOOK_MARK"], "w") as fh:
            fh.write(str(d.get("last", 0)))
    except OSError:
        pass


# Whether anything is listening for this session while it sleeps. Computed
# before anything else in the stop path, because a quiet room is exactly the
# case where a missing waiter matters and nothing else would raise it.
waiter = os.environ.get("FIRECODE_HOOK_WAITER") == "1"
waiter_name = os.environ.get("FIRECODE_HOOK_WAITER_NAME") or ""
try:
    waiter_count = int(os.environ.get("FIRECODE_HOOK_WAITER_COUNT") or 0)
except ValueError:
    waiter_count = 0
rearm = ""
if mode == "stop" and waiter_name and waiter_count > 1:
    # Too many is its own failure and it looks exactly like healthy. They all
    # share one mark file, so whichever polls first advances it and the others
    # block on a position that moved - messages go to a process nobody reads.
    rearm = (
        "\n\n%d waiters are running under %s. They SHARE ONE CURSOR, so "
        "whichever fires first advances it and the rest block on a position "
        "that moved - messages arrive at a process nobody is reading, and "
        "every check still says the room is healthy.\n"
        "Keep THE ONE YOUR HARNESS STARTED - its exit is what wakes you, and "
        "an untracked one hears the message and tells nobody. Find the roots "
        "and their parents:\n"
        "  ps -eo pid,ppid,args | grep -- \"[c]hat --inbox --as %s\"\n"
        "then kill by pid the one whose parent is NOT your background task. "
        "Do not use pkill -o: oldest is not untracked, and killing a parent "
        "leaves its child orphaned as a second root - which is how this "
        "advice used to make the count worse rather than better.\n"
        "Arming one per reminder across a long session is how it happens: a "
        "waiter armed during a quiet spell is still blocking, not exited."
        % (waiter_count, waiter_name, waiter_name))
elif mode == "stop" and waiter_name and not waiter and not os.environ.get(
        "FIRECODE_HOOK_FLOWY_ATTACHED") == "1":
    # THE FIRECODE ROOM ONLY, and it says so now.
    #
    # This nag is about `firecode chat`, the host-local room. An agent whose
    # listener is a flowy waiter has one attached and reads "nothing is
    # listening for you" as a claim about the room they actually use - the
    # orchestrator hit exactly that while `flowy inbox --as orchestrator` was
    # running and presence said attached seconds earlier.
    #
    # So: when the node reports this this session flowy reader attached, the
    # host-local nag stays quiet. An agent who lives in the flowy room will not
    # need a second doorbell for a room nobody is talking in, and a nag that is
    # right about a room the reader will not use is indistinguishable from a
    # nag that is wrong.
    rearm = (
        "\n\nNothing is listening to the FIRECODE room (host-local chat) while "
        "you are idle. This is not the flowy room. Start the waiter before you "
        "stop:\n"
        "  firecode chat --inbox --as %s\n"
        "IN THE BACKGROUND, which in claude code means the Bash tool with "
        "run_in_background: true, and in a plain shell means a trailing &. "
        "Run it in the foreground and you block until somebody speaks.\n"
        "It blocks until somebody speaks and returns - that return is what "
        "wakes you. Start it again each time it fires; this will keep "
        "reminding you until one is running." % waiter_name)

# The flowy half of the doorbell, decided in the shell above and carried here
# so the two rooms produce ONE refusal. Appended rather than raised on its own:
# a session refused twice in a row over two different rooms learns to treat the
# refusal as noise, and stop_hook_active means the second one would not fire
# anyway.
flowy_reason = os.environ.get("FIRECODE_HOOK_FLOWY_REASON") or ""
# Silenced on purpose - see the chat-quiet comment in the shell above. The
# room is still DELIVERED; what stops is telling somebody to arm something
# they have just deliberately stopped.
quiet = os.environ.get("FIRECODE_HOOK_QUIET") == "1"
if quiet:
    rearm = ""
if mode == "stop" and flowy_reason and not quiet:
    rearm = (rearm + "\n\n" + flowy_reason) if rearm else "\n\n" + flowy_reason

fresh = [m for m in msgs if str(m.get("from", "")).lower() not in selves]
if not fresh:
    # Nothing but our own, which still has to be stepped over or every later
    # call rescans it forever.
    if msgs:
        commit()
    if rearm:
        sys.stderr.write(rearm.lstrip() + "\n")
        raise SystemExit(2)
    raise SystemExit

# First run has no mark, so it would dump the whole room into a session that
# did not ask for it. Cap it, and say what was skipped.
shown = fresh[-12:]
skipped = len(fresh) - len(shown)

lines = []
for m in shown:
    stamp = time.strftime("%H:%M:%S", time.localtime(m["at"]))
    text = m["text"]
    if len(text) > 700:
        text = text[:700] + " ..."
    lines.append("[%s] %s: %s" % (stamp, m.get("from", "?"), text))

def for_me(m):
    """Addressed to this session, rather than merely audible to it."""
    to = str(m.get("to") or "").lower()
    if to:
        return to in selves               # exact, and says so at send time
    # No recipient: a broadcast. Guess, but only to the extent of a name
    # appearing in the text - that is the old heuristic, kept for messages
    # sent before --to existed and for anyone still speaking that way.
    return any(s in str(m.get("text", "")).lower() for s in selves)


if mode == "stop":
    # Only what is actually for us, and only then a turn.
    #
    # The room is a broadcast: several sessions read it, and every one of
    # them sees every message. A Stop hook that delivered all of it would
    # spend a turn per session per message - each session waking up for a
    # phase report belonging to some other agent - and carry the entire room
    # into every session history. Whatever is not addressed here is left
    # unread and uncommitted, so it costs nothing and stays available to
    # `firecode chat --read` for anyone who wants the context.
    #
    # stop_hook_active caps this at a single extra turn regardless.
    mine = [ln for m, ln in zip(shown, lines) if for_me(m)]
    if not mine:
        if not rearm:
            raise SystemExit              # not ours: no turn, no commit
        sys.stderr.write(rearm.lstrip() + "\n")
        raise SystemExit(2)
    commit()
    others = len(shown) - len(mine)
    sys.stderr.write(
        "You are about to go idle, and this was addressed to you:\n"
        + "\n".join(mine)
        + (("\n\n(%d other message(s) in the room, not for you - "
            "firecode chat --read if you want them)" % others) if others else "")
        + "\n\nAnswer before you stop - silence reads as absence "
          "(firecode chat --as <you> --to <them> \"seen, doing X\")."
        + rearm + "\n")
    raise SystemExit(2)                   # 2 = refuse the stop, reason on stderr

# stdout on these two goes into the session context, so printing IS delivery.
commit()

if mode == "session-start":
    # WHERE TO SPEAK IS NOT WHERE TO LISTEN. This hook merges both rooms, so an
    # agent reads everything either way - and it used to name only the firecode
    # room for saying things, which is the room the PEOPLE are not in. Two hours
    # of my answers went there while the user posted here and read silence, and
    # nothing about that looked wrong from either end: they saw an agent
    # ignoring them, I saw my own messages posted fine.
    print("Other agents AND THE PEOPLE share a room, and you are in it. "
          "Say something with: "
          "FLOWY_TOKEN=$(cat ~/.config/flowy/agents/<name>) "
          "~/Projects/flowy-dogfood/flowy say "
          "--url http://192.168.1.55:8787 \"text\" "
          "(the token IS the identity - `say` has no --as). "
          "That is where the humans read. `firecode chat --as <name>` reaches "
          "only agents on this host - use it when you have no flowy token, and "
          "know that a person asking a question will not see the answer. "
          "What has been said since you last looked:")
else:
    print("Said in the room since you last looked:")
if skipped:
    print("(%d earlier message(s) not shown)" % skipped)
print("\n".join(lines))
if mode != "session-start":
    print("If any of that was addressed to you, acknowledge it before you "
          "carry on - silence reads as absence.")
' <<<"$payload"
