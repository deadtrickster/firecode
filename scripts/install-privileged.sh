#!/usr/bin/env bash
# install-privileged.sh - one-time root setup so jailed runs do not prompt.
#
# Building images and extracting results need no privileges. Networking needs
# root once, and `firecode net-setup` is that once - it leaves persistent taps
# behind that belong to you. What is left is the jailer, which has to be root
# to chroot and to drop privileges, and cannot be made one-time.
#
# So this grants passwordless sudo for ONE root-owned wrapper around the
# jailer, never the jailer itself. The jailer execs any file named like
# firecracker as any uid you name, so a rule for it with free arguments is
# passwordless root for anything running as you - and the copy in vendor/bin
# is yours to overwrite besides. The wrapper (scripts/jail-wrapper.sh) accepts
# only what firecode passes: your own uid, a root-owned firecracker, a
# root-owned jail base.
#
# Everything root runs is copied to $LIBEXEC, owned by root. Re-run this after
# `firecode setup` fetches a new firecracker, so the copies match.
#
# If you would rather not, skip it: `firecode --no-jail` needs nothing, and
# still gives you a real KVM guest. You lose the chroot, uid drop and pid
# namespace around the VMM process.
#
#   sudo ./scripts/install-privileged.sh [--user NAME] [--uninstall]
set -euo pipefail

[[ $(uname -s) == Darwin ]] && {
	echo "install-privileged: nothing to install on macOS - there is no jailer, and the" >&2
	echo "  VM already runs inside Apple's sandboxed Virtualization service." >&2
	exit 0
}

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
VENDOR="$ROOT/vendor/bin"
LIBEXEC=/usr/local/libexec/firecode
SUDOERS=/etc/sudoers.d/firecode

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
	rm -rf "$LIBEXEC"
	echo "removed $SUDOERS and $LIBEXEC"
	echo "jails under $BASE are left; remove it once no VM is running"
	exit 0
fi

# WHAT KEEPS THE JAILER'S chown INSIDE THE JAIL. It makes /dev/kvm and friends
# and chowns them BY PATH, after pivot_root - so a symlink planted in the run's
# root/ (which is yours) resolves inside the jail, where nothing of the host is
# visible. The one way back out would be a hard link in there to a root-owned
# host file, and the kernel refuses to let you make one only while
# protected_hardlinks is on. The binary copy before the chroot is safe on its
# own: O_NOFOLLOW, a refusal of nlink > 1, and an fchown on the open file.
# (Read against firecracker v1.17.0, src/jailer/src/{env,chroot}.rs.)
if [[ $(cat /proc/sys/fs/protected_hardlinks 2>/dev/null) != 1 ]]; then
	echo "fs.protected_hardlinks is off, and the jail's safety depends on it." >&2
	echo "Turn it on (sysctl -w fs.protected_hardlinks=1, and persist it) first." >&2
	exit 1
fi

for f in jailer firecracker; do
	[[ -x $VENDOR/$f ]] || {
		echo "$f not found at $VENDOR/$f - run 'firecode setup' first" >&2
		exit 1
	}
done

# WHERE THE JAILS GO. Root-owned all the way up, or whoever owns a parent can
# swap a directory for a link while the jailer, as root, is making device nodes
# in it. And on the same filesystem as the checkout, because drives are
# hardlinked into the jail - across filesystems they are copied, and what the
# guest writes lands in the copy, not in the run's drive.
safe_chain() {
	local p=$1 owner mode
	while [[ $p != / ]]; do
		if [[ -e $p ]]; then
			[[ -L $p ]] && return 1
			read -r owner mode < <(stat -c '%u %a' "$p")
			((owner == 0)) || return 1
			# No group or other write, unless sticky (/tmp-style).
			((8#$mode & 8#022)) && ! ((8#$mode & 8#1000)) && return 1
		fi
		p=$(dirname "$p")
	done
	return 0
}
dev_of() {
	local p=$1
	while [[ ! -e $p ]]; do p=$(dirname "$p"); done
	stat -c %d "$p"
}
BASE=""
mnt=$(findmnt -no TARGET -T "$ROOT")
for cand in /var/lib/firecode/jail "${mnt%/}/.firecode-jail"; do
	[[ $(dev_of "$cand") == "$(dev_of "$ROOT")" ]] || continue
	safe_chain "$cand" || continue
	BASE=$cand
	break
done
[[ -n $BASE ]] || {
	echo "no root-owned place for jails on the filesystem holding $ROOT" >&2
	echo "(tried /var/lib/firecode/jail and ${mnt%/}/.firecode-jail)." >&2
	echo "Nothing installed. Jailed runs will ask sudo for a password; --no-jail needs none." >&2
	exit 1
}

# Copied, never linked: a link would still resolve into a tree you can write.
install -d -o root -g root -m 0755 "$LIBEXEC" "$BASE"
install -o root -g root -m 0755 "$VENDOR/jailer" "$LIBEXEC/jailer"
install -o root -g root -m 0755 "$VENDOR/firecracker" "$LIBEXEC/firecracker"
install -o root -g root -m 0755 "$ROOT/scripts/jail-wrapper.sh" "$LIBEXEC/jail"
sed -i "s|^BASE=.*|BASE=$BASE|" "$LIBEXEC/jail"
printf '%s\n' "$BASE" >"$LIBEXEC/jail-base"
chmod 0644 "$LIBEXEC/jail-base"

umask 077
cat >"$SUDOERS.tmp" <<EOF
# Installed by firecode ($ROOT). Lets $TARGET_USER start jailed microVMs
# without a password prompt.
#
# Networking is not here on purpose: 'firecode net-setup' does that once and
# leaves taps owned by $TARGET_USER, so runs need nothing further.
#
# Only the wrapper, which pins the uid to the caller's and the binary to a
# root-owned firecracker - never the jailer, whose free arguments are root.
# Remove with:
#   sudo $ROOT/scripts/install-privileged.sh --uninstall
$TARGET_USER ALL=(root) NOPASSWD: $LIBEXEC/jail
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

echo "installed $SUDOERS for $TARGET_USER - jails go in $BASE"
echo
echo "check it with:  firecode doctor"
