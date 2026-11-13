#!/usr/bin/env bash
# WHERE A BOOT WENT, from the logs a run already leaves.
#
# Boots on this host took 3-6 minutes at load ~380, and "it is slow" is not a
# measurement. Everything needed is on disk: the run id is the wall clock the
# run started, the guest writes its console to runs/<id>/console.log, and the
# guest's own log lines now carry the kernel's uptime - so the gap between two
# them is the time that phase took.
#
#   scripts/boot-timings.sh [RUNS_DIR...]      (default: runs/ runs-archive/)
#
# Per run: prep (wall clock before the VMM existed: packing, drives, config),
# guest (the console's span), and how long the kernel took to hand over to
# userspace. Then the five biggest gaps between stamped lines - that is where
# the time actually went - and a median across every run it read.
#
# Runs made before the stamps existed still report prep, guest and the kernel
# figure; they say "no stamps" rather than inventing a breakdown.
set -uo pipefail

usage() {
	cat <<'EOF'
usage: boot-timings.sh [RUNS_DIR...]

Reads runs/<id>/console.log (and runs-archive/*) and prints, per run, where the
boot time went, then the median across runs. Default directories: runs and
runs-archive where firecode writes them - $ROOT/runs, or FIRECODE_RUNS.
EOF
}

case "${1:-}" in
-h | --help)
	usage
	exit 0
	;;
esac

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
dirs=("$@")
# The directory a run writes to, as bin/firecode resolves it: FIRECODE_RUNS moves
# the runs elsewhere, and this would then read an empty one and print nothing.
RUNS=$(realpath -m "${FIRECODE_RUNS:-$ROOT/runs}")
((${#dirs[@]})) || dirs=("$RUNS" "$RUNS-archive")

# firecode-YYYYmmdd-HHMMSS-<pid>: the wall clock the run started, to the second.
id_epoch() {
	local stamp=${1#firecode-}
	stamp=${stamp%-*}
	[[ $stamp =~ ^[0-9]{8}-[0-9]{6}$ ]] || return 1
	if date -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" +%s 2>/dev/null; then
		return 0
	fi
	# BSD date (a Mac): the same fields, spelled differently.
	date -j -f '%Y%m%d-%H%M%S' "$stamp" +%s 2>/dev/null
}

mtime() {
	stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || date +%s
}

# The kernel's own stamps, which start at zero: the last one is how long the
# kernel took to hand over to userspace, whatever the load did to it after.
kernel_span() {
	awk '
		/^\[[[:space:]]*[0-9]+\.[0-9]+\]/ {
			t = $0; sub(/^\[[[:space:]]*/, "", t); sub(/\].*/, "", t)
			last = t; if (first == "") first = t
		}
		END { if (first != "") printf "%s %s\n", first, last }
	' "$1"
}

# Our own stamped lines: "[+12.34s] [tag] message". Prints "<seconds>\t<line>".
stamped() {
	awk '
		/^\[\+[0-9.]+s\]/ {
			s = $1; gsub(/^\[\+|s\]$/, "", s)
			print s "\t" $0
		}
	' "$1"
}

# The biggest gaps between consecutive stamped lines, biggest first, each
# carrying the line that ended the gap - the message says which phase it was.
gaps() {
	awk -F'\t' '
		{ s[NR] = $1; g[NR] = $2 }
		END {
			for (i = 2; i <= NR; i++) printf "%.1f\t%s\n", (s[i] - s[i - 1]), g[i]
		}
	' | sort -rn | head -5
}

printf '%-33s %8s %8s %9s\n' "run" "total" "prep" "kernel"
printf '%-33s %8s %8s %9s\n' "---" "-----" "----" "------"
totals=()
preps=()
for d in "${dirs[@]}"/*/; do
	[[ -f $d/console.log ]] || continue
	id=$(basename "${d%/}")
	start=$(id_epoch "$id") || continue
	total=0
	if [[ -n $start ]]; then total=$(($(mtime "$d/console.log") - start)); fi
	prep="-"
	if [[ -f $d/vsock ]]; then
		prep=$(($(mtime "$d/vsock") - start))
	elif [[ -f $d/jail ]]; then
		prep=$(($(mtime "$d/jail") - start))
	fi
	span=$(kernel_span "$d/console.log")
	kend=${span#* }
	[[ -n $kend ]] || kend="-"
	printf '%-33s %7ss %7ss %8ss\n' "$id" "$total" "$prep" "$kend"
	((${#totals[@]} < 2000)) && totals+=("$total")
	[[ $prep != "-" ]] && preps+=("$prep")

	out=$(stamped "$d/console.log")
	if [[ -z $out ]]; then
		echo "    (no stamps in this run's console - rebuilt before the guest stamped its lines)"
		continue
	fi
	first=${out%%$'\n'*}
	last=$(printf '%s\n' "$out" | tail -1)
	printf '    guest said: first %ss, last %ss\n' "${first%%$'\t'*}" "${last%%$'\t'*}"
	printf '%s\n' "$out" | gaps | while IFS=$'\t' read -r took line; do
		printf '    %6ss in  %s\n' "$took" "$line"
	done
done

median() {
	if (($# == 0)); then
		echo "-"
		return
	fi
	printf '%s\n' "$@" | sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }'
}

echo
printf 'median total %ss, median prep %ss, over %s run(s)\n' \
	"$(median ${totals+"${totals[@]}"})" "$(median ${preps+"${preps[@]}"})" "${#totals[@]}"
echo "prep is everything before the VMM existed: packing the project, building the drives, the config drive."
echo "A guest whose prep is most of the time is not slow to boot - it is slow to start."
