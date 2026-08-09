#!/usr/bin/env bash
# install-privileged.sh - one-time root setup so runs do not prompt.
#
# Building images and extracting results already need no privileges. What is
# left is the jailer itself and the tap device, and both genuinely need root.
# This installs a sudoers rule for them so an unattended run never stops to
# ask for a password.
#
# Be clear about what this grants: passwordless sudo for `ip`, `iptables`,
# `sysctl` and the jailer is, in practice, passwordless root. It is a
# convenience for a single-user workstation, not a security boundary. The
# boundary is the microVM, which is on the other side of these commands.
#
#   sudo ./scripts/install-privileged.sh [--user NAME] [--uninstall]
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
JAILER="$ROOT/vendor/bin/jailer"
SUDOERS=/etc/sudoers.d/firellm

TARGET_USER=${SUDO_USER:-${USER:-root}}
UNINSTALL=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	--user)
		TARGET_USER="$2"
		shift 2
		;;
	--uninstall)
		UNINSTALL=1
		shift
		;;
	*)
		echo "unknown option: $1" >&2
		exit 2
		;;
	esac
done

[[ $EUID -eq 0 ]] || {
	echo "run this with sudo" >&2
	exit 1
}

if ((UNINSTALL)); then
	rm -f "$SUDOERS"
	echo "removed $SUDOERS"
	exit 0
fi

[[ -x $JAILER ]] || {
	echo "jailer not found at $JAILER - run 'firellm setup' first" >&2
	exit 1
}

IP=$(command -v ip)
IPTABLES=$(command -v iptables)
SYSCTL=$(command -v sysctl)

umask 077
cat >"$SUDOERS.tmp" <<EOF
# Installed by firellm ($ROOT). Lets $TARGET_USER start jailed microVMs and
# manage their tap devices without a password prompt.
#
# This is effectively passwordless root. Remove with:
#   sudo $ROOT/scripts/install-privileged.sh --uninstall
$TARGET_USER ALL=(root) NOPASSWD: $JAILER
$TARGET_USER ALL=(root) NOPASSWD: $IP
$TARGET_USER ALL=(root) NOPASSWD: $IPTABLES
$TARGET_USER ALL=(root) NOPASSWD: $SYSCTL
EOF

# Never install a sudoers file that does not parse: a broken one locks
# everybody out of sudo.
if ! visudo -cqf "$SUDOERS.tmp"; then
	rm -f "$SUDOERS.tmp"
	echo "generated sudoers file is invalid, nothing installed" >&2
	exit 1
fi

mv -f "$SUDOERS.tmp" "$SUDOERS"
chmod 0440 "$SUDOERS"

echo "installed $SUDOERS for $TARGET_USER"
echo
echo "check it with:  firellm doctor"
