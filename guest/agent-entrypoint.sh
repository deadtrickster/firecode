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

declare -a CMD=()
if [[ -n ${FIRECODE_TIMEOUT:-} && ${FIRECODE_TIMEOUT} != 0 ]]; then
	CMD=(timeout --signal=TERM --kill-after=30s "$FIRECODE_TIMEOUT")
fi
CMD+=("$AGENT" "${ARGS[@]}")

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
	((STREAM)) && CMD+=(--output-format stream-json --verbose)
fi

narrate() {
	python3 -u -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except ValueError:
        print(line, flush=True)
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
' 2>/dev/null || cat
}

rc=0
if [[ $RUN_USER == root ]]; then
	if ((STREAM)); then
		set -o pipefail
		env "${ENV[@]}" "${CMD[@]}" </dev/null | narrate || rc=$?
	else
		env "${ENV[@]}" "${CMD[@]}" </dev/null || rc=$?
	fi
elif ((STREAM)); then
	set -o pipefail
	runuser -u "$RUN_USER" -- env "${ENV[@]}" "${CMD[@]}" </dev/null | narrate || rc=$?
else
	runuser -u "$RUN_USER" -- env "${ENV[@]}" "${CMD[@]}" </dev/null || rc=$?
fi

if ((rc == 124)); then
	log "agent hit the ${FIRECODE_TIMEOUT} second timeout and was stopped"
fi

echo
log "agent exited with status $rc"
echo "$rc" >"$PROJECT/.firecode-exit-status" 2>/dev/null || true
sync
exit "$rc"
