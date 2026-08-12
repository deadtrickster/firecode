#!/usr/bin/env bash
# Sourced from /root/.bash_profile on the serial console autologin.
# Interactive mode only - unattended runs never reach a login shell.
# shellcheck shell=bash

# Prefer the copy shipped on the control drive, so a fix here does not need
# the rootfs image rebuilt.
if [[ -x /opt/firecode/run/profile.sh && -z ${FIRECODE_PROFILE:-} ]]; then
	export FIRECODE_PROFILE=1
	# shellcheck source=/dev/null
	. /opt/firecode/run/profile.sh
	return 0
fi

# shellcheck source=/dev/null
[[ -f /opt/firecode/run/env ]] && . /opt/firecode/run/env

FIRECODE_USER=${FIRECODE_USER:-root}
FIRECODE_HOME=${FIRECODE_HOME:-/root}
FIRECODE_PROJECT=${FIRECODE_PROJECT:-$PWD}

# A Firecracker guest cannot power itself off - there is no ACPI power button
# to press from in here. A reset is what makes the VMM exit, and systemd
# still unmounts the project drive properly on the way.
firecode_finish() {
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

# agetty labels the serial line vt220, but the thing on the far end of it is
# the host's terminal, and it is the one answering capability probes. An
# application that believes the vt220 label then mis-decodes what that
# terminal sends back. Enter is the one you notice: a terminal speaking the
# kitty keyboard protocol reports it as CSI 13 u while arrows stay ordinary
# CSI, so the arrows work and Enter looks dead.
_fl_term=${FIRECODE_TERM:-}
if [[ -z $_fl_term ]] || ! infocmp "$_fl_term" >/dev/null 2>&1; then
	_fl_term=xterm-256color
	infocmp "$_fl_term" >/dev/null 2>&1 || _fl_term=${TERM:-vt220}
fi
export TERM=$_fl_term
[[ -n ${FIRECODE_TERM_PROGRAM:-} ]] && export TERM_PROGRAM=$FIRECODE_TERM_PROGRAM
[[ -n ${FIRECODE_COLORTERM:-} ]] && export COLORTERM=$FIRECODE_COLORTERM

declare -a _fl_env=(
	"HOME=$FIRECODE_HOME"
	"USER=$FIRECODE_USER"
	"LOGNAME=$FIRECODE_USER"
	"IS_SANDBOX=1"
	"FIRECODE=1"
	"TERM=$_fl_term"
	"TERM_PROGRAM=${FIRECODE_TERM_PROGRAM:-}"
	"COLORTERM=${FIRECODE_COLORTERM:-}"
	"PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
)

declare -a _fl_cmd=(bash -i)
# `firecode keys` - show what the guest receives for each keypress.
if [[ ${FIRECODE_AGENT:-} == keys ]]; then
	_fl_cmd=(/opt/firecode/run/keydump.sh)
fi
# The agent belongs to the session, not to the port.
#
# An interactive run's session arrives on this channel, so the first connection
# gets the agent. Every later one is someone opening a second window into a VM
# that is already working - `firecode enter`, or fctop's `s` - and handing them
# another agent instead of a shell is not what either of them asked for, and
# starts a second agent on the same project.
_fl_first_console=/opt/firecode/run/console-taken
if [[ ${FIRECODE_MODE:-} == interactive && -n ${FIRECODE_AGENT:-} &&
	${FIRECODE_AGENT} != keys ]] && mkdir "$_fl_first_console" 2>/dev/null; then
	if command -v "$FIRECODE_AGENT" >/dev/null 2>&1; then
		# Whatever was asked for on the host - --resume, a model, and so on.
		declare -a _fl_args=()
		if [[ -f /opt/firecode/run/interactive-args ]]; then
			mapfile -d '' -t _fl_args </opt/firecode/run/interactive-args
		fi
		echo "  starting $FIRECODE_AGENT ${_fl_args[*]-}"
		echo
		_fl_cmd=("$FIRECODE_AGENT" ${_fl_args+"${_fl_args[@]}"})
	else
		echo "  WARNING: $FIRECODE_AGENT is not installed in this guest."
		echo
	fi
fi

# The serial console reports 80x24 no matter what is on the other end, and
# there is no SIGWINCH to correct it later. Take the size the host had.
if [[ -n ${FIRECODE_ROWS:-} && -n ${FIRECODE_COLS:-} ]]; then
	stty rows "$FIRECODE_ROWS" cols "$FIRECODE_COLS" 2>/dev/null || true
	export LINES=$FIRECODE_ROWS COLUMNS=$FIRECODE_COLS
fi

cd "$FIRECODE_PROJECT" 2>/dev/null || cd "$FIRECODE_HOME" || true

# Not exec: when the shell or the agent exits we still want to shut the VM
# down rather than drop back to a login prompt nobody is watching.
if [[ $FIRECODE_USER == root ]]; then
	env "${_fl_env[@]}" "${_fl_cmd[@]}"
else
	runuser -u "$FIRECODE_USER" -- env "${_fl_env[@]}" "${_fl_cmd[@]}"
fi

firecode_finish
