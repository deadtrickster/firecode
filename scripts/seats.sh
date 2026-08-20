#!/usr/bin/env bash
# Which seats are WORKING, which are QUIET, and which are GONE.
#
#   scripts/seats.sh          every seat the node knows
#   scripts/seats.sh --quiet-ok   exit 0 even if a seat is only quiet
#
# 01M0GHJXB5. A quiet seat and a dead one look identical from a room: neither
# says anything. The difference matters enormously - one is thinking and one
# needs somebody - and the node has known it all along without anybody asking.
#
# THE THREE FACTS /api/presence CARRIES, and what each one alone cannot tell you:
#
#   attached       a reader is REGISTERED. It is not a heartbeat: a waiter that
#                  died leaves this true until something notices.
#   last_poll_at   when that reader last asked the node for messages. THIS is
#                  the heartbeat, and it is what separates registered from
#                  alive.
#   last_acted_at  when the seat last DID something. A seat can poll perfectly
#                  and act on nothing for an hour, which is exactly what "quiet"
#                  means and is not a fault.
#
# So the classification needs all three, and using any one of them alone is how
# three of us spent an evening unable to tell a working fleet from a stalled
# one:
#
#   WORKING   polling, and acted recently
#   QUIET     polling, but nothing done in a while. Alive. Possibly thinking,
#             possibly with nothing to do - the board says which, not this.
#   STALE     registered and NOT polling. The waiter is gone and the node has
#             not noticed yet. This is the one that looks like quiet and is not.
#   ORPHANED  its pid was on THIS host and is no longer running. Same as stale,
#             proved locally rather than inferred from a clock.
#   DETACHED  attached=false. Nothing is listening for that name at all.
#
# THE POLL CLOCK DECIDES, THE PID CORROBORATES - and the first cut of this had
# it the other way round, on the reasoning that `kill -0` is a fact and a
# threshold is a guess. That reasoning is sound and the conclusion was wrong:
# the node records waiter_pid when a waiter ARMS and does not rewrite it on
# every poll, so a seat that re-armed has an old pid on file while a new process
# polls happily. Run once, it called this very seat ORPHANED three seconds after
# that seat had polled.
#
# So a recent poll means alive, whatever the pid says. A dead pid is printed as
# a footnote, because it does mean something - the node would name the wrong
# process to anybody who went looking - just not what it first appeared to.
#
# ONLY TRACKED WAITERS ARE SEATS. The console keeps `cursor` readers of its own
# (overview:inbox) which are not agents and are routinely unattached; counting
# those as a fault makes every run non-zero and the tool becomes noise.
set -uo pipefail

ADDR=${FLOWY_ADDR:-http://192.168.1.55:8787}
AGENTS=${FLOWY_AGENTS:-$HOME/.config/flowy/agents}
ME=${FLOWY_AGENT:-claude-host}
# A poll older than this means the waiter is not running. The inbox deadline is
# 240s and a healthy waiter re-polls immediately, so anything past two of those
# is not a slow round trip - it is an absence.
STALE_AFTER=${SEATS_STALE_AFTER:-500}
# Acting is bursty by nature; this only decides the WORKING/QUIET wording and
# nothing acts on it.
QUIET_AFTER=${SEATS_QUIET_AFTER:-900}

quiet_ok=0
[[ ${1:-} == --quiet-ok ]] && quiet_ok=1

token=$(cat "$AGENTS/$ME" 2>/dev/null) || token=""
if [[ -z $token ]]; then
	echo "seats: no token for '$ME' at $AGENTS/$ME - cannot ask the node." >&2
	echo "  FLOWY_AGENT=<you> $0" >&2
	exit 2
fi

body=$(curl -s -m 10 -H "Authorization: Bearer $token" "$ADDR/api/presence" 2>/dev/null) || body=""
if [[ -z $body ]]; then
	# COULD NOT ASK IS NOT NOBODY HOME. This whole script exists because those
	# two got confused, so it must not confuse them itself.
	echo "seats: $ADDR did not answer - this says NOTHING about who is listening." >&2
	exit 2
fi

# The pid check happens here rather than in the classifier because only this
# machine can do it, and only for seats whose waiter_host is this machine.
host=$(hostname -s 2>/dev/null || echo "")
alive_pids=""
for p in $(printf '%s' "$body" | tr ',' '\n' | sed -n 's/.*"waiter_pid":[[:space:]]*\([0-9]*\).*/\1/p' | sort -u); do
	kill -0 "$p" 2>/dev/null && alive_pids="$alive_pids $p"
done

# The payload goes in a FILE, not on stdin: stdin is already carrying the
# program below, and two redirections competing for it is how the first cut of
# this handed python the JSON as its source. shellcheck named it (SC2261)
# before it ever ran anywhere but here.
payload=$(mktemp -t seats-XXXXXX.json)
trap 'rm -f "$payload"' EXIT
printf '%s' "$body" >"$payload"

SEATS_HOST="$host" SEATS_ALIVE="$alive_pids" SEATS_BODY="$payload" \
	SEATS_STALE="$STALE_AFTER" SEATS_QUIET="$QUIET_AFTER" \
	python3 - "$quiet_ok" <<'PY'
import datetime, json, os, sys

quiet_ok = sys.argv[1] == "1"
here = os.environ.get("SEATS_HOST", "")
alive = set(os.environ.get("SEATS_ALIVE", "").split())
stale_after = int(os.environ.get("SEATS_STALE", "500"))
quiet_after = int(os.environ.get("SEATS_QUIET", "900"))

now = datetime.datetime.now(datetime.timezone.utc)


def age(stamp):
    """Seconds since stamp, or None when there is no stamp at all.

    None is not zero and not infinity - it means the node never recorded one,
    which is a third answer and the callers below keep it separate."""
    if not stamp:
        return None
    try:
        return int((now - datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))).total_seconds())
    except ValueError:
        return None


def ago(seconds):
    if seconds is None:
        return "never"
    if seconds < 90:
        return f"{seconds}s"
    return f"{seconds // 60}m"


with open(os.environ["SEATS_BODY"]) as fh:
    rows = json.load(fh).get("listeners", [])
worst = 0
print(f"{'seat':16} {'state':9} {'polled':>7} {'acted':>7}  why")
for r in sorted(rows, key=lambda x: x.get("reader") or ""):
    name = r.get("reader") or "?"
    # A cursor is the console reading its own overview, not a seat somebody is
    # sitting in. Shown, because hiding it would be its own kind of lie, but
    # never counted as a fault.
    #
    # THE TEST IS "not a cursor", NOT "is tracked", and that is deliberate.
    # waiter_kind takes a THIRD value: measured three times in six seconds,
    # orchestrator reported tracked, then unknown, then unknown. Keying on
    # == "tracked" therefore demoted a live seat to "not a seat" at random,
    # which SILENCES its faults - the dangerous direction. An unknown kind on a
    # named reader is treated as a seat so that a fault still counts.
    is_seat = (r.get("waiter_kind") or "") != "cursor"
    proc = r.get("process") or {}
    pid, phost = proc.get("waiter_pid"), proc.get("waiter_host")
    polled, acted = age(r.get("last_poll_at")), age(r.get("last_acted_at"))

    # A RECENT POLL BEATS A DEAD PID, and the first cut of this had it the other
    # way round - it called claude-host ORPHANED while that seat had polled
    # three seconds earlier. Both facts were true: the node had an OLD
    # waiter_pid recorded and a NEW waiter was polling. The registration's pid
    # is written when a waiter arms and is not re-written by polling, so a dead
    # pid means "that registration is stale", not "nobody is home".
    #
    # So the clock decides liveness and the pid only corroborates. The mismatch
    # is still worth printing - it means the node would name the wrong process
    # if anybody went looking - but it is a footnote, not a verdict.
    pid_gone = bool(pid) and phost == here and str(pid) not in alive
    note = f"  (recorded pid {pid} is gone - stale registration)" if pid_gone else ""

    if not r.get("attached"):
        state, why, sev = "DETACHED", "no reader attached for this name", 2
    elif polled is None:
        state, why, sev = "STALE", "attached and has never polled", 3
    elif polled > stale_after:
        # Poll clock says gone. If the pid agrees, say so - two independent
        # facts pointing the same way is worth more than either alone.
        proof = "and its pid is gone too" if pid_gone else f"(pid {pid} still up - wedged, not dead)" if pid else ""
        state, why, sev = "GONE", f"attached, no poll in {ago(polled)} {proof}".strip(), 3
    elif acted is not None and acted > quiet_after:
        state, why, sev = "quiet", "polling, nothing done lately - alive", 1
    else:
        state, why, sev = "WORKING", "polling and acting", 0
    if not is_seat:
        state, sev = state.lower(), 0
        why += " (a console cursor, not a seat)"
    if sev > worst and not (sev == 1 and quiet_ok):
        worst = sev
    print(f"{name:16} {state:9} {ago(polled):>7} {ago(acted):>7}  {why}{note}")

if not rows:
    print("no listeners at all - which is a fact about the node, not about the seats")
    worst = max(worst, 2)

# 0 everything healthy, 1 somebody is merely quiet, 2 nobody listening for a
# name, 3 a waiter is gone. A caller that only checks "is it 0" still behaves,
# and one that cares about the difference has it.
sys.exit(0 if worst <= 1 and (quiet_ok or worst == 0) else worst)
PY
