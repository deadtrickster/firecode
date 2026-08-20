#!/usr/bin/env bash
# Which worktrees hold work that has already landed - and NOTHING ELSE.
#
# 01M0E7A4XK: `git worktree list` on ~/Projects/flowy answers 126 entries, most
# of them landed work from days ago, kept alive because nothing removes a
# worktree when its branch lands. Each is a full checkout - source, vendor/, and
# for the console ones node_modules - and the cost that bites first is inodes
# rather than bytes.
#
# THIS DOES NOT REMOVE ANYTHING, on purpose, and it never will. Half of those
# trees belong to seats that are still running and several hold unlanded work. A
# script that deletes a directory to be helpful is how this fleet lost another
# seat's database. What it does is turn 126 unknowns into three named lists, and
# print the command for the ones that are safe, for a person to run.
#
# The row asked for the measurement that decides whether the list is the whole
# fix: how many hold a branch that is an ancestor of the target. Measured
# 2026-08-20 - 66 of 126, and none of those 66 had a single uncommitted or
# untracked file.
#
#   scripts/worktrees.sh [--repo DIR] [--target master]
#
# Exit 0 always: this is a report, and a report that exits non-zero because it
# found something gets wrapped in `|| true` by the second caller and then means
# nothing.
set -euo pipefail

REPO=${FLOWY_REPO:-$HOME/Projects/flowy}
TARGET=master
while [ $# -gt 0 ]; do
	case "$1" in
	--repo)
		REPO=${2:?--repo needs a directory}
		shift 2
		;;
	--target)
		TARGET=${2:?--target needs a ref}
		shift 2
		;;
	*)
		printf 'usage: worktrees.sh [--repo DIR] [--target REF]\n' >&2
		exit 2
		;;
	esac
done

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 ||
	{
		printf 'worktrees: %s is not a git repository\n' "$REPO" >&2
		exit 2
	}
git -C "$REPO" rev-parse --verify --quiet "$TARGET" >/dev/null ||
	{
		printf 'worktrees: %s has no ref called %s - everything would read as unlanded\n' "$REPO" "$TARGET" >&2
		exit 2
	}

# THE MAIN CHECKOUT IS NOT A CANDIDATE and must not be listed as one. It is the
# first entry `git worktree list` prints, and it is also the one whose removal
# would take the repository with it.
main=$(git -C "$REPO" rev-parse --path-format=absolute --show-toplevel)

# WHO IS STANDING IN A TREE RIGHT NOW.
#
# A worktree is in use when a live process has its cwd inside it - the drainer
# between passes, a shell somebody left open, an agent mid-edit. `git worktree
# remove` does not check this: it checks the tree is clean, and a clean tree
# with somebody's shell in it is exactly the case that looks safe and is not.
#
# Read once, into one string, rather than per-entry: /proc has 126 x N reads in
# it otherwise, and the answer would drift between the first entry and the last.
# readlink rather than `ls -l | sed`: parsing ls output is a shellcheck finding
# for good reasons, and a worktree path with a space in it would land in the
# wrong list silently rather than loudly.
cwds=$(for d in /proc/[0-9]*; do readlink "$d/cwd" || true; done 2>/dev/null | sort -u)

landed=() unlanded=() inuse=()
path="" branch="" locked=""

classify() {
	[ -n "$path" ] || return 0
	[ "$path" != "$main" ] || return 0

	local name=${path##*/}
	if [ -n "$locked" ] || printf '%s\n' "$cwds" | grep -qxF "$path"; then
		inuse+=("$name	${branch:-(detached)}")
		return 0
	fi
	# A DETACHED WORKTREE NAMES NO BRANCH, so nothing says whether its commit is
	# somebody's work in progress. It is never a candidate here.
	if [ -z "$branch" ]; then
		unlanded+=("$name	(detached)")
		return 0
	fi
	if ! git -C "$REPO" merge-base --is-ancestor "$branch" "$TARGET" 2>/dev/null; then
		unlanded+=("$name	$branch")
		return 0
	fi
	# CLEAN INCLUDES UNTRACKED. An untracked file in a landed tree is the one
	# thing in it that exists nowhere else, which makes it the only thing worth
	# protecting - and `git worktree remove` would refuse over it anyway.
	if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
		unlanded+=("$name	$branch (landed, but the tree has uncommitted or untracked files)")
		return 0
	fi
	landed+=("$name	$branch	$path")
}

while IFS= read -r line; do
	case "$line" in
	"worktree "*)
		classify
		path=${line#worktree }
		branch=""
		locked=""
		;;
	"branch "*) branch=${line#branch refs/heads/} ;;
	"locked"*) locked=yes ;;
	esac
done < <(git -C "$REPO" worktree list --porcelain)
classify

total=$((${#landed[@]} + ${#unlanded[@]} + ${#inuse[@]}))
printf '%s worktrees of %s, besides the checkout itself\n\n' "$total" "$REPO"

if [ ${#landed[@]} -gt 0 ]; then
	printf 'LANDED AND CLEAN - %d. The branch is an ancestor of %s and the tree holds\n' "${#landed[@]}" "$TARGET"
	printf 'nothing uncommitted. Removing these loses nothing. THIS SCRIPT DOES NOT: run it\n'
	printf 'yourself, and only for the trees you know are yours.\n\n'
	printf '%s\n' "${landed[@]}" | sort | awk -F'\t' '{printf "  %-34s %s\n", $1, $2}'
	printf '\n  git -C %s worktree remove <path>   (or --force if it has a submodule)\n\n' "$REPO"
fi

if [ ${#inuse[@]} -gt 0 ]; then
	printf 'IN USE - %d. A live process has its cwd inside, or the worktree is locked.\n' "${#inuse[@]}"
	printf 'Not candidates whatever their branch says.\n\n'
	printf '%s\n' "${inuse[@]}" | sort | awk -F'\t' '{printf "  %-34s %s\n", $1, $2}'
	printf '\n'
fi

if [ ${#unlanded[@]} -gt 0 ]; then
	printf 'UNLANDED - %d. Somebody'"'"'s work, or a tree with local changes on top of\n' "${#unlanded[@]}"
	printf 'landed work. Leave them.\n\n'
	printf '%s\n' "${unlanded[@]}" | sort | awk -F'\t' '{printf "  %-34s %s\n", $1, $2}'
	printf '\n'
fi
