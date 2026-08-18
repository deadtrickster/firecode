#!/usr/bin/env bash
# Say something in the flowy room, and REFUSE to say too much.
#
# Caveman has been asked for seven times and drifts back within the hour every
# time. It is not a knowledge problem - the rule is in the preamble, in the node
# instructions, in a flowy memory and in my own memory file, and it still slips.
# It slips because remembering is a step somebody has to take before every
# message, and the cost of forgetting lands on the reader rather than the
# writer.
#
# So the check is mechanical. A message over the limit is REFUSED, with its own
# line count, and the writer either cuts it or moves the reasoning to where
# reasoning belongs - the row or the commit message. `--long` exists for the
# genuine exception and has to be typed, which is the point: it makes the
# decision visible instead of automatic.
#
# usage: say.sh [--room R] [--to NAME] [--long] "text"       or text on stdin
#        SAY_MAX=n   override the limit (default 6 lines, 600 chars)
set -euo pipefail

MAX_LINES=${SAY_MAX:-6}
MAX_CHARS=${SAY_MAX_CHARS:-600}
NAME=${FLOWY_AGENT:-${BOARD_NAG_NAME:-claude-host}}
ADDR=${FLOWY_ADDR:-http://192.168.1.55:8787}
AGENTS=${FLOWY_AGENTS:-$HOME/.config/flowy/agents}
FLOWY=${FLOWY_BIN:-$HOME/Projects/flowy-dogfood/flowy}

long=0
declare -a pass=()
text=""
while (($#)); do
	case $1 in
	--long)
		long=1
		shift
		;;
	--room | --to | --thread)
		pass+=("$1" "$2")
		shift 2
		;;
	*)
		text=$1
		shift
		;;
	esac
done

# Stdin is the other half, so a heredoc works the way it does with flowy say.
[[ -n $text ]] || text=$(cat)
[[ -n ${text//[[:space:]]/} ]] || {
	echo "say: nothing to say" >&2
	exit 2
}

lines=$(printf '%s\n' "$text" | grep -c '' || true)
chars=${#text}

if ((!long)) && { ((lines > MAX_LINES)) || ((chars > MAX_CHARS)); }; then
	cat >&2 <<EOF
say: REFUSED - $lines lines, $chars chars (limit $MAX_LINES lines, $MAX_CHARS chars)

  A room message is a MEASUREMENT AND A DECISION. Three lines is normal.
  Ten is a report and belongs in a filed row, where somebody can choose to
  read it - not in a room everybody pays for.

  Cut it, or move the reasoning to the row or the commit message.
  If this genuinely is the exception, say so on purpose: --long
EOF
	exit 3
fi

[[ -r $AGENTS/$NAME ]] || {
	printf 'say: no token for %s (looked for %s)\n' "$NAME" "$AGENTS/$NAME" >&2
	exit 2
}

FLOWY_TOKEN=$(cat "$AGENTS/$NAME") exec "$FLOWY" say --url "$ADDR" \
	${pass+"${pass[@]}"} "$text"
