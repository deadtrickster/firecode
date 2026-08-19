#!/usr/bin/env bash
# Ask the node for the FIELDS you need, never the whole payload.
# THE WHOLE ID, because a prefix is not an address.
#
# These printed ten characters, which reads beautifully in a room and is the
# single most expensive habit this fleet had on 2026-08-18: three incidents in
# three hours, two agents, three different doors. I declared a gate against a
# prefix I had reconstructed and got a 404; I reported a defect in the deps door
# that did not exist, on a 404 that was my own paste; orchestrator wrote a ruling
# on top of that report. Every one of them looked like a right answer.
#
# AND RESOLVING PREFIXES IS THE WRONG FIX, which is why this is the right one: a
# resolved prefix is an id whose meaning depends on WHEN it was resolved.
# 01M0BP8171 is unique tonight and stops being unique the day a row is filed
# that shares it, so a script pasting one works until it silently addresses a
# different row. That failure is invisible, which makes it worse than every
# incident above.
#
# So the id is printed whole and the TITLE is what gets cut - a title is read by
# a person and an id is pasted into a door.
#
# Measured on 2026-08-18, which is the only reason this exists: one
# /api/merge-queue read is 300KB, one /api/artifacts page with metadata is tens
# of KB, and an agent that pulls either into its context has spent more on
# looking than a room message costs in a day. Terseness in chat was about 2
# percent of a day's tokens; whole payloads and wasted gates were the rest.
#
# So every verb here prints LINES - one row per line, only the fields somebody
# acts on - and does the jq at the door rather than after. The full payload is
# still one curl away when it is genuinely wanted; the point is that it stops
# being the default.
#
# usage:
#   q.sh board [me|open|unowned]   the todo board, one row per line
#   q.sh queue                     merge requests, the lock, and the target
#   q.sh lock                      just the lock: who, which work, until when
#   q.sh findings [tag]            findings with their three axes
#   q.sh row <id>                  one row: status, assignee, title
#   q.sh master                    what the queue thinks the target is, and git's answer
set -euo pipefail

ADDR=${FLOWY_ADDR:-http://192.168.1.55:8787}
NAME=${FLOWY_AGENT:-${BOARD_NAG_NAME:-claude-host}}
AGENTS=${FLOWY_AGENTS:-$HOME/.config/flowy/agents}
REPO=${FLOWY_REPO:-$HOME/Projects/flowy}

[[ -r $AGENTS/$NAME ]] || {
	printf 'q: no token for %s\n' "$NAME" >&2
	exit 2
}
TOKEN=$(cat "$AGENTS/$NAME")

get() { curl -sS -m 20 -H "Authorization: Bearer $TOKEN" "$ADDR$1"; }

case ${1:-} in
board)
	# `todo` and `active` only: a done row is not work and paging it back is
	# most of what makes this read expensive.
	get "/api/artifacts?type=memory&kind=todo&limit=200" | jq -r --arg me "$NAME" --arg f "${2:-open}" '
			[.artifacts[]? | select(.status=="todo" or .status=="active")]
			| map(select(
					$f == "open"
					or ($f == "me"      and (.fields.assignee // "") == $me)
					or ($f == "unowned" and (.fields.assignee // "") == "")))
			| sort_by(.status)[]
			| "\(.id) \(.status[0:6]) \((.fields.assignee // "-")[0:12]) \(.title[0:48])"'
	;;
queue | lock)
	# RETIRED, 2026-08-19: `flowy queue` does this and does it better.
	#
	# These parsed the merge queue's json into lines, which was the right shape
	# and the wrong place: /api/merge-queue answered a map[string]any, so the
	# console, the drainer, the wait door and this file each rebuilt the answer
	# by hand and drifted. That is how I came to read `blocked_why` off a surface
	# that nests it and report a defect that did not exist.
	#
	# The verb decodes the node's own type, so the two ends cannot disagree. It
	# also prints the branch and the owner beside each row, and stamps the moment
	# it read the lock - the thing added here after two people quoted a stale
	# lock reading minutes old.
	#
	# And it refuses to speak as the operator by default, which this never
	# checked: every q.sh read without FLOWY_AGENT used the operator's token.
	{
		printf 'q: retired - use "flowy queue". It decodes the type the node itself\n'
		printf '   writes rather than parsing this shape by hand, names the branch and\n'
		printf '   owner on each row, stamps the moment it read the lock, and refuses\n'
		printf '   to speak as the operator by default - which this never checked.\n\n'
		printf '   FLOWY_AGENT=%s flowy queue --url %s\n' "$NAME" "$ADDR"
	} >&2
	exit 2
	;;
findings)
	# The three axes and nothing else. The bodies are the bulk of this door and
	# almost nobody wants them.
	get "/api/artifacts?type=finding&limit=200${2:+&tag=$2}" | jq -r '
			[.artifacts[]?] as $f
			| "n=\($f|length)",
			  ($f | group_by(.project)[] | "  project \(.[0].project): \(length)"),
			  ($f | group_by(.fields.upstream_state // "unset")[] | "  upstream \(.[0].fields.upstream_state // "unset"): \(length)"),
			  ($f | group_by(.fields.evidence_state // "unset")[] | "  evidence \(.[0].fields.evidence_state // "unset"): \(length)"),
			  "  with repro trees: \($f | map(select(.fields.repro_files)) | length)"'
	;;
row)
	[[ -n ${2:-} ]] || {
		echo "q: row needs an id" >&2
		exit 2
	}
	get "/api/artifact/$2" | jq -r 'if .error then "\(.error) \((.withdrawn.at // "")[0:19])"
			else "\((.artifact // .).status // "(none)") \(((.artifact // .).fields.assignee) // "-") \((.artifact // .).title)" end'
	;;
master)
	# The two answers side by side, because they disagreeing is a defect that
	# has cost this fleet a thirteen-commit gate. git's is the fact; the
	# queue's is what everybody else is deciding against.
	printf 'queue  %s\n' "$(get "/api/merge-queue" | jq -r '.target_tip[0:12]')"
	printf 'git    %s\n' "$(git -C "$REPO" rev-parse --short master 2>/dev/null || echo '?')"
	;;
*)
	sed -n '/^# usage:/,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'
	exit 2
	;;
esac
