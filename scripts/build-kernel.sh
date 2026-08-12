#!/usr/bin/env bash
# Build a guest kernel that can be traced.
#
# The kernel firecracker's CI publishes is deliberately minimal: no ftrace, no
# kprobes, no uprobes, no BPF tracing, no BTF. Which means that inside a VM -
# where you are root and nothing is restricted - you still cannot attach to a
# function, trace a syscall without ptrace, or run bpftrace at all. The
# machinery has to exist in the kernel before any of it is possible.
#
# So this builds one that has it, starting from the config of the kernel that
# already boots here (guest/kernel-base.config, read out of a running guest's
# /proc/config.gz) rather than from a config someone else guessed at. Whatever
# makes the stock kernel work under firecracker is kept; the tracing options
# are added on top.
#
# Everything runs in a container, so the host needs no kernel toolchain and no
# root - the same reason `firecode prepare` needs neither.
#
#   scripts/build-kernel.sh              build for the version in the base config
#   scripts/build-kernel.sh 6.18.39      build a specific version
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
IMAGES="$ROOT/images"
BASE_CONFIG="$ROOT/guest/kernel-base.config"
BUILDER=firecode/kernel-build:latest

[[ -f $BASE_CONFIG ]] || {
	echo "build-kernel: no $BASE_CONFIG" >&2
	echo "  it comes out of a running guest:" >&2
	echo "  firecode up && firecode in 'zcat /proc/config.gz' > $BASE_CONFIG" >&2
	exit 1
}

# The version the base config was taken from, unless told otherwise. Building
# a different version against this config is fine - olddefconfig fills the
# gaps - but the default should match what is known to boot.
VERSION=${1:-$(sed -n 's/^# Linux\/x86 \([0-9.]*\) Kernel Configuration/\1/p' "$BASE_CONFIG" | head -1)}
[[ -n $VERSION ]] || {
	echo "build-kernel: cannot tell which version to build; pass one" >&2
	exit 1
}
OUT="$IMAGES/vmlinux-$VERSION-debug"
MAJOR=${VERSION%%.*}

command -v docker >/dev/null 2>&1 || {
	echo "build-kernel: docker is required" >&2
	exit 1
}

echo "[kernel] building $VERSION with tracing enabled -> $OUT"

# What the stock kernel is missing, and what each one buys:
#
#   FTRACE, FUNCTION_TRACER   trace kernel functions; the tracefs everything
#   DYNAMIC_FTRACE            else attaches to
#   FTRACE_SYSCALLS           syscall tracing without a ptrace stop per call
#   KPROBES, KPROBE_EVENTS    attach to any kernel function
#   UPROBES, UPROBE_EVENTS    attach to a *userspace* function - serened's own
#   BPF_EVENTS, BPF_JIT       bpftrace and BCC
#   DEBUG_INFO_BTF            what modern BPF needs to know the kernel's types
#   STACK_TRACER, STACKTRACE  usable stacks in a profile
#
# BTF needs DWARF at build time and pahole to convert it, which is why the
# builder installs dwarves and why the build is slower than a stock one.
ENABLE=(
	FTRACE FUNCTION_TRACER FUNCTION_GRAPH_TRACER DYNAMIC_FTRACE
	FTRACE_SYSCALLS STACK_TRACER TRACER_SNAPSHOT
	KPROBES KPROBE_EVENTS OPTPROBES
	UPROBES UPROBE_EVENTS
	BPF_SYSCALL BPF_EVENTS BPF_JIT BPF_JIT_ALWAYS_ON
	DEBUG_INFO DEBUG_INFO_DWARF5 DEBUG_INFO_BTF DEBUG_FS
	PERF_EVENTS STACKTRACE MAGIC_SYSRQ
	DEBUG_KERNEL KALLSYMS KALLSYMS_ALL
	MODULES MODULE_UNLOAD
)

# What has to be OFF for an out-of-tree module to work at all.
#
# TRIM_UNUSED_KSYMS drops every exported symbol that nothing built in refers
# to. It is a sensible size win for an appliance kernel and fatal here: a GPU
# driver is out of tree by definition, so the symbols it needs are exactly the
# ones nothing in tree uses, and they are gone before it ever gets to compile.
# The failure arrives as "unknown symbol" at load time, long after the build
# looked like it worked.
DISABLE=(
	TRIM_UNUSED_KSYMS
	MODULE_SIG_FORCE
)

mkdir -p "$IMAGES"

# The builder image. Cached by docker after the first run.
docker build -q -t "$BUILDER" - <<'DOCKERFILE' >/dev/null
FROM ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
	build-essential flex bison bc libelf-dev libssl-dev \
	dwarves cpio kmod rsync curl xz-utils python3 \
	&& rm -rf /var/lib/apt/lists/*
DOCKERFILE

docker run --rm \
	-v "$IMAGES:/out" \
	-v "$BASE_CONFIG:/base.config:ro" \
	-e VERSION="$VERSION" -e MAJOR="$MAJOR" \
	-e OUT_NAME="$(basename "$OUT")" \
	-e ENABLE="${ENABLE[*]}" \
	-e DISABLE="${DISABLE[*]}" \
	-e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
	"$BUILDER" bash -euo pipefail -c '
	cd /tmp
	echo "[kernel] fetching linux-$VERSION"
	curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-${VERSION}.tar.xz" \
		| tar -xJf -
	cd "linux-$VERSION"

	cp /base.config .config
	for opt in $ENABLE; do
		./scripts/config --enable "$opt"
	done
	for opt in $DISABLE; do
		./scripts/config --disable "$opt"
	done
	# Asked for, but not at the price of a kernel that cannot boot: anything
	# these options need gets pulled in, and anything unavailable is dropped,
	# by the kernel own dependency resolver rather than by this script.
	make olddefconfig >/dev/null

	missing=""
	for opt in FTRACE KPROBES UPROBES BPF_EVENTS DEBUG_INFO_BTF; do
		grep -q "^CONFIG_$opt=y" .config || missing="$missing $opt"
	done
	[ -z "$missing" ] || { echo "[kernel] refused to enable:$missing" >&2; exit 1; }
	# And the one that has to be absent rather than present.
	if grep -q "^CONFIG_TRIM_UNUSED_KSYMS=y" .config; then
		echo "[kernel] TRIM_UNUSED_KSYMS survived: out-of-tree modules will not load" >&2
		exit 1
	fi

	echo "[kernel] compiling with $(nproc) jobs (this is the slow part)"
	make -j"$(nproc)" vmlinux

	# Module.symvers, which is what an out-of-tree module is linked against.
	# It falls out of `make modules` and not out of `make vmlinux`, so a build
	# that only wanted a kernel never produces it - and a module built without
	# it compiles cleanly, warns once about "Symbol version dump is missing",
	# and then cannot resolve a single kernel symbol at load time.
	#
	# Nothing here is configured as a module, so this is quick; it is modpost
	# over the built-in objects that matters.
	make -j"$(nproc)" modules

	# perf, from the same tree.
	#
	# Distributions package perf per kernel version, and there is no package
	# for a kernel built here - so a guest is left borrowing a released perf
	# and hoping the mismatch does not matter. It usually does not for
	# software events, but "usually" is a poor foundation for a profiler, and
	# the tools are sitting right there in the source that produced the kernel.
	#
	# Static, so it can be dropped into any guest without carrying its
	# libraries. NO_LIBTRACEEVENT and friends keep it building without a pile
	# of optional dependencies; what remains is record, report and script.
	echo "[kernel] building perf from the same tree"
	if make -C tools/perf -j"$(nproc)" \
		NO_LIBTRACEEVENT=1 NO_LIBELF=0 NO_JVMTI=1 NO_LIBBPF=1 \
		NO_LIBPYTHON=1 NO_LIBPERL=1 NO_SLANG=1 NO_LIBCAP=1 \
		NO_JEVENTS=1 \
		LDFLAGS=-static >/tmp/perf-build.log 2>&1; then
		cp tools/perf/perf "/out/perf-$VERSION"
		chown "$HOST_UID:$HOST_GID" "/out/perf-$VERSION"
		echo "[kernel] built perf-$VERSION"
	else
		echo "[kernel] perf did not build - the kernel is still fine" >&2
		tail -5 /tmp/perf-build.log >&2
	fi

	# DWARF was needed to generate BTF and is dead weight afterwards - it is
	# a third of a gigabyte that firecracker would parse and never load.
	# .BTF survives strip --strip-debug because the kernel actually maps it.
	# The tree an out-of-tree module is built against. No distribution ships
	# headers for a kernel built here, so a guest that wants to compile a
	# driver has nothing to compile against unless it comes from this build.
	# Object files are dropped; the built host tools under scripts/ are not,
	# because a module build runs them.
	echo "[kernel] packing the build tree for module builds"
	tar --exclude="*.o" --exclude="*.cmd" --exclude=".tmp_*" --exclude="*.ko" \
		-C /tmp -cJf "/out/kernel-build-$VERSION.tar.xz" "linux-$VERSION"
	chown "$HOST_UID:$HOST_GID" "/out/kernel-build-$VERSION.tar.xz"

	strip --strip-debug vmlinux -o "/out/$OUT_NAME.tmp"
	chown "$HOST_UID:$HOST_GID" "/out/$OUT_NAME.tmp"
	mv -f "/out/$OUT_NAME.tmp" "/out/$OUT_NAME"
	echo "[kernel] built $OUT_NAME"
'

echo
ls -lh "$OUT"
echo
echo "use it with:  firecode <command> --kernel debug"
