#!/usr/bin/env bash
#
# REAP VM LAYER IMAGES, WHICH NOTHING ELSE DOES.
#
#   scripts/reap-layers.sh                 # say what it would remove, remove nothing
#   scripts/reap-layers.sh --days 7        # a different cutoff
#   scripts/reap-layers.sh --apply         # actually remove them
#
# Measured 2026-08-29 by claude-host, filed as 01M17AKXX74DPAGDXC1YZ2EGGR:
# state held 147 files named *-layer.ext4 accounting for 169G, and on 2026-08-30
# root was at 99% - 32G free of 2.3T - with 146 layers holding 266G.
#
# WHY IT ONLY EVER GOES UP. A layer is the writable upper of one project's VM.
# Blocks allocated while a guest runs stay allocated when it stops: nothing
# punches holes back, nothing truncates, and `firecode gc` does not touch state
# at all - it clears runs, scratch, results and worktrees. So every VM a project
# ever ran ratchets the number and no ordinary command lowers it.
#
# THE FILES ARE SPARSE, so `du -sh --apparent-size` says 3.5T and `du -sh` says
# 266G. The second is the one that fills the disk. Every number printed here is
# the allocated one.
#
# WHAT A LAYER IS WORTH, because this is a delete and the cost is not zero: it
# holds that project's accumulated guest state - packages installed inside,
# caches, anything written outside the project directory. Removing one costs the
# next run of THAT project the time to build it again. It is a cache, not a
# record, and nothing in it is the only copy of anything. That is why age is the
# test: a project nobody has run in two weeks is not waiting on its cache.
#
# TWO GUARDS, AND A LIVE RUN IS NEVER TOUCHED WHATEVER THE AGE.
#
#   a layer whose project has a RUNNING VM is skipped - liveness is asked of
#   the run's cgroup, by reading cgroup.procs, the same way sweep_scratch and
#   `firecode list` ask it. Not by process name: a name matches the wrong
#   process eventually, and this command deletes disks.
#
#   a layer modified inside the cutoff is skipped, so a project somebody is
#   working on this week keeps its cache even between runs.
set -euo pipefail

SELF=$(readlink -f "$0")
# FIRECODE_ROOT WINS, because this script's own location is not always the
# installation's. Run out of a git worktree it sits beside an empty tree while
# state/ and runs/ are in the checkout the symlink at ~/bin/firecode resolves
# to - so a bare location guess reads the wrong disk and reports nothing to
# reap, which is a comfortable and completely wrong answer.
ROOT=${FIRECODE_ROOT:-$(cd "$(dirname "$SELF")/.." && pwd)}
STATE_DIR="$ROOT/state"
RUNS="$ROOT/runs"

days=14
apply=no
while [ $# -gt 0 ]; do
	case $1 in
	--days)
		days=${2:?--days needs a number}
		shift 2
		;;
	--apply)
		apply=yes
		shift
		;;
	-h | --help)
		sed -n '2,30p' "$SELF" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		printf 'reap-layers: unknown argument %s\n' "$1" >&2
		exit 2
		;;
	esac
done

[ -d "$STATE_DIR" ] || {
	printf 'reap-layers: no state directory at %s\n' "$STATE_DIR" >&2
	exit 2
}

# THE SLUG OF EVERY PROJECT WITH A LIVE VM. project_slug() in bin/firecode is
# basename(dir) sanitised, then the first 8 of sha256(dir) - reproduced here
# rather than sourced, because bin/firecode is 271K of script with side effects
# at load. If that ever changes, this over-reports live layers and reaps fewer,
# which is the safe direction to be wrong in.
live=""
if [ -d "$RUNS" ]; then
	for rd in "$RUNS"/*/; do
		[ -f "$rd/project" ] && [ -f "$rd/cgroup" ] || continue
		cg=$(cat "$rd/cgroup" 2>/dev/null) || continue
		[ -n "$cg" ] || continue
		procs=$(cat "$cg/cgroup.procs" "$cg"/*/cgroup.procs 2>/dev/null || true)
		[ -n "${procs//[[:space:]]/}" ] || continue
		dir=$(cat "$rd/project" 2>/dev/null) || continue
		hash=$(printf '%s' "$dir" | sha256sum | cut -c1-8)
		live="$live $(basename "$dir" | tr -c 'A-Za-z0-9._-' '-')-$hash"
	done
fi

# COUNTED BEFORE ANYTHING IS REMOVED. Taking this total after the loop is
# right in a dry run and wrong under --apply, because by then the files are
# gone: the first real run reported "14 newer than 14 days" where the dry run
# had correctly said 80. A number that changes meaning depending on whether the
# command did anything is worse than no number.
total_before=$(find "$STATE_DIR" -maxdepth 1 -name '*-layer.ext4' 2>/dev/null | wc -l)
kept_live=0 kept_young=0 n=0 bytes=0
skipped_live=""
while IFS= read -r f; do
	[ -n "$f" ] || continue
	base=$(basename "$f")
	slug=${base%-layer.ext4}
	held=no
	for l in $live; do
		[ "$slug" = "$l" ] && held=yes && break
	done
	if [ "$held" = yes ]; then
		kept_live=$((kept_live + 1))
		skipped_live="$skipped_live $slug"
		continue
	fi
	sz=$(du -B1 "$f" 2>/dev/null | cut -f1) || sz=0
	n=$((n + 1))
	bytes=$((bytes + sz))
	printf '%s  %s  %s\n' "$(numfmt --to=iec --suffix=B --padding=8 "$sz")" \
		"$(date -r "$f" '+%Y-%m-%d')" "$base"
	[ "$apply" = yes ] && rm -f "$f"
done < <(find "$STATE_DIR" -maxdepth 1 -name '*-layer.ext4' -mtime "+$days" 2>/dev/null | sort)

kept_young=$((total_before - n - kept_live))

printf '\n'
printf '%s layer(s), %s\n' "$n" "$(numfmt --to=iec --suffix=B "$bytes")"
printf 'kept: %s live, %s newer than %s day(s)\n' "$kept_live" "$kept_young" "$days"
[ -n "${skipped_live// /}" ] && printf 'live now:%s\n' "$skipped_live"
if [ "$apply" = yes ]; then
	printf 'REMOVED. %s free on %s\n' \
		"$(df -h "$STATE_DIR" | awk 'NR==2{print $4}')" "$(df -h "$STATE_DIR" | awk 'NR==2{print $6}')"
else
	printf 'Nothing was removed. --apply does it.\n'
fi
