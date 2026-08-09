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

export IS_SANDBOX=1
export FIRELLM=1
export HOME=/root
export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export TERM=${TERM:-xterm-256color}

[[ -d /src ]] && cd /src || true

# A Firecracker guest cannot power itself off - there is no ACPI power button
# to press from in here. A reset is what makes the VMM exit, and systemd
# still unmounts /src properly on the way.
firellm_finish() {
	echo
	echo "  shutting down, /src is being copied back out ..."
	sync
	systemctl reboot
}
alias poweroff='firellm_finish'
alias shutdown='firellm_finish'

cat <<BANNER

  firellm microVM  (${FIRELLM_ID:-unknown})

  /src                  your project, writable, copied back out on shutdown
  ~/.claude ~/.opencode host config, writable, kept between runs
  /root/FIRELLM.md      what this environment is

  Nothing in here can reach the host filesystem. Type exit (or poweroff)
  when you are done and the work in /src is copied back.

BANNER

if [[ ${FIRELLM_MODE:-} == interactive && -n ${FIRELLM_AGENT:-} ]]; then
	if command -v "$FIRELLM_AGENT" >/dev/null 2>&1; then
		echo "  starting $FIRELLM_AGENT ..."
		echo
		# Not exec: when the agent exits we still want to shut the VM down
		# rather than drop back to a login prompt nobody is watching.
		"$FIRELLM_AGENT"
		firellm_finish
	else
		echo "  WARNING: $FIRELLM_AGENT is not installed in this guest."
		echo
	fi
fi

# Typing exit, or Ctrl-D, ends the run.
trap firellm_finish EXIT
