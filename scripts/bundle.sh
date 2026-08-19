#!/usr/bin/env bash
# Fetch the bundle the node is actually SERVING, and refuse the fallback.
#
#   scripts/bundle.sh                  print the bundle's name, size and sha
#   scripts/bundle.sh <string> ...     say whether each string is in it
#
# WHY THIS EXISTS, and it is the only reason. Asking whether a console change is
# live is two steps - ask /api/node for the bundle name, then GET it - and the
# second step has a wrong answer that looks exactly like a right one. A single
# page app serves index.html for every path it does not recognise, WITH A 200,
# so a stale or mistyped bundle name fetches 459 bytes of html that contains
# none of the strings you are looking for. Every grep then returns 0 and reads
# as "the change is not deployed".
#
# I published four such zeroes on 2026-08-18 and reported them as a failed
# deploy. The deploy was fine. The measurement was html.
#
# So the fetch asserts what it got before anybody greps it: a 200 is not the
# fact here, and neither is a non-empty body.
set -euo pipefail

ADDR=${FLOWY_ADDR:-http://192.168.1.55:8787}
NAME=${FLOWY_AGENT:-${BOARD_NAG_NAME:-}}
if [ -z "$NAME" ]; then
	printf 'bundle: set FLOWY_AGENT - reading the node as the operator is not a default\n' >&2
	exit 2
fi
TOKEN_FILE=${FLOWY_TOKEN_FILE:-$HOME/.config/flowy/agents/$NAME}
[ -r "$TOKEN_FILE" ] || {
	printf 'bundle: no token at %s\n' "$TOKEN_FILE" >&2
	exit 2
}
TOKEN=$(cat "$TOKEN_FILE")

# WHICH BUNDLE, ASKED OF THE NODE. Not guessed from web/dist on this box: the
# question is what the node serves, and a local build is a different artefact
# that happens to have a similar name.
#
# FLOWY_BUNDLE_NAME overrides it, and exists so that the refusal below can be
# PROVEN rather than asserted: pointing this at a name the node does not have is
# the only way to make it answer with the fallback on purpose. A check that has
# never been seen to fail is a check nobody should trust.
name=${FLOWY_BUNDLE_NAME:-$(curl -sS -m 8 -H "Authorization: Bearer $TOKEN" "$ADDR/api/node" 2>/dev/null |
	sed -n 's/.*"bundle":"\([^"]*\)".*/\1/p')}
[ -n "$name" ] || {
	printf 'bundle: %s/api/node did not name a bundle - is it up, and is the token right?\n' "$ADDR" >&2
	exit 1
}

body=$(mktemp) || exit 1
trap 'rm -f "$body"' EXIT
code=$(curl -sS -m 20 -o "$body" -w '%{http_code}' "$ADDR/assets/$name" 2>/dev/null || echo 000)

# THE THREE THINGS THAT ARE NOT THE BUNDLE, each with its own sentence, because
# "could not check" and "checked and it is not there" are different answers and
# only one of them is about the code.
if [ "$code" != 200 ]; then
	printf 'bundle: %s/assets/%s answered %s - nothing was measured\n' "$ADDR" "$name" "$code" >&2
	exit 1
fi
first=$(head -c 400 "$body" | tr -d '\r\n' | tr '[:upper:]' '[:lower:]')
case "$first" in
*'<!doctype html'* | '<html'* | *'<head>'*)
	printf 'bundle: %s/assets/%s answered 200 with HTML, which is the single-page\n' "$ADDR" "$name" >&2
	printf '        fallback and not the bundle. %s bytes. NOTHING WAS MEASURED - a\n' "$(wc -c <"$body")" >&2
	printf '        grep over this returns 0 for every string and reads as "not deployed".\n' >&2
	exit 1
	;;
esac
bytes=$(wc -c <"$body")
if [ "$bytes" -lt 10000 ]; then
	printf 'bundle: %s is only %s bytes - a console bundle is hundreds of kB, so\n' "$name" "$bytes" >&2
	printf '        this is something else answering. Nothing was measured.\n' >&2
	exit 1
fi

printf '%s  %s bytes  sha256:%s\n' "$name" "$bytes" "$(sha256sum <"$body" | cut -c1-12)"
[ $# -gt 0 ] || exit 0

# AND THEN THE QUESTION SOMEBODY ACTUALLY CAME WITH. grep -c rather than -q so
# the count is visible: "1" and "0" are different from "found", and a string
# that appears once when you expected it minified away is worth seeing.
status=0
for want in "$@"; do
	n=$(grep -c -F -- "$want" "$body" 2>/dev/null || true)
	[ -n "$n" ] || n=0
	if [ "$n" = 0 ]; then
		printf '  NO   %s\n' "$want"
		status=1
	else
		printf '  yes  %s (%s line(s))\n' "$want" "$n"
	fi
done
exit "$status"
