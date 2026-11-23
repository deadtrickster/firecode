#!/usr/bin/env bash
# The check to run after ANY change to how firecode stores or moves a session.
#
# It boots ONE real VM with a session that outlives it, commits inside it, makes
# the bundle of what it committed, verifies that the bundle contains the commit,
# reads the session's manifest, and then releases the session - which only works
# if the manifest says the work is out. Then a second, ephemeral run of the same
# project, to see that a session nobody will resume releases its own state. Then
# the pool: a reusable session's VM has stopped by the time `exec` returns, so it
# goes back as disks, is taken by the next session of that project, and is put to
# bed by the sleep pass with its disks kept.
#
# Every one of those is a place where this repository has already lost work or
# claimed work it did not have; a host-side test cannot see any of them because
# they only exist with a guest in the way.
#
#   scripts/canary-roundtrip.sh            # boot, commit, extract, verify, release
#   scripts/canary-roundtrip.sh --pool     # and then the warm pool's whole story
#   scripts/canary-roundtrip.sh --keep     # leave the VM and the state for a look
#
# It uses its own state and run directories under a temp dir, so a failure
# cannot damage a real session. It boots a VM, so it is deliberately not part
# of `firecode test`.
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
FIRECODE="$ROOT/bin/firecode"

POOL=0
KEEP=0
for a in "$@"; do
	case "$a" in
	--pool) POOL=1 ;;
	--keep) KEEP=1 ;;
	-h | --help)
		sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "canary: unknown argument $a" >&2
		exit 2
		;;
	esac
done

WORK=$(realpath -m "$(mktemp -d "${TMPDIR:-/tmp}/firecode-canary.XXXXXX")")
PROJ="$WORK/canary-proj"
export FIRECODE_STATE="$WORK/state"
export FIRECODE_RUNS="$WORK/runs"
export FIRECODE_JAIL="$WORK/jail"
mkdir -p "$PROJ" "$FIRECODE_STATE" "$FIRECODE_RUNS"

# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() {
	if ((KEEP)); then
		echo
		echo "canary: kept for inspection"
		echo "  project: $PROJ"
		echo "  state:   $FIRECODE_STATE"
		echo "  runs:    $FIRECODE_RUNS"
		return
	fi
	(cd "$PROJ" && "$FIRECODE" down --project "$PROJ" --discard >/dev/null 2>&1) || true
	rm -rf "$WORK"
}
trap cleanup EXIT

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	printf '  \033[32mok\033[0m    %s\n' "$1"
}
no() {
	fail=$((fail + 1))
	printf '  \033[31mFAIL\033[0m  %s\n' "$1"
	[[ -n ${2:-} ]] && printf '        %s\n' "$2"
	return 0
}

# The session's name, as firecode makes it: the directory's own name and the
# first eight hex of its CANONICAL path, which is the path firecode recorded.
slug_of() {
	local dir
	dir=$(realpath -m -- "$1")
	printf '%s-%s\n' "$(basename "$dir" | tr -c 'A-Za-z0-9._-' '-')" \
		"$(printf '%s' "$dir" | sha256sum | cut -c1-8)"
}

# One field of a --json answer. Missing, unparseable, or a member that was never
# touched answers nothing, so a check has to name what it wanted: grepping for
# `"slept"` passed on `"slept":[]`, which is the shape of a pass that did
# nothing.
jget() {
	python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(2)
v = d.get(sys.argv[1])
if v is None:
    sys.exit(2)
print("true" if v is True else "false" if v is False else v)
' "$1" 2>/dev/null || true
}

# Does a --json answer's LIST field name this value?
jhas() {
	python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(2)
v = d.get(sys.argv[1])
sys.exit(0 if isinstance(v, list) and sys.argv[2] in v else 1)
' "$1" "$2" 2>/dev/null
}

# The guest's own lines arrive on the console, prefixed with the kernel's stamp
# and ending CRLF, so `grep '^[0-9a-f]{40}$'` matched nothing and a run that had
# committed looked like a run that said nothing. It says the answer in a line of
# its own instead, and the canary reads that line wherever the console put it.
guest_out() { tr -d '\r'; }

# The one JSON object in an answer. firecode says what it did to a person on
# stderr and the answer on stdout, and a caller that merges them - as a checker
# must, to have something to print when the answer is a refusal - has to pick
# the object out rather than hand python a log line.
json_only() { sed -n 's/^\({.*\)$/\1/p' | tail -1; }

slug=$(slug_of "$PROJ")

echo "firecode canary: boot, commit, extract, verify, release"
echo "  $WORK"

# A project with a history, so a commit inside the guest has a parent.
git -C "$PROJ" init -q
echo "# canary" >"$PROJ/README.md"
git -C "$PROJ" add -A
git -C "$PROJ" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
	commit -qm base

# A SESSION THAT OUTLIVES THIS RUN. Not --ephemeral: an ephemeral run releases
# its own state the moment its work is out - by design, and that is exactly what
# the second run below checks - so a manifest read afterwards would be reading a
# session firecode has already, correctly, forgotten.
# shellcheck disable=SC2016  # the GUEST's shell expands this, not this one
out=$(cd "$PROJ" && timeout 900 "$FIRECODE" exec --no-jail --no-net \
	--purpose test -- bash -c '
		echo "from the guest" >> README.md
		git add -A
		git -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
			commit -qm "a commit made inside the canary"
		echo "commit: $(git rev-parse HEAD)"' 2>&1 | guest_out)
rc=$?
if ((rc != 0)); then
	no "a VM booted and committed inside it" "exit $rc: $(printf '%s' "$out" | tail -3)"
else
	ok "a VM booted and committed inside it"
fi
tip=$(printf '%s\n' "$out" | sed -n 's/.*commit: *\([0-9a-f]\{40\}\).*/\1/p' | tail -1)
run=$(printf '%s\n' "$out" | sed -n 's/.*run \(firecode-[0-9-]*\).*/\1/p' | head -1)
if [[ -n $tip ]]; then
	ok "the guest reported the commit it made (${tip:0:8})"
else
	no "the guest reported the commit it made" "no 40-hex line in the output"
fi

result=$(printf '%s\n' "$out" | sed -n 's/^ *result: *//p' | head -1)
if [[ -n $result && -d $result ]]; then
	ok "the work came back to $result"
else
	no "the work came back" "no result directory in the output"
fi
if [[ -n $result && -n $tip ]] && git -C "$result" cat-file -e "${tip}^{commit}" 2>/dev/null; then
	ok "and the commit is in the delivered tree"
else
	no "and the commit is in the delivered tree" "cat-file ${tip:-?} in ${result:-no result}"
fi

bundle="$FIRECODE_RUNS/${run:-none}/work.bundle"
if [[ -f $bundle ]]; then
	ok "the run left a bundle of its refs ($(basename "$bundle"))"
	if git bundle verify "$bundle" >/dev/null 2>&1; then
		ok "the bundle verifies"
	else
		no "the bundle verifies" "git bundle verify said no"
	fi
	scratch=$(mktemp -d)
	git -C "$scratch" init -q
	if git -C "$scratch" fetch -q "$bundle" '+refs/*:refs/firecode/*' 2>/dev/null &&
		git -C "$scratch" cat-file -e "${tip}^{commit}" 2>/dev/null; then
		ok "and the bundle contains the commit the guest made"
	else
		no "and the bundle contains the commit the guest made" "it does not: ${tip:-?}"
	fi
	rm -rf "$scratch"
else
	no "the run left a bundle of its refs" "no $bundle"
fi

# THE MANIFEST, which is what every reaper reads.
manifest="$FIRECODE_STATE/$slug.json"
if [[ -f $manifest ]]; then
	ok "the session has a manifest"
else
	no "the session has a manifest" "no $manifest"
fi
got=$("$FIRECODE" state ls --json 2>/dev/null |
	python3 -c '
import json, sys
want = sys.argv[1]
for s in json.load(sys.stdin)["sessions"]:
    if s["name"] == want:
        print((s["extracted"] or {}).get("tip") or "-", s["work"], s["purpose"])
        break
' "$slug" 2>/dev/null || true)
case "$got" in
"$tip out test") ok "the manifest says its work is out, with the tip the guest reported" ;;
*) no "the manifest says its work is out, with the tip" "got [$got], wanted [$tip out test]" ;;
esac

# RELEASE ONLY WORKS IF THE MANIFEST SAYS THE WORK IS OUT, which is the whole
# point of running this after a storage change.
out=$("$FIRECODE" state release "$slug" --json 2>&1)
if [[ $(printf '%s' "$out" | json_only | jget released) == true ]]; then
	ok "state release accepted it and removed its files"
else
	no "state release accepted it" "$out"
fi
if [[ -e $FIRECODE_STATE/$slug.ext4 ]]; then
	no "and the session's files are gone" "$FIRECODE_STATE/$slug.ext4 survived"
else
	ok "and the session's files are gone"
fi

# AN EPHEMERAL SESSION RELEASES ITSELF. Nobody will resume it, so once its work
# is out there is nothing left to keep - and a build that keeps the manifest but
# drops the drives, or the other way round, is a session gc will sweep forever.
out=$(cd "$PROJ" && timeout 900 "$FIRECODE" exec --no-jail --no-net --ephemeral \
	--purpose test -- sh -c 'echo ephemeral >> README.md' 2>&1 | guest_out)
if printf '%s' "$out" | grep -q 'result:'; then
	ok "an ephemeral run finished and delivered its work"
else
	no "an ephemeral run finished" "$(printf '%s' "$out" | tail -3)"
fi
left=""
for f in "$FIRECODE_STATE/$slug".* "$FIRECODE_STATE/$slug"-*; do
	[[ -e $f ]] && left+="$(basename "$f") "
done
if [[ -z $left ]]; then
	ok "and it left no state behind, manifest and marker included"
else
	no "and it left no state behind" "left: ${left% }"
fi

# THE POOL, if asked. A reusable session given back by `exec` has already
# stopped - the run shut it down and copied its work out - so what goes back is
# its DISKS, and what it owes is the reset a live guest would have run.
if ((POOL)); then
	out=$(cd "$PROJ" && timeout 900 "$FIRECODE" exec --no-jail --no-net \
		--purpose reviewer --reuse -- sh -c 'echo pool >> README.md' 2>&1 | guest_out)
	if printf '%s' "$out" | grep -q 'result:'; then
		ok "a reusable run finished"
	else
		no "a reusable run finished" "$(printf '%s' "$out" | tail -3)"
	fi
	out=$("$FIRECODE" pool return "$slug" --json 2>&1)
	if [[ $(printf '%s' "$out" | json_only | jget returned) == true ]]; then
		ok "its VM went back to the pool ($(printf '%s' "$out" | json_only | jget state))"
	else
		no "its VM went back to the pool" "$out"
	fi
	if [[ -e $FIRECODE_STATE/$slug.ext4 ]]; then
		ok "with its disks kept, which is what the next one boots from"
	else
		no "with its disks kept" "$FIRECODE_STATE/$slug.ext4 is gone - nothing to be warm from"
	fi
	out=$("$FIRECODE" pool take --project "$PROJ" --json 2>&1)
	if [[ $(printf '%s' "$out" | json_only | jget taken) == true ]]; then
		ok "and the next session of that project takes it"
	else
		no "and the next session of that project takes it" "$out"
	fi
	out=$("$FIRECODE" pool sleep --idle 0 --json 2>&1)
	if printf '%s' "$out" | json_only | jhas slept "$slug"; then
		ok "the sleep pass puts it to bed"
	else
		no "the sleep pass puts it to bed" "$out"
	fi
	out=$("$FIRECODE" pool status --json 2>&1)
	state=$(printf '%s' "$out" | json_only | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(2)
for r in d.get("pool") or []:
    if r.get("name") == sys.argv[1]:
        print(r.get("state") or "")
        break
' "$slug" 2>/dev/null || true)
	if [[ $state == sleeping && -e $FIRECODE_STATE/$slug.ext4 ]]; then
		ok "and it is asleep, with its disks kept"
	else
		no "and it is asleep, with its disks kept" \
			"state [${state:-absent}], ext4 $([[ -e $FIRECODE_STATE/$slug.ext4 ]] && echo kept || echo gone): $out"
	fi
fi

echo
if ((fail)); then
	printf '\033[31m%d failed\033[0m, %d passed\n' "$fail" "$pass"
	exit 1
fi
printf '\033[32m%d passed\033[0m\n' "$pass"
exit 0
