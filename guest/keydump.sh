#!/usr/bin/env bash
# Print the exact bytes the guest receives for each keypress.
#
# When a key "does not work" in a full-screen application, the question is
# always whether the bytes arrive at all and what they are. Enter is CR (0d)
# on a plain terminal, and ESC [ 1 3 u on one that negotiated the kitty
# keyboard protocol - an application expecting the first will ignore the
# second, which looks exactly like a dead key.
set -u

echo
echo "  Press keys to see what the guest actually receives."
echo "  Try Enter, then an arrow, then a letter. Press q three times to stop."
echo
echo "  TERM=${TERM:-unset}  size=$(stty size 2>/dev/null)"
echo

echo "  before: $(stty -a 2>/dev/null | tr ' ' '\n' | grep -E '^-?(icrnl|inlcr|igncr|icanon)$' | tr '\n' ' ')"
stty raw -echo 2>/dev/null
echo "  after:  $(stty -a 2>/dev/null | tr ' ' '\n' | grep -E '^-?(icrnl|inlcr|igncr|icanon)$' | tr '\n' ' ')"
echo
quits=0
while IFS= read -r -n1 -d '' c; do
	printf '%s' "$c" | od -An -tx1 -c | head -2 | tr -s ' ' | tr '\n' ' '
	printf '\r\n'
	if [[ $c == q ]]; then
		quits=$((quits + 1))
		((quits >= 3)) && break
	else
		quits=0
	fi
done
stty sane 2>/dev/null
echo
echo "  done"
