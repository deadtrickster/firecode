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
# ABSOLUTE, ONCE. $(dirname "$0") is relative to where this was invoked, and the
# gate step runs inside a `cd "$WORK"` subshell - so a relative path resolved
# there looked for the script under the worktree and found nothing. Run five got
# all the way through declare, worktree and rebase before dying on
# "./scripts/pre-gate.sh: No such file or directory".
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

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

# WHAT THE LAST PASS DID, where something that is not this process can read it.
#
# The operator's ask, 2026-08-18: "then nagger shows last drainer status - thats
# how you catch stalls and errors." A drainer whose output goes to whichever
# session started it is a drainer nobody can check on, and the failure that
# matters most - it stopped running at all - is invisible from inside it.
#
# ONE JSON OBJECT AT A FIXED PATH, rewritten on every exit, so that the nag and
# the node's own reader answer the same question with the same bytes rather than
# each parsing a log differently. `at` is what makes it useful: "landed" from
# three hours ago and "landed" from a minute ago are the same word and different
# facts, so every reader reports the AGE and not just the outcome.
STATUS=${FLOWY_DRAIN_STATUS:-$HOME/.cache/flowy-drain/status.json}
mkdir -p "$(dirname "$STATUS")" 2>/dev/null || true
outcome="started"
note=""
record() {
	# jq rather than printf, because `note` carries a refusal in somebody's own
	# words - quotes, newlines and all - and a status file that stops parsing
	# the day a message contains a quote is a status file nobody trusts.
	jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg outcome "$outcome" \
		--arg row "${row:-}" \
		--arg branch "${branch:-}" \
		--arg tip "${tip:-}" \
		--arg agent "$AGENT" \
		--arg note "$note" \
		--argjson pid "$$" \
		'{at: $at, outcome: $outcome, row: $row, branch: $branch, tip: $tip,
		  agent: $agent, note: $note, pid: $pid}' >"$STATUS" 2>/dev/null || true
}
# Where this drainer remembers what it has already done. Beside the status file
# the nag reads, because they are the same kind of fact about the same passes.
STATE=${FLOWY_DRAIN_STATE:-$HOME/.cache/flowy-drain}
mkdir -p "$STATE" 2>/dev/null || true

say() { printf '[drain] %s\n' "$*"; }
die() {
	printf '[drain] REFUSED: %s\n' "$*" >&2
	outcome=refused
	note=$*
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
# shellcheck disable=SC2016  # the python is deliberately unexpanded by the shell
pick=$(body_of "$queue" | python3 -c '
import json, sys
q = json.load(sys.stdin)
lock = q.get("lock") or {}
if lock.get("held"):
    print("HELD", lock.get("holder_name", "somebody"), lock.get("item", ""))
    raise SystemExit
for it in q.get("items") or []:
    # Not admissible YET is the ordinary case for a row nobody has gated - it is
    # exactly what this script is for.
    #
    # A `gating` FLAG IS NOT SKIPPED, and that is deliberate rather than sloppy.
    # This code is only reached when the lock is FREE, because the block above
    # stops the run otherwise. Nobody can be gating a row without holding the
    # target - declaring is what takes it - so a gating flag seen from here is
    # residue from a run that died, and skipping it means the drainer refuses
    # forever to retry the row it abandoned itself.
    #
    # Measured: run one declared a row and then died on a worktree it could not
    # make. Run two skipped that same row - the only one it had any business
    # taking - and moved to another seat row. The flag expires on its own after
    # GateBelievedFor, so the old rule was "wait out a timer for a state that is
    # already known to be false".
    if (it.get("status") or "") in ("done", "abandoned"):
        continue
    if not (it.get("branch") or "").strip():
        continue
    print("ROW", it["id"], it["branch"], it.get("target") or "master")
print("END")
')

case "$pick" in
HELD*)
	outcome=held
	say "the target is ${pick#HELD }"
	say "somebody is landing or deploying - not racing them"
	exit 0
	;;
esac

# WHICH ROW IS TAKEABLE, ASKED BEFORE ANYTHING IS DECLARED.
#
# The first three real runs all died on the top row and never looked at the
# rest: a branch checked out in somebody's worktree cannot be rebased here, and
# refusing the whole run for it means one seat with an editor open blocks the
# queue for everybody. A reason that is about the WORKSPACE is a reason to try
# the next row; a reason about the TREE is a reason to stop.
#
# And this happens before the declare, because declaring takes the lock: the
# first cut declared, discovered the branch was unavailable, and released -
# taking and giving back the target once per unavailable row.
row="" branch="" rowtarget=""
while read -r kind id b t; do
	[ "$kind" = ROW ] || continue
	[ "$t" = "$TARGET" ] || {
		say "skipping $id - it targets $t and this drainer runs $TARGET"
		continue
	}
	elsewhere=$(git -C "$REPO" worktree list --porcelain |
		awk -v want="refs/heads/$b" '$1=="worktree"{w=$2} $1=="branch" && $2==want {print w}' |
		grep -v "^$WORK$" | head -1 || true)
	if [ -n "$elsewhere" ]; then
		say "skipping $id - $b is checked out in $elsewhere"
		continue
	fi
	row=$id branch=$b rowtarget=$t
	break
done <<<"$pick"

if [ -z "$row" ]; then
	outcome=idle
	say "nothing takeable in the queue - every row is landed, aimed elsewhere, or open in a worktree"
	exit 0
fi
say "taking $row - $branch onto $rowtarget"

if [ "$dry" = yes ]; then
	outcome="dry-run"
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
	# AND GIVE THE BRANCH BACK. The worktree keeps whatever it checked out, so
	# after a pass the seat that owns that branch cannot touch it - git refuses
	# a branch checked out anywhere else, and the message names a directory they
	# did not create. claude-host hit this from the other side within minutes of
	# the first red: their fixture fix could not go on their own branch.
	#
	# Detached costs the drainer nothing: the next pass checks out whatever it
	# picks, and this one is finished with it either way.
	git -C "$WORK" checkout -q --detach 2>/dev/null || true
}
# ONE EXIT TRAP, because bash has one and a second REPLACES the first - the
# defect this fleet shipped in deploy.sh this evening and caught in the logs an
# hour later. So the lock and the status line are given back by the same
# handler, in that order: the lock first, because a stalled status line costs a
# reader a question and a held lock costs everybody the next fifteen minutes.
finish() {
	release
	record
}
trap finish EXIT

# ------------------------------------------------------------ the tree

# THE WORKTREE, AND WHY THE FIRST RUN DIED HERE.
#
# This was `worktree add 2>/dev/null || checkout || die`, and the first real run
# produced "cannot put the branch in /home/dead/Projects/wt-drain" - which says
# what did not happen and nothing about why. The reason was that git refuses to
# check out a branch that is checked out in ANOTHER worktree, and my own
# worktree held it. Hiding stderr on the first arm threw away the one sentence
# that explained the failure, which is the defect this fleet has filed four
# times today under other names.
#
# So: stderr is kept, the branch being held elsewhere is refused BY NAME before
# the attempt, and the fallback only runs when the directory is actually there.
# Asked again, after the declare, because the window between the pick and here
# is one where somebody can open a worktree. It is a die rather than a skip now:
# the lock is ours and the row is chosen, so there is nothing left to fall back
# to.
held=$(git -C "$REPO" worktree list --porcelain |
	awk -v b="refs/heads/$branch" '$1=="worktree"{w=$2} $1=="branch" && $2==b {print w}' |
	grep -v "^$WORK$" | head -1 || true)
if [ -n "$held" ]; then
	die "$branch was checked out in $held between the pick and the declare"
fi

if [ -d "$WORK" ]; then
	git -C "$WORK" checkout -q "$branch" || die "cannot check out $branch in $WORK"
else
	git -C "$REPO" worktree add --checkout "$WORK" "$branch" ||
		die "cannot create the drain worktree at $WORK"
fi
git -C "$WORK" fetch -q 2>/dev/null || true
git -C "$WORK" rebase -q "$rowtarget" ||
	die "$branch does not rebase onto $rowtarget cleanly - a person resolves this"

tip=$(git -C "$WORK" rev-parse --short HEAD)
say "rebased onto $rowtarget, tip $tip"

# A RED THIS DRAINER HAS ALREADY SEEN IS NOT TAKEN AGAIN.
#
# The script never retried; a LOOP around it did - claude-host ran --once every
# sixty seconds and it re-took a red row every minute. My fault rather than the
# loop's: on red this records nothing, so the queue cannot tell a row nobody has
# gated from one that just failed, and every caller takes it again forever.
#
# HERE RATHER THAN BEFORE THE DECLARE, because the tip is what identifies the
# tree and the tip is not known until the rebase. The first cut asked this next
# to the declare and died on "tip: unbound variable" - a check about a value
# placed above the line that computes it.
#
# The real fix is a queue that can say GATED AND FAILED. It cannot today:
# gated_tip means "this is the evidence" and MergeAdmissible compares base to
# tip without asking pass or fail, so recording a red verdict would make the row
# look LANDABLE. Filed separately; this is what stops the bleeding meanwhile.
#
# Keyed by TIP as well as row, so a rebase or a fix is taken immediately - what
# is refused is repeating a measurement of a tree already measured, which is the
# rule the whole fleet agreed on this afternoon.
if [ -f "$STATE/red-$row-$tip" ]; then
	say "$row at $tip already gated red - $(cat "$STATE/red-$row-$tip")"
	say "push a fix or rebase; a second run of the same tree measures the same tree"
	exit 0
fi

# ------------------------------------------------------------ worth gating

# THE SAME ENVIRONMENT THE GATE GETS, or pre-gate answers about a different one.
#
# pre-gate checks that postgres is on PATH, because the suite exits in two
# seconds without it - and it exports pg17-bin for its OWN initdb probe, which
# the suite does not inherit. So calling it without that PATH gets a refusal
# that is true of the caller and false of the run. Measured by hand twenty
# minutes before this script was first used: "postgres is installed and NOT on
# your PATH", from a shell whose gate would have worked.
#
# FLOWY_AGENT for the other half of the same lesson: without it, pre-gate cannot
# tell this seat's lock from another's, and it says so rather than guessing.
(cd "$WORK" && PATH=$HOME/.local/pg17-bin:$PATH LD_LIBRARY_PATH=$HOME/.local/pg17-libs \
	FLOWY_AGENT="$AGENT" bash "$HERE/pre-gate.sh" "$branch") ||
	die "pre-gate says this run is not worth starting"

# ------------------------------------------------------------ the gate

# KEYED BY ROW AND TIP, not by row. The retry below overwrote the log of the
# run that mattered with the log of the run that repeated it - so the evidence
# of the first red was destroyed by the second identical red.
log=$STATE/drain-$row-$tip.log
say "gating $tip - about 35 minutes, log at $log"
if (cd "$WORK" && PATH=$HOME/.local/pg17-bin:$PATH \
	LD_LIBRARY_PATH=$HOME/.local/pg17-libs ./run-tests.sh >"$log" 2>&1); then
	outcome=green
	note=$(grep -E "^passed:" "$log" | tail -1)
	say "green: $(grep -E '^passed:' "$log" | tail -1)"
else
	# RECORDED, NOT RETRIED, and not diagnosed either.
	outcome=red
	note="$(grep -E "^passed:" "$log" | tail -1) - log at $log"
	say "RED: $(grep -E '^passed:' "$log" | tail -1)"
	grep -E '^\s+--- FAIL|^FAIL ' "$log" | head -5 >&2 || true
	printf 'red at %s, %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$(grep -E '^passed:' "$log" | tail -1)" >"$STATE/red-$row-$tip"
	say "the row stays open and the log stays at $log - a person reads it"
	say "and $tip will not be gated again by this drainer until it changes"
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
outcome=landed
note="$landed"
say "landed $landed"

# ------------------------------------------------------------ and only then

if [ "$deploy" != yes ]; then
	say "not deploying - green and deployed are two claims, and this run was asked for one"
	exit 0
fi
"$REPO/scripts/deploy.sh"
outcome=deployed
note="$landed"
