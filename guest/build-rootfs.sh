#!/usr/bin/env bash
# Build a firecode guest rootfs, from inside a firecode guest.
#
# The old way needs docker on the host, which is a heavy dependency for what
# is really "unpack some packages into a directory" - and on a machine whose
# resolver is a loopback DoH proxy, docker's bridge cannot resolve names at
# all, so builds fail in ways that look like broken package lists. A VM has
# root, a real network with a real resolver, and every tool this needs. It is
# also the only machine on which the result is ever going to run.
#
#   build-rootfs.sh <target-device> <guest-dir> [tools]
#
# <target-device> is a blank disk attached to this VM (--disk file:-:rw); the
# finished filesystem is written straight onto it, so the host has the image
# the moment this VM stops. <guest-dir> is a read-only mount of firecode's
# guest/ directory, for the harness scripts and systemd units.
set -euo pipefail

DEV=${1:?usage: build-rootfs.sh <device> <repo-dir> [tools]}
GUESTDIR=${2:?}
TOOLS=${3:-}
TREE=/tmp/firecode-tree
SUITE=${SUITE:-noble}
MIRROR=${MIRROR:-http://archive.ubuntu.com/ubuntu}

say() { echo "[build-rootfs] $*"; }

[[ -b $DEV ]] || {
	echo "[build-rootfs] $DEV is not a block device" >&2
	exit 1
}
[[ -d $GUESTDIR/systemd ]] || {
	echo "[build-rootfs] $GUESTDIR does not look like firecode's guest directory" >&2
	exit 1
}

say "installing the bootstrapper"
export DEBIAN_FRONTEND=noninteractive
sudo -n apt-get update -qq
sudo -n apt-get install -y -qq mmdebstrap arch-test >/dev/null

# The base system. Everything here is what firecode-setup.sh and the agent
# assume exists before anything else runs.
BASE=systemd,systemd-sysv,udev,dbus-daemon,e2fsprogs,util-linux,iproute2
BASE=$BASE,iputils-ping,netbase,ca-certificates,curl,wget,gnupg,socat,sudo
BASE=$BASE,passwd,locales,tzdata,git,git-lfs,openssh-client,build-essential
BASE=$BASE,make,pkg-config,python3,python3-pip,python3-venv,ripgrep,fd-find
BASE=$BASE,jq,unzip,tar,xz-utils,zstd,libicu74,vim,less,tmux,procps,psmisc
BASE=$BASE,file,bash-completion,busybox-static,cpio
# FUSE: the kernel has always had it, and without the userspace half a
# filesystem written in a VM cannot be mounted there.
BASE=$BASE,fuse3,libfuse3-dev,libfuse-dev,python3-fusepy,python3-pyfuse3
# Postgres, because a gate that stores anything wants it and every run was
# apt-getting it over the network first. It is here as the SERVER BINARIES
# rather than a service - initdb, pg_ctl and psql, for gates that stand up a
# throwaway cluster in a temp directory and tear it down again. Nothing
# starts a system postgres; the package is installed and left alone.
#
# Note the version this pins you to: noble ships PostgreSQL 16, so a gate in
# a VM tests against 16. If what the code runs on in earnest is 17, that gap
# is real and belongs in a README rather than in a surprise.
BASE=$BASE,postgresql,postgresql-client

say "bootstrapping $SUITE"
sudo -n rm -rf "$TREE"
sudo -n mmdebstrap --variant=important --include="$BASE" \
	--components=main,universe "$SUITE" "$TREE" "$MIRROR"

say "installing the harness"
sudo -n install -d "$TREE/opt/firecode"
for f in firecode-setup.sh agent-entrypoint.sh profile.sh chat-client.sh \
	firecode-context.md; do
	sudo -n install -m 0755 "$GUESTDIR/$f" "$TREE/opt/firecode/$f"
done
sudo -n install -m 0755 "$GUESTDIR/mkimage.sh" "$TREE/usr/local/sbin/firecode-mkimage"
sudo -n install -d "$TREE/etc/systemd/system/multi-user.target.wants"
for u in firecode-mounts.service firecode-agent.service; do
	sudo -n install -m 0644 "$GUESTDIR/systemd/$u" "$TREE/etc/systemd/system/$u"
	sudo -n ln -sf "/etc/systemd/system/$u" \
		"$TREE/etc/systemd/system/multi-user.target.wants/$u"
done

# The console: autologin on ttyS0, which is how an interactive session lands
# in a shell rather than at a login prompt nobody can answer.
sudo -n install -d "$TREE/etc/systemd/system/serial-getty@ttyS0.service.d"
sudo -n tee "$TREE/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" \
	>/dev/null <<-'EOF'
		[Service]
		ExecStart=
		ExecStart=-/sbin/agetty -o '-p -- \\u' --autologin root --keep-baud 115200,38400,9600 ttyS0 vt220
	EOF

say "the initramfs that assembles the layered root"
INITRD=/tmp/firecode-initrd
sudo -n rm -rf "$INITRD"
sudo -n install -d "$INITRD/bin" "$INITRD/proc" "$INITRD/sys" "$INITRD/dev" "$INITRD/newroot"
sudo -n cp "$TREE/usr/bin/busybox" "$INITRD/bin/busybox"
sudo -n install -m 0755 "$GUESTDIR/initramfs/init" "$INITRD/init"
sudo -n ln -sf busybox "$INITRD/bin/sh"
(cd "$INITRD" && sudo -n sh -c 'find . | cpio -o -H newc --quiet | gzip -9') \
	>/tmp/firecode-initrd.gz

if [[ -n $TOOLS ]]; then
	say "toolchains: $TOOLS"
	# mise inside the tree, so the versions are the guest's own rather than
	# this builder's. Retried, because a host on a VPN loses a mirror now and
	# then and losing one should not lose the build.
	sudo -n chroot "$TREE" /bin/bash -c "
		set -e
		export MISE_DATA_DIR=/opt/mise MISE_CONFIG_DIR=/opt/mise/config
		export MISE_STATE_DIR=/opt/mise/state MISE_CACHE_DIR=/var/cache/mise
		export MISE_HTTP_TIMEOUT=300
		curl -fsSL --retry 5 --retry-delay 3 --retry-connrefused https://mise.run | sh
		install -m 0755 /root/.local/bin/mise /usr/local/bin/mise
		mise use -g $TOOLS
		mise install -y || { sleep 10; mise install -y; }
		mise reshim
		chmod -R a+rX /opt/mise
	"
fi

say "writing the filesystem onto $DEV"
sudo -n mkfs.ext4 -q -F -L firecode-root -d "$TREE" "$DEV"
sudo -n e2fsck -fy "$DEV" >/dev/null 2>&1 || true

say "done - $(sudo -n dumpe2fs -h "$DEV" 2>/dev/null | grep -c .) fs properties, initrd at /tmp/firecode-initrd.gz"
