#!/usr/bin/env bash
# setup-macos.sh - the macOS half of `firecode setup`.
#
# There is no firecracker and no KVM here. The VMM is firecode-vz, built from
# macos/ over Apple's Virtualization.framework, and the guest is arm64. Its
# kernel is Ubuntu's: Virtualization.framework puts every device on PCI, which
# firecracker's kernels have no support for, and building one needs a Linux
# machine this does not yet have.
#
# Ubuntu builds overlayfs and vsock as modules, so the initramfs carries them
# and loads them before assembling the root. Everything else the guest needs -
# virtio-pci, -blk, -net, -console, -balloon, ext4, fuse - is built in.
#
# Produces, in images/:
#   vmlinux-<ver>-arm64   the uncompressed Image Virtualization.framework boots
#   initrd.gz             firecode's initramfs, with those modules
#   macos/                busybox and the modules, for the bootstrap initramfs
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
IMAGES="$ROOT/images"
VENDOR="$ROOT/vendor/bin"
MAC="$IMAGES/macos"
PORTS=${FIRECODE_UBUNTU_PORTS:-http://ports.ubuntu.com/ubuntu-ports}
SUITE=${FIRECODE_KERNEL_SUITE:-noble-updates}

FORCE=0
for arg in "$@"; do
	case "$arg" in
	--force) FORCE=1 ;;
	--debug-kernel) ;; # Ubuntu's kernel already has ftrace, kprobes, BPF and BTF
	*)
		echo "setup: unknown argument $arg" >&2
		exit 1
		;;
	esac
done

say() { echo "[setup] $*"; }

[[ $(uname -m) == arm64 ]] || {
	echo "setup: an Intel Mac has no Virtualization.framework support for this - arm64 only" >&2
	exit 1
}
for t in swiftc codesign curl zstd cpio gzip; do
	command -v "$t" >/dev/null || {
		echo "setup: $t is missing$([[ $t == zstd ]] && echo " - brew install zstd")$([[ $t == swiftc ]] && echo " - xcode-select --install")" >&2
		exit 1
	}
done

mkdir -p "$VENDOR" "$IMAGES" "$MAC"

say "building firecode-vz"
"$ROOT/macos/build.sh" "$VENDOR/firecode-vz" >/dev/null
say "  $VENDOR/firecode-vz (ad-hoc signed, with the virtualization entitlement)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# One Packages index answers every question below.
fetch_index() {
	[[ -s $TMP/Packages ]] && return 0
	curl -fsSL "$PORTS/dists/$SUITE/main/binary-arm64/Packages.xz" | xz -dc >"$TMP/Packages"
}

# Field $2 of package $1 in the index.
pkg_field() {
	awk -v p="$1" -v f="$2" '
		$0 == "Package: " p { on = 1; next }
		/^Package: / { on = 0 }
		on && index($0, f ": ") == 1 { print substr($0, length(f) + 3); exit }
	' "$TMP/Packages"
}

# Unpack a .deb's data into $2. bsdtar reads the ar container and the
# compressed tarball inside it.
fetch_deb() {
	local pkg=$1 dest=$2 file
	file=$(pkg_field "$pkg" Filename)
	[[ -n $file ]] || {
		echo "setup: $pkg is not in $SUITE" >&2
		exit 1
	}
	curl -fsSL -o "$TMP/$pkg.deb" "$PORTS/$file"
	mkdir -p "$TMP/$pkg.x" "$dest"
	tar -xf "$TMP/$pkg.deb" -C "$TMP/$pkg.x"
	tar -xf "$TMP/$pkg.x"/data.tar* -C "$dest"
}

unpack_kernel() {
	local in=$1 out=$2
	if [[ $(head -c 8 "$in" | tail -c 4) == zimg ]]; then
		local comp
		comp=$(python3 - "$in" "$out.payload" <<-'PY'
			import struct, sys
			data = open(sys.argv[1], "rb").read()
			off, size = struct.unpack_from("<II", data, 8)
			open(sys.argv[2], "wb").write(data[off:off + size])
			print(data[24:32].rstrip(b"\0").decode())
		PY
		)
		case $comp in
		zstd) zstd -qdc "$out.payload" >"$out" ;;
		gzip) gzip -dc "$out.payload" >"$out" ;;
		*)
			echo "setup: zboot kernel compressed with $comp, which this cannot unpack" >&2
			exit 1
			;;
		esac
		rm -f "$out.payload"
	else
		gzip -dc "$in" >"$out"
	fi
	[[ $(head -c 60 "$out" | tail -c 4) == ARMd ]] || {
		echo "setup: $in did not unpack to an arm64 Image" >&2
		exit 1
	}
}

if compgen -G "$IMAGES/vmlinux-*-arm64" >/dev/null && [[ -f $MAC/busybox && -d $MAC/modules ]] && ((!FORCE)); then
	say "kernel already present: $(basename "$(find "$IMAGES" -maxdepth 1 -name 'vmlinux-*-arm64' | sort -V | tail -1)")"
else
	fetch_index
	ver=$(grep -oE '^Package: linux-image-unsigned-[0-9.]+-[0-9]+-generic$' "$TMP/Packages" |
		sed 's/^Package: linux-image-unsigned-//' | sort -V | tail -1)
	[[ -n $ver ]] || {
		echo "setup: no arm64 generic kernel in $SUITE" >&2
		exit 1
	}
	say "kernel $ver, from Ubuntu $SUITE"
	fetch_deb "linux-image-unsigned-$ver" "$TMP/img"
	fetch_deb "linux-modules-$ver" "$TMP/mod"
	fetch_deb busybox-static "$TMP/bb"

	# Virtualization.framework boots an uncompressed arm64 Image. Ubuntu
	# ships it gzipped, or - from 7.0 - as EFI zboot: a PE stub carrying the
	# compressed Image, its offset and size at bytes 8 and 12 and the
	# compressor's name at 24.
	unpack_kernel "$TMP/img/boot/vmlinuz-$ver" "$IMAGES/vmlinux-$ver-arm64.new"
	mv -f "$IMAGES/vmlinux-$ver-arm64.new" "$IMAGES/vmlinux-$ver-arm64"

	# The modules the root cannot be assembled or reached without, in the
	# order they have to load. No depmod here, so the order is written down;
	# modinfo's depends= is what decided it.
	rm -rf "$MAC/modules"
	mkdir -p "$MAC/modules"
	mods=(overlay vsock vmw_vsock_virtio_transport_common vmw_vsock_virtio_transport)
	for m in "${mods[@]}"; do
		f=$(find "$TMP/mod/lib/modules/$ver/kernel" -name "$m.ko.zst" | head -1)
		[[ -n $f ]] || {
			echo "setup: $m.ko is not in linux-modules-$ver" >&2
			exit 1
		}
		zstd -qdc "$f" >"$MAC/modules/$m.ko"
	done
	printf '%s\n' "${mods[@]}" >"$MAC/modules/load"
	install -m 0755 "$TMP/bb/usr/bin/busybox" "$MAC/busybox"
	printf '%s\n' "$ver" >"$MAC/kernel-version"
fi

# An initramfs: busybox, the modules, and an init. Owned by root inside the
# archive whatever owns the files out here.
make_initrd() {
	local init=$1 out=$2 dir="$TMP/initrd.$$"
	rm -rf "$dir"
	mkdir -p "$dir/bin" "$dir/proc" "$dir/sys" "$dir/dev" "$dir/newroot" "$dir/lib"
	cp "$MAC/busybox" "$dir/bin/busybox"
	ln -s busybox "$dir/bin/sh"
	cp -R "$MAC/modules" "$dir/lib/modules"
	install -m 0755 "$init" "$dir/init"
	(cd "$dir" && find . | cpio -o -H newc -R 0:0 2>/dev/null | gzip -9) >"$out.new"
	mv -f "$out.new" "$out"
	rm -rf "$dir"
}

say "initramfs"
make_initrd "$ROOT/guest/initramfs/init" "$IMAGES/initrd.gz"
make_initrd "$ROOT/guest/initramfs/bootstrap" "$MAC/bootstrap-initrd.gz"

echo
say "done."
say "  vmm:     $VENDOR/firecode-vz"
say "  kernel:  $(find "$IMAGES" -maxdepth 1 -name 'vmlinux-*-arm64' | sort -V | tail -1)"
echo
echo "next:  firecode prepare"
