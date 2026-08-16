#!/usr/bin/env bash
# firecode agent entrypoint - runs the requested agent inside the microVM.
# Started by firecode-agent.service, which only runs when the host asked for
# an unattended run (that is, when the control drive carries an args file).
set -u

CTL_MNT=/opt/firecode/run

log() { echo "[firecode] $*"; }

# Prefer the copy the harness shipped on the control drive, so a fix here
# does not need the rootfs image rebuilt.
if [[ -x $CTL_MNT/agent-entrypoint.sh && -z ${FIRECODE_REEXEC:-} ]]; then
	export FIRECODE_REEXEC=1
	exec "$CTL_MNT/agent-entrypoint.sh"
fi

# shellcheck source=/dev/null
[[ -f $CTL_MNT/env ]] && . "$CTL_MNT/env"

AGENT=${FIRECODE_AGENT:-claude}
RUN_USER=${FIRECODE_USER:-root}
RUN_HOME=${FIRECODE_HOME:-/root}
PROJECT=${FIRECODE_PROJECT:-$PWD}

declare -a ARGS=()
if [[ -f $CTL_MNT/args ]]; then
	mapfile -d '' -t ARGS <"$CTL_MNT/args"
fi

if ! command -v "$AGENT" >/dev/null 2>&1; then
	log "ERROR: $AGENT is not installed in the guest."
	log "The config drive should carry it at /opt/firecode/config/bin/$AGENT."
	# shellcheck disable=SC2012  # human-readable diagnostic, not parsed
	ls -la /opt/firecode/config/bin 2>&1 | sed 's/^/[firecode] /'
	exit 127
fi

# The agent owns the console while it runs. Done here rather than with a
# Conflicts= in the unit, which systemd acts on when the job is queued and so
# also fired on interactive runs, where this unit is skipped entirely.
systemctl stop serial-getty@ttyS0.service 2>/dev/null || true

cd "$PROJECT" 2>/dev/null || cd "$RUN_HOME" || exit 1

log "running as $RUN_USER in $(pwd): $AGENT ${ARGS[*]}"
echo

# Claude Code refuses --dangerously-skip-permissions as root unless it is
# told it is in a sandbox. It is: that is the entire point of this harness.
declare -a ENV=(
	"HOME=$RUN_HOME"
	"USER=$RUN_USER"
	"LOGNAME=$RUN_USER"
	"IS_SANDBOX=1"
	"FIRECODE=1"
	"TERM=${TERM:-dumb}"
	"PATH=/opt/mise/shims:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
	"MISE_DATA_DIR=/opt/mise"
	"MISE_CONFIG_DIR=/opt/mise/config"
	"MISE_STATE_DIR=/opt/mise/state"
	"MISE_CACHE_DIR=/var/cache/mise"
)

# Authenticating through the host rather than with a copied token. Set only
# when the run asked for it, because pointing an agent at a base URL that is
# not there fails every call rather than falling back to anything.
if [[ -n ${ANTHROPIC_BASE_URL:-} ]]; then
	ENV+=("ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL")
	# A placeholder, not a secret. The client refuses to start with no
	# credentials at all - "Not logged in, please run /login" - before it ever
	# makes a request, so it needs something to hold. The relay strips whatever
	# arrives and authenticates with the host's own token, so what this says
	# does not matter and is worth nothing if it leaves the VM.
	ENV+=("ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-firecode-relay-placeholder}")
	log "model API reached through the host - no real credentials in this VM"
fi

# Model names, when this client is pointed somewhere that has never heard of
# opus or sonnet. Sourced from the control drive rather than exported, so they
# have to be carried into the agent's environment explicitly.
for v in ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
	ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL; do
	[[ -n ${!v:-} ]] && ENV+=("$v=${!v}")
done
# A key for an endpoint that is not anthropic. AUTH_TOKEN and not API_KEY:
# with both set the client warns about conflicting credentials and may pick
# the wrong one.
if [[ -n ${ANTHROPIC_AUTH_TOKEN:-} ]]; then
	ENV+=("ANTHROPIC_AUTH_TOKEN=$ANTHROPIC_AUTH_TOKEN")
	log "using the key this run was given for $ANTHROPIC_BASE_URL"
fi

# An unattended agent prints nothing until it finishes, which for a job
# measured in hours means a console showing one line and no way to tell working
# from wedged. Asked for its events as they happen, it says what it is doing;
# this turns them back into something a person reading a log can follow.
#
# Only when nothing else was asked for: an explicit --output-format is the
# caller wanting the raw stream, and taking that away would break whatever is
# parsing it.
STREAM=0
if [[ $AGENT == claude ]] && [[ ${FIRECODE_MODE:-} == auto ]] &&
	[[ " ${ARGS[*]} " != *" --output-format "* ]]; then
	for a in "${ARGS[@]}"; do
		[[ $a == -p || $a == --print ]] && STREAM=1
	done
fi

# The prompt moves out of the command line and onto stdin.
#
# --input-format stream-json makes stdin the only source of user turns: the
# text after -p is then read by nobody, and a run started that way sits waiting
# for a first message that never comes. So the prompt is taken out of the
# arguments here and written into the inbox as the first turn, which is also
# what makes every later turn from `firecode say` land in the same place.
PROMPT=""
declare -a AGENT_ARGS=()
if ((STREAM)); then
	skip=0
	for a in "${ARGS[@]}"; do
		if ((skip)); then
			skip=0
			PROMPT=$a
			continue
		fi
		if [[ $a == -p || $a == --print ]]; then
			AGENT_ARGS+=("$a")
			skip=1
			continue
		fi
		AGENT_ARGS+=("$a")
	done
else
	AGENT_ARGS=("${ARGS[@]}")
fi

declare -a CMD=()
if [[ -n ${FIRECODE_TIMEOUT:-} && ${FIRECODE_TIMEOUT} != 0 ]]; then
	CMD=(timeout --signal=TERM --kill-after=30s "$FIRECODE_TIMEOUT")
fi
CMD+=("$AGENT" ${AGENT_ARGS+"${AGENT_ARGS[@]}"})
((STREAM)) && CMD+=(--output-format stream-json --verbose --input-format stream-json)

# The run can be spoken to while it runs.
#
# An unattended agent started on /dev/null is a thing you can watch and not a
# thing you can answer - and half of what a person wants to say to a six-hour
# run is a correction that arrives in minute ten. With stream-json input the
# agent takes further user turns on stdin, so stdin is a fifo and `firecode
# say` writes a turn into it.
#
# Held open by this shell for as long as the agent runs: a fifo with no writer
# reads EOF, and an agent whose stdin closed will not take another word.
# opencode has no stdin channel - `run` is one shot and its --port listens for
# nothing - but it will attach to a server and take another message into a
# session that is already working. So an unattended run gets a server of its
# own, works through it, and `firecode say` posts into the same session.
SAY_PORT=${FIRECODE_OPENCODE_PORT:-4096}
SESSION_FILE=/tmp/firecode-agent-session
if [[ $AGENT == opencode && ${FIRECODE_MODE:-} == auto ]] &&
	[[ " ${ARGS[*]} " != *" --attach "* ]] && command -v curl >/dev/null 2>&1; then
	rm -f "$SESSION_FILE"
	if [[ $RUN_USER == root ]]; then
		env "${ENV[@]}" opencode serve --port "$SAY_PORT" >/tmp/firecode-opencode-serve.log 2>&1 &
	else
		runuser -u "$RUN_USER" -- env "${ENV[@]}" opencode serve --port "$SAY_PORT" \
			>/tmp/firecode-opencode-serve.log 2>&1 &
	fi
	OC_SERVER=$!
	waited=0
	while ((waited < 100)) && ! curl -s -m 1 "http://127.0.0.1:$SAY_PORT/session" >/dev/null 2>&1; do
		sleep 0.2
		waited=$((waited + 1))
	done
	if curl -s -m 2 "http://127.0.0.1:$SAY_PORT/session" >/dev/null 2>&1; then
		# Attach the run itself, so its session lives on that server where a
		# later message can reach it.
		declare -a with_attach=()
		for a in "${AGENT_ARGS[@]}"; do
			with_attach+=("$a")
			[[ $a == run ]] && with_attach+=(--attach "http://127.0.0.1:$SAY_PORT")
		done
		AGENT_ARGS=("${with_attach[@]}")
		CMD=()
		if [[ -n ${FIRECODE_TIMEOUT:-} && ${FIRECODE_TIMEOUT} != 0 ]]; then
			CMD=(timeout --signal=TERM --kill-after=30s "$FIRECODE_TIMEOUT")
		fi
		CMD+=("$AGENT" "${AGENT_ARGS[@]}")
		log "this run can be spoken to: firecode say <text>"
		# The session does not exist until the run has created it, so its id is
		# picked up in the background rather than waited for here.
		(
			for _ in $(seq 1 120); do
				sid=$(curl -s -m 2 "http://127.0.0.1:$SAY_PORT/session" 2>/dev/null |
					python3 -c 'import json,sys
d = json.load(sys.stdin)
print(sorted(d, key=lambda s: s.get("time", {}).get("created", 0))[-1]["id"] if d else "")' 2>/dev/null)
				if [[ -n $sid ]]; then
					echo "$sid" >"$SESSION_FILE"
					chmod 666 "$SESSION_FILE" 2>/dev/null
					break
				fi
				sleep 1
			done
		) &
	else
		log "opencode server did not come up - this run cannot be spoken to"
		kill "$OC_SERVER" 2>/dev/null || true
		OC_SERVER=""
	fi
fi

INBOX=/tmp/firecode-agent-inbox
# Named here rather than where it is written, because the watcher below reads
# it and a variable that is still empty when the watcher starts makes the
# watcher a no-op - which is a run that never closes its own stdin and ends at
# its timeout hours after it finished.
RAW=/tmp/firecode-agent-stream.jsonl
if ((STREAM)); then
	rm -f "$INBOX" "$INBOX.stamp" "$INBOX.close"
	if mkfifo "$INBOX" 2>/dev/null; then
		chmod 666 "$INBOX"
		# A separate process holds the write end, rather than this shell.
		#
		# Something has to, or the agent's stdin reaches EOF the moment the
		# prompt has been written and it never takes another turn. But held
		# forever it never *stops* taking turns either: an agent that has
		# finished sits waiting for input that is not coming, and a run that
		# took ten seconds ends at its timeout hours later. So the holder is
		# a process that can be told to let go.
		# Opened read-write, which is the only way to open a fifo without
		# waiting: a plain > blocks until a reader arrives, and the reader is
		# the agent, which this script has not started yet.
		# shellcheck disable=SC2016  # $1 is the holder's own argument, not ours
		setsid bash -c 'exec 3<>"$1"; while [[ ! -f "$1.close" ]]; do sleep 2; done' \
			_ "$INBOX" >/dev/null 2>&1 &
		INBOX_HOLDER=$!

		# What tells it to let go: the agent has reported a result, and
		# nothing has been said to it since. `firecode say` touches the stamp,
		# so a conversation keeps the run alive and silence ends it.
		(
			# Long enough to say something into a run that has just finished,
			# short enough that a ten-second job does not cost three minutes.
			idle=${FIRECODE_INBOX_IDLE:-60}
			while [[ ! -f "$INBOX.close" ]]; do
				sleep 5
				grep -q '"type":"result"' "$RAW" 2>/dev/null || continue
				last=$(stat -c %Y "$INBOX.stamp" 2>/dev/null || echo 0)
				quiet=$(stat -c %Y "$RAW" 2>/dev/null || echo 0)
				((last > quiet)) && quiet=$last
				(($(date +%s) - quiet >= idle)) && touch "$INBOX.close"
			done
		) &
	else
		log "no inbox: could not create $INBOX - this run cannot be spoken to"
		INBOX=""
	fi
fi

narrate() {
	python3 -u -c '
import json, sys
# Bytes, decoded leniently, and nothing in here may raise. This process is
# only here to make a log readable; if it dies it must not take the run with
# it, and a single odd byte in a tool result is not a reason to stop.
raw = getattr(sys.stdin, "buffer", sys.stdin)
for line in iter(raw.readline, b""):
  try:
    line = line.decode("utf-8", "replace").strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except ValueError:
        print(line[:400], flush=True)
        continue
    kind = ev.get("type")
    msg = ev.get("message") or {}
    for block in (msg.get("content") or []) if isinstance(msg, dict) else []:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text" and block.get("text", "").strip():
            print("  " + block["text"].strip()[:400], flush=True)
        elif block.get("type") == "tool_use":
            inp = block.get("input") or {}
            hint = (inp.get("file_path") or inp.get("command") or inp.get("pattern")
                    or inp.get("url") or inp.get("description") or "")
            print("  %-10s %s" % (block.get("name", "?"), str(hint)[:120]), flush=True)
    if kind == "result":
        print("  == %s in %ss, %s turns ==" % (
            ev.get("subtype", "done"), round(ev.get("duration_ms", 0) / 1000),
            ev.get("num_turns", "?")), flush=True)
  except Exception:
    continue
' 2>/dev/null || cat
}

rc=0
if ((STREAM)); then
	# Through a file, not a pipe.
	#
	# Piping the agent into the narrator makes the agent's life depend on the
	# narrator's: anything that ends the reader sends SIGPIPE to the writer,
	# and a run that had been working for six minutes dies mid-write with
	# "Session terminated, killing shell" and no exit status. A log prettifier
	# must not be able to kill the thing it is describing.
	#
	# So the agent writes to a file it owns, and the narrator tails it. If the
	# narrator dies, the run does not notice, and the raw stream is still on
	# disk to read afterwards.
	: >"$RAW"
	chmod 666 "$RAW" 2>/dev/null || true
	tail -n +1 -F "$RAW" 2>/dev/null | narrate &
	NARRATOR=$!
	# The first turn is the prompt the run was started with; anything `firecode
	# say` writes later arrives on the same channel. json.dumps rather than
	# hand-quoting, because a prompt is arbitrary text - quotes, newlines,
	# backslashes - and one wrong escape makes the whole run a parse error.
	# In the background: this write waits for the agent to open the other end,
	# and the agent is started by the next statement.
	if [[ -n $INBOX && -n $PROMPT ]]; then
		FIRECODE_MSG=$PROMPT python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({
    "type": "user",
    "message": {"role": "user", "content": os.environ["FIRECODE_MSG"]},
}) + "\n")
' >"$INBOX" &
	fi
	if [[ $RUN_USER == root ]]; then
		env "${ENV[@]}" "${CMD[@]}" <"${INBOX:-/dev/null}" >"$RAW" 2>&1 || rc=$?
	else
		runuser -u "$RUN_USER" -- env "${ENV[@]}" "${CMD[@]}" \
			<"${INBOX:-/dev/null}" >"$RAW" 2>&1 || rc=$?
	fi
	# Let it drain what is left before it goes.
	sleep 1
	kill "$NARRATOR" 2>/dev/null || true
	touch "$INBOX.close" 2>/dev/null || true
	[[ -n ${INBOX_HOLDER:-} ]] && kill "$INBOX_HOLDER" 2>/dev/null
	rm -f "$INBOX" "$INBOX.stamp" "$INBOX.close"
elif [[ -n ${OC_SERVER:-} ]]; then
	if [[ $RUN_USER == root ]]; then
		env "${ENV[@]}" "${CMD[@]}" </dev/null || rc=$?
	else
		runuser -u "$RUN_USER" -- env "${ENV[@]}" "${CMD[@]}" </dev/null || rc=$?
	fi
	kill "$OC_SERVER" 2>/dev/null || true
	rm -f "$SESSION_FILE"
elif [[ $RUN_USER == root ]]; then
	env "${ENV[@]}" "${CMD[@]}" </dev/null || rc=$?
else
	runuser -u "$RUN_USER" -- env "${ENV[@]}" "${CMD[@]}" </dev/null || rc=$?
fi

if ((rc == 124)); then
	log "agent hit the ${FIRECODE_TIMEOUT} second timeout and was stopped"
fi

echo
log "agent exited with status $rc"
# Bookkeeping stays out of the project until the gate has run.
#
# These markers used to be written into the project root immediately, and the
# verify command then ran against a tree containing them - so any gate that
# asserts a clean tree, or that everything is committed, failed on the
# harness's own files. A gate is supposed to judge the work; it should not be
# tripped by the thing judging it. They are moved in at the very end, after
# the gate has had its look.
STATUS_TMP=/tmp/firecode-exit-status
echo "$rc" >"$STATUS_TMP" 2>/dev/null || true

# The gate.
#
# Run here rather than on the host because this is where the toolchain is: the
# agent spent an hour installing a compiler, a database, a Lisp - and the same
# check on the host would fail for want of all of it and prove nothing. Run
# after the agent has exited, in the project directory as it will be handed
# over, so nothing the agent's own process was holding can make it pass.
#
# Its output goes into the delivered tree. A verification whose result only
# ever appeared on a console that scrolled away is worth about as much as the
# claim it was meant to replace.
if [[ -n ${FIRECODE_VERIFY:-} ]]; then
	echo
	log "verifying: $FIRECODE_VERIFY"
	vrc=0
	# Written outside the project while the gate runs, for the same reason as
	# the status file, and moved in afterwards.
	vlog=/tmp/firecode-verify.log
	started=$SECONDS
	{
		echo "# firecode verification"
		echo "# command: $FIRECODE_VERIFY"
		echo "# run after the agent exited, in $PROJECT"
		echo
	} >"$vlog" 2>/dev/null || true
	if [[ $RUN_USER == root ]]; then
		timeout --signal=TERM --kill-after=30s "${FIRECODE_VERIFY_TIMEOUT:-1800}" \
			env "${ENV[@]}" bash -lc "cd $(printf '%q' "$PROJECT") && $FIRECODE_VERIFY" \
			</dev/null >>"$vlog" 2>&1 || vrc=$?
	else
		timeout --signal=TERM --kill-after=30s "${FIRECODE_VERIFY_TIMEOUT:-1800}" \
			runuser -u "$RUN_USER" -- env "${ENV[@]}" \
			bash -lc "cd $(printf '%q' "$PROJECT") && $FIRECODE_VERIFY" \
			</dev/null >>"$vlog" 2>&1 || vrc=$?
	fi
	took=$((SECONDS - started))

	# The last lines on the console, because a failure nobody sees is the
	# problem this exists to solve. The whole output stays in the log.
	tail -n 25 "$vlog" 2>/dev/null | sed 's/^/  /'
	echo "$vrc" >/tmp/firecode-verify-status 2>/dev/null || true
	# How long the gate took, written down rather than only said.
	#
	# This number already existed - it is in the console line below - but
	# only as prose, so anything that wanted it had to guess from file
	# mtimes, and mtimes lie here because the whole tree is copied out at
	# once and lands with one timestamp. A gate that took 0.2s on a run that
	# took forty minutes is a gate that is not testing anything, and that is
	# invisible unless the duration is a fact somebody can read.
	echo "$took" >/tmp/firecode-verify-seconds 2>/dev/null || true
	if ((vrc == 0)); then
		log "verification passed in ${took}s"
	elif ((vrc == 124)); then
		log "verification hit its ${FIRECODE_VERIFY_TIMEOUT:-1800}s timeout - reported as a failure"
	else
		log "VERIFICATION FAILED (exit $vrc) after ${took}s - the full output is in .firecode-verify.log"
	fi
	# A failed check outranks a cheerful agent: what this run reports is
	# whether the work can be used, not whether the agent thought so.
	((vrc == 0)) || rc=$vrc
fi

# Now the markers go in, with the gate finished and nothing left to mislead.
# The host reads them out of the delivered tree and deletes them there, so
# they are a courier rather than part of anyone's project.
[[ -f $STATUS_TMP ]] &&
	cp -f "$STATUS_TMP" "$PROJECT/.firecode-exit-status" 2>/dev/null
[[ -f /tmp/firecode-verify-status ]] &&
	cp -f /tmp/firecode-verify-status "$PROJECT/.firecode-verify-status" 2>/dev/null
[[ -f /tmp/firecode-verify-seconds ]] &&
	cp -f /tmp/firecode-verify-seconds "$PROJECT/.firecode-verify-seconds" 2>/dev/null
[[ -f /tmp/firecode-verify.log ]] &&
	cp -f /tmp/firecode-verify.log "$PROJECT/.firecode-verify.log" 2>/dev/null

sync
exit "$rc"
