#!/usr/bin/env bash
#
# Run the landing chain for one queued branch, with no judgement in it.
#
# The operator's, said plainly: "you could build an API cluster that accepts
# your branches in a queue and handles gating and deploying - we dont need an
# llm for this. look at your patterns here - hardcode them, done."
#
# They are right. Every step below already exists as a script with an exit code,
# and what an agent was doing between them was polling and typing:
#
#   GET  /api/merge-queue            the next row that is decided and admissible
#   POST /api/merge/{id}/gate        declare - THIS TAKES THE LOCK
#   git rebase master                the tree that lands is the tree measured
#   pre-gate.sh <branch>             is this run worth its 35 minutes
#   ./run-tests.sh                   the gate
#   POST /api/merge/{id}/gate        record the verdict, with gated_tip
#   git merge --ff-only + POST land  land, through the door that writes the chain
#   scripts/deploy.sh                deploy, only on a signal
#
# THE ORDER IS THE ONLY THING THAT TOOK JUDGEMENT, and it is measured rather
# than argued: declaring BEFORE the gate is what stops the base moving under the
# run. flowy-claude did that for six consecutive landings - four wasted runs
# before, zero after - while I gated first and re-ran three unchanged diffs in
# one afternoon. pre-gate.sh now refuses the wrong order outright, and this
# script cannot get it wrong because the order is written here once.
#
# ON RED IT DOES NOT RETRY. A red gate is a fact about that tree; a second
# identical run is the thing this fleet ruled against on 01M0ARZY6X. It also
# must not decide whether a red is the branch or the environment - three reds
# today were host libraries, a port collision and a stale mode bit, none of them
# the diff - so it records, releases, leaves the row red, and stops. A person
# reads the log.
#
# GREEN IS NOT DEPLOYED. Two different claims. It drains to LANDED always, and
# deploys only when --deploy is passed or FLOWY_DRAIN_DEPLOY=yes is set, which
# is the seam the operator asked for: a monitor between green and live.
#
#   scripts/drain.sh --once [--deploy] [--dry-run]
#
# Exit 0 something landed, or there was nothing to do. 1 the gate was red or a
# step refused. 2 misused.
set -euo pipefail

NODE=${FLOWY_URL:-http://192.168.1.55:8787}
REPO=${FLOWY_REPO:-$HOME/Projects/flowy}
AGENT=${FLOWY_AGENT:-orchestrator}
TOKEN_FILE=${FLOWY_TOKEN_FILE:-$HOME/.config/flowy/agents/$AGENT}
# A WORKTREE OF ITS OWN. The gate compiles the directory it runs in, so draining
# in the shared checkout would measure whatever anybody else is mid-edit on -
# and deploy.sh refuses a dirty tree for the same reason.
WORK=${FLOWY_DRAIN_WORKTREE:-$HOME/Projects/wt-drain}
TARGET=${FLOWY_DRAIN_TARGET:-master}

once=no deploy=${FLOWY_DRAIN_DEPLOY:-no} dry=no
while [ $# -gt 0 ]; do
	case "$1" in
	--once) once=yes ;;
	--deploy) deploy=yes ;;
	--dry-run) dry=yes ;;
	*)
		printf 'usage: %s --once [--deploy] [--dry-run]\n' "$0" >&2
		exit 2
		;;
	esac
	shift
done
[ "$once" = yes ] || {
	printf 'usage: %s --once [--deploy] [--dry-run]\n' "$0" >&2
	exit 2
}

say() { printf '[drain] %s\n' "$*"; }
die() {
	printf '[drain] REFUSED: %s\n' "$*" >&2
	exit 1
}

[ -r "$TOKEN_FILE" ] || die "no token at $TOKEN_FILE - the queue cannot be read without one"
TOKEN=$(cat "$TOKEN_FILE")

api() { # method path [body]
	local method=$1 path=$2 body=${3:-}
	if [ -n "$body" ]; then
		curl -sS -m 30 -w '\n%{http_code}' -X "$method" \
			-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
			-d "$body" "$NODE$path"
	else
		curl -sS -m 30 -w '\n%{http_code}' -X "$method" \
			-H "Authorization: Bearer $TOKEN" "$NODE$path"
	fi
}
code_of() { printf '%s' "$1" | tail -1; }
body_of() { printf '%s' "$1" | head -n -1; }

# ------------------------------------------------------------ pick one row

queue=$(api GET /api/merge-queue) || die "cannot reach $NODE"
[ "$(code_of "$queue")" = 200 ] || die "the queue answered $(code_of "$queue")"

# THE QUEUE'S OWN ANSWER, not a re-derivation of it. `admissible` is the node's
# judgement of whether a verdict would be honoured, and asking it here rather
# than reimplementing gated_base against target_tip is what keeps this script
# from disagreeing with the door it is about to call.
pick=$(body_of "$queue" | python3 -c '
import json, sys
q = json.load(sys.stdin)
lock = q.get("lock") or {}
if lock.get("held"):
    print("HELD", lock.get("holder_name", "somebody"), lock.get("item", ""))
    raise SystemExit
for it in q.get("items") or []:
    # Not admissible YET is the ordinary case for a row nobody has gated - it
    # is exactly what this script is for. What it must not take is a row that
    # is already gating (somebody else is on it) or already landed.
    if it.get("gating"):
        continue
    if (it.get("status") or "") in ("done", "abandoned"):
        continue
    if not (it.get("branch") or "").strip():
        continue
    print("ROW", it["id"], it["branch"], it.get("target") or "master")
    raise SystemExit
print("EMPTY")
')

case "$pick" in
HELD*)
	say "the target is ${pick#HELD }"
	say "somebody is landing or deploying - not racing them"
	exit 0
	;;
EMPTY)
	say "nothing queued to drain"
	exit 0
	;;
esac

read -r _ row branch rowtarget <<<"$pick"
[ "$rowtarget" = "$TARGET" ] || die "row $row targets $rowtarget, and this drainer runs $TARGET"
say "taking $row - $branch onto $rowtarget"

if [ "$dry" = yes ]; then
	say "dry run: would declare, rebase, pre-gate, gate, record, land"
	[ "$deploy" = yes ] && say "dry run: and would deploy"
	exit 0
fi

# ------------------------------------------------------------ declare first

run="drain-$(date -u +%Y%m%dT%H%M%SZ)"
declared=$(api POST "/api/merge/$row/gate" "$(printf '{"run":"%s"}' "$run")")
case "$(code_of "$declared")" in
200) say "declared $run - the lock is ours and the base cannot move" ;;
409)
	body_of "$declared" >&2
	say "somebody took the target between the read and the declare - stopping"
	exit 0
	;;
*)
	body_of "$declared" >&2
	die "declaring answered $(code_of "$declared")"
	;;
esac

# FROM HERE ON THE LOCK IS OURS, so every exit gives it back. A drainer that
# dies holding it freezes landing for the full expiry, and the person who waits
# is not the one who broke it. Releasing a lock we no longer hold is a no-op the
# door answers with released:false, so this is safe on every path.
release() {
	api POST /api/lock/release "$(printf '{"item":"%s"}' "$row")" >/dev/null 2>&1 || true
}
trap release EXIT

# ------------------------------------------------------------ the tree

git -C "$REPO" worktree add -q --checkout "$WORK" "$branch" 2>/dev/null ||
	git -C "$WORK" checkout -q "$branch" ||
	die "cannot put $branch in $WORK"
git -C "$WORK" fetch -q 2>/dev/null || true
git -C "$WORK" rebase -q "$rowtarget" ||
	die "$branch does not rebase onto $rowtarget cleanly - a person resolves this"

tip=$(git -C "$WORK" rev-parse --short HEAD)
say "rebased onto $rowtarget, tip $tip"

# ------------------------------------------------------------ worth gating

(cd "$WORK" && FLOWY_AGENT="$AGENT" bash "$(dirname "$0")/pre-gate.sh" "$branch") ||
	die "pre-gate says this run is not worth starting"

# ------------------------------------------------------------ the gate

log=${TMPDIR:-/tmp}/drain-$row.log
say "gating $tip - about 35 minutes, log at $log"
if (cd "$WORK" && PATH=$HOME/.local/pg17-bin:$PATH \
	LD_LIBRARY_PATH=$HOME/.local/pg17-libs ./run-tests.sh >"$log" 2>&1); then
	say "green: $(grep -E '^passed:' "$log" | tail -1)"
else
	# RECORDED, NOT RETRIED, and not diagnosed either.
	say "RED: $(grep -E '^passed:' "$log" | tail -1)"
	grep -E '^\s+--- FAIL|^FAIL ' "$log" | head -5 >&2 || true
	say "the row stays open and the log stays at $log - a person reads it"
	exit 1
fi

# ------------------------------------------------------------ record and land

verdict=$(api POST "/api/merge/$row/gate" "$(printf '{"run":"%s","gated_tip":"%s"}' "$run" "$tip")")
[ "$(code_of "$verdict")" = 200 ] || {
	body_of "$verdict" >&2
	die "recording the verdict answered $(code_of "$verdict")"
}
say "verdict recorded, gated_tip $tip"

# LAND WHERE THE TARGET IS, AND PROVE IT MOVED.
#
# flowy-claude hit this by hand minutes after this script was written: they ran
# the fast-forward INSIDE THE WORKTREE, where HEAD is already the branch, so git
# answered "Already up to date", the land verb recorded a landing, and master
# had not moved. The land guard then refused their next attempt, correctly, for
# a lock nobody held - the queue and the repository disagreeing about what had
# happened.
#
# $REPO is the shared checkout and should be on the target, but "should be" is
# what that failure was made of. So: refuse if it is not, and afterwards require
# the target to have actually become the tip that was gated. A no-op merge
# passes the first check and fails the second.
on=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
[ "$on" = "$rowtarget" ] ||
	die "$REPO is on $on, not $rowtarget - a fast-forward there lands nothing and reports success"
before=$(git -C "$REPO" rev-parse --short HEAD)

FLOWY_TOKEN="$TOKEN" git -C "$REPO" merge --ff-only "$branch" >/dev/null ||
	die "the fast-forward refused - the land guard or a moved target"
landed=$(git -C "$REPO" rev-parse --short HEAD)
[ "$landed" != "$before" ] ||
	die "$rowtarget is still $before after the merge - nothing landed, and recording one would tell the queue something that did not happen"
git -C "$REPO" merge-base --is-ancestor "$tip" HEAD ||
	die "$rowtarget is $landed and does not contain the gated tip $tip"
land=$(api POST "/api/merge/$row/land" "$(printf '{"sha":"%s"}' "$landed")")
[ "$(code_of "$land")" = 200 ] || {
	body_of "$land" >&2
	die "the land door answered $(code_of "$land") AFTER the branch was merged - master is at $landed and the queue does not know"
}
say "landed $landed"

# ------------------------------------------------------------ and only then

if [ "$deploy" != yes ]; then
	say "not deploying - green and deployed are two claims, and this run was asked for one"
	exit 0
fi
"$REPO/scripts/deploy.sh"
