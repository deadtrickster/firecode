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
	printf 'usage: pre-gate.sh <branch-or-sha> [--target master] [--row ID]\n' >&2
	exit 2
}
target=master
row=""
shift || true
while [ $# -gt 0 ]; do
	case "$1" in
	--target)
		target=${2:-master}
		shift 2 || shift
		;;
	--row)
		row=${2:-}
		shift 2 || shift
		;;
	*) shift ;;
	esac
done

fail=0
say() { printf '  %-6s %s\n' "$1" "$2"; }
bad() {
	say NO "$1"
	fail=1
}

printf 'pre-gate %s -> %s\n' "$branch" "$target"

# THE QUEUE'S HALF, ASKED OF THE QUEUE.
#
# 01M0B8JFXS: this file used to answer two queue questions itself - is the
# target where the node thinks it is, and is the lock mine - by pulling
# /api/merge-queue and parsing it in python. drain.sh had its own copy, and so
# did a curl and a python shim, and twice two of us disagreed about whether a
# branch was landable. Both disagreements were readings of the same rows through
# different code.
#
# GET /api/merge/{id}/admissible answers both, computed where the rows are, and
# it answers a third this could never ask honestly: would a declaration FROM ME
# be taken right now - which the node knows because it knows which principal is
# asking, and this file could only guess by comparing names.
#
# IT NEEDS THE ROW ID, which is why this is behind --row rather than the default.
# A caller with only a branch name keeps the old questions below; the drainer
# knows the id and passes it. A door answering about "the row for this branch"
# would be this file guessing again, one level down.
ask_the_door() {
	local answer
	answer=$(curl -sS -m 8 -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
		"$NODE/api/merge/$row/admissible" 2>/dev/null) || return 1
	[ -n "$answer" ] || return 1
	local why declarable gating mine
	declarable=$(printf '%s' "$answer" | jq -r '.declarable // false' 2>/dev/null) || return 1
	why=$(printf '%s' "$answer" | jq -r '.why // ""' 2>/dev/null)
	[ -n "$why" ] || return 1
	gating=$(printf '%s' "$answer" | jq -r '.item.gating // false' 2>/dev/null)
	mine=$(printf '%s' "$answer" | jq -r '.lock_is_mine // false' 2>/dev/null)

	if [ "$declarable" != true ]; then
		bad "$why"
	elif [ "$gating" = true ] && [ "$mine" != true ]; then
		# DECLARABLE AND ALREADY BEING MEASURED, which is the residue case this
		# question exists for: a gating flag with no live lock behind it. The
		# lock would be taken, and a run started on it duplicates one that may
		# still be reporting. Two of us disagreed about exactly this row shape.
		bad "$why - and the lock is not yours, so this would be a second run on the same tree"
	elif [ "$gating" = true ]; then
		# Your own declaration, which is what the drainer's own chain looks like
		# between declare and gate. Not a refusal; saying whose run it is stops
		# it reading as one.
		say ok "your own run is declared on this row - $why"
	else
		say ok "the node would take a declaration from you: $why"
	fi
	# The tip the node compared against, said out loud for the same reason the
	# door carries it: "not admissible" against a deployed tip a dozen landings
	# old is a refusal about the node rather than about the branch.
	say ok "judged against $(printf '%s' "$answer" | jq -r '.target_tip // "?"') (from $(printf '%s' "$answer" | jq -r '.tip_from // "?"'))"
	return 0
}

# ASKED ONCE, and the answer decides whether the two questions below run at all.
# A door that answered and a door this file then second-guesses would be five
# answers rather than four.
asked=no
if [ -n "$row" ] && [ -r "$TOKEN_FILE" ]; then
	if ask_the_door; then
		asked=yes
	else
		say '--' "the node could not answer about $row - falling back to the old questions"
	fi
fi

if [ "$asked" = no ]; then
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
fi

# 3. CAN THIS MACHINE RUN THIS PROJECT'S GATE - ASKED OF THE PROJECT.
#
# This used to ask about initdb, pg_ctl and llvmjit, and about run-tests.sh's
# mode bit. Every one of those is flowy's requirement rather than a universal
# definition of a machine that can run tests, and a second project inherited
# them: a repository that has never needed Postgres was refused a run over a
# missing initdb, and one whose suite is called something else was told its
# suite was not executable. 01M0DZPFQD.
#
# So the project answers it, in .flowy-pregate beside its checkout. The contract
# is one finding per line - `ok <what is true>`, `bad <what is wrong and the
# fix>` - and a non-zero exit if any of them is bad. The lines are relayed
# through say/bad here so a refusal reads the same whichever half produced it.
#
# ASKED OF $PWD, which is the worktree that will be gated, not of $REPO. The
# checks are about the tree that is about to be compiled, and the mode bit
# question in particular is only honest about a fresh checkout.
#
# NO DEFAULT. A project that declares no .flowy-pregate is refused, and named -
# it is not asked flowy's questions instead. A fallback reached by a question
# the caller did not ask answers confidently and wrongly, which is the shape
# that broke landing fleet-wide tonight.
if [ ! -x "$PWD/.flowy-pregate" ]; then
	bad "$PWD has no executable .flowy-pregate - the drainer will not guess what this project needs.
    Declare one beside the checkout: ok/bad lines on stdout, exit 1 if any bad"
else
	# THE EXIT CODE IS THE ANSWER, not a count of bad lines here. A pregate that
	# dies before printing anything - a missing interpreter, a set -e trip - has
	# said nothing, and reading its silence as "no findings" would turn a broken
	# check into a green one.
	pregate_out=$("$PWD/.flowy-pregate" 2>&1) && pregate_rc=0 || pregate_rc=$?
	pregate_bad=0
	while IFS= read -r line; do
		case "$line" in
		"ok "*) say ok "${line#ok }" ;;
		"bad "*)
			bad "${line#bad }"
			pregate_bad=1
			;;
		*) [ -n "$line" ] && printf '       %s\n' "$line" ;;
		esac
	done <<<"$pregate_out"
	# WHETHER THIS BLOCK SAID SO, not whether anything has failed yet.
	#
	# The first cut asked `[ "$fail" = 0 ]`, which is the global set by every
	# check above. Measured with a pregate that exits 7 in silence: the queue
	# half had already failed in the fixture repo, so $fail was 1, the condition
	# was false, and the silent death went unreported - the exact case this line
	# exists for, hidden by an unrelated failure elsewhere in the file.
	if [ "$pregate_rc" != 0 ] && [ "$pregate_bad" = 0 ]; then
		bad ".flowy-pregate exited $pregate_rc without printing a bad line - it failed before it could say why"
	fi
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
