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
AGENT=${FLOWY_AGENT:-orchestrator}
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
	else
		say ok "the lock is free or already yours"
	fi
fi

# 3. CAN THIS HOST EVEN RUN THE SUITE. Cheaper to ask than to discover in a VM,
# and a host-local run is free - see run-tests.sh, which needs both of these.
if [ -x "$HOME/.local/pg17-bin/initdb" ]; then
	if LD_LIBRARY_PATH="$HOME/.local/pg17-libs" "$HOME/.local/pg17-bin/initdb" --version >/dev/null 2>&1; then
		say ok "initdb runs with pg17-libs on the path"
	else
		bad "initdb will not start - check LD_LIBRARY_PATH=$HOME/.local/pg17-libs"
	fi
else
	say '--' "no pg17-bin here, host-local runs are not available"
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
	printf '%s is still %s - the verdict describes the tree that was measured\n' "$branch" "$have"
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
