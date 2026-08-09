#!/usr/bin/env bash
set -euo pipefail

# setup.sh - install firecracker, jailer and fetch kernel + base rootfs
# must be run as root or via sudo

if [[ $EUID -ne 0 ]]; then
	echo "run as root or with sudo" >&2
	exit 1
fi

ARCH=$(uname -m)
[[ $ARCH == x86_64 ]] || {
	echo "only x86_64 supported in this harness for now"
	exit 1
}

DEST=/usr/local/bin
mkdir -p "$DEST" /srv/jailer/firellm

echo "[setup] fetching latest firecracker release..."
RELEASE_URL="https://github.com/firecracker-microvm/firecracker/releases"
LATEST=$(basename "$(curl -fsSLI -o /dev/null -w "%{url_effective}" "${RELEASE_URL}/latest")")
echo "latest tag: $LATEST"

TARBALL="firecracker-${LATEST}-${ARCH}.tgz"
curl -fL "${RELEASE_URL}/download/${LATEST}/${TARBALL}" | tar -xz -C /tmp

# the tar contains release-xxx/firecracker and jailer
cp -f "/tmp/release-${LATEST}-${ARCH}/firecracker-${LATEST}-${ARCH}" "$DEST/firecracker"
cp -f "/tmp/release-${LATEST}-${ARCH}/jailer-${LATEST}-${ARCH}" "$DEST/jailer"
chmod +x "$DEST/firecracker" "$DEST/jailer"
ln -sf "$DEST/firecracker" "$DEST/firecracker-${LATEST}"
ln -sf "$DEST/jailer" "$DEST/jailer-${LATEST}"

echo "[setup] firecracker and jailer installed to $DEST"

# now fetch kernel + rootfs from firecracker CI artifacts (same as getting-started)
echo "[setup] fetching kernel and rootfs from CI (may take a minute)..."

S3="https://s3.amazonaws.com/spec.ccfc.min"

CI_PREFIX=$(curl -fsSL "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" |
	grep -oP '(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)' | sort | tail -1)

KERN_KEY=$(curl -fsSL "$S3?list-type=2&prefix=${CI_PREFIX}${ARCH}/vmlinux-" |
	grep -oP "(?<=<Key>)${CI_PREFIX}${ARCH}/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3}(?=</Key>)" | sort -V | tail -1)

ROOT_KEY=$(curl -fsSL "$S3?list-type=2&prefix=${CI_PREFIX}${ARCH}/ubuntu-" |
	grep -oP "(?<=<Key>)${CI_PREFIX}${ARCH}/ubuntu-[0-9]+\.[0-9]+\.squashfs(?=</Key>)" | sort -V | tail -1)

mkdir -p /home/dead/Projects/firellm/images
cd /home/dead/Projects/firellm/images

echo "kernel: $KERN_KEY"
wget -q -O "vmlinux-$(basename "$KERN_KEY" | cut -d- -f2-)" "$S3/$KERN_KEY" || curl -fL -o "vmlinux-latest" "$S3/$KERN_KEY"

echo "rootfs: $ROOT_KEY"
wget -q -O "base.squashfs" "$S3/$ROOT_KEY"

# convert squashfs to ext4 like in the docs
echo "[setup] converting to ext4 rootfs..."
if command -v unsquashfs >/dev/null; then
	rm -rf squashfs-root || true
	unsquashfs base.squashfs
	# ensure ssh dir etc for potential manual debug
	mkdir -p squashfs-root/root/.ssh squashfs-root/work
	truncate -s 2G base.ext4
	mkfs.ext4 -d squashfs-root -F base.ext4
	mv -f base.ext4 agent-base.ext4
	rm -rf squashfs-root base.squashfs
else
	echo "unsquashfs not found, leaving squashfs. You can convert manually."
	mv base.squashfs agent-base.squashfs
fi

echo "[setup] done. kernels and rootfs in $(pwd)"
ls -lh
echo
echo "next: ./scripts/prepare-rootfs.sh   (or ./bin/firellm prepare)"
