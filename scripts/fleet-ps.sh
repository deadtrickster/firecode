#!/usr/bin/env bash
#
# List processes whose command line matches a pattern, WITHOUT matching the
# search itself.
#
# WHY THIS EXISTS. On 2026-09-05 three seats independently got wrong answers
# from `pgrep -af X | grep ...` in one evening: lubuntu3-oracle four times
# (once concluding a listener had died when it had not), claude-oracle once
# while checking whether a deletion script was running during an outage, and
# claude-host twice on earlier days. The fabric already carried seven notes
# about it. Documentation was not the gap - having to remember was.
#
# THE DEFECT. pgrep matches against other processes' command lines, and the
# pipeline doing the search has the pattern on ITS command line too. The usual
# bracket trick, [f]oo, only protects the pattern argument. It does nothing once
# the literal name appears anywhere else on the same line - piped to grep, to
# sed, or inside an echo - which is what happens in every real invocation.
#
# So the searcher matches itself, and the count is one too high. Worse in the
# other direction: a program spelled differently from how you searched (an
# absolute path, a wrapper, an interpreter prefix) is missed entirely, and a
# miss reads exactly like "not running".
#
# WHAT THIS DOES INSTEAD. Walks /proc directly and reads each pid's own
# cmdline, then excludes this script and the shell that invoked it - the only
# two processes guaranteed to carry the pattern for no reason. Nothing else is
# filtered, so a genuine match is never hidden by cleverness.
#
# The one accepted false negative: if the process you are hunting IS this
# script's parent, it is not reported. That is deliberate and vanishingly rare,
# and the alternative - reporting the caller every time - is the bug this
# replaces.
set -uo pipefail

usage() {
	cat <<'EOF'
usage: fleet-ps.sh [-q] PATTERN

  Lists "PID CMDLINE" for every process whose full command line matches
  PATTERN (an extended regular expression), excluding this search itself.

  -q  print only pids, one per line, for scripting

  Exits 0 if anything matched, 1 if nothing did - like pgrep, so it can gate
  a conditional. Any other status is this script failing, not an empty result.

examples:
  fleet-ps.sh 'flowy inbox'          # who holds a reader
  fleet-ps.sh -q 'run-tests\.sh'     # pids only
  fleet-ps.sh 'repair-missing-blobs' # is the deleter running
EOF
}

quiet=0
while getopts ":qh" opt; do
	case "$opt" in
	q) quiet=1 ;;
	h)
		usage
		exit 0
		;;
	\?)
		printf 'fleet-ps.sh: unknown option -%s\n\n' "$OPTARG" >&2
		usage >&2
		exit 2
		;;
	esac
done
shift $((OPTIND - 1))

if [ $# -ne 1 ] || [ -z "$1" ]; then
	usage >&2
	exit 2
fi
pattern=$1

# The two pids that carry the pattern without being what anybody is looking
# for: this script, and whatever invoked it.
self=$$
caller=${PPID:-0}

found=0
for entry in /proc/[0-9]*; do
	pid=${entry#/proc/}
	[ "$pid" = "$self" ] && continue
	[ "$pid" = "$caller" ] && continue

	# A process can exit between the glob and the read, and kernel threads have
	# an empty cmdline. Both are ordinary, not errors - skip them quietly.
	#
	# The braces matter. The SHELL opens the redirect, so it reports "No such
	# file" itself before tr ever runs, and a 2>/dev/null on tr does not cover
	# it. Grouping puts the redirect inside the suppressed scope. Without this
	# the tool prints a line of noise per process that exits mid-scan, which on
	# a busy box is most runs - measured, on the first smoke test.
	cmdline=$({ tr '\0' ' ' <"$entry/cmdline"; } 2>/dev/null) || continue
	[ -n "$cmdline" ] || continue

	# Trailing separator from the final NUL.
	cmdline=${cmdline%"${cmdline##*[! ]}"}

	if printf '%s' "$cmdline" | grep -qE -- "$pattern"; then
		found=1
		if [ "$quiet" -eq 1 ]; then
			printf '%s\n' "$pid"
		else
			printf '%s %s\n' "$pid" "$cmdline"
		fi
	fi
done

[ "$found" -eq 1 ]
