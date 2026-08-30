#!/usr/bin/env bash
#
# DOES reap-layers.sh SPARE A LAYER WHOSE VM IS RUNNING?
#
# The guard exists for one case and it is not the common one: a layer that is
# OLD ENOUGH TO REAP AND LIVE ANYWAY. In ordinary use a running VM writes its
# layer, so the age filter excludes it before liveness is ever consulted - which
# means the guard can be completely broken and every real run still looks right.
# That is the shape of a check that cannot fail, so this builds the case on
# purpose: a fixture root holding an old-dated layer whose project has a live
# cgroup.
#
# THE ASSERTION IS A DIFFERENCE. The same fixture is read twice, varying only
# whether the run's cgroup has processes in it. Live must be spared and dead
# must be listed; a run where both come out the same says the script is not
# reading liveness at all, whichever way it decided.
set -euo pipefail

self=$(readlink -f "$0")
reap=$(dirname "$self")/reap-layers.sh
[ -x "$reap" ] || {
	printf 'reap-layers-check: no reap-layers.sh beside me\n' >&2
	exit 2
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/state" "$work/runs/live" "$work/runs/dead"

# A project path, and the slug reap-layers must derive from it. Built the way
# bin/firecode's project_slug does - basename sanitised, then the first 8 of the
# sha256 OF THE PATH. The trailing newline from basename becomes a dash, which
# is why real layers carry a double dash before the hash; getting that wrong is
# how this guard silently matches nothing.
proj_live=/tmp/reap-check-live
proj_dead=/tmp/reap-check-dead
slug() {
	local dir=$1 hash
	hash=$(printf '%s' "$dir" | sha256sum | cut -c1-8)
	echo "$(basename "$dir" | tr -c 'A-Za-z0-9._-' '-')-$hash"
}
live_layer="$work/state/$(slug "$proj_live")-layer.ext4"
dead_layer="$work/state/$(slug "$proj_dead")-layer.ext4"
printf 'x' >"$live_layer"
printf 'x' >"$dead_layer"
touch -d '60 days ago' "$live_layer" "$dead_layer"

# The live run points at a cgroup that really does hold processes - this one.
# A made-up path would test the script's error handling, not its liveness.
# ASKED THE WAY THE REAPER ASKS IT - the cgroup AND its children - then walked
# up until that read answers. My own leaf cgroup lists nothing: under cgroup v2
# a node with children holds no processes itself, so `-s cgroup.procs` on the
# leaf I happen to sit in is empty and says nothing about liveness. A fixture
# that tested a different question than the code does is not a fixture.
mine=/sys/fs/cgroup$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup)
while [ "$mine" != /sys/fs/cgroup ] && [ -n "$mine" ]; do
	if [ -n "$(cat "$mine/cgroup.procs" "$mine"/*/cgroup.procs 2>/dev/null || true)" ]; then
		break
	fi
	mine=$(dirname "$mine")
done
if [ -z "$(cat "$mine/cgroup.procs" "$mine"/*/cgroup.procs 2>/dev/null || true)" ]; then
	printf 'reap-layers-check: found no cgroup holding processes, so this box cannot host the fixture\n' >&2
	exit 2
fi
printf '%s\n' "$proj_live" >"$work/runs/live/project"
printf '%s\n' "$mine" >"$work/runs/live/cgroup"
printf '%s\n' "$proj_dead" >"$work/runs/dead/project"
printf '%s\n' "$work/no-such-cgroup" >"$work/runs/dead/cgroup"

out=$(FIRECODE_ROOT="$work" "$reap" --days 14)

fails=0
say() {
	printf '%s\n' "$1" >&2
	fails=$((fails + 1))
}

case $out in
*"$(basename "$dead_layer")"*) ;;
*) say "a 60-day-old layer with no live run was NOT listed for removal - the script is reaping nothing and would report the same success on a full disk" ;;
esac
case $out in
*"$(basename "$live_layer")"*)
	say "a layer whose project has a LIVE cgroup was listed for removal. This is the whole guard: --apply would have deleted the disk of a running VM."
	;;
esac
case $out in
*"kept: 1 live"*) ;;
*) say "the summary does not report exactly 1 live layer kept, so the count and the listing disagree: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')" ;;
esac

if [ "$fails" -gt 0 ]; then
	printf 'reap-layers-check: %s arm(s) failed\n' "$fails" >&2
	exit 1
fi
printf 'an old layer is reaped, and an old layer whose VM is running is spared\n'
