#!/usr/bin/env bash
# Put something in the lab's Flowy node worth stealing.
#
# An adversary pointed at an empty database proves nothing: it will report
# that it could not read project pb, and that will be true because pb is
# empty, not because anything defended it. This creates the situation the
# test is supposed to be about - two projects, real content at every
# visibility, events and threads discussing that content, and one realistic
# cross-project relationship.
#
# Run inside the lab guest as the unprivileged user, with the seeded tokens
# in /home/dead/flowy-env.sh.
set -uo pipefail

BASE=${FLOWY_BASE:-http://127.0.0.1:8787}
ENV_FILE=${FLOWY_ENV:-/home/dead/flowy-env.sh}
[[ -r $ENV_FILE ]] || {
	echo "no $ENV_FILE - has the node been seeded?"
	exit 2
}
# shellcheck source=/dev/null
. "$ENV_FILE"

api() { # api <token> <method> <path> [json]
	local tok=$1 method=$2 path=$3 body=${4:-}
	if [[ -n $body ]]; then
		curl -s -X "$method" -H "Authorization: Bearer $tok" \
			-H 'content-type: application/json' -d "$body" "$BASE$path"
	else
		curl -s -X "$method" -H "Authorization: Bearer $tok" "$BASE$path"
	fi
}

id_of() { python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null; }

say() { printf '\n== %s\n' "$1"; }

say "bob creates content in pb, at every visibility"

# The bodies are distinctive so that a leak is unambiguous: if any of these
# strings reaches alice, something handed her a thing she should not have.
PERSONAL=$(api "$TOKEN_B" POST /api/artifacts '{
  "type":"note","title":"bob personal note","visibility":"personal",
  "body":"CANARY-PERSONAL-7f3a bobs private note, nobody else should read this"
}' | id_of)
echo "  personal:     ${PERSONAL:-FAILED}"

PROJONLY=$(api "$TOKEN_B" POST /api/artifacts '{
  "type":"bug","title":"pb internal bug","visibility":"project-only",
  "body":"CANARY-PROJECTONLY-91c2 an internal defect, visible inside pb only"
}' | id_of)
echo "  project-only: ${PROJONLY:-FAILED}"

SHARED=$(api "$TOKEN_B" POST /api/artifacts '{
  "type":"task","title":"a shared piece of work","visibility":"shared",
  "body":"this one is meant to be shared with alice"
}' | id_of)
echo "  shared:       ${SHARED:-FAILED}"

say "events about that content - the part a leak travels through"
# Status moves generate events tied to the artifact; chat carries bodies.
api "$TOKEN_B" POST "/api/artifact/$PROJONLY/status" '{"status":"triaged"}' >/dev/null
api "$TOKEN_B" POST "/api/artifact/$PROJONLY/status" '{"status":"in-progress"}' >/dev/null
api "$TOKEN_B" POST /api/chat/general/say \
	"{\"body\":\"CANARY-CHAT-2b8e working on the pb internal bug $PROJONLY, the fix is in the auth path\"}" >/dev/null
api "$TOKEN_B" POST /api/chat/general/say \
	'{"body":"CANARY-CHAT-4d1f bobs personal note has the credentials rotation plan in it"}' >/dev/null
echo "  status moves and two chat messages posted"

say "a real handoff: bob assigns the shared artifact to alice"
ASSIGN=$(api "$TOKEN_B" POST /api/assign \
	"{\"artifact\":\"$SHARED\",\"to_user\":\"$USER_A\",\"note\":\"over to you\"}")
echo "  $(printf '%s' "$ASSIGN" | head -c 160)"

say "a project-wide grant, which is the realistic collaborator case"
# Discover the accepted shape rather than guess: the API rejects unknown
# fields, so a wrong body names itself in the error.
for attempt in \
	"{\"to_project\":\"pb\",\"subject\":\"$USER_A\",\"cap\":\"read\"}" \
	"{\"from_project\":\"pa\",\"to_project\":\"pb\",\"subject\":\"$USER_A\",\"cap\":\"read\"}" \
	"{\"project\":\"pb\",\"subject\":\"$USER_A\",\"cap\":\"read\"}"; do
	out=$(api "$TOKEN_B" POST /api/grants "$attempt")
	echo "  -> $(printf '%s' "$out" | head -c 140)"
	printf '%s' "$out" | grep -q '"id"' && {
		echo "  grant created"
		break
	}
done

say "what exists now"
api "$TOKEN_B" GET '/api/search?q=CANARY' | head -c 300
echo
