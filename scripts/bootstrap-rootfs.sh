#!/usr/bin/env bash
# bootstrap-rootfs.sh - the first guest image, built in a VM, with no docker.
#
#   bootstrap-rootfs.sh <out.ext4> [size] [tools]
#
# guest/initramfs/bootstrap does the work; see there. This side assembles its
# three drives, boots it under firecode-vz, and believes the filesystem rather
# than the console: the result has to have a /sbin/init to be installed.
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
IMAGES="$ROOT/images"
MAC="$IMAGES/macos"
VZ="$ROOT/vendor/bin/firecode-vz"
OUT=${1:?usage: bootstrap-rootfs.sh <out.ext4> [size] [tools]}
SIZE=${2:-6G}
TOOLS=${3:-}
BASE_URL=${FIRECODE_UBUNTU_BASE:-https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release}

say() { echo "[bootstrap] $*"; }
die() {
	echo "[bootstrap] ERROR: $*" >&2
	exit 1
}

[[ -x $VZ ]] || die "no firecode-vz - run: firecode setup"
[[ -f $MAC/bootstrap-initrd.gz ]] || die "no bootstrap initramfs - run: firecode setup"
KERNEL=$(find "$IMAGES" -maxdepth 1 -name 'vmlinux-*-arm64' | sort -V | tail -1)
[[ -n $KERNEL ]] || die "no arm64 kernel - run: firecode setup"
command -v mkfs.ext4 >/dev/null || die "no mkfs.ext4 - brew install e2fsprogs"

base="$MAC/ubuntu-base-arm64.tar.gz"
if [[ ! -s $base ]]; then
	name=$(curl -fsSL "$BASE_URL/" | grep -oE 'ubuntu-base-[0-9.]+-base-arm64\.tar\.gz' | sort -uV | tail -1)
	[[ -n $name ]] || die "could not find an arm64 ubuntu-base at $BASE_URL"
	say "fetching $name"
	curl -fL --progress-bar -o "$base.new" "$BASE_URL/$name"
	curl -fsSL "$BASE_URL/SHA256SUMS" | grep " \*\?$name\$" | awk '{print $1}' >"$base.sha256"
	[[ $(sha256sum "$base.new" | cut -d' ' -f1) == $(cat "$base.sha256") ]] ||
		die "$name does not match its published sha256"
	mv -f "$base.new" "$base"
fi

# In images/, next to where the result goes, so it is a rename and not a copy.
work=$(mktemp -d "$IMAGES/.bootstrap.XXXXXX")
trap 'rm -rf "$work"' EXIT

say "drives"
truncate -s 24G "$work/scratch.ext4"
mkfs.ext4 -q -F -L firecode-scratch "$work/scratch.ext4"
truncate -s "$SIZE" "$work/target.ext4"
mkdir -p "$work/in"
cp "$base" "$work/in/ubuntu-base.tar.gz"
cp -R "$ROOT/guest" "$work/in/guest"
printf '%s\n' "$TOOLS" >"$work/in/tools"
tar --format ustar -cf "$work/input.tar" -C "$work/in" .
rm -rf "$work/in"

cp "$KERNEL" "$work/kernel"
cp "$MAC/bootstrap-initrd.gz" "$work/initrd.gz"
cat >"$work/vm-config.json" <<EOF
{
  "boot-source": {"kernel_image_path": "kernel", "initrd_path": "initrd.gz",
                  "boot_args": "console=hvc0 panic=1 quiet loglevel=3"},
  "drives": [
    {"drive_id": "scratch", "path_on_host": "scratch.ext4", "is_root_device": false, "is_read_only": false},
    {"drive_id": "target", "path_on_host": "target.ext4", "is_root_device": false, "is_read_only": false},
    {"drive_id": "input", "path_on_host": "input.tar", "is_root_device": false, "is_read_only": true}
  ],
  "machine-config": {"vcpu_count": $(( $(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo 4) )), "mem_size_mib": 4096},
  "network-interfaces": [{"iface_id": "eth0", "guest_mac": "06:00:ac:10:fe:02", "host_dev_name": "nat"}]
}
EOF

say "booting the builder - this takes a while: a whole distribution is installed"
(cd "$work" && "$VZ" --config-file vm-config.json </dev/null 2>&1) | tee "$IMAGES/bootstrap.log"

tail -5 "$IMAGES/bootstrap.log" | grep -q 'BOOTSTRAP-OK' ||
	die "the builder failed - its console is in $IMAGES/bootstrap.log"
debugfs -R "stat /sbin/init" "$work/target.ext4" >/dev/null 2>&1 ||
	die "the image has no /sbin/init - refusing to install it"

mv -f "$work/target.ext4" "$OUT"
say "rootfs: $OUT ($(du -h "$OUT" | cut -f1) on disk)"
