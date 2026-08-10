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
# dd, not bash's read: read has its own ideas about line endings, and which
# byte actually arrived is the entire question.
quits=0
while :; do
	byte=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
	[[ -z $byte ]] && break
	printf '  %s' "$byte"
	case "$byte" in
	0d) printf '   CR  - Enter, exactly as a raw terminal sends it' ;;
	0a) printf '   LF  - something rewrote Enter on the way in' ;;
	1b) printf '   ESC - start of an escape sequence' ;;
	esac
	printf '\r\n'
	if [[ $byte == 71 ]]; then
		quits=$((quits + 1))
		((quits >= 3)) && break
	else
		quits=0
	fi
done
stty sane 2>/dev/null
echo
echo "  done"
