#!/usr/bin/env bash
# setup.sh - fetch firecracker, jailer and a guest kernel.
#
# Needs no root: the binaries land in vendor/bin inside the checkout. Only
# running a VM needs privileges, and only for the jailer and the tap device.
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
IMAGES="$ROOT/images"
VENDOR="$ROOT/vendor/bin"

ARCH=$(uname -m)

WANT_DEBUG_KERNEL=0
for arg in "$@"; do
	case "$arg" in
	--debug-kernel) WANT_DEBUG_KERNEL=1 ;;
	*)
		echo "setup: unknown argument $arg" >&2
		exit 1
		;;
	esac
done
[[ $ARCH == x86_64 ]] || {
	echo "setup: only x86_64 is supported for now (this is $ARCH)" >&2
	exit 1
}

mkdir -p "$VENDOR" "$IMAGES"

RELEASE_URL="https://github.com/firecracker-microvm/firecracker/releases"

if [[ -x $VENDOR/firecracker && -x $VENDOR/jailer && ${1:-} != --force ]]; then
	echo "[setup] firecracker $("$VENDOR/firecracker" --version | head -1) already in vendor/bin"
else
	echo "[setup] fetching the latest firecracker release"
	LATEST=$(basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$RELEASE_URL/latest")")
	echo "[setup] release $LATEST"

	TMP=$(mktemp -d)
	trap 'rm -rf "$TMP"' EXIT
	curl -fL "$RELEASE_URL/download/$LATEST/firecracker-$LATEST-$ARCH.tgz" | tar -xz -C "$TMP"

	install -m 0755 "$TMP/release-$LATEST-$ARCH/firecracker-$LATEST-$ARCH" "$VENDOR/firecracker"
	install -m 0755 "$TMP/release-$LATEST-$ARCH/jailer-$LATEST-$ARCH" "$VENDOR/jailer"
	echo "[setup] installed firecracker and jailer in $VENDOR"
fi

# The guest kernel. Firecracker's CI publishes uncompressed vmlinux images
# with the virtio drivers built in, which is exactly what we need.
if compgen -G "$IMAGES/vmlinux-*" >/dev/null; then
	echo "[setup] kernel already present: $(find "$IMAGES" -maxdepth 1 -name 'vmlinux-*' | sort -V | tail -1)"
else
	echo "[setup] fetching a guest kernel"
	S3="https://s3.amazonaws.com/spec.ccfc.min"

	CI_PREFIX=$(curl -fsSL "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" |
		grep -oP '(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)' | sort | tail -1)
	[[ -n $CI_PREFIX ]] || {
		echo "setup: could not work out the firecracker CI prefix" >&2
		exit 1
	}

	KERN_KEY=$(curl -fsSL "$S3?list-type=2&prefix=${CI_PREFIX}${ARCH}/vmlinux-" |
		grep -oP "(?<=<Key>)${CI_PREFIX}${ARCH}/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3}(?=</Key>)" |
		sort -V | tail -1)
	[[ -n $KERN_KEY ]] || {
		echo "setup: no kernel found under $CI_PREFIX" >&2
		exit 1
	}

	echo "[setup] kernel $KERN_KEY"
	curl -fL --progress-bar -o "$IMAGES/$(basename "$KERN_KEY")" "$S3/$KERN_KEY"
fi

# The traceable kernel, which CI builds and publishes because building one
# costs an hour of CPU and the result is identical for everybody. Optional:
# every VM boots fine without it, it just cannot be traced from inside.
if [[ ${WANT_DEBUG_KERNEL:-0} == 1 ]]; then
	if compgen -G "$IMAGES/vmlinux-*-debug" >/dev/null; then
		echo "[setup] debug kernel already present: $(find "$IMAGES" -maxdepth 1 -name 'vmlinux-*-debug' | sort -V | tail -1)"
	elif ! command -v gh >/dev/null 2>&1; then
		echo "setup: gh is needed to pull the debug kernel from the repo's releases" >&2
		echo "  or build it yourself: scripts/build-kernel.sh" >&2
	else
		TAG=$(gh release list --limit 100 2>/dev/null |
			grep -oE 'kernel-[0-9.]+-debug' | sort -V | tail -1)
		if [[ -z $TAG ]]; then
			echo "setup: no kernel release published yet - run the 'guest kernel' workflow," >&2
			echo "  or build it yourself: scripts/build-kernel.sh" >&2
		else
			echo "[setup] pulling $TAG"
			gh release download "$TAG" --dir "$IMAGES" --clobber --pattern 'vmlinux-*'
			(cd "$IMAGES" && sha256sum -c ./*-debug.sha256) ||
				echo "setup: WARNING: checksum mismatch on the debug kernel" >&2
		fi
	fi
fi

echo
echo "[setup] done."
echo "  binaries: $VENDOR"
echo "  images:   $IMAGES"
echo
echo "next:  firecode prepare"
