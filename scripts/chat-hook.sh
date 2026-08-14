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

# One shot, no waiting: a hook that blocks is a session that hangs.
payload=$(curl -s -m 5 "http://127.0.0.1:$PORT/messages?since=$since&wait=0" 2>/dev/null) || exit 0
[[ -n $payload ]] || exit 0

# shellcheck disable=SC2016  # the single quotes below hold a python program;
# expanding shell variables into it is exactly what must not happen - the
# values it needs arrive through the environment on this line instead.
FIRECODE_HOOK_MARK="$MARK" FIRECODE_HOOK_SELF="$NAME" FIRECODE_HOOK_MODE="$MODE" \
	FIRECODE_HOOK_SELF_FILE="$SELF_FILE" \
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

# Only a mode that can DELIVER is allowed to move the mark.
#
# session-start and prompt-submit put their stdout into the session
# context, so once they have printed a message it has genuinely arrived and
# the cursor should move past it. Stop cannot: its stdout goes to the
# transcript, and its only channel to the session is refusing to stop. A
# Stop hook that advanced the cursor would therefore consume messages it had
# no way to show - which is exactly what happened here, silently, to a
# message that did not happen to mention my name.
#
# So Stop reads and never commits. The cost is that Stop may see the same
# message twice; the cost of the alternative is losing it entirely.
if msgs and mode != "stop":
    try:
        with open(os.environ["FIRECODE_HOOK_MARK"], "w") as fh:
            fh.write(str(d.get("last", 0)))
    except OSError:
        pass

fresh = [m for m in msgs if str(m.get("from", "")).lower() not in selves]
if not fresh:
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

if mode == "stop":
    # Only when somebody is talking TO us.
    #
    # Being in a room where others are talking is not a reason to refuse to
    # finish, so this needs a name, in the message TEXT. The first version
    # blocked on a bare "?" anywhere and searched the whole formatted line,
    # which meant the "from" label counted: it caught a session on its own
    # question and would not let it stop. A question addressed to nobody is
    # not addressed to us.
    addressed = [ln for m, ln in zip(shown, lines)
                 if any(s in str(m.get("text", "")).lower() for s in selves)]
    if not addressed:
        raise SystemExit
    sys.stderr.write(
        "Unanswered in the room, and you are about to go idle:\n"
        + "\n".join(addressed)
        + "\n\nAcknowledge it before you stop - silence reads as absence. "
          "One line is enough: firecode chat --as <name> \"seen, doing X\".\n")
    raise SystemExit(2)                   # 2 = refuse the stop, reason on stderr

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
