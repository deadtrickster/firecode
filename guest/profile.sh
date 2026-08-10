#!/usr/bin/env bash
# Sourced from /root/.bash_profile on the serial console autologin.
# Interactive mode only - unattended runs never reach a login shell.
# shellcheck shell=bash

# Prefer the copy shipped on the control drive, so a fix here does not need
# the rootfs image rebuilt.
if [[ -x /opt/firellm/run/profile.sh && -z ${FIRELLM_PROFILE:-} ]]; then
	export FIRELLM_PROFILE=1
	# shellcheck source=/dev/null
	. /opt/firellm/run/profile.sh
	return 0
fi

# shellcheck source=/dev/null
[[ -f /opt/firellm/run/env ]] && . /opt/firellm/run/env

FIRELLM_USER=${FIRELLM_USER:-root}
FIRELLM_HOME=${FIRELLM_HOME:-/root}
FIRELLM_PROJECT=${FIRELLM_PROJECT:-/src}

# A Firecracker guest cannot power itself off - there is no ACPI power button
# to press from in here. A reset is what makes the VMM exit, and systemd
# still unmounts the project drive properly on the way.
firellm_finish() {
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

declare -a _fl_env=(
	"HOME=$FIRELLM_HOME"
	"USER=$FIRELLM_USER"
	"LOGNAME=$FIRELLM_USER"
	"IS_SANDBOX=1"
	"FIRELLM=1"
	"TERM=${TERM:-xterm-256color}"
	"PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
)

declare -a _fl_cmd=(bash -i)
if [[ ${FIRELLM_MODE:-} == interactive && -n ${FIRELLM_AGENT:-} ]]; then
	if command -v "$FIRELLM_AGENT" >/dev/null 2>&1; then
		# Whatever was asked for on the host - --resume, a model, and so on.
		declare -a _fl_args=()
		if [[ -f /opt/firellm/run/interactive-args ]]; then
			mapfile -d '' -t _fl_args </opt/firellm/run/interactive-args
		fi
		echo "  starting $FIRELLM_AGENT ${_fl_args[*]-}"
		echo
		_fl_cmd=("$FIRELLM_AGENT" ${_fl_args+"${_fl_args[@]}"})
	else
		echo "  WARNING: $FIRELLM_AGENT is not installed in this guest."
		echo
	fi
fi

# The serial console reports 80x24 no matter what is on the other end, and
# there is no SIGWINCH to correct it later. Take the size the host had.
if [[ -n ${FIRELLM_ROWS:-} && -n ${FIRELLM_COLS:-} ]]; then
	stty rows "$FIRELLM_ROWS" cols "$FIRELLM_COLS" 2>/dev/null || true
	export LINES=$FIRELLM_ROWS COLUMNS=$FIRELLM_COLS
fi

cd "$FIRELLM_PROJECT" 2>/dev/null || cd "$FIRELLM_HOME" || true

# Not exec: when the shell or the agent exits we still want to shut the VM
# down rather than drop back to a login prompt nobody is watching.
if [[ $FIRELLM_USER == root ]]; then
	env "${_fl_env[@]}" "${_fl_cmd[@]}"
else
	runuser -u "$FIRELLM_USER" -- env "${_fl_env[@]}" "${_fl_cmd[@]}"
fi

firellm_finish
