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
# Postgres is NOT in this list on purpose - see the PGDG step below. Noble
# ships PostgreSQL 16, and a gate that tests against a version nobody runs is
# testing a hypothetical.
PGVERSION=${PGVERSION:-18}

say "bootstrapping $SUITE"
sudo -n rm -rf "$TREE"
sudo -n mmdebstrap --variant=important --include="$BASE" \
	--components=main,universe "$SUITE" "$TREE" "$MIRROR"

# mmdebstrap leaves no working resolver in the tree, so anything that reaches
# the network from INSIDE the chroot - PGDG below, mise further down - fails
# with "Could not resolve host" while the VM around it has perfectly good DNS.
# The builder's resolver is copied in for those steps and removed again before
# the filesystem is written, so nothing about this machine ships in the image.
# It would be harmless anyway: firecode-setup.sh rewrites resolv.conf at every
# boot. Removing it keeps that the only place the guest's resolver comes from.
# The rm is not redundant: what mmdebstrap leaves there is a symlink into
# systemd-resolved's runtime directory, which nothing has created inside the
# tree, and cp refuses to write through a dangling symlink.
sudo -n rm -f "$TREE/etc/resolv.conf"
sudo -n cp /etc/resolv.conf "$TREE/etc/resolv.conf"

say "postgresql $PGVERSION, from PGDG rather than from the suite"
# A gate that stores anything wants postgres, and every run was apt-getting it
# over the network first - the orchestrator's did it all day. So it is baked.
#
# It is baked as SERVER BINARIES and not as a service: nothing here starts a
# system postgres, and the postinst is stopped from building a cluster inside
# the image (create_main_cluster, plus a policy-rc.d that makes invoke-rc.d a
# no-op in the chroot). A gate makes its own throwaway cluster with initdb in
# a temp directory and tears it down again.
#
# From PGDG and pinned by name because noble ships 16 and the instance this is
# tested against runs 18. A gate passing on a version nobody runs is testing a
# hypothetical - which was the first question asked about it, twice.
#
# The binaries land in /usr/lib/postgresql/<v>/bin, which is on nobody's PATH,
# so they are linked into /usr/local/bin - ahead of the Debian wrappers, so
# `initdb` in a gate is this version rather than whatever a wrapper picks.
# A GATE RUNS AS uid 1000 HERE, not as root, with passwordless sudo. So plain
# `initdb -D /tmp/pgdata` is what a gate wants, and the famous workaround for
# initdb refusing root - `su postgres -c initdb` - FAILS in a firecode VM:
# `install -o postgres` gets EPERM and su prompts for a password nobody can
# type. This comment said the opposite for one commit and an agent copied it
# into a brief before it was caught, which is the whole reason it is spelled
# out. initdb refusing root is true; its precondition is false here.
sudo -n chroot "$TREE" /bin/bash -s "$PGVERSION" <<-'PGDG'
	set -euo pipefail
	pgver=$1
	export DEBIAN_FRONTEND=noninteractive
	printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
	chmod 0755 /usr/sbin/policy-rc.d
	install -d /etc/postgresql-common
	echo 'create_main_cluster = false' >/etc/postgresql-common/createcluster.conf
	curl -fsSL --retry 5 --retry-delay 3 --retry-connrefused \
		https://www.postgresql.org/media/keys/ACCC4CF8.asc \
		-o /usr/share/keyrings/pgdg.asc
	. /etc/os-release
	echo "deb [signed-by=/usr/share/keyrings/pgdg.asc]" \
		"http://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
		>/etc/apt/sources.list.d/pgdg.list
	apt-get update -qq
	apt-get install -y -qq "postgresql-$pgver" "postgresql-client-$pgver" >/dev/null
	for b in "/usr/lib/postgresql/$pgver/bin/"*; do
		ln -sf "$b" "/usr/local/bin/$(basename "$b")"
	done
	# Units the postgres packages enable behind you. Deleting the .wants
	# symlink IS what `systemctl disable` does, and it works in a chroot,
	# where systemctl has no /proc to talk to.
	#
	# postgresql.service otherwise reports enabled AND active in every guest
	# while serving nothing - there is no cluster - which is precisely the
	# shape of thing that costs somebody an hour when psql cannot connect.
	# sysstat is a recommends that came along for the ride, and its timers
	# would wake up and collect in every ephemeral VM forever, which is both
	# waste and noise in anything measuring a VM.
	rm -f /etc/systemd/system/multi-user.target.wants/postgresql.service
	rm -f /etc/systemd/system/multi-user.target.wants/sysstat.service
	rm -f /etc/systemd/system/sysstat.service.wants/sysstat-collect.timer
	rm -f /etc/systemd/system/sysstat.service.wants/sysstat-summary.timer
	rm -f /usr/sbin/policy-rc.d
	apt-get clean
	# Fail the build here rather than let a gate discover it: PGDG not having
	# this version for this suite is otherwise a silent fallback to 16.
	got=$(/usr/local/bin/initdb --version)
	case $got in
	"initdb (PostgreSQL) $pgver"*) echo "[build-rootfs] $got" ;;
	*)
		echo "[build-rootfs] wanted postgres $pgver, image has: $got" >&2
		exit 1
		;;
	esac
PGDG

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

# The builder's resolver goes back out - see the copy above.
sudo -n rm -f "$TREE/etc/resolv.conf"

say "writing the filesystem onto $DEV"
sudo -n mkfs.ext4 -q -F -L firecode-root -d "$TREE" "$DEV"
sudo -n e2fsck -fy "$DEV" >/dev/null 2>&1 || true

say "done - $(sudo -n dumpe2fs -h "$DEV" 2>/dev/null | grep -c .) fs properties, initrd at /tmp/firecode-initrd.gz"
