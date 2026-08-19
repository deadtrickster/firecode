#!/usr/bin/env bash
# File a finished branch for the merge queue, without retyping what the commit
# already says.
#
#   scripts/file-branch.sh [branch] [--target master] [--room general] [--title T]
#
# WHY THIS EXISTS. Counted on 2026-08-19, six times in one session, the same
# four steps in the same order:
#
#   git worktree add -b <branch> ~/Projects/wt-<name> master
#   ...work, commit...
#   git worktree remove <path>          # so the drainer can check the branch out
#   flowy merge open --branch <branch> --room general --title ... "$(git log -1 --format=%B)"
#
# Nothing there is hard and every step has a way to be wrong.
#
# FORGETTING THE REMOVE IS THE ONE THAT BITES, and it bit me. The branch stays
# checked out in a worktree, the drainer cannot rebase it, and the row sits
# BLOCKED with "checked out in /home/dead/Projects/wt-nagwait" until somebody
# reads the reason - twenty minutes, on a row nobody was watching. So this
# REFUSES rather than files a row that cannot be worked, and names the path and
# the command.
#
# It does not remove the worktree for you. A script that deletes a directory to
# be helpful is how this fleet lost another seat's database this morning.
#
# THE BODY IS THE COMMIT MESSAGE, read here rather than retyped as a command
# substitution in whatever shell you are standing in. One of mine went out with
# three phrases missing because backticks in the prose were executed.
set -euo pipefail

REPO=${FLOWY_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}
FLOWY=${FLOWY_BIN:-$HOME/Projects/flowy-dogfood/flowy}
ADDR=${FLOWY_ADDR:-http://192.168.1.55:8787}
NAME=${FLOWY_AGENT:-}
target=master
room=general
title=""
branch=""

while [ $# -gt 0 ]; do
	case "$1" in
	--target)
		target=${2:-master}
		shift 2
		;;
	--room)
		room=${2:-general}
		shift 2
		;;
	--title)
		title=${2:-}
		shift 2
		;;
	-h | --help)
		sed -n '2,8p' "$0" >&2
		exit 0
		;;
	-*)
		printf 'file-branch: unknown flag %s\n' "$1" >&2
		exit 2
		;;
	*)
		branch=$1
		shift
		;;
	esac
done

die() {
	printf 'file-branch: %s\n' "$*" >&2
	exit 1
}

[ -n "$NAME" ] || die "set FLOWY_AGENT - a row filed with no name is filed as the operator"
[ -n "$REPO" ] || die "not in a git checkout, and FLOWY_REPO is unset"

# The branch, defaulting to whatever is checked out here. A detached HEAD has no
# branch to file, and saying so beats filing a row naming "HEAD".
if [ -z "$branch" ]; then
	branch=$(git -C "$REPO" symbolic-ref --quiet --short HEAD) ||
		die "HEAD is detached here - name the branch: file-branch.sh <branch>"
fi
git -C "$REPO" rev-parse --verify --quiet "$branch" >/dev/null ||
	die "no branch called $branch in $REPO"

# IS ANYBODY HOLDING IT. `git worktree list --porcelain` is the whole answer and
# it includes THIS checkout, which is the case that bites: the tree you are
# standing in is holding the branch you are about to file.
held=$(git -C "$REPO" worktree list --porcelain 2>/dev/null |
	awk -v want="refs/heads/$branch" '
		/^worktree /  { path = substr($0, 10) }
		$0 == "branch " want { print path }
	')
if [ -n "$held" ]; then
	printf 'file-branch: %s is checked out and the drainer cannot rebase it there:\n' "$branch" >&2
	printf '%s\n' "$held" | sed 's/^/         /' >&2
	printf '\n       Free it and file again - from somewhere else, if that path is here:\n' >&2
	printf '%s\n' "$held" | sed "s|^|         git -C $REPO worktree remove |" >&2
	printf '\n       Not removed for you: a script that deletes a directory to be helpful\n' >&2
	printf '       is how this fleet lost another seat'"'"'s database this morning.\n' >&2
	exit 1
fi

# WHAT THE COMMIT ALREADY SAYS. The title is its first line unless one was
# given; the body is the whole message, so the row carries the reasoning that
# was written when it was fresh rather than a summary written now.
message=$(git -C "$REPO" log -1 --format=%B "$branch")
[ -n "$title" ] || title=$(printf '%s' "$message" | head -1)
[ -n "$message" ] || die "$branch has no commit message to file"

printf 'file-branch: %s -> %s, in #%s\n' "$branch" "$target" "$room" >&2
printf '%s' "$message" | FLOWY_AGENT="$NAME" FLOWY_ADDR="$ADDR" "$FLOWY" merge open \
	--branch "$branch" --target "$target" --room "$room" \
	--assignee "$NAME" --scope project --title "$title"
