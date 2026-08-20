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
#   pre-gate.sh <branch>             is this run worth its five minutes
#   ./.flowy-gate                    the gate, as the PROJECT declares it
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

once=no deploy=${FLOWY_DRAIN_DEPLOY:-no} dry=no only=""
while [ $# -gt 0 ]; do
	case "$1" in
	--once) once=yes ;;
	--deploy) deploy=yes ;;
	--dry-run) dry=yes ;;
	# ONE NAMED ROW, WHICH IS FOR ONE SITUATION AND SAYS SO.
	#
	# The queue is a queue: the drainer takes the first row it can work, and
	# that ordering IS the fairness. This exists for the case the ordering
	# cannot solve - a defect that stops every row landing, whose FIX is in the
	# queue behind the rows it is blocking. Measured 2026-08-20: nine rows, none
	# landable, and the fix ninth.
	#
	# It does not skip any check. The row still has to be takeable, declarable,
	# rebasable, gated and admissible; this only decides WHICH row a pass
	# considers, and the pass refuses if that row is not workable.
	--row)
		only=${2:-}
		shift
		;;
	*)
		printf 'usage: %s --once [--deploy] [--dry-run] [--row ID]\n' "$0" >&2
		exit 2
		;;
	esac
	shift
done
[ "$once" = yes ] || {
	printf 'usage: %s --once [--deploy] [--dry-run]\n' "$0" >&2
	exit 2
}

# ONE DRAINER AT A TIME, ON THIS MACHINE.
#
# Nothing enforced this and the shape it fails in is quiet. Two passes both pick
# the same admissible row, both declare, and the second is refused at the lock -
# that half is fine. What is not fine is the gate: the loser has already spent a
# worktree, a rebase and five minutes measuring a tree it will never land,
# and both passes write $STATUS, so the nag reports whichever finished last as
# "the drainer" and the other run becomes invisible.
#
# A flock on a file descriptor rather than a pid file: the kernel drops it when
# the process dies, however it dies, so a drainer killed mid-gate does not leave
# a lock nobody can explain. `-n` because waiting is wrong here - a second
# drainer is not early, it is redundant.
#
# BEFORE THE STATUS FILE IS TOUCHED, deliberately. A refusal that wrote "another
# drainer is running" into $STATUS would overwrite the status of the pass that
# IS running, and the nag would report the drainer as refused while it was
# working - the same signal carrying two meanings, which is this fleet's most
# expensive recurring defect.
DRAIN_LOCK=${FLOWY_DRAIN_LOCK:-${TMPDIR:-/tmp}/flowy-drain.lock}
exec 9>"$DRAIN_LOCK" || {
	printf 'drain: cannot open %s\n' "$DRAIN_LOCK" >&2
	exit 2
}
if ! flock -n 9; then
	printf 'drain: another drainer holds %s - not starting a second one.\n' "$DRAIN_LOCK" >&2
	printf '       Its status is in %s and its age is what tells you whether it is\n' \
		"${FLOWY_DRAIN_STATUS:-$HOME/.cache/flowy-drain/status.json}" >&2
	printf '       stuck. This exits 3 without writing that file, so the running\n' >&2
	printf '       pass keeps its own last word.\n' >&2
	exit 3
fi

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

# THE DRAINER'S OWN NARRATION GOES BESIDE THE SUITE'S OUTPUT, once there is a
# log to put it in.
#
# It used to go only to stdout, and the loop that runs a pass pipes stdout to
# `tail -6` - so the reason a pass refused survived for six lines and then did
# not exist. Measured 2026-08-20: a row refused at the land TWICE, an hour
# apart, each time after a full suite, and the only record was the status file's
# one-line note - "the fast-forward refused - the land guard or a moved target",
# which names two causes and distinguishes neither. Another seat asked what my
# log said and there was nothing to answer with.
#
# $log is empty until the gate names it, so early lines still only reach stdout;
# everything from the rebase onward lands in the file the verdict points at.
say() {
	printf '[drain] %s\n' "$*"
	[ -n "${log:-}" ] && printf '[drain] %s\n' "$*" >>"$log" 2>/dev/null
	return 0
}
die() {
	printf '[drain] REFUSED: %s\n' "$*" >&2
	[ -n "${log:-}" ] && printf '[drain] REFUSED: %s\n' "$*" >>"$log" 2>/dev/null
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
# THE SET IS FRESH BECAUSE THE LOOP IS OUTSIDE THIS SCRIPT, and that is a
# property worth writing down rather than leaving as luck.
#
# One invocation reads the queue once and exits, so every pass sees the rows as
# they are at the moment it starts. Nothing here caches a row list across
# passes, and nothing needs to.
#
# IF YOU EVER MAKE THIS LOOP INTERNALLY, RE-READ THE QUEUE EACH ITERATION. A
# loop that freezes its set at start reports about a world that stopped existing
# when it launched - which is the same defect as a watcher that fixed its row
# list at boot and reported "no reds on my rows" while two of them were red, and
# as a brief that told an agent about a window that had closed by the time it
# acted. Five instances of it in one day, filed as 01M0BFB7WP.
#
# The gap between reading and acting is what makes it wrong, and here that gap
# is a whole gate: the queue read below decides which row the next five minutes
# are spent on.

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
    print("ROW", it["id"], it["branch"], it.get("target") or "master", it.get("project") or "-")
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
# A SKIP IS A FACT SOMEBODY ELSE NEEDS. Until 69c3251 these two lines went into
# this script's own log and nowhere else, so a row nobody could take and a row
# waiting its turn looked identical to every reader - which is how the queue sat
# still for nine minutes tonight with three rows in it and nothing said why.
#
# The blocked door takes the reason and the row carries it, with the moment it
# was found. It is a fact about a MOMENT rather than about the row: "checked out
# in wt-qorder" is true until somebody detaches, so a declaration clears it and
# every reader treats it as evidence with an age.

# WHICH CHECKOUT A ROW'S BRANCH LIVES IN.
#
# 01M0DZPFP1. A merge row carries a branch and a target and NOT a repository -
# the drainer supplied one from its own configuration, which is invisible while
# one project files merge rows and wrong the moment a second does. Picking the
# wrong checkout is not a failure that announces itself: it rebases a branch
# from one project onto another project's master, gates the result, and records
# a verdict about a tree nobody asked about.
#
# The row already carries a project - every artifact does. What is missing is
# the map from a project to a checkout ON THIS MACHINE, and that is firecode's
# to know: the node has no checkout and cannot answer it.
#
#   FLOWY_DRAIN_REPOS="flowy=/home/dead/Projects/flowy,serenedb=/home/dead/Projects/serenedb"
#
# UNSET MEANS WHAT IT MEANT BEFORE. One project, one checkout, $FLOWY_REPO for
# every row - so a drainer nobody reconfigures behaves exactly as it did, and
# the map is what a second project turns on rather than a migration everybody
# has to do first.
REPOS=${FLOWY_DRAIN_REPOS:-}

# repo_for prints the checkout a row's project lives in, or nothing when this
# machine has none for it.
#
# A PROJECT WITH NO CHECKOUT IS A REFUSAL, not a skip, and that is the half that
# matters. Silently working only the rows it happens to have a repo for looks
# exactly like an idle queue - which is the shape that had four rows waiting
# behind a parked checkout tonight with nothing said. See the blocked() call.
repo_for() { # project
	local want=$1 pair
	[ -n "$REPOS" ] || {
		printf '%s' "$REPO"
		return 0
	}
	# A row with no project takes the default too: it predates projects being
	# on rows, and refusing it would be this map deciding about history.
	[ -n "$want" ] && [ "$want" != "-" ] || {
		printf '%s' "$REPO"
		return 0
	}
	local IFS=,
	for pair in $REPOS; do
		case "$pair" in
		"$want"=*) printf '%s' "${pair#*=}" && return 0 ;;
		esac
	done
	return 1
}
blocked() { # id why
	api POST "/api/merge/$1/blocked" \
		"$(printf '{"why":"%s"}' "$(printf '%s' "$2" | sed 's/"/\\"/g')")" >/dev/null 2>&1 || true
}
while read -r kind id b t proj; do
	[ "$kind" = ROW ] || continue
	# A named row means this pass is about that row and nothing else.
	[ -z "$only" ] || [ "$id" = "$only" ] || continue
	[ "$t" = "$TARGET" ] || {
		say "skipping $id - it targets $t and this drainer runs $TARGET"
		blocked "$id" "targets $t, and this drainer runs $TARGET"
		continue
	}
	# THE CHECKOUT THIS ROW'S BRANCH LIVES IN, before anything is spent on it.
	rowrepo=$(repo_for "$proj") || {
		say "skipping $id - no checkout on this machine for project $proj"
		blocked "$id" "this drainer has no checkout for project $proj - it cannot rebase or gate the branch. Add it to FLOWY_DRAIN_REPOS on the box that runs the drainer, or run a drainer where that project lives"
		continue
	}
	elsewhere=$(git -C "$rowrepo" worktree list --porcelain |
		awk -v want="refs/heads/$b" '$1=="worktree"{w=$2} $1=="branch" && $2==want {print w}' |
		grep -v "^$WORK$" | head -1 || true)
	if [ -n "$elsewhere" ]; then
		say "skipping $id - $b is checked out in $elsewhere"
		blocked "$id" "$b is checked out in $elsewhere, so it cannot be rebased here"
		continue
	fi
	# WOULD THIS REBASE CONFLICT, ASKED BEFORE ANYTHING IS SPENT.
	#
	# `git merge-tree --write-tree` computes the merge in the object store: no
	# worktree, no index, no checkout, and it answers in about a second. So the
	# drainer can know a branch cannot be rebased before it takes the lock,
	# builds a worktree, or starts the suite.
	#
	# MEASURED THREE TIMES ON 2026-08-18, by hand, by three different agents
	# within twenty minutes - and two of the three found a conflict. flowy-claude
	# probed six branches and found one; I probed my own and found run-tests.sh
	# conflicting; orchestrator probed theirs and found api.go. Each of those
	# would have been a pass declared, rebased, and abandoned.
	#
	# IT ALSO REMOVES THE CLASS RATHER THAN HANDLING IT. A rebase that dies
	# halfway leaves the worktree mid-rebase with the branch still checked out,
	# which pins the row for its own owner - the drainer making a row unavailable
	# by failing at it. The cleanup for that exists a few lines further down and
	# this is what makes it unreachable in the ordinary case.
	#
	# The answer is computed against the target AS IT IS NOW, never stored: master
	# moves with every landing, so a conflict answer from three landings ago is an
	# answer to a different question.
	if ! git -C "$rowrepo" merge-tree --write-tree "$t" "$b" >/dev/null 2>&1; then
		say "skipping $id - $b does not merge onto $t cleanly"
		blocked "$id" "$b conflicts with $t as it is now - a person resolves this, the drainer cannot"
		continue
	fi
	# A RED THIS DRAINER HAS ALREADY SEEN IS SKIPPED, NOT EXITED ON.
	#
	# This check used to live after the rebase and END THE PASS, which starved
	# the queue: a parked row at the head meant every row behind it was never
	# looked at, and nothing drained for twelve minutes tonight with two rows
	# waiting and one of them the fix for the other.
	#
	# So it is a skip like any other, and it happens BEFORE the declare - which
	# means it cannot use the post-rebase tip. It uses the pair that determines
	# that tip instead: the branch as it is now and the target as it is now. If
	# both are what they were when the red was recorded, the rebase would produce
	# the tree that was already measured, so there is nothing to learn.
	#
	# Either one moving takes the row immediately, which is the property the
	# whole fleet agreed on: what is refused is repeating a measurement, never
	# refusing a tree nobody has measured.
	bsha=$(git -C "$rowrepo" rev-parse --short "$b" 2>/dev/null || true)
	tsha=$(git -C "$rowrepo" rev-parse --short "$t" 2>/dev/null || true)
	if [ -n "$bsha" ] && [ -n "$tsha" ] &&
		grep -qxF "$bsha $tsha" "$STATE/red-$id" 2>/dev/null; then
		say "skipping $id - $b at $bsha onto $t at $tsha was already gated red"
		continue
	fi
	# THE CHOSEN ROW DECIDES THE CHECKOUT for everything after this loop, which
	# is why REPO is assigned here rather than read from the environment: the
	# rest of the pass - worktree, rebase, gate, land - is about ONE row, and
	# that row names its project.
	row=$id branch=$b rowtarget=$t REPO=$rowrepo
	break
done <<<"$pick"

if [ -z "$row" ]; then
	# NOTHING TO LAND IS NOT NOTHING TO DO. A deploy that refused - because the
	# shared checkout was dirty, because the build was interrupted - leaves master
	# ahead of the node, and nothing retries it: the pass that failed has ended and
	# the next row is what triggers the next deploy. On an empty queue there is no
	# next row, so the box stays behind until a person reads the nag.
	#
	# So an idle pass asks the two questions it is already holding the answers to -
	# what is master, what is the node serving - and deploys when they differ. It
	# is the cheapest possible catch-up: no state, no retry counter, just the same
	# comparison the deploy itself makes at the end.
	if [ "$deploy" = yes ]; then
		serving=$(curl -sS -m 5 "$NODE/api/node" 2>/dev/null |
			sed -n 's/.*"version":"[^+]*+\([^"]*\)".*/\1/p')
		head=$(git -C "$REPO" rev-parse --short master 2>/dev/null || true)
		if [ -n "$serving" ] && [ -n "$head" ] && ! printf '%s' "$head" | grep -q "^$serving"; then
			outcome=catching-up
			note="node serving $serving, master is $head"
			say "the node is serving $serving and master is $head - deploying the difference"
			# The catch-up deploy writes where somebody can read it too, and to
			# its own file because this path has no row and therefore no pass
			# log. Same reason as the one after a landing: a deploy whose output
			# goes to a background shell's stdout is a deploy nobody can check.
			if "$REPO/scripts/deploy.sh" 2>&1 | tee -a "$STATE/catch-up.log"; then
				outcome=deployed
				note="$head (catch-up)"
				exit 0
			fi
			outcome="deploy-refused"
			note="node still on $serving, master is $head"
			exit 1
		fi
	fi
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
# A REFUSAL THAT LEAVES A MESS IS WORSE THAN THE REFUSAL.
#
# `git rebase` that hits a conflict does not stop cleanly: it leaves the
# worktree mid-rebase with conflict markers in the files AND the branch still
# checked out here. So the row this drainer just gave up on became a row it had
# PINNED - the next pass skipped it saying "checked out in wt-drain", and its
# owner found a half-finished rebase in a directory they do not use.
#
# Measured on 2026-08-19 by orchestrator, on the ordering fix: aborted the
# rebase, detached the worktree, rebased by hand. The drainer had made the row
# unavailable to everyone including itself.
#
# So the failure path puts the worktree back the way it found it: abort the
# rebase, detach the branch, and only then refuse. `blocked` says why, since a
# conflict is a fact somebody has to act on and this is the one failure the
# drainer cannot fix and the author always can.
if ! git -C "$WORK" rebase -q "$rowtarget"; then
	git -C "$WORK" rebase --abort >/dev/null 2>&1 || true
	git -C "$WORK" checkout -q --detach >/dev/null 2>&1 || true
	blocked "$row" "$branch does not rebase onto $rowtarget cleanly - a person resolves this"
	die "$branch does not rebase onto $rowtarget cleanly - a person resolves this"
fi

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
	# AND REMEMBER IT WHERE THE PICK LOOP CAN READ IT, which is the half that was
	# missing and the reason this stalled a queue.
	#
	# There are two red memories and they answer two questions: the tip-keyed
	# file above answers "have I measured this exact tree", which is only
	# answerable AFTER a rebase; the per-row file records the branch and target
	# shas that produced it, which is what the pick loop can ask BEFORE spending
	# a declare and a lock. A pass that reached here proved the tree is already
	# measured and did not write the second one, so every later pass declared,
	# locked, rebased and arrived back here - and this exits the PASS, so
	# whatever was queued behind this row never got looked at at all.
	#
	# Measured by orchestrator on 2026-08-19 against 01M0D2TXH8: the pick loop
	# was not what held it, this was.
	printf '%s %s\n' \
		"$(git -C "$REPO" rev-parse --short "$branch" 2>/dev/null || echo unknown)" \
		"$(git -C "$REPO" rev-parse --short "$rowtarget" 2>/dev/null || echo unknown)" \
		>>"$STATE/red-$row"
	blocked "$row" "already gated red at $tip - $(cat "$STATE/red-$row-$tip"). Push a fix or rebase; the drainer will not measure the same tree twice"
	exit 0
fi

# ------------------------------------------------------------ worth gating
# THE PROJECT'S OWN QUESTIONS, IN THE PROJECT'S OWN ENVIRONMENT.
#
# This used to export flowy's Postgres paths here, because pre-gate asked about
# initdb and the suite would exit in two seconds without them - so the caller
# had to arrange the conditions before asking whether they held. Measured by
# hand twenty minutes before this script was first used: "postgres is installed
# and NOT on your PATH", from a shell whose gate would have worked.
#
# The machine half is now .flowy-pregate in the project, and it knows its own
# paths, so there is nothing for the drainer to splice in. What is left here is
# the drainer's half of the same lesson: FLOWY_AGENT, without which pre-gate
# cannot tell this seat's lock from another's, and says so rather than guessing.
(cd "$WORK" && FLOWY_AGENT="$AGENT" bash "$HERE/pre-gate.sh" "$branch" --row "$row") ||
	die "pre-gate says this run is not worth starting"

# ------------------------------------------------------------ the gate

# KEYED BY ROW AND TIP, not by row. The retry below overwrote the log of the
# run that mattered with the log of the run that repeated it - so the evidence
# of the first red was destroyed by the second identical red.
log=$STATE/drain-$row-$tip.log
# TRUNCATED HERE, SO THE DRAINER'S OWN NARRATION SURVIVES IT.
#
# say() appends to $log, and the gate used to write it with `>` - so every line
# the drainer said about a pass was destroyed by the first byte the suite wrote.
# Measured 2026-08-20 while trying to confirm which gate command had run: the
# line naming it had been said, and the log it was said into began with the
# suite's own first heading.
#
# Truncating here and appending below keeps one log per (row, tip) - a retry of
# the same tip still starts clean, which is what the keying is for - and leaves
# the pass's own account of itself at the top of the file where a reader starts.
: >"$log"
# NAMING THE COMMAND, because nothing else can tell you which one ran.
#
# .flowy-gate execs the project's suite, so the process that ends up in `ps` is
# the suite with the drainer as its parent - which is exactly what the old
# hardcoded `./run-tests.sh` produced too. Measured 2026-08-20 while trying to
# confirm the first pass through the project's own gate: the process tree, the
# environment and the log were all identical either way, and the only evidence
# available was that the pass had started three seconds after the file changed.
#
# A mechanism whose use cannot be observed is one nobody can verify, so the
# drainer says which command it is about to run, in the line that already goes
# to the row's log.
say "gating $tip with ./.flowy-gate - about five minutes, log at $log"
# FLOWY_AGENT IS UNSET FOR THE SUITE, and this is the drainer changing the
# meaning of the thing it measures.
#
# resolveToken (tui.go:146) checks FLOWY_AGENT BEFORE FLOWY_TOKEN, so a named
# seat outranks an explicit credential - defensible on its own terms. The
# drainer exports FLOWY_AGENT because pre-gate needs it to tell its own lock
# from somebody else's, and the suite then inherited it: every CLI check, even
# the ones that set FLOWY_TOKEN="$TOKEN_A" themselves, resolved to the
# orchestrator seat inside a config directory the gate builds fresh and empty.
#
# Five checks failed with "peer answered 401: unknown token" on a tree that went
# 651/0 when its author ran it. Twice, for me, on two different branches - and
# both times I read the failures as belonging to the diff.
#
# pre-gate keeps the variable, the suite does not get it.
# WHAT THIS PROJECT CALLS RUNNING ITS TESTS, which the drainer does not know.
#
# It used to be `./run-tests.sh` with flowy's Postgres paths spliced in. For a
# second project that is wrong twice over and quiet both times - a suite by
# another name reads as a red on the branch, and a project with no database is
# handed a requirement it does not have. 01M0DZPFQD.
#
# .flowy-gate is the project's answer, exit 0 for green, with `passed: N failed:
# M` on stdout for the note. A project that declares none is REFUSED and named:
# guessing a suite is how a misconfigured drainer writes a red onto somebody's
# branch.
[ -x "$WORK/.flowy-gate" ] ||
	die "$WORK has no executable .flowy-gate - this project has not said what running its tests means, and the drainer will not guess"
# THE RUN SAYS IT IS STILL ALIVE WHILE IT MEASURES.
#
# 01M0EBXHQ3: the landing lock is believed for fifteen minutes, a gate takes
# about five, and nothing renewed it in between - the only renew was at verdict
# time, after the measurement rather than during it. Five minutes fits; a retry
# or a slow box does not, and crossing the window now loses the VERDICT rather
# than just the land, because recording one refuses when there is nothing to
# renew.
#
# TIED TO THE GATE'S PID, NOT TO A TIMER. A heartbeat that outlives its pass
# would hold a target for a run that is no longer measuring anything, which is
# worse than the gap it closes. `kill -0` on the gate is the liveness signal,
# checked before every beat as well as after the sleep.
#
# IT RENEWS, IT NEVER DECLARES. Declaring again rewrites gate_run and clears
# gated_tip - it would destroy the verdict it is renewing for. The door is a
# renew for exactly that reason.
#
# A 409 STOPS IT AND SAYS SO. That is the node reporting the window has already
# gone, and beating harder cannot bring it back; the pass will hear the same
# thing at the verdict, and this makes it visible five minutes earlier instead
# of at the end of a run that is now worthless.
#
# A 404 STOPS IT QUIETLY, ONCE. The door lands separately from this - a drainer
# that logged a failure every five minutes against a node without it would be
# noise the first reader learns to skip.
heartbeat() {
	local watch=$1 every=${FLOWY_DRAIN_RENEW_EVERY:-300} answer code
	while kill -0 "$watch" 2>/dev/null; do
		sleep "$every"
		kill -0 "$watch" 2>/dev/null || return 0
		answer=$(api POST "/api/merge/$row/renew" '{}' 2>/dev/null) || return 0
		code=$(code_of "$answer")
		case "$code" in
		200) ;;
		404)
			say "this node has no renew door - the lock will not be held past its window"
			return 0
			;;
		*)
			say "RENEW REFUSED ($code): the window on $rowtarget has gone while the gate was running - the verdict will be refused too"
			return 0
			;;
		esac
	done
}

(cd "$WORK" && env -u FLOWY_AGENT ./.flowy-gate >>"$log" 2>&1) &
gate_pid=$!
heartbeat "$gate_pid" &
heart_pid=$!
if wait "$gate_pid"; then
	kill "$heart_pid" 2>/dev/null || true
	outcome=green
	note=$(grep -E "^passed:" "$log" | tail -1)
	say "green: $(grep -E '^passed:' "$log" | tail -1)"
else
	# THE SAME STOP ON BOTH ARMS. A heartbeat left running past a red would hold
	# the target for a run that has finished and failed - the exact thing the
	# pid check exists to prevent, defeated by forgetting one branch.
	kill "$heart_pid" 2>/dev/null || true
	# RECORDED, NOT RETRIED, and not diagnosed either.
	outcome=red
	note="$(grep -E "^passed:" "$log" | tail -1) - log at $log"
	say "RED: $(grep -E '^passed:' "$log" | tail -1)"
	grep -E '^\s+--- FAIL|^FAIL ' "$log" | head -5 >&2 || true

	# THE RED GOES TO THE QUEUE, not just to this box.
	#
	# It used to be a file here - red-<row>-<tip> - because the store had no move
	# for a red: the only way to end a declaration was to write a tip, and a
	# written tip is what MergeAdmissible reads as evidence FOR landing. So a
	# failed pass could either make the branch landable or say nothing, and it
	# said nothing.
	#
	# 7ea9fa7 gave it the third case. Posting it ends the declaration the moment
	# the run reports - without it the row reads `gating` for the full fifteen
	# minutes after the pass died, which is how two rows came to read as gating
	# at once tonight when the lock is one.
	# AND WHAT FAILED, not only how many.
	#
	# 01M0DXTNPM: every red this session ended with somebody typing a variant of
	# `grep -n "^FAIL" -A 12 "$log" | head -25` to find out what broke. Four
	# times by me on three rows, and two other seats did it in the room with
	# their own spellings.
	#
	# The count alone cannot be acted on. "passed: 668 failed: 1" sends a reader
	# to a log, and THE LOG LIVES ON WHICHEVER BOX RAN THE GATE - so for anybody
	# else it is a fact with no way to check it. The first failure's own line
	# fits in the note and travels with the row, which means `flowy queue` shows
	# it to a seat that has no access to this machine at all.
	#
	# THE FIRST ONE, and the count says how many more. 31 failures with one cause
	# read as 31 problems for an hour today until somebody read the first and saw
	# every other was the same refusal.
	#
	# Quoted with %s through jq's own escaping below - a check name carries
	# quotes and apostrophes ("a person's own row"), and a note that stops
	# parsing is a note nobody sees.
	first=$(grep -aE '^FAIL ' "$log" 2>/dev/null | head -1 | sed 's/ (exit [0-9]*)$//')
	count=$(grep -aE '^passed:' "$log" 2>/dev/null | tail -1)
	note=$count
	[ -n "$first" ] && note="$count - $first"

	# AND WHICH TEST, because the check's NAME is not the failure.
	#
	# run-tests.sh:12190 registers its Go check as `check "go test ./..."`, so
	# the FAIL line above reads "FAIL go test ./..." - true, and useless. Three
	# reds today were reported that way and every one of them cost somebody a
	# trip to the gate log to run the same grep by hand. I did it for vm-door
	# and orchestrator did it for the switcher within the hour.
	#
	# APPENDED, NEVER SUBSTITUTED, which is orchestrator's rule and the right
	# one: the check name says WHERE the suite broke and the test name says
	# WHAT broke, and a note carrying only the second would lose the harness
	# that produced it. Both, or the reader has to guess which they were given.
	#
	# Up to three, because a red with fifteen failing tests is usually one
	# cause and the first few are enough to recognise it - and a note long
	# enough to be truncated by the queue display is a note nobody reads.
	tests=$(grep -aoE '^ *--- FAIL: [A-Za-z0-9_/]+' "$log" 2>/dev/null |
		sed 's/^ *--- FAIL: //' | head -3 | paste -sd, -)
	[ -n "$tests" ] && note="$note - $tests"
	reported=$(api POST "/api/merge/$row/gate" \
		"$(jq -nc --arg run "$run" --arg tip "$tip" --arg note "$note" \
			'{run: $run, gated_tip: $tip, result: "red", note: $note}')")
	case "$(code_of "$reported")" in
	200) say "red recorded on the row - the declaration is over and the queue can say so" ;;
	*)
		# Said, not swallowed: a red the queue never heard is the state this
		# whole path exists to end, and a reader has to know which one they have.
		say "WARNING: the red could not be recorded ($(code_of "$reported")) - the queue still reads gating"
		body_of "$reported" >&2
		;;
	esac
	# The local note stays as a belt: the skip check below reads it, and a drainer
	# whose node is briefly unreachable must still not re-measure a tree it has
	# already measured. It is a cache of the queue's answer, not a second opinion.
	# Recorded twice, because two different readers ask two different questions.
	# The tip-keyed file answers "have I measured this exact tree", which the
	# post-rebase check reads. The per-row file records the BRANCH and TARGET
	# that produced that tree, which is what the pick loop can ask BEFORE a
	# declare - it has no tip yet, and getting one costs a lock and a rebase.
	printf 'red at %s, %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$(grep -E '^passed:' "$log" | tail -1)" >"$STATE/red-$row-$tip"
	printf '%s %s\n' \
		"$(git -C "$REPO" rev-parse --short "$branch" 2>/dev/null || echo unknown)" \
		"$(git -C "$REPO" rev-parse --short "$rowtarget" 2>/dev/null || echo unknown)" \
		>>"$STATE/red-$row"
	say "the row stays open and the log stays at $log - a person reads it"
	say "and $tip will not be gated again by this drainer until it changes"
	exit 1
fi

# ------------------------------------------------------------ record and land

# THE COUNT RIDES THE VERDICT, from the same line this pass already greps for
# its own status file. flowy 791719b made a green carry a note and the landing
# repeat it, and the drainer is the caller that has the number - the suite's own
# "passed: N failed: M". Without this the door can carry it and nothing does.
#
# A green with no count was the asymmetry: a red has carried its note since the
# verdict became a row, so the outcome nobody has to explain is the one whose
# evidence was thrown away - exactly when a landing is announced to the room.
count=$(grep -aE '^passed:' "$log" 2>/dev/null | tail -1)
verdict=$(api POST "/api/merge/$row/gate" \
	"$(printf '{"run":"%s","gated_tip":"%s","note":"%s"}' "$run" "$tip" "$count")")
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
if [ "$on" != "$rowtarget" ]; then
	# SAID ON THE ROW, not only in this log. The refusal itself is right and has
	# been since it was written; what was missing is that it stalls the WHOLE
	# QUEUE and announces it to a status file on one box.
	#
	# Measured 2026-08-19: a seat parked the shared checkout on its own branch
	# while waiting for a gate, four rows queued behind it, and I found it by
	# reading the drainer's status for another reason. Nothing was broken and
	# nobody could see it.
	#
	# This does not stop the next seat parking it - only working in a worktree
	# does that, and we all already do. It makes the stall self-announcing,
	# which is the same rule the conflict and checked-out skips follow: the
	# thing that tried writes why it could not, where everybody reads.
	blocked "$row" "the shared checkout $REPO is on $on, not $rowtarget - nothing can land until it is back. Whoever parked it: git -C $REPO checkout $rowtarget"
	die "$REPO is on $on, not $rowtarget - a fast-forward there lands nothing and reports success"
fi
before=$(git -C "$REPO" rev-parse --short HEAD)

# THE HATCH GOES ON THE LAND AND NOWHERE ELSE.
#
# FLOWY_LAND_GUARD=off belongs to this one git command. Setting it for the whole
# pass puts it in the environment the SUITE runs in, and the suite tests the
# guard: measured 2026-08-20, a bypass pass came back 683/2 with "git itself
# will not move master without the lock" and "the escape hatch never refuses and
# writes a trace with no node" - two failures about the guard being off, on a
# branch that had nothing to do with either.
#
# So the drainer takes it as its own variable and applies it here. A pass that
# needs the hatch still gates with the guard armed, which is the only way the
# verdict means anything.
# A word that only BECOMES an assignment after expansion is not an assignment.
# `${VAR:+NAME=value} git ...` looks right and is not: bash decides what is an
# assignment prefix while parsing, before any expansion, so the expanded word is
# taken as the COMMAND NAME. Measured 2026-08-20 - the land step died with
# "FLOWY_LAND_GUARD=off: command not found" after a green 685/0 gate.
# `env` is what applies a computed assignment, and an array is what keeps the
# reason's spaces from splitting it into words.
landenv=()
[ -n "${FLOWY_DRAIN_LAND_GUARD:-}" ] &&
	landenv+=("FLOWY_LAND_GUARD=$FLOWY_DRAIN_LAND_GUARD")
[ -n "${FLOWY_DRAIN_LAND_GUARD_REASON:-}" ] &&
	landenv+=("FLOWY_LAND_GUARD_REASON=$FLOWY_DRAIN_LAND_GUARD_REASON")
env FLOWY_TOKEN="$TOKEN" "${landenv[@]}" \
	git -C "$REPO" merge --ff-only "$branch" >/dev/null ||
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
# A DEPLOY THAT REFUSES IS ITS OWN OUTCOME, not silence.
#
# Measured at 20:52: the deploy refused because the shared checkout had another
# agent's work in it, the pass exited, and the status file still said "landed" -
# which is true and useless. The node then caught up only because another row
# was queued behind this one and its pass deployed. A refusal on the LAST row of
# the queue never retries: nothing comes after it, so the node stays behind and
# the only record is a line in a log nobody is reading.
#
# So the status carries the state that actually obtains - landed, not deployed -
# and says why, because "landed but not serving" is the condition row 01M09SKFBQ
# is entirely about.
# THE DEPLOY'S OWN OUTPUT GOES IN THE PASS LOG, because the pass is not over
# when the suite is.
#
# orchestrator, measuring the new deploy path from the outside: "the pass log
# stops before the last thing the pass does". drain-<row>-<tip>.log ended at
# "passed: 662 failed: 0" and the deploy ran after it, into a session's
# scrollback - so the one arm nobody could check was whether deploy.sh said it
# built in a throwaway worktree, which is the line that distinguishes doing the
# thing from never having done it.
#
# tee rather than redirect: the operator watching a foreground pass should still
# see it, and the log is for whoever reads it tomorrow.
if ! "$REPO/scripts/deploy.sh" 2>&1 | tee -a "$log"; then
	outcome="deploy-refused"
	note="landed $landed and the deploy refused - master has moved and the node has not"
	printf '[drain] the branch LANDED and the deploy did not: %s is on master, the node is serving something older\n' "$landed" >&2
	exit 1
fi
outcome=deployed
note="$landed"
