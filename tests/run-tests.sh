#!/usr/bin/env bash
# firecode tests. No framework, no dependencies beyond what firecode needs.
#
#   firecode test           everything, boots VMs, a few minutes
#   firecode test --quick   host-side only, no VM boots, seconds
#   firecode test <name>    one test by name
#
# VM tests run with --no-jail --no-net so they need no privileges.
#
# shellcheck disable=SC2329  # tests are dispatched by name, not called directly
# shellcheck disable=SC2016  # single quotes are deliberate: these run in the guest
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
FIRECODE="$ROOT/bin/firecode"
WORK=$(mktemp -d /tmp/firecode-tests.XXXXXX)

QUICK=0
ONLY=""
PASS=0
FAIL=0
declare -a FAILED=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	--quick)
		QUICK=1
		shift
		;;
	*)
		ONLY="$1"
		shift
		;;
	esac
done

cleanup() {
	rm -rf "$WORK"
	rm -rf "$ROOT/state/testproj-"* "$ROOT/state/ro-testref-"* 2>/dev/null
}
trap cleanup EXIT

# ------------------------------------------------------------------ harness

ok() {
	PASS=$((PASS + 1))
	printf '  \033[32mok\033[0m    %s\n' "$1"
}

no() {
	FAIL=$((FAIL + 1))
	FAILED+=("$1")
	printf '  \033[31mFAIL\033[0m  %s\n' "$1"
	[[ -n ${2:-} ]] && printf '        %s\n' "$2"
}

check() {
	local what=$1 expected=$2 actual=$3
	if [[ $expected == "$actual" ]]; then
		ok "$what"
	else
		no "$what" "expected [$expected], got [$actual]"
	fi
}

contains() {
	local what=$1 needle=$2 haystack=$3
	if [[ $haystack == *"$needle"* ]]; then
		ok "$what"
	else
		no "$what" "[$needle] not found in output"
	fi
}

run_test() {
	local name=$1
	[[ -n $ONLY && $ONLY != "$name" ]] && return 0
	printf '\n%s\n' "$name"
	"test_$name"
}

# A project to work on, and a reference tree to --add-dir.
make_project() {
	local dir="$WORK/testproj"
	rm -rf "$dir"
	mkdir -p "$dir/src"
	echo "# test project" >"$dir/README.md"
	echo "print('hello')" >"$dir/src/main.py"
	printf 'build/\n*.log\n' >"$dir/.gitignore"
	mkdir -p "$dir/build"
	head -c 200000 /dev/zero >"$dir/build/artifact.bin"
	echo "noise" >"$dir/debug.log"
	git -C "$dir" init -q 2>/dev/null
	git -C "$dir" add -A 2>/dev/null
	# commit.gpgsign=false because a machine that signs by default cannot sign
	# from here: there is no tty for pinentry, so the commit dies on a timeout
	# and leaves a repository with no commits at all. The 2>/dev/null hid that,
	# and the test that noticed reported it as "git history came along" failing
	# in the guest - the guest was fine, the fixture had never committed.
	git -C "$dir" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
		commit -qm init >/dev/null 2>&1 ||
		echo "make_project: the fixture commit failed, so git tests will lie" >&2
	echo "$dir"
}

# A throwaway ~/.claude so no test can touch the real one.
make_fake_claude_home() {
	local home="$WORK/fakeclaude" project=$1 slug
	slug=$(printf '%s' "$project" | tr -c 'A-Za-z0-9' '-')
	rm -rf "$home"
	mkdir -p "$home/projects/$slug"
	python3 - "$home/projects/$slug/aaaa1111-test.jsonl" "$project" <<'PY'
import json, sys
out, project = sys.argv[1], sys.argv[2]
rows = [
    {"type": "user", "sessionId": "aaaa1111-test", "cwd": project,
     "message": {"role": "user", "content": "look at %s/README.md" % project}},
    {"type": "assistant", "sessionId": "aaaa1111-test", "cwd": project,
     "toolUse": {"file_path": project + "/src/main.py"}},
]
with open(out, "w") as fh:
    fh.write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
	echo "$home"
}

# Run a shell command inside a VM and print its output.
in_vm() {
	local project=$1
	shift
	(cd "$project" && timeout 240 "$FIRECODE" exec --no-jail --no-net "$@" \
		2>&1 | sed -n 's/.*agent-entrypoint\.sh\[[0-9]*\]: //p')
}

# ------------------------------------------------------------------- tests

# The one that matters most: importing a session must not touch the host's
# copy of it. Run against the real ~/.claude, because that is the thing that
# would hurt, and the guarantee is that it is only ever read.
test_host_transcripts_untouched() {
	local real="$HOME/.claude/projects"
	if [[ ! -d $real ]]; then
		ok "no host transcripts to protect (skipped)"
		return
	fi

	# A claude session running right now is appending to its own transcript,
	# which is not firecode writing. Compare only the files nothing is
	# actively touching - a real breach would change one of those.
	local before after settled
	settled=$(mktemp)
	find "$real" -type f -mmin +2 2>/dev/null | sort >"$settled"
	before=$(xargs -r -a "$settled" sha256sum 2>/dev/null | sha256sum)

	local project
	project=$(make_project)
	# Import for this very repo, which has real host sessions.
	(cd "$ROOT" && "$FIRECODE" claude --import-sessions --no-jail --no-net \
		--workdir "$project" --timeout 1 -- --version >/dev/null 2>&1)

	after=$(xargs -r -a "$settled" sha256sum 2>/dev/null | sha256sum)
	check "host transcripts are byte-identical after an import" "$before" "$after"

	local missing
	missing=$(while IFS= read -r f; do [[ -f $f ]] || echo "$f"; done <"$settled" | wc -l)
	check "no host transcript was removed" "0" "$missing"
	rm -f "$settled"
}

test_project_tree_untouched() {
	local project before after
	project=$(make_project)
	before=$(find "$project" -type f -exec sha256sum {} + | sort | sha256sum)

	if ((QUICK)); then
		ok "project tree unchanged (skipped, needs a VM)"
		return
	fi
	local out
	out=$(in_vm "$project" -- bash -c 'rm -rf ./* 2>/dev/null; echo "LEFT=$(ls | wc -l)"')

	# The guest has to actually manage the deletion, or this proves nothing.
	contains "the guest really can delete its whole project" "LEFT=0" "$out"

	after=$(find "$project" -type f -exec sha256sum {} + | sort | sha256sum)
	check "a guest deleting everything leaves the host tree alone" "$before" "$after"
}

test_denylist() {
	local deny="$WORK/never-share" project out
	project=$(make_project)
	printf '%s\n' "$WORK/secret" >"$deny"
	mkdir -p "$WORK/secret/inner"

	out=$(FIRECODE_DENY_FILE="$deny" "$FIRECODE" exec --workdir "$WORK/secret" true 2>&1)
	contains "denied as --workdir" "refusing" "$out"

	out=$(FIRECODE_DENY_FILE="$deny" "$FIRECODE" exec --workdir "$WORK/secret/inner" true 2>&1)
	contains "denied as a subdirectory of a listed path" "refusing" "$out"

	out=$(FIRECODE_DENY_FILE="$deny" "$FIRECODE" exec --workdir "$project" \
		--add-dir "$WORK/secret" true 2>&1)
	contains "denied as --add-dir" "refusing" "$out"

	# The built-in list stands on its own, with no deny file at all.
	mkdir -p "$HOME/.aws"
	out=$(FIRECODE_DENY_FILE=/nonexistent "$FIRECODE" exec --workdir "$HOME/.aws" true 2>&1)
	contains "credential directories refused without any config" "refusing" "$out"
	rmdir "$HOME/.aws" 2>/dev/null
}

test_gitignore_excluded() {
	local project out
	project=$(make_project)
	if ((QUICK)); then
		ok "gitignored files excluded (skipped, needs a VM)"
		return
	fi
	out=$(in_vm "$project" -- bash -c 'echo "B=$(ls build 2>&1)"; echo "L=$(ls debug.log 2>&1)"; echo "G=$(git log --oneline | wc -l)"; echo "R=$(ls README.md)"')
	contains "gitignored directory is not in the guest" "B=ls: cannot access" "$out"
	contains "gitignored file is not in the guest" "L=ls: cannot access" "$out"
	contains "git history came along" "G=1" "$out"
	contains "tracked files came along" "R=README.md" "$out"
}

test_paths_mirror_host() {
	local project out
	project=$(make_project)
	if ((QUICK)); then
		ok "guest mirrors host paths (skipped, needs a VM)"
		return
	fi
	out=$(in_vm "$project" -- bash -c 'echo "P=$(pwd)"; echo "H=$HOME"; echo "U=$(id -un):$(id -u)"')
	contains "project is at its host path in the guest" "P=$project" "$out"
	contains "home directory matches the host" "H=$HOME" "$out"
	contains "user and uid match the host" "U=$(id -un):$(id -u)" "$out"
}

test_state_persists() {
	local project out
	project=$(make_project)
	if ((QUICK)); then
		ok "agent home persists between runs (skipped, needs a VM)"
		return
	fi
	in_vm "$project" -- bash -c 'echo marker-7 > ~/.claude/test-probe' >/dev/null
	out=$(in_vm "$project" -- bash -c 'echo "P=$(cat ~/.claude/test-probe 2>&1)"')
	contains "what the agent wrote to its home is there next run" "P=marker-7" "$out"
}

test_session_import_resumable() {
	local project fake out slug
	project=$(make_project)
	fake=$(make_fake_claude_home "$project")
	slug=$(printf '%s' "$project" | tr -c 'A-Za-z0-9' '-')

	if ((QUICK)); then
		ok "imported session is resumable (skipped, needs a VM)"
		return
	fi
	rm -rf "$ROOT/state/$(basename "$project")-"*
	out=$(FIRECODE_CLAUDE_HOME="$fake" in_vm "$project" --import-sessions -- \
		bash -c "echo \"S=\$(ls ~/.claude/projects/$slug/)\"; echo \"C=\$(head -1 ~/.claude/projects/$slug/aaaa1111-test.jsonl)\"")

	contains "the transcript is in the guest under the same project key" \
		"S=aaaa1111-test.jsonl" "$out"
	contains "paths inside it still point at the project" \
		"\"cwd\": \"$project\"" "$out"

	# And the fixture it came from is untouched.
	local host_line
	host_line=$(head -1 "$fake/projects/$slug/aaaa1111-test.jsonl")
	contains "the host copy was not rewritten" "\"cwd\": \"$project\"" "$host_line"
}

test_results_come_back() {
	local project out result
	project=$(make_project)
	if ((QUICK)); then
		ok "work is copied back out (skipped, needs a VM)"
		return
	fi
	out=$(cd "$project" && timeout 240 "$FIRECODE" exec --no-jail --no-net -- \
		bash -c 'echo "from the vm" > NEWFILE.txt' 2>&1)
	result=$(sed -n 's/^  result:  //p' <<<"$out" | head -1)

	if [[ -z $result ]]; then
		no "a result directory was reported"
		return
	fi
	ok "a result directory was reported"
	check "the new file is in it" "from the vm" "$(cat "$result/NEWFILE.txt" 2>&1)"
	if [[ ! -e $project/NEWFILE.txt ]]; then
		ok "the original project did not get it"
	else
		no "the original project did not get it" "NEWFILE.txt leaked into the source tree"
	fi

	# A result is mostly the project it came from, and a full second copy of
	# it per run is what turns a project directory into landfill. What came
	# back unchanged should cost nothing.
	local a b
	a=$(stat -c %i "$project/README.md" 2>/dev/null)
	b=$(stat -c %i "$result/README.md" 2>/dev/null)
	if [[ -n $a && $a == "$b" ]]; then
		ok "an unchanged file is not a second copy"
	else
		no "an unchanged file is not a second copy" "inodes $a vs $b"
	fi
	# ...but what the run actually wrote has to be its own file, or writing
	# to the result would write to the project.
	if [[ $(stat -c %h "$result/NEWFILE.txt" 2>/dev/null) == "1" ]]; then
		ok "and what changed is a file of its own"
	else
		no "and what changed is a file of its own" \
			"NEWFILE.txt has $(stat -c %h "$result/NEWFILE.txt" 2>/dev/null) links"
	fi
	rm -rf "$result"
}

# A commit made in a run is not a commit in your project, and the run has to
# say so. Four pieces of finished work were announced as "landed on master" in
# one morning by agents who had committed inside a VM and read the result line
# as confirmation - the work was in a directory beside the project the whole
# time. What is asserted here is the WARNING, because the copy-out behaviour
# was always correct and silent, and silence is what everybody misread.
test_commits_are_reported_unlanded() {
	local project out result sha
	project=$(make_project)
	if ((QUICK)); then
		ok "a commit that did not land is reported (skipped, needs a VM)"
		return
	fi
	# The identity is given explicitly: a commit that fails because the guest
	# has no git identity would fail this test for a reason it is not about.
	out=$(cd "$project" && timeout 240 "$FIRECODE" exec --no-jail --no-net -- \
		bash -c 'echo inside > INSIDE.txt && git add -A &&
			git -c user.email=t@example.com -c user.name=t \
			    commit -qm "committed inside the run"' 2>&1)

	contains "a commit that did not land is reported" "NOT LANDED" "$out"
	contains "and the report says how to fold it in" "firecode land " "$out"

	result=$(sed -n 's/^  result:  //p' <<<"$out" | head -1)
	sha=$(git -C "$result" rev-parse --short HEAD 2>/dev/null || true)
	if [[ -n $sha ]] && ! git -C "$project" cat-file -e "${sha}^{commit}" 2>/dev/null; then
		ok "and the project really does not have that commit"
	else
		no "and the project really does not have that commit" \
			"result HEAD [$sha] - the warning would have been a lie"
	fi
	[[ -n $result ]] && rm -rf "$result"
}

# Existence is not reachability, and this asserts the DIFFERENCE rather than an
# absolute: a single reading cannot tell a rule being enforced from a rule that
# was never implemented. Two commits in one repository, identical in every way
# except that one is on a branch and the other is not, must get opposite
# answers. `cat-file -e` - what firecode used to ask in three places - answers
# yes to both, so this test goes red against that version.
test_commit_reachability() {
	local repo reachable detached fn
	repo="$WORK/reach"
	git init -q "$repo"
	git -C "$repo" config user.email t@example.com
	git -C "$repo" config user.name t
	git -C "$repo" config commit.gpgsign false
	echo one >"$repo/f"
	git -C "$repo" add f
	git -C "$repo" commit -qm one
	reachable=$(git -C "$repo" rev-parse HEAD)
	git -C "$repo" checkout -q --detach
	echo two >"$repo/f"
	git -C "$repo" commit -qam two
	detached=$(git -C "$repo" rev-parse HEAD)

	# The function comes out of the script itself rather than being restated
	# here. A local copy would keep passing while firecode's own answer went
	# wrong, which is the whole failure this is meant to catch.
	fn=$(sed -n '/^commit_reachable() {$/,/^}$/p' "$FIRECODE")
	if [[ -z $fn ]]; then
		no "commit_reachable can be read out of firecode" "not found in $FIRECODE"
		return
	fi
	eval "$fn"

	if commit_reachable "$repo" "$reachable"; then
		ok "a commit on a branch is reachable"
	else
		no "a commit on a branch is reachable" "$reachable is on master"
	fi
	if commit_reachable "$repo" "$detached"; then
		no "a detached-HEAD commit is not reachable" \
			"$detached is on no ref, but the check said it was"
	else
		ok "a detached-HEAD commit is not reachable"
	fi
}

# gc DELETES, so what it keeps has to be provable rather than assumed. Two
# result directories that differ in one respect - one holds a commit that is on
# a branch in the project, the other holds two commits that are on no branch
# anywhere - must get opposite treatment, and the kept one must say which
# commits are keeping it alive. That last part is the whole point: 38 of 103
# directories survived one reclaim silently, and nobody could tell an abandoned
# experiment from somebody's only copy.
#
# sweep_results runs for real here, taken out of the script, against roots that
# exist only inside $WORK. FIRECODE_RESULT_ROOTS is what keeps it away from
# /tmp and ~/Projects.
test_gc_keeps_unreachable_work() {
	local root landed orphan out
	root="$WORK/gcroots"
	mkdir -p "$root"
	g() { git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t "$@"; }

	g init -q "$root/proj"
	echo base >"$root/proj/f"
	g -C "$root/proj" add f
	g -C "$root/proj" commit -qm base

	# Landed: the run's commit ends up on a branch in the project.
	landed="$root/proj-20260818-101010-1111"
	g clone -q "$root/proj" "$landed"
	echo a >"$landed/f"
	g -C "$landed" commit -qam "work that landed"
	g -C "$landed" push -q "$root/proj" HEAD:refs/heads/landed

	# Orphaned: two commits, on no ref in either repository.
	orphan="$root/proj-20260818-101011-2222"
	g clone -q "$root/proj" "$orphan"
	echo b >"$orphan/f"
	g -C "$orphan" commit -qam "the only copy of this"
	echo c >"$orphan/f"
	g -C "$orphan" commit -qam "and this"

	# Older than the age floor, which is the backstop for a directory whose run
	# this host has no record of - and no host has a record of these.
	touch -d '2 hours ago' "$landed" "$orphan"

	out=$(
		log() { printf 'gc: %s\n' "$*" >&2; }
		eval "$(sed -n '/^commit_reachable() {$/,/^}$/p' "$FIRECODE")"
		eval "$(sed -n '/^main_checkout() {$/,/^}$/p' "$FIRECODE")"
		eval "$(sed -n '/^sweep_results() {$/,/^}$/p' "$FIRECODE")"
		# shellcheck disable=SC2034  # read by the eval'd sweep_results, not by this file
		RUNS="$WORK/no-such-runs"
		FIRECODE_RESULT_ROOTS="$root" FIRECODE_RESULT_HOURS=1 sweep_results 2>&1
	)

	if [[ -d $landed ]]; then
		no "gc removes a result whose work is on a branch" "$landed survived"
	else
		ok "gc removes a result whose work is on a branch"
	fi
	if [[ -d $orphan ]]; then
		ok "gc keeps a result whose work is on no branch"
	else
		no "gc keeps a result whose work is on no branch" \
			"$orphan was the only copy of two commits"
	fi
	contains "and names the commits that keep it" "the only copy of this" "$out"
	contains "and how to land them" "firecode land firecode-20260818-101011-2222" "$out"
}

test_ro_image_cached() {
	local project ref out1
	project=$(make_project)
	ref="$WORK/testref"
	mkdir -p "$ref"
	echo "reference material" >"$ref/note.txt"

	if ((QUICK)); then
		ok "read-only images are cached (skipped, needs a VM)"
		return
	fi
	rm -f "$ROOT/state/ro-testref-"*
	in_vm "$project" --add-dir "$ref" -- true >/dev/null
	out1=$(find "$ROOT/state" -name 'ro-testref-*.ext4' | wc -l)
	check "an image was cached for the reference tree" "1" "$out1"

	local stamp_before stamp_after
	stamp_before=$(stat -c %Y "$ROOT/state/ro-testref-"*.ext4 2>/dev/null)
	sleep 1
	in_vm "$project" --add-dir "$ref" -- true >/dev/null
	stamp_after=$(stat -c %Y "$ROOT/state/ro-testref-"*.ext4 2>/dev/null)
	check "an unchanged tree is not re-imaged" "$stamp_before" "$stamp_after"

	echo "changed" >>"$ref/note.txt"
	in_vm "$project" --add-dir "$ref" -- true >/dev/null
	local stamp_third
	stamp_third=$(stat -c %Y "$ROOT/state/ro-testref-"*.ext4 2>/dev/null)
	if [[ $stamp_third != "$stamp_after" ]]; then
		ok "a changed tree is re-imaged"
	else
		no "a changed tree is re-imaged" "the cache was reused after an edit"
	fi
}

# The jailed path, if it can be reached without a prompt. Everything else
# runs --no-jail so the suite needs no privileges at all.
test_jailed() {
	local project out
	if ((QUICK)); then
		ok "jailed boot (skipped, needs a VM)"
		return
	fi
	# Probe the jailer itself, not sudo in general. A correctly scoped
	# sudoers rule grants this one binary and nothing else, so `sudo -n true`
	# failing says nothing about whether a jailed run can start.
	if ! sudo -n "$ROOT/vendor/bin/jailer" --version >/dev/null 2>&1; then
		ok "jailed boot (skipped, the jailer would prompt for a password)"
		return
	fi
	project=$(make_project)
	out=$(cd "$project" && timeout 240 "$FIRECODE" exec --no-net -- \
		bash -c 'echo "U=$(id -un)"; echo "P=$(pwd)"; echo "F=$(ls)"' 2>&1 |
		sed -n 's/.*agent-entrypoint\.sh\[[0-9]*\]: //p')
	contains "boots under the jailer as the right user" "U=$(id -un)" "$out"
	contains "project is mounted in the jailed guest" "P=$project" "$out"
	contains "the project files are there" "README.md" "$out"
}

# A run with nothing at all to forward: no MCP, no --host-port. Used to take
# the whole run down without printing anything.
test_no_relays() {
	local project out
	project=$(make_project)
	if ((QUICK)); then
		ok "a run with no relays at all (skipped, needs a VM)"
		return
	fi
	out=$(in_vm "$project" --no-mcp -- bash -c 'echo "ALIVE=yes"')
	contains "a run with nothing to forward still boots" "ALIVE=yes" "$out"
}

# Two runs at once on the same project. They must take different network
# slots, and only one may hold the state drive. Both used to grab slot 1 and
# the second died on "Resource busy", because the lock was taken inside a
# command substitution and released with its subshell.
test_concurrent_runs() {
	local project a b rc_a rc_b
	project=$(make_project)
	if ((QUICK)); then
		ok "two runs at once (skipped, needs a VM)"
		return
	fi

	# TWO RUNS AT ONCE NEED TWO FREE TAPS, and on a host shared with a fleet
	# there are often fewer. Without this the check ran anyway and reported
	# "they used different tap devices: expected 2, got 1" - which reads as a
	# slot-allocation bug and is really "there was only one slot to be had".
	# It cost a run to work out that the same failure reproduces on a commit
	# from before anything I had changed.
	#
	# FREE MEANS BOTH LOCKS ARE FREE, and counting only carrier was wrong:
	# firecode holds a flock on a slot for the WHOLE run, setup and teardown
	# included, while carrier only goes up once a VM is actually attached. So a
	# host with four carriers can still have every slot claimed, the picker
	# walks past the last existing tap, and the run asks for a tap that has to
	# be created - which needs root. Measured: run A took fccode6 and passed
	# while run B asked for fccode9 with only four carriers showing.
	#
	# Reported rather than silently passed: a check that skips without saying so
	# is how a suite comes to mean nothing.
	local free=0 tap slot lock
	for tap in /sys/class/net/fccode*/carrier; do
		[[ -r $tap ]] || continue
		[[ $(cat "$tap" 2>/dev/null) == 0 ]] || continue
		slot=${tap#/sys/class/net/fccode}
		slot=${slot%/carrier}
		lock="$ROOT/state/net/$slot.lock"
		# No lock file yet means nothing has ever claimed the slot: free.
		[[ -e $lock ]] || {
			((free++))
			continue
		}
		if flock -n "$lock" true 2>/dev/null; then ((free++)); fi
	done
	if ((free < 2)); then
		ok "two runs at once (skipped: $free free tap(s), something else holds the rest)"
		return
	fi
	a="$WORK/concurrent-a.log"
	b="$WORK/concurrent-b.log"

	(cd "$project" && timeout 240 "$FIRECODE" exec --no-jail -- \
		bash -c 'sleep 6; echo A-DONE' >"$a" 2>&1) &
	local pid_a=$!
	sleep 2
	(cd "$project" && timeout 240 "$FIRECODE" exec --no-jail -- \
		bash -c 'echo B-DONE' >"$b" 2>&1) &
	local pid_b=$!

	wait "$pid_a"
	rc_a=$?
	wait "$pid_b"
	rc_b=$?

	check "the first concurrent run succeeds" "0" "$rc_a"
	check "the second concurrent run succeeds" "0" "$rc_b"
	contains "the first one really ran" "A-DONE" "$(cat "$a")"
	contains "the second one really ran" "B-DONE" "$(cat "$b")"

	local taps
	taps=$(grep -ho 'fccode[0-9]*' "$a" "$b" | sort -u | wc -l)
	check "they used different tap devices" "2" "$taps"
	contains "the second one is told its session is not resumable" \
		"not be resumable" "$(cat "$b")"
}

# `firecode shell` hands the guest console to a terminal, which a pipe is not,
# so this is the only test that drives a real pty. It is where the console
# was found dead: firecode-agent.service declared a conflict with the getty,
# and systemd acted on it even though the unit itself was skipped.
test_interactive() {
	local project out rc
	project=$(make_project)
	if ((QUICK)); then
		ok "an interactive session (skipped, needs a VM)"
		return
	fi
	out=$(timeout 300 python3 -u "$ROOT/tests/interactive.py" "$project" "$FIRECODE" 2>&1)
	rc=$?
	printf '%s\n' "$out" | sed 's/^  /    /'
	# interactive.py prints its own ok/FAIL lines; count them here.
	local n_ok n_fail
	n_ok=$(grep -c '^  ok' <<<"$out")
	n_fail=$(grep -c '^  FAIL' <<<"$out")
	PASS=$((PASS + n_ok))
	FAIL=$((FAIL + n_fail))
	((n_fail > 0)) && FAILED+=("interactive session")
	((rc != 0 && n_fail == 0)) && no "the interactive test exited $rc"
	return 0
}

# `claude -p` with nothing to do fails on its first line. Catch it before
# building drives and booting a VM.
test_prompt_required() {
	local project out
	project=$(make_project)

	# The agent's own flags go after --, because firecode refuses a flag it
	# does not know rather than passing it on and hoping. These invocations
	# predated that and were being refused before anything they check was
	# reached: three checks about argument handling, none of which got as far
	# as an argument being handled.
	#
	# --api-base satisfies the same guard as in arg_massaging: --no-net with
	# no endpoint is refused before the command is composed.
	local unattended="--no-jail --no-net --api-base http://127.0.0.1:9/v1 --timeout 1"

	# Flags with no task mean a session you drive, not an unattended run with
	# nothing to do - so this opens the REPL rather than being refused.
	out=$("$FIRECODE" claude --workdir "$project" --dry-run -- --resume abc123 2>&1)
	contains "a bare --resume opens a session" "mode=interactive" "$out"

	# shellcheck disable=SC2086  # deliberately word-split: these are separate flags
	out=$("$FIRECODE" claude --workdir "$project" $unattended \
		"carry on" -- --resume abc123 2>&1 | sed -n 's/.*agent command: //p' | head -1)
	contains "--resume with a prompt is not refused" "carry on" "$out"

	# shellcheck disable=SC2086  # deliberately word-split: these are separate flags
	out=$("$FIRECODE" claude --workdir "$project" $unattended \
		"do a thing" -- --model opus 2>&1 | sed -n 's/.*agent command: //p' | head -1)
	contains "a flag value is not mistaken for a prompt" "do a thing" "$out"
}

# A guest writes to your terminal, and a terminal executes some of what is
# printed at it. These are the sequences that do something other than draw.
test_terminal_escapes() {
	local line
	while IFS= read -r line; do
		case "$line" in
		ok\ *) ok "${line#ok }" ;;
		NO\ *) no "${line#NO }" ;;
		esac
	done < <(python3 "$ROOT/tests/escapes.py" 2>&1)
}

test_arg_massaging() {
	local project out
	project=$(make_project)
	# Unattended claude gets -p and permission bypass added, so it does not
	# sit at a prompt nobody is watching.
	#
	# --api-base is here to satisfy a guard, not to reach anything: an agent
	# with --no-net and no model endpoint is now refused before it boots,
	# because such a run only hangs. That refusal happens before the command
	# is composed, so without this the greps below found an empty string and
	# these checks failed for a reason that had nothing to do with arguments.
	local composed="--no-jail --no-net --api-base http://127.0.0.1:9/v1"
	# shellcheck disable=SC2086  # deliberately word-split: these are separate flags
	out=$("$FIRECODE" claude --workdir "$project" $composed \
		--timeout 1 "do a thing" 2>&1 | sed -n 's/.*agent command: //p' | head -1)
	if [[ -z $out ]]; then
		no "the agent command is reported at all" \
			"nothing matched 'agent command:' - the checks below would pass on an empty string"
		return
	fi
	contains "unattended claude gets --print" "-p" "$out"
	contains "unattended claude gets permission bypass" "--dangerously-skip-permissions" "$out"

	# shellcheck disable=SC2086  # deliberately word-split: these are separate flags
	out=$("$FIRECODE" claude --workdir "$project" $composed --no-auto-flags \
		--timeout 1 "do a thing" 2>&1 | sed -n 's/.*agent command: //p' | head -1)
	if [[ $out != *"--dangerously-skip-permissions"* ]]; then
		ok "--no-auto-flags leaves the command alone"
	else
		no "--no-auto-flags leaves the command alone" "$out"
	fi
}

test_shellcheck() {
	local f out=""
	for f in "$ROOT/bin/firecode" "$ROOT"/scripts/*.sh "$ROOT"/guest/*.sh \
		"$ROOT"/tests/*.sh; do
		shellcheck "$f" >/dev/null 2>&1 || out="$out $(basename "$f")"
	done
	if command -v shellcheck >/dev/null 2>&1; then
		check "every script passes shellcheck" "" "$out"
	else
		ok "shellcheck not installed (skipped)"
	fi
	# What an agent is told, and when. The connect-time slot is small - a
	# couple of thousand characters before a client truncates it - so the
	# brief has to stay inside it and the real guide has to ride along with
	# the first tool result instead.
	local brief_size
	brief_size=$(wc -c <"$ROOT/mcp/brief.md" 2>/dev/null || echo 99999)
	if ((brief_size < 2000)); then
		ok "the connect-time brief fits in the budget ($brief_size chars)"
	else
		no "the connect-time brief fits in the budget" "$brief_size chars, limit 2000"
	fi
	if [[ -s $ROOT/mcp/guide.md ]]; then
		ok "there is a full guide to send after it"
	else
		no "there is a full guide to send after it"
	fi

	if python3 -m py_compile "$ROOT/mcp/firecode-spawn.py" 2>/dev/null; then
		ok "the spawn server parses"
	else
		no "the spawn server parses"
	fi
}

# ------------------------------------------------------------- lifetime
#
# What a VM's lifetime has to guarantee, stated as behaviour rather than as
# mechanism. Nothing below knows that cgroups exist: the contract is that
# stopping a VM stops everything it started, that a VM which dies badly is
# still recognisable as dead, and that nothing is left running afterwards -
# which is what any implementation of this has to keep true.

# Every VM firecode can see, by the project it belongs to.
vms_running() {
	"$FIRECODE" list --ids 2>/dev/null | grep -c "$WORK" || true
}

# Wait for a condition rather than sleeping a guessed amount.
wait_until() {
	local what=$1 secs=$2 waited=0
	shift 2
	while ((waited * 4 < secs * 4)); do
		if "$@"; then return 0; fi
		sleep 0.25
		waited=$((waited + 1))
	done
	return 1
}

start_vm() {
	local dir=$1
	shift
	(cd "$dir" && "$FIRECODE" up --no-jail --no-net --mem 1024 "$@" >/dev/null 2>&1)
}

test_vm_stops_completely() {
	((QUICK)) && return 0
	local p
	p=$(make_project)
	if ! start_vm "$p"; then
		no "a VM starts"
		return 0
	fi
	ok "a VM starts"
	check "it answers commands" "alive" \
		"$(cd "$p" && "$FIRECODE" in 'echo alive' 2>/dev/null | tail -1)"

	(cd "$p" && "$FIRECODE" down >/dev/null 2>&1)
	if wait_until "gone" 30 test "$(vms_running)" = "0"; then
		ok "down leaves nothing running"
	else
		no "down leaves nothing running" "$("$FIRECODE" list 2>&1 | head -3)"
	fi
}

test_child_dies_with_parent() {
	((QUICK)) && return 0
	local parent child parent_run
	parent=$(make_project)
	child="$WORK/childproj"
	rm -rf "$child"
	mkdir -p "$child"
	echo x >"$child/README.md"
	git -C "$child" init -q 2>/dev/null

	if ! start_vm "$parent"; then
		no "the parent VM starts"
		return 0
	fi
	ok "the parent VM starts"

	# Whatever identifies a run to firecode - here, the id it reports for the
	# VM belonging to this project.
	parent_run=$("$FIRECODE" list --ids 2>/dev/null | awk -v p="$parent" '$2==p{print $1}' | head -1)
	if [[ -z $parent_run ]]; then
		no "the parent VM has an id" "firecode list --ids reported none"
		(cd "$parent" && "$FIRECODE" down >/dev/null 2>&1)
		return 0
	fi
	ok "the parent VM has an id"

	if ! start_vm "$child" --parent-run "$parent_run"; then
		no "a VM starts as a child of it"
		(cd "$parent" && "$FIRECODE" down >/dev/null 2>&1)
		return 0
	fi
	ok "a VM starts as a child of it"
	check "both are running" "2" "$(vms_running)"

	# The whole point: stopping the parent has to reach the child, which no
	# process tree connects it to.
	(cd "$parent" && "$FIRECODE" down --project "$parent" >/dev/null 2>&1)
	if wait_until "child gone" 45 test "$(vms_running)" = "0"; then
		ok "stopping the parent stops the child too"
	else
		no "stopping the parent stops the child too" \
			"$("$FIRECODE" list 2>&1 | head -4)"
		(cd "$child" && "$FIRECODE" down --project "$child" >/dev/null 2>&1)
	fi
}

test_killed_vm_is_reported_dead() {
	((QUICK)) && return 0
	local p
	p=$(make_project)
	if ! start_vm "$p"; then
		no "a VM starts"
		return 0
	fi
	ok "a VM starts"

	# A launcher killed outright runs no cleanup, which is how strays were
	# left behind before. What must not happen is firecode continuing to
	# report the VM as usable.
	#
	# The VM is found through its OWN cgroup, never by picking a firecracker
	# off the machine. This used to `kill -9` the last firecracker in pgrep
	# and then assert that none was left anywhere - on a host where other
	# agents run VMs, that killed somebody else's work and then failed
	# because somebody else's VM was still up. It cost a green gate today and
	# could have cost a colleague their run. A cgroup names the processes of
	# exactly one run, which is the same reason firecode itself asks the
	# cgroup rather than a pattern.
	local id cg pids
	id=$("$FIRECODE" list --ids 2>/dev/null | awk -v p="$p" '$2 == p {print $1; exit}')
	if [[ -z $id ]]; then
		no "the VM this test started can be named" "not in list --ids for $p"
		return 0
	fi
	cg=$(cat "$ROOT/runs/$id/cgroup" 2>/dev/null)
	pids=$(cat "$cg/vm/cgroup.procs" 2>/dev/null)
	if [[ -z $pids ]]; then
		no "the VM this test started has a live process" "nothing in $cg/vm"
		return 0
	fi
	# shellcheck disable=SC2086  # a list of pids, deliberately word-split
	kill -9 $pids 2>/dev/null || true

	if wait_until "reported gone" 30 test "$(vms_running)" = "0"; then
		ok "a VM killed outright stops being listed"
	else
		no "a VM killed outright stops being listed" "$("$FIRECODE" list 2>&1 | head -3)"
	fi
	# Everything of THIS run: the vm cgroup, the relays beside it, and the
	# run's own. A cgroup that has been removed reads as empty, which is the
	# answer we want anyway.
	local left
	left=$(cat "$cg/cgroup.procs" "$cg"/*/cgroup.procs 2>/dev/null | tr '\n' ' ')
	if [[ -z ${left// /} ]]; then
		ok "and nothing of it is left running"
	else
		no "and nothing of it is left running" "pids still in its cgroup: $left"
	fi
}

# --------------------------------------------------------- the guest's /proc
#
# Reading /proc on the host while the process runs in a VM describes the wrong
# machine and looks healthy doing it, which is the failure these two guard
# against. Both assert against numbers that cannot match by accident: a VM
# booted with 1G against a host with rather more.

host_memtotal() { awk '/MemTotal/{print $2}' /proc/meminfo; }

test_proc_mirror() {
	((QUICK)) && return 0
	local p out
	p=$(make_project)
	out="$WORK/mirror"
	if ! start_vm "$p"; then
		no "a VM starts"
		return 0
	fi
	ok "a VM starts"

	if (cd "$p" && "$FIRECODE" mirror --once --out "$out" \
		'/proc/meminfo' '/proc/uptime' >/dev/null 2>&1); then
		ok "mirror pulls the paths it was given"
	else
		no "mirror pulls the paths it was given"
		(cd "$p" && "$FIRECODE" down >/dev/null 2>&1)
		return 0
	fi

	local guest host
	guest=$(awk '/MemTotal/{print $2}' "$out/proc/meminfo" 2>/dev/null)
	host=$(host_memtotal)
	if [[ -n $guest && $guest != "$host" ]]; then
		ok "what it pulled is the guest's, not this machine's ($guest vs $host kB)"
	else
		no "what it pulled is the guest's, not this machine's" "got [$guest] vs host [$host]"
	fi

	# A pattern matching nothing has to fail rather than quietly leaving the
	# last tick's files in place, which would age into wrong answers.
	if (cd "$p" && "$FIRECODE" mirror --once --out "$out" \
		'/proc/definitely-not-here' >/dev/null 2>&1); then
		no "a pattern that matches nothing is an error"
	else
		ok "a pattern that matches nothing is an error"
	fi
	(cd "$p" && "$FIRECODE" down >/dev/null 2>&1)
}

test_proc_mounted() {
	((QUICK)) && return 0
	local p mnt venv
	venv="$ROOT/.venv/bin/python"
	if [[ ! -x $venv ]] || ! "$venv" -c "import fuse" 2>/dev/null; then
		ok "the /proc mount (skipped, needs fusepy in .venv)"
		return 0
	fi
	p=$(make_project)
	mnt="$WORK/vmproc"
	rm -rf "$mnt"
	mkdir -p "$mnt"
	if ! start_vm "$p"; then
		no "a VM starts"
		return 0
	fi

	local sock
	sock=$("$FIRECODE" list --ids 2>/dev/null | awk -v p="$p" '$2==p{print $1}' | head -1)
	sock=$(cat "$ROOT/runs/$sock/jail" 2>/dev/null)/firecracker-vsock.sock
	"$venv" "$ROOT/scripts/vmprocfs.py" "$sock" 1026 "$mnt" --ttl 2 \
		>"$WORK/vmprocfs.log" 2>&1 &
	local fuse_pid=$!
	wait_until "mounted" 20 mountpoint -q "$mnt" || true

	if mountpoint -q "$mnt"; then
		ok "the guest's /proc mounts"
	else
		no "the guest's /proc mounts" "$(tail -2 "$WORK/vmprocfs.log" 2>/dev/null)"
		kill "$fuse_pid" 2>/dev/null
		(cd "$p" && "$FIRECODE" down >/dev/null 2>&1)
		return 0
	fi

	local guest host
	guest=$(timeout 30 awk '/MemTotal/{print $2}' "$mnt/meminfo" 2>/dev/null)
	host=$(host_memtotal)
	if [[ -n $guest && $guest != "$host" ]]; then
		ok "reading it gives the guest's numbers ($guest vs $host kB)"
	else
		no "reading it gives the guest's numbers" "got [$guest] vs host [$host]"
	fi

	# Listing must not read what it lists. It used to, and `ls` of a few
	# hundred entries then took minutes and looked exactly like a hang.
	local began ended
	began=${EPOCHREALTIME/[.,]/}
	timeout 45 ls "$mnt" >/dev/null 2>&1
	ended=${EPOCHREALTIME/[.,]/}
	if (((ended - began) / 1000000 < 20)); then
		ok "listing it does not read every file in it ($(((ended - began) / 1000000))s)"
	else
		no "listing it does not read every file in it" "took $(((ended - began) / 1000000))s"
	fi

	# Anything the guest does not have has to come from this machine, or an
	# unmodified tool breaks for reasons unrelated to the VM.
	if [[ -n $(timeout 20 cat "$mnt/self/comm" 2>/dev/null) ]]; then
		ok "what the guest lacks falls through to the host"
	else
		no "what the guest lacks falls through to the host" "/self/comm was empty"
	fi

	fusermount -u "$mnt" 2>/dev/null || kill "$fuse_pid" 2>/dev/null
	(cd "$p" && "$FIRECODE" down >/dev/null 2>&1)
}

# -------------------------------------------------------------------- main

echo "firecode tests  ($([[ $QUICK -eq 1 ]] && echo "quick, no VMs" || echo "full, boots VMs"))"

run_test shellcheck
run_test denylist
run_test arg_massaging
run_test terminal_escapes
run_test prompt_required
run_test host_transcripts_untouched
run_test project_tree_untouched
run_test gitignore_excluded
run_test paths_mirror_host
run_test state_persists
run_test session_import_resumable
run_test results_come_back
run_test commits_are_reported_unlanded
run_test commit_reachability
run_test gc_keeps_unreachable_work
run_test no_relays
run_test concurrent_runs
run_test ro_image_cached
run_test jailed
run_test interactive
run_test vm_stops_completely
run_test child_dies_with_parent
run_test killed_vm_is_reported_dead
run_test proc_mirror
run_test proc_mounted

echo
if ((FAIL == 0)); then
	printf '\033[32m%d passed\033[0m\n' "$PASS"
	exit 0
fi
printf '\033[31m%d failed\033[0m, %d passed\n' "$FAIL" "$PASS"
printf '  %s\n' "${FAILED[@]}"
exit 1
