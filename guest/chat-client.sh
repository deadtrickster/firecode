#!/usr/bin/env bash
# firecode-chat - talk to the room from inside a VM.
#
# An unattended run is given no MCP servers at all, so an agent in here looks
# for a chat tool, finds none, and concludes there is no room - which has now
# happened three times, each time to an agent that had something worth saying.
# The room was always reachable: it is plain HTTP on a forwarded port. What
# was missing was a *command*, because that is what an agent goes looking for.
#
#   firecode-chat 'text'          say something
#   firecode-chat --read          what has been said
#   firecode-chat --wait          block until somebody says something new
#   firecode-chat --ask 'text'    ask, and wait for an answer
#
# --ask is the one an unattended run usually wants. It posts the question and
# blocks for a few minutes; if somebody answers, you get their words, and if
# nobody does you are told so and carry on with your own judgement. That is
# better than both alternatives an agent falls into on its own: guessing
# silently, or stopping and reporting that it needed a human.
#
# The name it speaks under comes from FIRECODE_CHAT_NAME, or the VM's own
# name, so a room full of agents is legible.
set -u

PORT=${FIRECODE_CHAT_PORT:-9761}
BASE="http://localhost:$PORT"
WHO=${FIRECODE_CHAT_NAME:-${FIRECODE_ID:-vm}}

usage() {
	sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

# One long poll, printing anything said after `since` that is not our own, and
# remembering how far we read so the next call carries on rather than repeats.
chat_poll() {
	local since=$1 wait=$2
	FIRECODE_CHAT_SELF="$WHO" curl -s -m $((wait + 30)) \
		"$BASE/messages?since=$since&wait=$wait" 2>/dev/null |
		FIRECODE_CHAT_SELF="$WHO" python3 -c '
import json, os, sys, time
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
me = os.environ.get("FIRECODE_CHAT_SELF", "")
for m in d.get("messages", []):
    if m.get("from") == me:
        continue
    print("[%s] %s: %s" % (time.strftime("%H:%M:%S", time.localtime(m["at"])),
                           m["from"], m["text"]))
if d.get("messages"):
    with open("/tmp/firecode-chat.mark", "w") as fh:
        fh.write(str(d.get("last", 0)))
'
}

case "${1:-}" in
-h | --help) usage 0 ;;
--read)
	curl -s -m 20 "$BASE/" || {
		echo "no room on $BASE - carry on and say so in your final answer" >&2
		exit 1
	}
	;;
--wait)
	# From where you last looked, not from the beginning: a mark on disk, so
	# repeated calls are the same command and never replay the room.
	mark=$(cat /tmp/firecode-chat.mark 2>/dev/null || echo 0)
	[[ $mark =~ ^[0-9]+$ ]] || mark=0
	chat_poll "$mark" "${FIRECODE_CHAT_WAIT:-60}"
	;;
--ask)
	shift
	[[ $# -gt 0 ]] || usage 2
	# Ask, then wait for the answer. The point of this command: an unattended
	# run that needs a decision it cannot make has, without it, only two
	# moves - guess, or stop and report that it needed a human. Both are
	# worse than asking and waiting a few minutes.
	before=$(curl -s -m 20 "$BASE/messages?since=0&wait=0" |
		python3 -c 'import json,sys; print(json.load(sys.stdin).get("last", 0))' 2>/dev/null || echo 0)
	"$0" "$@" >/dev/null || exit 1
	echo "asked. waiting up to ${FIRECODE_ASK_WAIT:-300}s for an answer ..." >&2
	waited=0
	while ((waited < ${FIRECODE_ASK_WAIT:-300})); do
		out=$(chat_poll "$before" 60)
		[[ -n $out ]] && {
			printf '%s\n' "$out"
			exit 0
		}
		waited=$((waited + 60))
	done
	echo "nobody answered in ${FIRECODE_ASK_WAIT:-300}s - decide it yourself and say what you chose" >&2
	exit 3
	;;
"")
	usage 2
	;;
*)
	# The message is every argument, so quoting mistakes cost a word rather
	# than the whole post.
	FIRECODE_CHAT_WHO=$WHO FIRECODE_CHAT_TEXT="$*" python3 -c '
import json, os, sys, urllib.request
body = json.dumps({"from": os.environ["FIRECODE_CHAT_WHO"],
                   "text": os.environ["FIRECODE_CHAT_TEXT"]}).encode()
req = urllib.request.Request(sys.argv[1], data=body,
                             headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        print("said it (#%d)" % json.load(r)["id"])
except Exception as exc:
    sys.exit("no room reachable at %s (%s) - carry on without it" % (sys.argv[1], exc))
' "$BASE/say"
	;;
esac
