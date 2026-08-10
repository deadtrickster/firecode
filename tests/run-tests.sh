#!/usr/bin/env bash
# firellm tests. No framework, no dependencies beyond what firellm needs.
#
#   firellm test           everything, boots VMs, a few minutes
#   firellm test --quick   host-side only, no VM boots, seconds
#   firellm test <name>    one test by name
#
# VM tests run with --no-jail --no-net so they need no privileges.
#
# shellcheck disable=SC2329  # tests are dispatched by name, not called directly
# shellcheck disable=SC2016  # single quotes are deliberate: these run in the guest
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIRELLM="$ROOT/bin/firellm"
WORK=$(mktemp -d /tmp/firellm-tests.XXXXXX)

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
	git -C "$dir" -c user.name=t -c user.email=t@t commit -qm init 2>/dev/null
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
	(cd "$project" && timeout 240 "$FIRELLM" exec --no-jail --no-net "$@" \
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

	local before after
	before=$(find "$real" -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum)

	local project
	project=$(make_project)
	# Import for this very repo, which has real host sessions.
	(cd "$ROOT" && "$FIRELLM" claude --import-sessions --no-jail --no-net \
		--workdir "$project" --timeout 1 -- --version >/dev/null 2>&1)

	after=$(find "$real" -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum)
	check "host transcripts are byte-identical after an import" "$before" "$after"

	local count_before count_after
	count_before=$(find "$real" -name '*.jsonl' | wc -l)
	count_after=$(find "$real" -name '*.jsonl' | wc -l)
	check "no host transcript added or removed" "$count_before" "$count_after"
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

	out=$(FIRELLM_DENY_FILE="$deny" "$FIRELLM" exec --workdir "$WORK/secret" true 2>&1)
	contains "denied as --workdir" "refusing" "$out"

	out=$(FIRELLM_DENY_FILE="$deny" "$FIRELLM" exec --workdir "$WORK/secret/inner" true 2>&1)
	contains "denied as a subdirectory of a listed path" "refusing" "$out"

	out=$(FIRELLM_DENY_FILE="$deny" "$FIRELLM" exec --workdir "$project" \
		--add-dir "$WORK/secret" true 2>&1)
	contains "denied as --add-dir" "refusing" "$out"

	# The built-in list stands on its own, with no deny file at all.
	mkdir -p "$HOME/.aws"
	out=$(FIRELLM_DENY_FILE=/nonexistent "$FIRELLM" exec --workdir "$HOME/.aws" true 2>&1)
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
	out=$(FIRELLM_CLAUDE_HOME="$fake" in_vm "$project" --import-sessions -- \
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
	out=$(cd "$project" && timeout 240 "$FIRELLM" exec --no-jail --no-net -- \
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
	rm -rf "$result"
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
	if ! sudo -n true 2>/dev/null; then
		ok "jailed boot (skipped, needs passwordless sudo for the jailer)"
		return
	fi
	project=$(make_project)
	out=$(cd "$project" && timeout 240 "$FIRELLM" exec --no-net -- \
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
	a="$WORK/concurrent-a.log"
	b="$WORK/concurrent-b.log"

	(cd "$project" && timeout 240 "$FIRELLM" exec --no-jail -- \
		bash -c 'sleep 6; echo A-DONE' >"$a" 2>&1) &
	local pid_a=$!
	sleep 2
	(cd "$project" && timeout 240 "$FIRELLM" exec --no-jail -- \
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
	taps=$(grep -ho 'fcllm[0-9]*' "$a" "$b" | sort -u | wc -l)
	check "they used different tap devices" "2" "$taps"
	contains "the second one is told its session is not resumable" \
		"not be resumable" "$(cat "$b")"
}

test_arg_massaging() {
	local project out
	project=$(make_project)
	# Unattended claude gets -p and permission bypass added, so it does not
	# sit at a prompt nobody is watching.
	out=$("$FIRELLM" claude --workdir "$project" --no-jail --no-net \
		--timeout 1 "do a thing" 2>&1 | sed -n 's/.*agent command: //p' | head -1)
	contains "unattended claude gets --print" "-p" "$out"
	contains "unattended claude gets permission bypass" "--dangerously-skip-permissions" "$out"

	out=$("$FIRELLM" claude --workdir "$project" --no-jail --no-net --no-auto-flags \
		--timeout 1 "do a thing" 2>&1 | sed -n 's/.*agent command: //p' | head -1)
	if [[ $out != *"--dangerously-skip-permissions"* ]]; then
		ok "--no-auto-flags leaves the command alone"
	else
		no "--no-auto-flags leaves the command alone" "$out"
	fi
}

test_shellcheck() {
	local f out=""
	for f in "$ROOT/bin/firellm" "$ROOT"/scripts/*.sh "$ROOT"/guest/*.sh \
		"$ROOT"/tests/*.sh; do
		shellcheck "$f" >/dev/null 2>&1 || out="$out $(basename "$f")"
	done
	if command -v shellcheck >/dev/null 2>&1; then
		check "every script passes shellcheck" "" "$out"
	else
		ok "shellcheck not installed (skipped)"
	fi
	if python3 -m py_compile "$ROOT/mcp/firellm-spawn.py" 2>/dev/null; then
		ok "the spawn server parses"
	else
		no "the spawn server parses"
	fi
}

# -------------------------------------------------------------------- main

echo "firellm tests  ($([[ $QUICK -eq 1 ]] && echo "quick, no VMs" || echo "full, boots VMs"))"

run_test shellcheck
run_test denylist
run_test arg_massaging
run_test host_transcripts_untouched
run_test project_tree_untouched
run_test gitignore_excluded
run_test paths_mirror_host
run_test state_persists
run_test session_import_resumable
run_test results_come_back
run_test no_relays
run_test concurrent_runs
run_test ro_image_cached
run_test jailed

echo
if ((FAIL == 0)); then
	printf '\033[32m%d passed\033[0m\n' "$PASS"
	exit 0
fi
printf '\033[31m%d failed\033[0m, %d passed\n' "$FAIL" "$PASS"
printf '  %s\n' "${FAILED[@]}"
exit 1
