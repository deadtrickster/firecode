#!/bin/bash
# jail-wrapper.sh - the only thing firecode's sudoers rule lets you run as root.
#
# Installed root-owned by install-privileged.sh as /usr/local/libexec/firecode/jail.
# This copy in the repository is the source; the installed one is what runs, and
# nothing in a directory you can write to is ever executed as root.
#
# WHY NOT JUST THE JAILER. The jailer execs --exec-file as --uid, and checks
# little more than that the file's name contains "firecracker". So a sudoers
# rule for the jailer with free arguments is root for anything running as you:
# `sudo jailer --uid 0 --exec-file ./firecracker-is-a-shell`. Moving the binary
# somewhere root-owned does not change that; constraining the arguments does.
#
# So this accepts exactly what firecode passes, and refuses anything else:
#
#   jail run --id ID --exec-file F --uid U --gid G --chroot-base-dir B
#            --new-pid-ns [--cgroup-version 2] [--cgroup K=V ...] -- ARGS...
#       F must be the root-owned firecracker installed beside this script,
#       U and G must be the caller's own and not root, B must be the
#       root-owned jail base, and K must be memory.max, cpu.max or pids.max
#       with numeric values. ARGS go to firecracker, which runs as U inside
#       the chroot, so they are not this script's business.
#
#   jail prepare ID
#       Make the run's chroot directory and give it to the caller, who puts
#       the kernel and drives in it before booting. The base is root-owned.
#
#   jail clean ID
#       Remove one jail directory, for the same reason.
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

LIBEXEC=/usr/local/libexec/firecode
# Rewritten by install-privileged.sh to a root-owned directory on the same
# filesystem as the firecode checkout, so drives hardlink in rather than copy.
BASE=/var/lib/firecode/jail

die() {
	echo "firecode jail: $*" >&2
	exit 2
}

[[ $EUID -eq 0 ]] || die "must be run through sudo"
caller_uid=${SUDO_UID:-}
caller_gid=${SUDO_GID:-}
[[ $caller_uid =~ ^[0-9]+$ && $caller_gid =~ ^[0-9]+$ ]] || die "no sudo caller"
((caller_uid != 0 && caller_gid != 0)) || die "refusing to jail as root"

valid_id() { [[ $1 =~ ^[A-Za-z0-9-]{1,64}$ ]]; }

cmd=${1:-}
shift || true

case $cmd in
prepare)
	{ [[ $# -eq 1 ]] && valid_id "$1"; } || die "usage: jail prepare ID"
	[[ -e $BASE/firecracker/$1 ]] && die "jail $1 already exists"
	install -d -o root -g root -m 0755 "$BASE/firecracker" "$BASE/firecracker/$1"
	install -d -o "$caller_uid" -g "$caller_gid" -m 0755 "$BASE/firecracker/$1/root"
	exit 0
	;;
clean)
	{ [[ $# -eq 1 ]] && valid_id "$1"; } || die "usage: jail clean ID"
	target="$BASE/firecracker/$1"
	[[ -L $target ]] && die "$target is a link"
	[[ -d $target ]] || exit 0
	rm -rf --one-file-system -- "$target"
	exit 0
	;;
run) ;;
*) die "usage: jail run ... | jail prepare ID | jail clean ID" ;;
esac

id="" exec_file="" uid="" gid="" base="" pidns=0
declare -a extra=()
while [[ $# -gt 0 ]]; do
	case $1 in
	--id) id=${2:-} && shift 2 ;;
	--exec-file) exec_file=${2:-} && shift 2 ;;
	--uid) uid=${2:-} && shift 2 ;;
	--gid) gid=${2:-} && shift 2 ;;
	--chroot-base-dir) base=${2:-} && shift 2 ;;
	--new-pid-ns) pidns=1 && shift ;;
	--cgroup-version)
		[[ ${2:-} == 2 ]] || die "only cgroup v2"
		extra+=(--cgroup-version 2)
		shift 2
		;;
	--cgroup)
		[[ ${2:-} =~ ^(memory\.max=[0-9]+|pids\.max=[0-9]+|cpu\.max=[0-9]+\ [0-9]+)$ ]] ||
			die "cgroup setting not allowed: ${2:-}"
		extra+=(--cgroup "$2")
		shift 2
		;;
	--) break ;;
	*) die "argument not allowed: $1" ;;
	esac
done
[[ ${1:-} == -- ]] || die "expected -- before the firecracker arguments"

valid_id "$id" || die "bad --id"
[[ $exec_file == "$LIBEXEC/firecracker" ]] || die "--exec-file must be $LIBEXEC/firecracker"
[[ $uid == "$caller_uid" && $gid == "$caller_gid" ]] || die "--uid/--gid must be your own"
[[ $base == "$BASE" ]] || die "--chroot-base-dir must be $BASE"
((pidns)) || die "--new-pid-ns is required"

exec "$LIBEXEC/jailer" --id "$id" --exec-file "$exec_file" --uid "$uid" --gid "$gid" \
	--chroot-base-dir "$base" --new-pid-ns ${extra+"${extra[@]}"} "$@"
