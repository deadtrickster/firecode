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
[[ -f /opt/firecode/run/env ]] && . /opt/firecode/run/env

FIRECODE_USER=${FIRECODE_USER:-root}
FIRECODE_HOME=${FIRECODE_HOME:-/root}
FIRECODE_PROJECT=${FIRECODE_PROJECT:-$PWD}

# Same terminal the host has. There is no SIGWINCH over this channel, so it
# is fixed for the life of the session.
_term=${FIRECODE_TERM:-}
if [[ -z $_term ]] || ! infocmp "$_term" >/dev/null 2>&1; then
	_term=xterm-256color
fi
if [[ -n ${FIRECODE_ROWS:-} && -n ${FIRECODE_COLS:-} ]]; then
	stty rows "$FIRECODE_ROWS" cols "$FIRECODE_COLS" 2>/dev/null || true
fi

finish() {
	echo
	echo "  shutting down, the project is being copied back out ..."
	sync
	systemctl reboot
}

cat <<BANNER

  firecode microVM  (${FIRECODE_ID:-unknown})

  $FIRECODE_PROJECT
      your project, writable, copied back out on shutdown. The same path
      it has on the host.
  ~/.claude ~/.opencode
      your host config, writable, kept between runs

  You are $FIRECODE_USER, with passwordless sudo. Nothing in here can reach
  the host filesystem. Type exit when you are done.

BANNER

declare -a env=(
	"HOME=$FIRECODE_HOME"
	"USER=$FIRECODE_USER"
	"LOGNAME=$FIRECODE_USER"
	"IS_SANDBOX=1"
	"FIRECODE=1"
	"TERM=$_term"
	"TERM_PROGRAM=${FIRECODE_TERM_PROGRAM:-}"
	"COLORTERM=${FIRECODE_COLORTERM:-}"
	"PATH=/opt/mise/shims:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
	"MISE_DATA_DIR=/opt/mise"
	"MISE_CONFIG_DIR=/opt/mise/config"
	"MISE_STATE_DIR=/opt/mise/state"
	"MISE_CACHE_DIR=/var/cache/mise"
)
[[ -n ${FIRECODE_ROWS:-} ]] && env+=("LINES=$FIRECODE_ROWS" "COLUMNS=$FIRECODE_COLS")

declare -a cmd=(bash -i)
if [[ ${FIRECODE_AGENT:-} == keys ]]; then
	cmd=(/opt/firecode/run/keydump.sh)
elif [[ -n ${FIRECODE_AGENT:-} ]] && command -v "$FIRECODE_AGENT" >/dev/null 2>&1; then
	declare -a args=()
	[[ -f /opt/firecode/run/interactive-args ]] &&
		mapfile -d '' -t args </opt/firecode/run/interactive-args
	echo "  starting $FIRECODE_AGENT ${args[*]-}"
	echo
	cmd=("$FIRECODE_AGENT" ${args+"${args[@]}"})
fi

cd "$FIRECODE_PROJECT" 2>/dev/null || cd "$FIRECODE_HOME" || true

if [[ $FIRECODE_USER == root ]]; then
	env "${env[@]}" "${cmd[@]}"
else
	runuser -u "$FIRECODE_USER" -- env "${env[@]}" "${cmd[@]}"
fi

finish
