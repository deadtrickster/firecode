#!/usr/bin/env bash
# firecode chat, wired into Claude Code's hooks.
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
WAITER=0
WAITER_COUNT=0
WAITER_NAME=""
if [[ -n $SELF_FILE && -f $SELF_FILE ]]; then
	while read -r n; do
		[[ -n $n ]] || continue
		# First name in the file, kept only as the fallback for the rearm
		# line when nothing is listening under any of them.
		[[ -z $WAITER_NAME ]] && WAITER_NAME=$n
		# `|| true`: pgrep exits 1 when it matches nothing, which under
		# set -e plus pipefail would kill the hook on the quiet case.
		pids=$(pgrep -f -- "chat --inbox --as $n" 2>/dev/null) || true
		# Count WAITERS, not processes, and they are not the same number.
		# One healthy waiter shows up as two or three matches: `firecode` is
		# a bash script that re-execs itself, so there is a parent and a
		# child with identical command lines, and arming it through a
		# harness leaves a `bash -c` wrapper whose command line also carries
		# the pattern. Counting lines therefore reports three waiters where
		# there is one, and the too-many warning below fires on a healthy
		# room every single time.
		#
		# So count only the matches whose parent is NOT itself a match -
		# the root of each little tree. Two independent roots is two
		# waiters; a parent and its child is one.
		count=0
		for pid in $pids; do
			ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
			[[ -n $ppid ]] || continue
			grep -qx -- "$ppid" <<<"$pids" || count=$((count + 1))
		done
		if ((count > 0)); then
			WAITER_COUNT=$count
			# The name that matters is the one whose process is actually up,
			# because that is the name whose cursor the waiter is moving.
			# Leaving the first name here instead lets the hook confirm one
			# identity's waiter while keying the mark to another's - two
			# readers, two positions, and a message delivered twice, which
			# is the bug the cursor comment below says was already fixed.
			WAITER_NAME=$n
			WAITER=1
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
for n in ${flowy_candidates[@]+"${flowy_candidates[@]}"}; do
	if pgrep -f -- "flowy inbox --as $n" >/dev/null 2>&1; then
		FLOWY_NAME=$n
		break
	fi
done
if [[ -z $FLOWY_NAME && ${#flowy_candidates[@]} -eq 1 ]]; then
	FLOWY_NAME=${flowy_candidates[0]}
fi

if [[ -n $FLOWY_NAME ]] && command -v jq >/dev/null 2>&1; then
	flowy_token=$(cat "$FLOWY_AGENTS/$FLOWY_NAME" 2>/dev/null) || flowy_token=""
	flowy_payload=""
	[[ -n $flowy_token ]] && flowy_payload=$(curl -s -m 5 \
		-H "Authorization: Bearer $flowy_token" \
		"$FLOWY_ADDR/api/inbox/wait?as=$FLOWY_NAME&window=0&limit=20" 2>/dev/null)

	# Listeners, counted as ROOTS. `flowy inbox` is its own process plus
	# whatever wrapper armed it, so one healthy listener is two or three
	# matches and a naive count fires the too-many warning on a healthy room.
	flowy_pids=$(pgrep -f -- "flowy inbox --as $FLOWY_NAME" 2>/dev/null) || true
	flowy_listeners=0
	for pid in $flowy_pids; do
		ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
		[[ -n $ppid ]] || continue
		grep -qx -- "$ppid" <<<"$flowy_pids" || flowy_listeners=$((flowy_listeners + 1))
	done

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
		flowy_mine=$(jq --arg me "$FLOWY_NAME" \
			'[.[] | select(.addressee_name == $me or .addressee == $me)] | length' \
			<<<"$flowy_events" 2>/dev/null) || flowy_mine=0
		[[ $flowy_mine =~ ^[0-9]+$ ]] || flowy_mine=0
	fi

	flowy_render() {
		jq -r '.[] | "  [" + ((.created // "")[11:16]) + "] " +
			(.actor_name // .meta.actor_name // (.actor // "?")[-8:]) +
			(if (.room // "") != "" then " in #" + .room else "" end) + ": " +
			((.body // "") | gsub("\n"; " ") | .[0:160])' <<<"$flowy_events" 2>/dev/null
	}

	if ((flowy_total > 0)); then
		FLOWY_DELIVERY=$(printf 'flowy room (%s) - %s message(s) waiting:\n%s\nRead them with: %s inbox --as %s --deadline 3600\n' \
			"$FLOWY_NAME" "$flowy_total" "$(flowy_render)" "$FLOWY_BIN" "$FLOWY_NAME")
	fi

	if [[ $MODE == stop ]]; then
		if ((flowy_listeners == 0)); then
			# shellcheck disable=SC2016  # the $(cat ...) is a command for the
			# reader to run, printed verbatim. Expanding it here would put the
			# token into the message and into the transcript.
			FLOWY_REASON=$(printf 'Nothing is listening to the FLOWY room while you are idle. Start it as a BACKGROUND command:\n  FLOWY_TOKEN=$(cat %s/%s) %s inbox --as %s --url %s --deadline 3600\nIt returns when somebody speaks - 0 with the event, 1 on a quiet deadline, 2 broken - and that return is what wakes you. Arm it again each time it fires.' \
				"$FLOWY_AGENTS" "$FLOWY_NAME" "$FLOWY_BIN" "$FLOWY_NAME" "$FLOWY_ADDR")
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
elif mode == "stop" and waiter_name and not waiter:
    rearm = (
        "\n\nNothing is listening for you while you are idle. Start the "
        "waiter before you stop:\n"
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
if mode == "stop" and flowy_reason:
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
    print("Other agents on this machine share a room, and you are in it. "
          "Say something with: firecode chat --as <name> \"text\". "
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
