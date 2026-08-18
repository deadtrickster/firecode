#!/usr/bin/env bash
# Land a gated branch onto the merge target, and REFUSE every way it can be wrong.
#
# THE MEASUREMENT. Master took two partial lands in one night. Both times an
# agent gated a large integration branch, announced it landed, and master moved
# forward by exactly one commit - fifteen commits stranded the first time, six
# the second, all of it work other agents believed was in. Nobody was careless
# either time: a merge request carries `branch`, that field is what a lander
# resolves to fast-forward, and when the thing MEASURED is a union the green sha
# lives on a branch the row does not name. The queue records gated_tip
# faithfully and then hands the lander a branch that does not contain it.
#
# So the queue's founding rule - a verdict is only as good as the tip it was
# measured against - is half of one. A verdict is also only as good as THE TREE
# IT IS APPLIED TO. The tip is half an identity; reachability is the other half,
# and this script is where that half lives, because the node has no git and
# cannot answer it.
#
#   scripts/land.sh <sha-or-branch> --tip <gated-tip> [--request <merge row>]
#                   [--onto <target>] [--repo <path>] [--as <agent>] [--dry-run]
#
# <sha-or-branch> is WHAT YOU MEASURED - the integration branch if you batched,
# not the feature branch the row was filed about. --tip is the tip that gate
# reported green on. Both are required and separate on purpose: passing the same
# value twice is a claim worth having to make explicitly.
#
# THE SEAM WITH THE NODE, agreed in the room and built to it: the merge-base and
# the fast-forward happen HERE, in the repository, and then POST
# /api/merge/{id}/land records the sha master became and releases the landing
# lock. One protocol step, so exclusivity and the chain record attach to the
# reachability check rather than floating beside it. The node's half refuses what
# it can see without git - no verdict, no lock, somebody else's lock - and this
# half refuses what only git can see.
#
# WHAT IT REFUSES, each of which cost somebody a run:
#
#   NOT A FAST-FORWARD. If the target is not an ancestor of what is landing, it
#   stops. It never merges the target into the branch and lands the merge: that
#   produces a tree no gate ever measured, which is the failure the whole queue
#   exists to prevent.
#
#   A TIP THE TREE DOES NOT CONTAIN. If the gated tip is not an ancestor of what
#   is about to land, the evidence is for a tree you are not landing.
#
#   A TIP NO VERDICT WAS RECORDED FOR. The queue must hold a request whose
#   gated_tip is this tip, compared as a full sha after both are resolved
#   through git. A tip nobody gated is not a verdict.
#
#   A LOCK HELD BY SOMEBODY ELSE, naming WHO and UNTIL WHEN, and exiting 3 -
#   held is a WAIT, not a verdict about your evidence, and an agent that cannot
#   tell those apart re-gates when it should sleep.
#
#   A LOCK THAT IS NOT THIS DECLARATION'S. Live defect, and the reason this
#   check exists: the node's lock keys on the AGENT ID, so a sibling session of
#   the same seat reads as the holder and lands straight through the node's
#   ownership test. This half can see the difference, because a declaration
#   takes the lock at the instant it writes its own merge.gate event: if the
#   lock's taken_at is not that instant, the lock on the target belongs to some
#   other declaration made under the same name. It refuses and says so.
#
#   A RUN IN FLIGHT ON THE SAME TARGET. Landing invalidates it.
#
#   A DIRTY TREE, and a target that moved between the announcement and the
#   merge.
#
# IT NEVER RELEASES A LOCK IT DID NOT TAKE. The only release is the node's own,
# inside the land verb, which releases for the holder after recording the tip.
# There is no path here that releases anything, on any refusal, ever.
#
# ANNOUNCE BEFORE THE FF, NOT AFTER, and the ff does not run if the announcement
# fails. Every landing rule this room wrote was advisory and advisory rules lost
# within minutes. A subagent landing through this door announces by construction,
# whatever its brief says.
#
# Exit 0 landed, 1 refused, 2 misused, 3 the target is held - wait, do not re-gate.
#
# IF YOU CHANGE THIS, TELL THE ROOM.
set -uo pipefail

FLOWY_ADDR=${FLOWY_ADDR:-${FLOWY_URL:-http://192.168.1.55:8787}}
AGENTS=${FLOWY_AGENTS:-$HOME/.config/flowy/agents}
NAME=${FLOWY_AGENT:-${BOARD_NAG_NAME:-}}
REPO=${FLOWY_REPO:-$HOME/Projects/flowy}
TARGET=${FLOWY_MERGE_TARGET:-master}
ROOM=${FLOWY_ROOM:-general}

# How far the lock's taken_at may sit from the declaration that took it before
# they are called different acts. The two writes are one round trip apart on
# this LAN and both are stamped by the node's own clock, so seconds is generous;
# it is not tuned to be forgiving, because the thing on the other side of this
# number is a sibling session landing under somebody's run.
SLACK=${LAND_LOCK_SLACK:-5}

WHAT=""
TIP=""
REQUEST=""
DRY=no

usage() {
	printf 'usage: land.sh <sha-or-branch> --tip <gated-tip> [--request <merge row>]\n' >&2
	printf '                [--onto <target>] [--repo <path>] [--as <agent>] [--dry-run]\n' >&2
	printf '  exit 0 landed, 1 refused, 2 misused, 3 target held by somebody else\n' >&2
	exit 2
}

say() { printf '%s\n' "$*"; }

# A refusal is a decision, not an obstacle: it prints the fact it measured and
# stops. Nothing below ever falls through to a different spelling of the landing.
refuse() {
	printf 'REFUSED: %s\n' "$*" >&2
	exit 1
}

# HELD IS NOT REFUSED. Different exit code because it is a different instruction
# to the caller: wait for the holder, then land the same evidence, rather than
# re-gate because the evidence went stale.
held() {
	printf 'HELD: %s\n' "$*" >&2
	exit 3
}

while [ $# -gt 0 ]; do
	case "$1" in
	--tip)
		[ $# -ge 2 ] || usage
		TIP=$2
		shift 2
		;;
	--request)
		[ $# -ge 2 ] || usage
		REQUEST=$2
		shift 2
		;;
	--onto)
		[ $# -ge 2 ] || usage
		TARGET=$2
		shift 2
		;;
	--repo)
		[ $# -ge 2 ] || usage
		REPO=$2
		shift 2
		;;
	--as)
		[ $# -ge 2 ] || usage
		NAME=$2
		shift 2
		;;
	--room)
		[ $# -ge 2 ] || usage
		ROOM=$2
		shift 2
		;;
	--dry-run)
		DRY=yes
		shift
		;;
	-h | --help) usage ;;
	-*) usage ;;
	*)
		[ -z "$WHAT" ] || usage
		WHAT=$1
		shift
		;;
	esac
done

[ -n "$WHAT" ] || usage
[ -n "$TIP" ] || usage
[ -n "$NAME" ] || {
	printf 'land.sh: who are you? pass --as NAME or set FLOWY_AGENT\n' >&2
	exit 2
}

# jq is not optional. An unparsed answer is an unknown lock state, and an unknown
# lock state has to refuse - the same rule claim-row.sh follows next door.
command -v jq >/dev/null 2>&1 || {
	printf 'land.sh: jq is required\n' >&2
	exit 2
}

# A helper claims under a name that says whose helper it is - "claude-host/sub-2"
# - and only real seats have tokens, so the token is looked up under the name and
# then under the part before the first "/", exactly as claim-row.sh resolves it.
seat=$NAME
[ -r "$AGENTS/$seat" ] || seat=${NAME%%/*}
[ -r "$AGENTS/$seat" ] || {
	printf 'land.sh: no token for %s (looked for %s)\n' "$NAME" "$AGENTS/$seat" >&2
	exit 2
}
TOKEN=$(cat "$AGENTS/$seat") || {
	printf 'land.sh: cannot read %s\n' "$AGENTS/$seat" >&2
	exit 2
}

api() { # api METHOD PATH [BODY] -> body on stdout, non-zero on transport or HTTP error
	local method=$1 path=$2 body=${3:-} out code
	if [ -n "$body" ]; then
		out=$(curl -sS -m 20 -w '\n%{http_code}' -X "$method" \
			-H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
			-d "$body" "$FLOWY_ADDR$path" 2>/dev/null) || return 1
	else
		out=$(curl -sS -m 20 -w '\n%{http_code}' -X "$method" \
			-H "Authorization: Bearer $TOKEN" "$FLOWY_ADDR$path" 2>/dev/null) || return 1
	fi
	code=${out##*$'\n'}
	out=${out%$'\n'*}
	[ "${code:0:1}" = 2 ] || {
		printf '%s\n' "$out" >&2
		return 1
	}
	printf '%s\n' "$out"
}

cd "$REPO" || refuse "no repo at $REPO"
git rev-parse --git-dir >/dev/null 2>&1 || refuse "$REPO is not a git repository"

# ON THE TARGET, and checked before anything is announced. A fast-forward moves
# the branch that is CHECKED OUT, so a checkout sitting on a feature branch
# either fails at the merge or moves the wrong ref - and finding that out after
# the room post leaves an announcement of a landing that never happened.
on=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || on=""
[ "$on" = "$TARGET" ] ||
	refuse "the checkout at $REPO is on ${on:-a detached HEAD}, not on $TARGET - \
check out $TARGET there first"

# ------------------------------------------------------------ the repo half

# A dirty tree is somebody else's work in progress - four agents share this
# checkout. A fast-forward does not touch uncommitted files, but landing under
# somebody's half-finished edit means the tree that gets built next is not the
# tree that went green either.
if [ -n "$(git status --porcelain)" ]; then
	git status --short >&2
	refuse "the tree has uncommitted changes - somebody is mid-edit in the shared checkout"
fi

head_sha=$(git rev-parse --verify "$WHAT^{commit}" 2>/dev/null) ||
	refuse "no such commit or branch: $WHAT"
tip_sha=$(git rev-parse --verify "$TIP^{commit}" 2>/dev/null) ||
	refuse "the gated tip $TIP is not a commit in this repo"
target_sha=$(git rev-parse --verify "$TARGET^{commit}" 2>/dev/null) ||
	refuse "no such merge target: $TARGET"

short() { git rev-parse --short "$1"; }

# THE CHECK THIS SCRIPT EXISTS FOR. The green verdict was recorded against $TIP;
# landing $WHAT means something only if $WHAT actually contains it. A union gated
# green and a feature branch landed from the row is exactly this case, and it is
# the case that cost twenty-one commits in one night.
if ! git merge-base --is-ancestor "$tip_sha" "$head_sha"; then
	printf 'gated tip: %s\nlanding:   %s\n' "$(short "$tip_sha")" "$(short "$head_sha")" >&2
	refuse "$(short "$head_sha") does not contain the tip that was measured - \
the evidence is for a tree you are not landing"
fi

# FAST-FORWARD ONLY. If the target is not already an ancestor, the tree that
# would result is a merge nobody gated. There is deliberately no branch here that
# merges the target in and lands the result: that is the wrong answer to this
# refusal, and it is the answer somebody reaches for at four in the morning.
if ! git merge-base --is-ancestor "$target_sha" "$head_sha"; then
	printf '%s: %s\nlanding: %s\n' "$TARGET" "$(short "$target_sha")" "$(short "$head_sha")" >&2
	refuse "$TARGET is not an ancestor of $(short "$head_sha") - this would not be a \
fast-forward. Rebase onto $TARGET and re-gate; do NOT merge $TARGET in and land that"
fi

if [ "$target_sha" = "$head_sha" ]; then
	say "$TARGET is already at $(short "$head_sha") - nothing to land"
	exit 0
fi

ahead=$(git rev-list --count "$target_sha..$head_sha")

# ------------------------------------------------------------ the node half

me=$(api GET /api/whoami | jq -r '.agent // ""') ||
	refuse "cannot reach the node at $FLOWY_ADDR - a lock that cannot be read is not a lock that is free"
[ -n "$me" ] || refuse "the node does not resolve $seat's token to an agent, so it cannot hold a lock"

# THE TARGET TIP IS STATED, not left to the node. Asked bare, the queue judges
# admissibility against the last land it recorded or, failing that, the commit
# the node was BUILT from - which froze a dozen landings behind for a whole night
# and refused green branches for reasons that were already false. Git is right
# here, so git answers.
queue=$(api GET "/api/merge-queue?target=$TARGET&target_tip=$target_sha") ||
	refuse "cannot read the merge queue - refusing rather than landing blind"

# WHICH VERDICT IS BEING LANDED. Not a convenience: a tip with no request behind
# it is a tip nobody gated, and this is where that is caught. Named with
# --request, or found by the tip, and either way the row's own gated_tip has to
# resolve to the same commit.
if [ -z "$REQUEST" ]; then
	matches=$(jq -r --arg t "$tip_sha" '
		[.items[]? | select((.gated_tip // "") != "")
		 | select(.gated_tip as $g | $t | startswith($g))] | .[].id' <<<"$queue")
	count=$(printf '%s' "$matches" | grep -c . || true)
	[ "$count" = 1 ] ||
		refuse "$count open merge requests on $TARGET carry gated tip $(short "$tip_sha") - \
name the one you are landing with --request"
	REQUEST=$matches
fi

row=$(jq -r --arg id "$REQUEST" '.items[]? | select(.id == $id)' <<<"$queue")
[ -n "$row" ] ||
	refuse "$REQUEST is not an open merge request on $TARGET - a tip with no request \
behind it is a tip nobody gated"

row_tip=$(jq -r '.gated_tip // ""' <<<"$row")
[ -n "$row_tip" ] ||
	refuse "$REQUEST has no verdict on it - there is nothing to land. Declare a run, \
wait for green, then land"

# FULL SHA, resolved through git rather than compared as text: the queue may hold
# a seven-character tip and a prefix match on strings is how two different
# commits become one.
row_tip_sha=$(git rev-parse --verify "$row_tip^{commit}" 2>/dev/null) ||
	refuse "$REQUEST was gated on $row_tip, which is not a commit in this repo"
[ "$row_tip_sha" = "$tip_sha" ] ||
	refuse "$REQUEST was gated on $(short "$row_tip_sha"), not on $(short "$tip_sha") - \
you are applying a verdict to a tip it did not measure"

# A RUN IN FLIGHT IS A WAIT. Landing moves the tip under a gate that is measuring
# it right now, and the invalidated party finds out by reading a number that was
# already worthless. It happened twice in one hour.
gating=$(jq -r --arg id "$REQUEST" '
	[.items[]? | select(.gating == true) | select(.id != $id)
	 | "\(.branch) (\(.assignee // "unowned"))"] | join(", ")' <<<"$queue")
[ -z "$gating" ] ||
	held "a run is measuring $TARGET right now: $gating. Landing invalidates it - wait for their sha"

lock_held=$(jq -r '.lock.held // false' <<<"$queue")
lock_holder=$(jq -r '.lock.holder // ""' <<<"$queue")
lock_name=$(jq -r '.lock.holder_name // .lock.holder // "somebody"' <<<"$queue")
lock_until=$(jq -r '.lock.until // ""' <<<"$queue")
lock_taken=$(jq -r '.lock.taken_at // ""' <<<"$queue")

# NO LOCK IS NOT PERMISSION. The node's land verb refuses a target nobody holds,
# and it is right to: a land outside the lock is a land under somebody's run.
[ "$lock_held" = true ] ||
	refuse "$TARGET is not held by anybody. A land is exclusive through the lock a gate \
declaration takes - declare the run and land inside it"

if [ "$lock_holder" != "$me" ]; then
	held "$TARGET is held by $lock_name until $lock_until - their run is measuring it. \
Wait for their sha and land the same evidence; do not re-gate"
fi

# THE SIBLING CHECK, and the defect it is written about.
#
# The lock keys on the AGENT ID. Two sessions of the same seat are one holder to
# the node, so a sibling's declaration takes the lock out from under this one -
# ON CONFLICT ... WHERE holder = $2 is a renewal to the database - and both
# sessions then read themselves as the holder and land under each other's runs.
# The node cannot see this. This side can, because a declaration takes the lock
# and writes its merge.gate event in the same act: if the lock's taken_at is not
# the instant this row declared, the lock belongs to some other declaration made
# under the same name.
events=$(api GET "/api/events?thread=$REQUEST&type=merge.gate&limit=50") ||
	refuse "cannot read the gate declarations on $REQUEST, so the lock cannot be shown \
to be this run's - refusing"

decl=$(jq -r '[.events[]? | select((.meta.gated_tip // "") == "")]
	| sort_by(.created) | last // {} | "\(.created // "")\t\(.actor // "")"' <<<"$events")
decl_at=${decl%%$'\t'*}
decl_by=${decl##*$'\t'}
[ -n "$decl_at" ] ||
	refuse "no gate declaration is recorded on $REQUEST, so nothing proves the lock on \
$TARGET is this run's - declare the run and land inside it"
[ "$decl_by" = "$me" ] ||
	refuse "$REQUEST was declared by $decl_by and the lock on $TARGET is held under your \
name - you are holding it for a different declaration. Do not land this one"

taken_epoch=$(date -u -d "$lock_taken" +%s 2>/dev/null) ||
	refuse "the node reported taken_at as $lock_taken, which is not a time this can read"
decl_epoch=$(date -u -d "$decl_at" +%s 2>/dev/null) ||
	refuse "the declaration on $REQUEST is stamped $decl_at, which is not a time this can read"
drift=$((taken_epoch - decl_epoch))
[ "$drift" -ge 0 ] || drift=$((-drift))
if [ "$drift" -gt "$SLACK" ]; then
	printf 'declared: %s\nlock taken: %s\n' "$decl_at" "$lock_taken" >&2
	refuse "the lock on $TARGET was taken ${drift}s away from this row's declaration, so it \
is not the lock this run took. The node keys the lock on the agent id, so a sibling session of \
$NAME reads as the holder - one of you would be landing under the other's run. Sort out which \
session holds $TARGET before landing"
fi

# ------------------------------------------------------------ announce, land

subjects=$(git log --format='  %h %s' "$target_sha..$head_sha" | head -12)
notice="landing $(short "$head_sha") onto $TARGET $(short "$target_sha"), $ahead commits.
gated tip $(short "$tip_sha") contained, $REQUEST, lock mine.
$subjects"

if [ "$DRY" = yes ]; then
	say "would land $(short "$head_sha") onto $TARGET ($ahead commits), request $REQUEST"
	say "$notice"
	exit 0
fi

# BEFORE the ff, and the ff does not run if this fails.
if ! api POST "/api/chat/$ROOM/say" "$(jq -nc --arg b "$notice" '{body:$b}')" >/dev/null; then
	refuse "could not announce in $ROOM as $NAME - not landing silently"
fi

# Re-read the target IMMEDIATELY before moving it. The room post takes a moment,
# and a moment is all it took: master moved between one agent's admissibility
# check and their merge, twice in one night.
now_sha=$(git rev-parse --verify "$TARGET^{commit}") || refuse "cannot re-read $TARGET"
[ "$now_sha" = "$target_sha" ] ||
	refuse "$TARGET moved from $(short "$target_sha") to $(short "$now_sha") while \
announcing - re-gate on the new tip"

if ! git merge --ff-only "$head_sha" >/dev/null 2>&1; then
	refuse "fast-forward onto $TARGET failed - the tree may not be on $TARGET"
fi

landed=$(git rev-parse --verify "$TARGET^{commit}")

# THE RECORD, and the lock's release, in the node's own verb. Released by its
# holder, after the landed tip is written - never by a second call from here, and
# never on any path above this one.
if ! api POST "/api/merge/$REQUEST/land" "$(jq -nc --arg s "$landed" '{sha:$s}')" >/dev/null; then
	say "LANDED $(short "$landed") but the node was NOT told: POST /api/merge/$REQUEST/land failed."
	say "$TARGET has moved and the queue does not know. Retry it now:"
	say "  curl -sS -X POST -H \"Authorization: Bearer \$(cat $AGENTS/$seat)\" \\"
	say "    -H 'content-type: application/json' -d '{\"sha\":\"$landed\"}' \\"
	say "    $FLOWY_ADDR/api/merge/$REQUEST/land"
	exit 1
fi

say "landed $(short "$landed") onto $TARGET, $ahead commits, gated tip $(short "$tip_sha"), $REQUEST recorded"
api POST "/api/chat/$ROOM/say" \
	"$(jq -nc --arg b "landed. $TARGET $(short "$landed"), $ahead commits, gated tip $(short "$tip_sha")." '{body:$b}')" \
	>/dev/null || say "WARNING: landed and recorded, but could not post the confirmation"
