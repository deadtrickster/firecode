#!/usr/bin/env bash
# prepare-rootfs.sh - build the guest rootfs image.
#
# Uses Docker rather than loop-mounting and chrooting, so this needs no root:
# the container is exported and converted to ext4 by `mkfs.ext4 -d` running
# inside a throwaway container (which is root, so ownership survives).
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
IMAGES="$ROOT/images"
GUEST="$ROOT/guest"

IMAGE_TAG=firecode/rootfs:latest
OUT="$IMAGES/agent-firecode.ext4"
SIZE=${FIRECODE_ROOTFS_SIZE:-6G}
TOOLCHAINS=lean
# Remembered between builds. A rebuild for an unrelated reason must not
# silently drop the toolchain every project depends on.
TOOLS_FILE="$IMAGES/.tools"
TOOLS=${FIRECODE_TOOLS:-}
[[ -z $TOOLS && -f $TOOLS_FILE ]] && TOOLS=$(cat "$TOOLS_FILE")
FORCE=0
NO_CACHE=""

usage() {
	cat <<'EOF'
usage: firecode prepare [--full] [--force] [--no-cache] [--size 6G]

  --with LIST tools for the base image, which every project inherits.
              mise syntax, quoted: --with "dotnet@10 java@temurin-21 uv"
              remembered, so later rebuilds keep them. --with "" to clear.
  --full      also install rust, go, zig, clang/llvm and sbcl
              (much slower build, roughly 3x the image size)
  --force     rebuild even if the image looks current
  --no-cache  ignore the Docker layer cache
  --size      ext4 image size (default 6G, or 12G with --full)
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--full)
		TOOLCHAINS=full
		shift
		;;
	--with)
		TOOLS="$2"
		shift 2
		;;
	-f | --force)
		FORCE=1
		shift
		;;
	--no-cache)
		NO_CACHE="--no-cache"
		shift
		;;
	--size)
		SIZE="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "prepare: unknown option $1" >&2
		usage >&2
		exit 2
		;;
	esac
done

if [[ $TOOLCHAINS == full && ${FIRECODE_ROOTFS_SIZE:-} == "" && $SIZE == 6G ]]; then
	SIZE=12G
fi

command -v docker >/dev/null 2>&1 || {
	echo "prepare: docker is required to build the rootfs" >&2
	exit 1
}
docker info >/dev/null 2>&1 || {
	echo "prepare: cannot talk to the docker daemon (is your user in the docker group?)" >&2
	exit 1
}

mkdir -p "$IMAGES"

if [[ -f $OUT && $FORCE -eq 0 ]]; then
	if ! find "$GUEST" -newer "$OUT" -print -quit 2>/dev/null | grep -q .; then
		echo "[prepare] $OUT is up to date (use --force to rebuild)"
		exit 0
	fi
fi

echo "[prepare] building container image ($TOOLCHAINS toolchains)"
[[ -n $TOOLS ]] && echo "[prepare] base toolchain: $TOOLS"
mkdir -p "$IMAGES"
printf '%s' "$TOOLS" >"$TOOLS_FILE"
# shellcheck disable=SC2086  # NO_CACHE is a deliberate single optional flag
docker build $NO_CACHE \
	--build-arg "FIRECODE_TOOLCHAINS=$TOOLCHAINS" \
	--build-arg "FIRECODE_TOOLS=$TOOLS" \
	-t "$IMAGE_TAG" \
	"$GUEST"

TAR="$IMAGES/.rootfs-export.tar"
cleanup() { rm -f "$TAR"; }
trap cleanup EXIT

echo "[prepare] exporting container filesystem"
CID=$(docker create "$IMAGE_TAG" /bin/true)
docker export "$CID" -o "$TAR"
docker rm -f "$CID" >/dev/null

echo "[prepare] converting to ext4 ($SIZE)"
docker run --rm \
	-v "$IMAGES:/out" \
	--entrypoint /usr/local/sbin/firecode-mkimage \
	"$IMAGE_TAG" \
	"/out/$(basename "$TAR")" "/out/$(basename "$OUT")" \
	"$SIZE" "$(id -u)" "$(id -g)"

echo
echo "[prepare] rootfs ready:"
ls -lh "$OUT"
echo
echo "next:  firecode claude -p 'what is in this repo?'"
