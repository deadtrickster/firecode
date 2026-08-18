#!/usr/bin/env bash
# Refuse to spend a gate run that is already doomed. Exit 0 to gate, 1 not to.
#
# WHY THIS EXISTS. A firecode gate is 200-350k tokens. On 2026-08-18 six runs
# across two agents measured something other than the diff:
#
#   master moved under a running gate, twice - the verdict was stale before it
#     was recorded, and the branch had to be rebased and re-gated
#   the host was missing libLLVM.so.19.1, so four metrics checks failed on a
#     tree that was fine, twice
#   a browser check that passes on the host and fails in the VM decided a red
#
# Every one of those was knowable in under a second before spending the run.
# This asks the three questions.
set -uo pipefail

REPO=${FLOWY_REPO:-$HOME/Projects/flowy}
NODE=${FLOWY_ADDR:-http://192.168.1.55:8787}
# WHO THIS RUN IS, and it is not guessable.
#
# The default used to be a name - orchestrator - so any other seat that had not
# set FLOWY_AGENT was told the lock it had just taken belonged to somebody else.
# That is not a near miss: the answer was a collision that was not happening,
# and the correct response to it - do not gate - is the expensive one. Measured
# on 2026-08-18 by claude-host, who declared, held the lock, and was told
# "master is held by claude-host - their run or yours is about to be wasted".
#
# A missing identity is now its own answer, once, rather than a wrong one at
# every question that needs a name.
AGENT=${FLOWY_AGENT:-${BOARD_NAG_NAME:-}}
if [ -z "$AGENT" ]; then
	printf 'pre-gate: set FLOWY_AGENT - without a name this cannot tell your own lock\n' >&2
	printf '          from another seat holding it, and it would answer that they do.\n' >&2
	exit 2
fi
TOKEN_FILE=${FLOWY_TOKEN_FILE:-$HOME/.config/flowy/agents/$AGENT}

branch=${1:-}
[ -n "$branch" ] || {
	printf 'usage: pre-gate.sh <branch-or-sha> [--target master]\n' >&2
	exit 2
}
target=master
[ "${2:-}" = "--target" ] && target=${3:-master}

fail=0
say() { printf '  %-6s %s\n' "$1" "$2"; }
bad() {
	say NO "$1"
	fail=1
}

printf 'pre-gate %s -> %s\n' "$branch" "$target"

# 1. IS THE BASE STILL THE BASE. A gate measures branch-on-target, and if the
# target moves the answer describes a tree nobody will land. This is the one
# that cost two runs.
tip=$(git -C "$REPO" rev-parse --short "$target" 2>/dev/null) || tip=""
node_tip=""
if [ -r "$TOKEN_FILE" ]; then
	node_tip=$(curl -sS -m 5 -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
		"$NODE/api/merge-queue" 2>/dev/null |
		python3 -c 'import json,sys; print(json.load(sys.stdin).get("target_tip","")[:7])' 2>/dev/null)
fi
if [ -n "$tip" ] && [ -n "$node_tip" ] && [ "$tip" != "$node_tip" ]; then
	bad "$target is $tip here and $node_tip on the node - fetch before gating"
else
	say ok "$target is $tip, and the node agrees"
fi

if ! git -C "$REPO" merge-base --is-ancestor "$target" "$branch" 2>/dev/null; then
	bad "$branch does not contain $target - rebase, or the gate measures a tree that cannot land"
else
	say ok "$branch contains $target"
fi

# 2. IS ANYBODY ELSE HOLDING THE TARGET. Gating into somebody's lock means one
# of the two runs is wasted, and the loser is whoever finishes second.
if [ -r "$TOKEN_FILE" ]; then
	holder=$(curl -sS -m 5 -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
		"$NODE/api/merge-queue" 2>/dev/null |
		python3 -c '
import json, sys
lock = json.load(sys.stdin).get("lock") or {}
print(lock.get("holder_name", "") if lock.get("held") else "")
' 2>/dev/null)
	if [ -n "$holder" ] && [ "$holder" != "$AGENT" ]; then
		bad "$target is held by $holder - their run or yours is about to be wasted"
	elif [ -z "$holder" ]; then
		# FREE IS NOT GOOD ENOUGH, and this line used to pass on it.
		#
		# A verdict is admissible only while its base holds - MergeAdmissible
		# compares gated_base against the target tip - so anybody landing during
		# a run invalidates that run by definition, and they are doing nothing
		# wrong. The lock is what stops the base moving, and a gate that has not
		# taken it is a gate anybody may waste.
		#
		# MEASURED, and this is why it is a refusal rather than a note.
		# flowy-claude declared before gating for six consecutive landings: four
		# wasted runs before they started, zero after, six landings from six
		# runs. Over the same afternoon I gated first and declared after, and
		# re-ran three unchanged diffs because master moved underneath them.
		#
		# The declare door already takes the lock. So "declare, rebase, gate,
		# record, land" needs no new mechanism - only this check refusing the
		# order that wastes runs.
		bad "nobody holds $target, INCLUDING YOU - declare your merge row first
    POST $NODE/api/merge/{row}/gate  {\"run\": \"...\"}
    then rebase, gate, record the verdict, land. A gate that has not taken the
    lock is one anybody can land under, and the loser is whoever finishes second"
	else
		say ok "the lock is yours, so the base cannot move under this run"
	fi
fi

# 3. CAN THIS HOST EVEN RUN THE SUITE, AND WILL THE SUITE FIND IT.
#
# Those are two questions and this used to ask only the first. It ran initdb by
# its absolute path, with LD_LIBRARY_PATH set here, and reported ok. The gate
# then died in two seconds with "no initdb/pg_ctl found; install postgresql",
# because run-tests.sh searches PATH - and PATH belongs to whoever invoked it,
# not to this script. Measured on 2026-08-18: pre-gate green, gate dead, nothing
# wrong with the branch.
#
# An instrument that arranges the conditions it is testing reports on itself.
# So the first check is `command -v`, in the caller's own environment, and the
# absolute-path check stays underneath it to tell "not installed" from
# "installed and not on your PATH" - which have different fixes.
if command -v initdb >/dev/null 2>&1 && command -v pg_ctl >/dev/null 2>&1; then
	say ok "initdb and pg_ctl are on PATH, which is where the suite looks"
elif [ -x "$HOME/.local/pg17-bin/initdb" ]; then
	bad "postgres is installed and NOT on your PATH, so the suite exits in two seconds:
    PATH=\$HOME/.local/pg17-bin:\$PATH LD_LIBRARY_PATH=\$HOME/.local/pg17-libs ./run-tests.sh"
else
	say '--' "no pg17-bin here, host-local runs are not available"
fi
if [ -x "$HOME/.local/pg17-bin/initdb" ]; then
	if LD_LIBRARY_PATH="$HOME/.local/pg17-libs" "$HOME/.local/pg17-bin/initdb" --version >/dev/null 2>&1; then
		say ok "and it starts with pg17-libs on the library path"
	else
		bad "initdb will not start - check LD_LIBRARY_PATH=$HOME/.local/pg17-libs"
	fi
fi
# 4. CAN THE SUITE BE RUN AT ALL. On 2026-08-18 a commit dropped run-tests.sh
# from 100755 to 100644 and every gate that day passed, because every existing
# worktree keeps the mode it was checked out with and `bash file.sh` ignores the
# bit entirely. Only a FRESH worktree exec'ing ./run-tests.sh sees it, and what
# it sees is "Permission denied", which reads as a broken sandbox rather than as
# a file mode.
#
# The suite cannot catch this - it is the thing that would not start. So it is
# checked here, where a fresh tree is being prepared anyway.
suite="$REPO/run-tests.sh"
if [ -f "$suite" ] && [ ! -x "$suite" ]; then
	bad "run-tests.sh is not executable ($(stat -c %a "$suite")) - a fresh worktree cannot ./run it"
else
	say ok "the suite is executable"
fi

# THE GATE COMPILES THE WORKING TREE, NOT THE COMMIT.
#
# run-tests.sh does `go build -o "$ROOT/flowy" .` and reads "$ROOT/schema.sql"
# from the directory it runs in, so an uncommitted edit is measured and a
# verdict recorded from it names a commit that does not contain what was tested.
# Everything else here guards against the branch MOVING; nothing guarded against
# it never having been what was measured in the first place.
#
# Asked of the worktree the gate will run in - $PWD - and not of $REPO. Gates
# run in worktrees now, and the main checkout's cleanliness says nothing about
# the tree that is about to be compiled.
#
# .gitignore already covers what a run leaves behind - the flowy binary and
# web/dist - so a worktree that has just gated is clean by this test, which is
# what makes it usable at VERIFY time too.
dirty=$(git -C "$PWD" status --porcelain 2>/dev/null)
if [ -n "$dirty" ]; then
	bad "the tree that would be gated has uncommitted changes - the verdict would name a commit that does not contain what ran:
$(printf '%s\n' "$dirty" | head -5)"
else
	say ok "the working tree is clean, so the commit is what gets compiled"
fi

jit=$(find /usr/lib/postgresql -name llvmjit.so -type f 2>/dev/null | head -1)
if [ -n "$jit" ]; then
	if ldd "$jit" 2>/dev/null | grep -q 'not found'; then
		bad "$(basename "$jit") has an unresolved library - expensive queries will fail, not the diff"
	else
		say ok "the postgres jit module resolves its libraries"
	fi
fi

# 4. REMEMBER WHAT WE ARE ABOUT TO MEASURE. Every guard here assumes the threat
# is somebody else moving the target; on 2026-08-18 the tree changed under a
# running gate because the person who spawned it kept editing the branch. Nobody
# noticed until the verdict was about to be recorded against a tip that no longer
# existed.
#
# So the tip is written down at gate time, and `pre-gate.sh --verify <branch>`
# says whether it still holds. Same check as gated_tip, pointed at the branch
# instead of the target.
stamp_dir=${FLOWY_GATE_STAMPS:-${TMPDIR:-/tmp}/flowy-gate-stamps}
stamp_file="$stamp_dir/$(printf '%s' "$branch" | tr '/' '_')"

if [ "${VERIFY:-no}" = yes ]; then
	want=$(cat "$stamp_file" 2>/dev/null || echo "")
	have=$(git -C "$REPO" rev-parse --short "$branch" 2>/dev/null || echo "")
	if [ -z "$want" ]; then
		printf 'no stamp for %s - nothing recorded this gate, so nothing can say the tree held\n' "$branch" >&2
		exit 1
	fi
	if [ "$want" != "$have" ]; then
		printf 'THE BRANCH MOVED UNDER ITS OWN GATE: measured %s, now %s. That verdict describes a tree that is gone.\n' \
			"$want" "$have" >&2
		exit 1
	fi
	# AND THE TREE IS STILL THE COMMIT. An edit made during the run leaves the
	# sha untouched, so the check above passes while the thing that ran is not
	# the thing that would land.
	dirty=$(git -C "$PWD" status --porcelain 2>/dev/null)
	if [ -n "$dirty" ]; then
		printf 'THE TREE CHANGED UNDER ITS OWN GATE - %s is still %s, and the worktree is not:\n%s\n' \
			"$branch" "$have" "$(printf '%s\n' "$dirty" | head -5)" >&2
		exit 1
	fi
	printf '%s is still %s and the tree is clean - the verdict describes what ran\n' "$branch" "$have"
	exit 0
fi

if [ "$fail" -ne 0 ]; then
	printf '\nNOT worth a gate run yet. Fix the NOs above - each one is 200-350k tokens.\n' >&2
	exit 1
fi
mkdir -p "$stamp_dir" 2>/dev/null || true
git -C "$REPO" rev-parse --short "$branch" >"$stamp_file" 2>/dev/null || true
printf '\nworth gating, and %s is stamped - check with VERIFY=yes before recording a verdict.\n' \
	"$(cat "$stamp_file" 2>/dev/null)"
