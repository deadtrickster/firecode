#!/usr/bin/env bash
# Run a project's suite inside a firecode VM instead of on this box.
#
# WHY: drain-loop.sh skips its poll while ANY run-tests.sh exists on the host,
# because two suites on one machine fight over ports and postgres clusters. So
# a seat that gates locally before filing - which is the right thing to do, it
# keeps red rows out of the queue - starves the drainer for the length of the
# run. Measured 2026-08-21: the drainer gated nothing for ten minutes and two of
# the three suites holding it were mine.
#
# A suite inside a VM is not a host run-tests.sh, so suite_running does not see
# it and the drainer keeps working. @flowy-claude found this; this file is their
# recipe with the sharp edges taken off.
#
# WHAT IT COSTS: a VM boot, and the VM packs the REPO rather than your worktree,
# so the branch has to be committed and the VM has to be restarted to pick it
# up. That is why this refuses a dirty tree rather than quietly measuring the
# last commit - "I gated it" about a tree that is not the one on disk is the
# lie this whole night was made of.
set -uo pipefail

FIRECODE=${FIRECODE:-/home/dead/Projects/firecode/bin/firecode}
REPO=${GATE_REPO:-$PWD}
SUITE=${GATE_SUITE:-./run-tests.sh}
VM=${GATE_VM:-}

usage() {
	cat >&2 <<'EOF'
usage: gate-in-a-vm.sh [BRANCH]

Gates BRANCH (default: the current branch) inside a firecode VM, so the host's
drainer is not blocked for the length of the run.

  GATE_REPO   the checkout to gate (default: $PWD)
  GATE_SUITE  what to run inside (default: ./run-tests.sh)
  GATE_VM     which VM to use (default: firecode's own choice for this project)

Exit status is the SUITE'S, not the transport's - a VM that cannot be reached
is 2, so it can never be read as a pass.
EOF
}
[[ ${1:-} == -h || ${1:-} == --help ]] && {
	usage
	exit 0
}

cd "$REPO" || {
	printf 'no such checkout: %s\n' "$REPO" >&2
	exit 2
}
branch=${1:-$(git rev-parse --abbrev-ref HEAD)}

# COMMITTED, OR THE VM MEASURES SOMETHING ELSE. The image packs the repository,
# not the working tree, so an uncommitted change is simply absent from the run -
# and the run would pass, cheerfully, about a tree nobody has.
if [[ -n $(git status --porcelain) ]]; then
	printf 'the tree is dirty and the VM packs the REPOSITORY, not your worktree.\n' >&2
	printf 'commit first, or this gates a tree that is not the one you are looking at:\n\n' >&2
	git status --short >&2
	exit 2
fi
if ! git rev-parse --verify --quiet "$branch" >/dev/null; then
	printf 'no such branch here: %s\n' "$branch" >&2
	exit 2
fi

vmargs=()
[[ -n $VM ]] && vmargs=("$VM")

# down THEN up, so the image packs the commit that exists NOW. Skipping this is
# how a VM gates yesterday's tree and says so in the present tense.
printf '>> repacking the VM so it carries %s\n' "$(git rev-parse --short "$branch")" >&2
"$FIRECODE" down "${vmargs[@]}" >/dev/null 2>&1 || true
"$FIRECODE" up "${vmargs[@]}" >&2 || {
	printf 'the VM would not start - NOT a suite failure, and not a pass\n' >&2
	exit 2
}

"$FIRECODE" in "${vmargs[@]}" git checkout --quiet "$branch" >&2 || {
	printf 'could not check %s out inside the VM\n' "$branch" >&2
	exit 2
}

# THE SUITE'S OWN EXIT STATUS, carried out whole. `firecode in` returns the
# command's status, which is the one thing that must not be lost here: a
# transport that reports its own success is how a red run reads as green.
"$FIRECODE" in "${vmargs[@]}" bash -c "$SUITE"
rc=$?
printf '>> suite exit %s (inside the VM; the host drainer was never blocked)\n' "$rc" >&2
exit "$rc"
