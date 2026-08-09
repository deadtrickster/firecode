#!/usr/bin/env bash
set -euo pipefail

# prepare-rootfs.sh - customize a base image into an agent-ready rootfs
# run as normal user (will sudo when needed for mount)

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGES="$ROOT/images"
GUEST="$ROOT/guest"

BASE="$IMAGES/agent-base.ext4"
OUT="$IMAGES/agent-firellm.ext4"

if [[ ! -f $BASE ]]; then
	echo "base not found, run ./scripts/setup.sh first (or ./bin/firellm setup)"
	exit 1
fi

echo "[prepare] using base $BASE"

# copy base so we don't mutate the original
cp -f "$BASE" "$OUT"

MNT=$(mktemp -d /tmp/firellm-root.XXXX)
sudo mount -o loop "$OUT" "$MNT"

cleanup() {
	sudo umount "$MNT" 2>/dev/null || true
	rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

echo "[prepare] mounted at $MNT"

# copy our guest files
sudo mkdir -p "$MNT/opt/firellm" "$MNT/work"
sudo cp -a "$GUEST"/. "$MNT/opt/firellm/"

# make sure we have a sane env for agents
sudo tee "$MNT/etc/environment" >/dev/null <<'E'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
FIRELLM=1
E

# install extra packages inside the image (chroot needs proc/sys/dev)
echo "[prepare] installing agent essentials inside rootfs (this can take 1-2 min)..."
sudo mount -t proc none "$MNT/proc"
sudo mount -t sysfs none "$MNT/sys"
sudo mount --bind /dev "$MNT/dev"
sudo mount --bind /dev/pts "$MNT/dev/pts" 2>/dev/null || true

sudo chroot "$MNT" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  git curl ca-certificates build-essential \
  python3 python3-pip python3-venv \
  ripgrep fd-find jq socat net-tools iproute2 \
  vim less tmux 2>&1 | tail -5
# node 20
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs || true
# bun
curl -fsSL https://bun.sh/install | bash -s -- --yes || true
ln -sf /root/.bun/bin/bun /usr/local/bin/bun || true
echo "agent packages installed"
' || echo "[prepare] some package installs may have failed, continuing"

sudo umount "$MNT/proc" "$MNT/sys" "$MNT/dev/pts" "$MNT/dev" 2>/dev/null || true

# ensure our entrypoint is executable
sudo chmod +x "$MNT/opt/firellm/agent-entrypoint.sh" 2>/dev/null || true

# create a simple init-like or ensure /sbin/init exists (the CI base usually has one)
if [[ ! -x "$MNT/sbin/init" && ! -L "$MNT/sbin/init" ]]; then
	echo "[prepare] adding minimal init shim"
	sudo tee "$MNT/sbin/init" >/dev/null <<'SH'
#!/bin/sh
export PATH=/usr/local/bin:/usr/bin:/bin
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sys /sys 2>/dev/null || true
ip link set lo up 2>/dev/null || true
# second drive from firellm is /dev/vdb (or vdc etc). Try common names.
for dev in /dev/vdb /dev/vdc /dev/sdb; do
  if [ -b "$dev" ]; then
    mkdir -p /work
    mount "$dev" /work 2>/dev/null || true
    echo "[firellm] mounted work at /work from $dev"
    break
  fi
done
echo "[firellm init] basic mounts done"
exec /opt/firellm/agent-entrypoint.sh
SH
	sudo chmod +x "$MNT/sbin/init"
fi

sudo umount "$MNT"
trap - EXIT

echo "[prepare] rootfs ready: $OUT"
ls -lh "$OUT"
echo
echo "use with: ./bin/firellm run --workdir ."
