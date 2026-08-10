#!/usr/bin/env bash
# install-privileged.sh - one-time root setup so jailed runs do not prompt.
#
# Building images and extracting results need no privileges. Networking needs
# root once, and `firellm net-setup` is that once - it leaves persistent taps
# behind that belong to you. What is left is the jailer, which has to be root
# to chroot and to drop privileges, and cannot be made one-time.
#
# So this grants passwordless sudo for the jailer alone. Be clear about what
# that is: the jailer execs a binary as a uid you choose, so it is closer to
# passwordless root than to a narrow permission. It is a convenience for a
# single-user workstation, not a security boundary. The boundary is the
# microVM, on the other side of this command.
#
# If you would rather not, skip it: `firellm --no-jail` needs nothing, and
# still gives you a real KVM guest. You lose the chroot, uid drop and pid
# namespace around the VMM process.
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

umask 077
cat >"$SUDOERS.tmp" <<EOF
# Installed by firellm ($ROOT). Lets $TARGET_USER start jailed microVMs
# without a password prompt.
#
# Networking is not here on purpose: 'firellm net-setup' does that once and
# leaves taps owned by $TARGET_USER, so runs need nothing further.
#
# The jailer execs a binary as a uid of the caller's choosing, so treat this
# as passwordless root. Remove with:
#   sudo $ROOT/scripts/install-privileged.sh --uninstall
$TARGET_USER ALL=(root) NOPASSWD: $JAILER
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
