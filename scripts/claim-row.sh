#!/usr/bin/env bash
# Win the row or do not spawn: a claim you can lose, and be told you lost.
#
# THE MEASUREMENT, all on the night of 2026-08-17:
#
#   two helpers were spawned onto the same console file within ten minutes, and
#   two more onto the same unowned row within two minutes, because neither
#   spawner wrote its claim to the board before starting. Worktrees kept the
#   files apart and did nothing about the duplicated work.
#
#   three agents fixed the same one-line biome config within five minutes.
#
# Announcing in the room does not help: a hook can read the board, nothing can
# read a sentence. So this is the step BEFORE the spawn, and it either wins the
# claim and prints the helper's brief, or it refuses - and every refusal exits
# non-zero, so `claim-row.sh ... && spawn` cannot spawn unclaimed.
#
#   scripts/claim-row.sh --as <name> <row id>   win it, print the brief
#   scripts/claim-row.sh --release --as <name> <row id>   hand it back
#
#   exit 0   it is yours. stdout is the brief to paste into the helper prompt
#   exit 3   refused - somebody else holds it, or you lost the race. DO NOT SPAWN
#   exit 1   could not reach the board, or bad arguments. ALSO DO NOT SPAWN
#
# FAIL CLOSED IS THE WHOLE POINT. A board that cannot be read is not a board
# that says the row is free, so every error path here refuses rather than
# letting the caller through - the opposite of board-nag.sh beside it, which
# exits 0 on every failure because a nag that dies must not take deliveries
# with it. Different jobs, opposite defaults, on purpose.
#
# WHY THIS IS NOT A ONE-LINE curl. POST /api/todo/{id}/assignee is
# last-write-wins by design (internal/store/assign.go: it does not even refuse a
# restatement), and there is no compare-and-set door for todos on this node -
# POST /api/work/{id}/claim is 404 here, measured 2026-08-18. So the mutual
# exclusion is built out of the one thing the node does keep: the ASSIGNMENT LOG,
# which records every claim with a seq_hlc and who it was taken from.
#
#   1. read the log, remember its tip. Refuse now if somebody else holds the row.
#   2. write the claim.
#   3. wait out the settle window, read the log again.
#   4. of the entries ABOVE the remembered tip, the LOWEST seq_hlc wins.
#
# That turns last-write-wins into first-writer-wins, and it works because both
# racers fold the same log with the same rule and so reach the same answer -
# whichever of them wrote second. The loser puts the winner's name back, because
# last-write-wins left its own name in the field.
#
# IF YOU CHANGE THIS, TELL THE ROOM. Two rescue scripts were written four times
# over on 2026-08-17 because nobody said they existed.
set -u

FLOWY_ADDR=${FLOWY_ADDR:-http://192.168.1.55:8787}
AGENTS=${FLOWY_AGENTS:-$HOME/.config/flowy/agents}
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PREAMBLE=${HELPER_PREAMBLE:-$HERE/helper-preamble.md}

# The settle window is how long a racer gets to land its write before we decide.
# Four seconds covers two HTTP round trips to the node on this LAN with room to
# spare; the wide window - one agent starting minutes after another - is caught
# by the read in step 1, not by this.
SETTLE=${FLOWY_CLAIM_SETTLE:-4}

die() {
	printf 'claim-row: %s\n' "$1" >&2
	exit "${2:-1}"
}

usage() {
	printf 'usage: claim-row.sh [--as NAME] [--steal] [--release] [--quiet] <row id>\n' >&2
	printf '  exit 0 = it is yours, 3 = refused, 1 = could not tell. Only 0 may spawn.\n' >&2
	exit 1
}

name=${FLOWY_AGENT:-${BOARD_NAG_NAME:-}}
steal=0
release=0
quiet=0
row=""
while (($# > 0)); do
	case "$1" in
	--as)
		shift
		name=${1:-}
		;;
	--steal) steal=1 ;;
	--release) release=1 ;;
	--quiet) quiet=1 ;;
	-h | --help) usage ;;
	-*) die "unknown option: $1" ;;
	*)
		[[ -n $row ]] && die "one row id at a time (got $row and $1)"
		row=$1
		;;
	esac
	shift
done
[[ -n $row ]] || usage
[[ -n $name ]] || die 'who are you? pass --as NAME or set FLOWY_AGENT'
[[ $name == *[$'\n\t\r']* ]] && die 'a name is one line'

# A HELPER CLAIMS UNDER A NAME THAT SAYS WHOSE HELPER IT IS - "claude-host/sub-2"
# rather than "claude-host", so the board shows three helpers rather than one
# seat that looks like it is doing three things at once. The node takes any
# one-line handle as an assignee, but only real seats have tokens, so the token
# is looked up under the name and then under the part before the first "/".
seat=$name
if [[ ! -r "$AGENTS/$seat" ]]; then
	seat=${name%%/*}
fi
[[ -r "$AGENTS/$seat" ]] || die "no token for $name (looked for $AGENTS/$seat)"
token=$(cat "$AGENTS/$seat") || die "cannot read $AGENTS/$seat"

api() { # api METHOD PATH [BODY] -> body on stdout, non-zero on transport or HTTP error
	local method=$1 path=$2 body=${3:-} out code
	if [[ -n $body ]]; then
		out=$(curl -sS -m 15 -w '\n%{http_code}' -X "$method" \
			-H "Authorization: Bearer $token" -H 'content-type: application/json' \
			-d "$body" "$FLOWY_ADDR$path" 2>/dev/null) || return 1
	else
		out=$(curl -sS -m 15 -w '\n%{http_code}' -X "$method" \
			-H "Authorization: Bearer $token" "$FLOWY_ADDR$path" 2>/dev/null) || return 1
	fi
	code=${out##*$'\n'}
	out=${out%$'\n'*}
	[[ $code == 2?? ]] || {
		printf '%s\n' "$out" >&2
		return 1
	}
	printf '%s\n' "$out"
}

# jq is not optional here. An unparsed answer is an unknown board state, and an
# unknown board state has to refuse.
command -v jq >/dev/null || die 'jq is required'

view=$(api GET "/api/todo/$row/assignee") || die "cannot read row $row from the board" 1
holder=$(jq -r '.assignee // ""' <<<"$view" 2>/dev/null) || die 'the board answered something jq could not read'
title=$(jq -r '.item.title // ""' <<<"$view")
# The tip of the log as it was BEFORE we wrote. Everything above it is the race.
tip=$(jq -r '[.log[]?.seq_hlc] | max // 0' <<<"$view")
[[ $tip =~ ^[0-9]+$ ]] || tip=0

if ((release)); then
	# Handing back is not a claim and needs no arbitration - but it is still only
	# yours to hand back. Releasing somebody else's row is how a row gets worked
	# twice, which is the thing this file exists to stop.
	[[ $holder == "$name" || $steal == 1 ]] || die "row $row is held by ${holder:-nobody}, not by $name" 3
	api POST "/api/todo/$row/assignee" '{"assignee":""}' >/dev/null || die 'could not release the row' 1
	api POST "/api/artifact/$row/status" '{"status":"todo"}' >/dev/null || true
	printf 'released %s (%s)\n' "$row" "$title" >&2
	exit 0
fi

if [[ -n $holder && $holder != "$name" ]]; then
	((steal)) || die "row $row is already held by $holder - do not spawn. --steal to take it anyway" 3
	printf 'claim-row: taking %s from %s (--steal)\n' "$row" "$holder" >&2
fi

if [[ $holder != "$name" ]]; then
	api POST "/api/todo/$row/assignee" "$(jq -nc --arg a "$name" '{assignee:$a}')" >/dev/null ||
		die 'could not write the claim' 1

	sleep "$SETTLE"

	after=$(api GET "/api/todo/$row/assignee") || die 'wrote the claim but could not read it back' 1
	# First writer above the remembered tip wins. Empty-assignee entries are
	# releases and are not claims, so they do not win anything.
	winner=$(jq -r --argjson tip "$tip" '
		[.log[]? | select(.seq_hlc > $tip) | select((.assignee // "") != "")]
		| sort_by(.seq_hlc) | .[0].assignee // ""' <<<"$after")
	if [[ -z $winner ]]; then
		# Our own write should be up there. If it is not, we cannot tell who holds
		# this row, and an unknown answer refuses.
		die "wrote the claim on $row but the log does not show it - refusing" 1
	fi
	if [[ $winner != "$name" ]]; then
		# We lost, and last-write-wins left OUR name on the row. Put the winner's
		# name back before we go, or the loser's refusal would still have stolen
		# the row it refused.
		api POST "/api/todo/$row/assignee" "$(jq -nc --arg a "$winner" '{assignee:$a}')" >/dev/null || true
		die "lost the race for $row to $winner (their claim landed first) - do not spawn" 3
	fi
	# We won, but the loser may not have restored us yet, or may have written
	# after our read. Re-assert only when the field disagrees, so an uncontested
	# claim leaves exactly one entry in the log.
	held=$(jq -r '.assignee // ""' <<<"$after")
	[[ $held == "$name" ]] ||
		api POST "/api/todo/$row/assignee" "$(jq -nc --arg a "$name" '{assignee:$a}')" >/dev/null || true
fi

# Active, so an idle-watcher can tell a row being worked from a row sitting.
api POST "/api/artifact/$row/status" '{"status":"active"}' >/dev/null || true

((quiet)) && exit 0

# THE BRIEF. Printing it here rather than leaving it to the spawner is the point:
# an agent landed a commit onto master while a fifteen-commit batch was gating,
# because its brief said "land when admissible" and nothing said "not while a
# batch gates". The rules travel with the claim or they do not travel.
queue=$(api GET '/api/merge-queue' 2>/dev/null) || queue=""
gating=$(jq -r '.gating // 0' <<<"${queue:-{\}}" 2>/dev/null)
[[ $gating =~ ^[0-9]+$ ]] || gating=0

printf 'You are %s. The row below is claimed for you on the board already.\n\n' "$name"
if [[ -r $PREAMBLE ]]; then
	cat "$PREAMBLE"
else
	# The preamble is the three rules. Losing the file must not silently lose
	# them, so the rules themselves are here too.
	printf 'RULES: claim every further row on the board before starting it;\n'
	printf 'work in your OWN git worktree; never land while a batch is gating.\n'
fi
printf '\n---\n\nYOUR ROW %s\n\n' "$row"
jq -r '"  " + (.item.title // "") + "\n\n" + (.item.body // "")' <<<"$view"
printf '\n'
if ((gating > 0)); then
	printf 'MERGE QUEUE: %d batch(es) GATING RIGHT NOW. DO NOT LAND ANYTHING on the\n' "$gating"
	printf 'target while that is true - a commit onto the target invalidates the run\n'
	printf 'measuring it and the whole batch has to be re-gated. File your branch and wait.\n\n'
fi
printf 'When you finish: POST %s/api/artifact/%s/status {"status":"done"}, then one line in the room.\n' \
	"$FLOWY_ADDR" "$row"
