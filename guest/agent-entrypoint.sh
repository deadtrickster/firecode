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
	"PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
)

declare -a CMD=()
if [[ -n ${FIRECODE_TIMEOUT:-} && ${FIRECODE_TIMEOUT} != 0 ]]; then
	CMD=(timeout --signal=TERM --kill-after=30s "$FIRECODE_TIMEOUT")
fi
CMD+=("$AGENT" "${ARGS[@]}")

rc=0
if [[ $RUN_USER == root ]]; then
	env "${ENV[@]}" "${CMD[@]}" </dev/null || rc=$?
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
