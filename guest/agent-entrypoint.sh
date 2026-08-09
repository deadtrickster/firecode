#!/usr/bin/env bash
# firellm agent entrypoint - runs the requested agent inside the microVM.
# Started by firellm-agent.service, which only runs when the host asked for
# an unattended run (that is, when the control drive carries an args file).
set -u

CTL_MNT=/opt/firellm/run

log() { echo "[firellm] $*"; }

# Prefer the copy the harness shipped on the control drive, so a fix here
# does not need the rootfs image rebuilt.
if [[ -x $CTL_MNT/agent-entrypoint.sh && -z ${FIRELLM_REEXEC:-} ]]; then
	export FIRELLM_REEXEC=1
	exec "$CTL_MNT/agent-entrypoint.sh"
fi

# shellcheck source=/dev/null
[[ -f $CTL_MNT/env ]] && . "$CTL_MNT/env"

AGENT=${FIRELLM_AGENT:-claude}

declare -a ARGS=()
if [[ -f $CTL_MNT/args ]]; then
	mapfile -d '' -t ARGS <"$CTL_MNT/args"
fi

if ! command -v "$AGENT" >/dev/null 2>&1; then
	log "ERROR: $AGENT is not installed in the guest."
	log "The config drive should carry it at /opt/firellm/config/bin/$AGENT."
	# shellcheck disable=SC2012  # human-readable diagnostic, not parsed
	ls -la /opt/firellm/config/bin 2>&1 | sed 's/^/[firellm] /'
	exit 127
fi

cd /src 2>/dev/null || cd /root || exit 1

# Claude Code refuses --dangerously-skip-permissions as root unless it is
# told it is in a sandbox. It is: that is the entire point of this harness.
export IS_SANDBOX=1
export FIRELLM=1
export HOME=/root
export TERM=${TERM:-dumb}
export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin

log "running: $AGENT ${ARGS[*]}"
log "cwd: $(pwd)"
echo

rc=0
if [[ -n ${FIRELLM_TIMEOUT:-} && ${FIRELLM_TIMEOUT} != 0 ]]; then
	timeout --signal=TERM --kill-after=30s "$FIRELLM_TIMEOUT" \
		"$AGENT" "${ARGS[@]}" </dev/null || rc=$?
	if ((rc == 124)); then
		log "agent hit the ${FIRELLM_TIMEOUT} timeout and was stopped"
	fi
else
	"$AGENT" "${ARGS[@]}" </dev/null || rc=$?
fi

echo
log "agent exited with status $rc"
echo "$rc" >/src/.firellm-exit-status 2>/dev/null || true
sync
exit "$rc"
