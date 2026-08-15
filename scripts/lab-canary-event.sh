#!/usr/bin/env bash
# Plant the one canary that can only travel through the leak being tested.
#
# The earlier canaries are ambiguous and would have scored a false positive:
# a chat message in a shared room that names no artifact is something a
# project-wide grant is SUPPOSED to share, and an artifact body never travels
# the event path at all - if that leaked it would be a different and worse
# bug. The unambiguous case is an EVENT that NAMES an artifact whose own row
# is correctly refused. If that string reaches a collaborator, exactly one
# thing explains it.
set -uo pipefail

BASE=${FLOWY_BASE:-http://127.0.0.1:8787}
ENV_FILE=${FLOWY_ENV:-/home/dead/flowy-env.sh}
# shellcheck source=/dev/null
. "$ENV_FILE"

api() {
	local tok=$1 method=$2 path=$3 body=${4:-}
	if [[ -n $body ]]; then
		curl -s -X "$method" -H "Authorization: Bearer $tok" \
			-H 'content-type: application/json' -d "$body" "$BASE$path"
	else
		curl -s -X "$method" -H "Authorization: Bearer $tok" "$BASE$path"
	fi
}

# The project-only artifact bob owns - the one whose row alice must not read.
# Matched on the canary in the body rather than on a visibility string:
# the stored value is not necessarily the word passed at creation, and a
# filter that silently matches nothing looks exactly like "no such artifact".
#
# Searching for the whole hyphenated canary returns nothing while searching
# for CANARY returns the row: the text search tokenises, so the long string
# is not a term. Ask for the term that exists and filter here.
TARGET=$(api "$TOKEN_B" GET '/api/search?q=CANARY' |
	python3 -c 'import json,sys
d = json.load(sys.stdin)
for a in d.get("artifacts") or []:
    if "CANARY-PROJECTONLY" in (a.get("body") or ""):
        print(a["id"], file=sys.stderr) or None
        print(a["id"]); break' 2>/dev/null)

if [[ -z $TARGET ]]; then
	echo "could not find the project-only artifact - run dev.sh lab scenario first"
	exit 2
fi
echo "target artifact (project-only, bob's): $TARGET"

echo
echo "posting events that NAME it, each carrying a canary:"
# Several shapes, because the accepted body is not documented and a rejected
# attempt names its own missing field.
for body in \
	"{\"artifact\":\"$TARGET\",\"type\":\"comment\",\"body\":\"CANARY-EVENT-a91d the pb internal bug is caused by the token parser, do not share\"}" \
	"{\"artifact\":\"$TARGET\",\"body\":\"CANARY-EVENT-a91d the pb internal bug is caused by the token parser, do not share\"}" \
	"{\"artifact\":\"$TARGET\",\"room\":\"general\",\"body\":\"CANARY-EVENT-a91d the pb internal bug is caused by the token parser, do not share\"}"; do
	out=$(api "$TOKEN_B" POST /api/events "$body")
	echo "  -> $(printf '%s' "$out" | head -c 150)"
	printf '%s' "$out" | grep -q '"id"' && {
		echo "  planted"
		break
	}
done

echo
echo "sanity: bob can see it, and it names the artifact"
api "$TOKEN_B" GET "/api/events?limit=5" | head -c 400
echo
