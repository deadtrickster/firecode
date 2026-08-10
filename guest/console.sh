#!/usr/bin/env bash
# One interactive session, on the far end of a vsock connection.
#
# Not the serial console. Firecracker's serial input path rewrites CR to LF,
# so a full-screen application in raw mode never sees Enter - it is watching
# for \r and \r cannot get through. Everything else survives, which is why
# arrow keys work and only Enter looks broken.
#
# socat gives this script a pty of its own and relays bytes to the host
# untouched, so keystrokes arrive exactly as they were typed.
set -u

# shellcheck source=/dev/null
[[ -f /opt/firellm/run/env ]] && . /opt/firellm/run/env

FIRELLM_USER=${FIRELLM_USER:-root}
FIRELLM_HOME=${FIRELLM_HOME:-/root}
FIRELLM_PROJECT=${FIRELLM_PROJECT:-/src}

# Same terminal the host has. There is no SIGWINCH over this channel, so it
# is fixed for the life of the session.
_term=${FIRELLM_TERM:-}
if [[ -z $_term ]] || ! infocmp "$_term" >/dev/null 2>&1; then
	_term=xterm-256color
fi
if [[ -n ${FIRELLM_ROWS:-} && -n ${FIRELLM_COLS:-} ]]; then
	stty rows "$FIRELLM_ROWS" cols "$FIRELLM_COLS" 2>/dev/null || true
fi

finish() {
	echo
	echo "  shutting down, the project is being copied back out ..."
	sync
	systemctl reboot
}

cat <<BANNER

  firellm microVM  (${FIRELLM_ID:-unknown})

  $FIRELLM_PROJECT
      your project, writable, copied back out on shutdown. Same path as on
      the host, and /src points at it.
  ~/.claude ~/.opencode
      your host config, writable, kept between runs

  You are $FIRELLM_USER, with passwordless sudo. Nothing in here can reach
  the host filesystem. Type exit when you are done.

BANNER

declare -a env=(
	"HOME=$FIRELLM_HOME"
	"USER=$FIRELLM_USER"
	"LOGNAME=$FIRELLM_USER"
	"IS_SANDBOX=1"
	"FIRELLM=1"
	"TERM=$_term"
	"TERM_PROGRAM=${FIRELLM_TERM_PROGRAM:-}"
	"COLORTERM=${FIRELLM_COLORTERM:-}"
	"PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
)
[[ -n ${FIRELLM_ROWS:-} ]] && env+=("LINES=$FIRELLM_ROWS" "COLUMNS=$FIRELLM_COLS")

declare -a cmd=(bash -i)
if [[ ${FIRELLM_AGENT:-} == keys ]]; then
	cmd=(/opt/firellm/run/keydump.sh)
elif [[ -n ${FIRELLM_AGENT:-} ]] && command -v "$FIRELLM_AGENT" >/dev/null 2>&1; then
	declare -a args=()
	[[ -f /opt/firellm/run/interactive-args ]] &&
		mapfile -d '' -t args </opt/firellm/run/interactive-args
	echo "  starting $FIRELLM_AGENT ${args[*]-}"
	echo
	cmd=("$FIRELLM_AGENT" ${args+"${args[@]}"})
fi

cd "$FIRELLM_PROJECT" 2>/dev/null || cd "$FIRELLM_HOME" || true

if [[ $FIRELLM_USER == root ]]; then
	env "${env[@]}" "${cmd[@]}"
else
	runuser -u "$FIRELLM_USER" -- env "${env[@]}" "${cmd[@]}"
fi

finish
