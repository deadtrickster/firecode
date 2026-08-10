#!/usr/bin/env bash
# Convert an exported container filesystem into an ext4 image.
#
# Runs *inside* the guest image (which carries e2fsprogs), as root, so file
# ownership survives the round trip. That is why `firecode prepare` needs no
# sudo on the host.
#
# usage: firecode-mkimage <rootfs.tar> <out.ext4> <size> <host-uid> <host-gid>
set -euo pipefail

TAR=$1
OUT=$2
SIZE=$3
HOST_UID=$4
HOST_GID=$5

STAGE=/tmp/firecode-rootdir

echo "[mkimage] extracting $TAR"
rm -rf "$STAGE"
mkdir -p "$STAGE"
tar -C "$STAGE" -xf "$TAR"

# Docker injects these into a running container; in an image they are stale
# leftovers. The guest writes its own at boot.
rm -f "$STAGE/.dockerenv"

echo "[mkimage] building $SIZE ext4 image"
rm -f "$OUT.tmp"
truncate -s "$SIZE" "$OUT.tmp"
mkfs.ext4 -q -F -L firecode-root -d "$STAGE" "$OUT.tmp"

chown "$HOST_UID:$HOST_GID" "$OUT.tmp"
mv -f "$OUT.tmp" "$OUT"

# The initramfs that assembles the layered root. Built into this image, needed
# on the host, so it comes out alongside the rootfs.
if [ -f /firecode-initrd.gz ]; then
	cp -f /firecode-initrd.gz "$(dirname "$OUT")/initrd.gz"
	chown "$HOST_UID:$HOST_GID" "$(dirname "$OUT")/initrd.gz"
	echo "[mkimage] wrote $(dirname "$OUT")/initrd.gz"
fi
rm -rf "$STAGE"

echo "[mkimage] wrote $OUT"
