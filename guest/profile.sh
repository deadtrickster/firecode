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

# agetty labels the serial line vt220, but the thing on the far end of it is
# the host's terminal, and it is the one answering capability probes. An
# application that believes the vt220 label then mis-decodes what that
# terminal sends back. Enter is the one you notice: a terminal speaking the
# kitty keyboard protocol reports it as CSI 13 u while arrows stay ordinary
# CSI, so the arrows work and Enter looks dead.
_fl_term=${FIRELLM_TERM:-}
if [[ -z $_fl_term ]] || ! infocmp "$_fl_term" >/dev/null 2>&1; then
	_fl_term=xterm-256color
	infocmp "$_fl_term" >/dev/null 2>&1 || _fl_term=${TERM:-vt220}
fi
export TERM=$_fl_term
[[ -n ${FIRELLM_TERM_PROGRAM:-} ]] && export TERM_PROGRAM=$FIRELLM_TERM_PROGRAM
[[ -n ${FIRELLM_COLORTERM:-} ]] && export COLORTERM=$FIRELLM_COLORTERM

declare -a _fl_env=(
	"HOME=$FIRELLM_HOME"
	"USER=$FIRELLM_USER"
	"LOGNAME=$FIRELLM_USER"
	"IS_SANDBOX=1"
	"FIRELLM=1"
	"TERM=$_fl_term"
	"TERM_PROGRAM=${FIRELLM_TERM_PROGRAM:-}"
	"COLORTERM=${FIRELLM_COLORTERM:-}"
	"PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
)

declare -a _fl_cmd=(bash -i)
# `firellm keys` - show what the guest receives for each keypress.
if [[ ${FIRELLM_AGENT:-} == keys ]]; then
	_fl_cmd=(/opt/firellm/run/keydump.sh)
fi
if [[ ${FIRELLM_MODE:-} == interactive && -n ${FIRELLM_AGENT:-} &&
	${FIRELLM_AGENT} != keys ]]; then
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
