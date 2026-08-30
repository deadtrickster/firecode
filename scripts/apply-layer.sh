#!/usr/bin/env bash
#
# APPLY A PROJECT'S DECLARED LAYER TO ITS RUNNING VM.
#
#   scripts/apply-layer.sh --vm NAME --project DIR [--dry-run] [--force]
#
# 01M0G8AM6R2BGPCWZQMV6321DR, the operator: "fc vms support per project layers.
# i should be able to manage them from the flowy ui. Dockerfile style. also must
# be available for agent to edit."
#
# WHAT IT REPLACES. ensure_layer() makes one empty 16G sparse ext4 per project
# and nothing ever puts anything in it declaratively - it fills only as a guest
# happens to write. So a project's toolchain is whatever somebody installed by
# hand, most recently through an UNTRACKED vm-provision.sh sitting in a scratch
# directory. Untracked means unreviewed, unversioned, and not applied to a fresh
# guest unless a person remembers. That is the drift that cost a night on
# 2026-08-28: go1.22 in the guest against go1.26 on the box, one check red in
# one place and green in the other on the same commit.
#
# THE FILE. <project>/firecode.layer, Dockerfile-ish and deliberately small:
#
#   ENV KEY=value        exported for every RUN below it
#   RUN  <shell>         run in the guest AS ROOT, in the project directory
#   #    comment
#
# NO FROM. The base is the firecode image, and a FROM line would be a claim
# about reproducibility this cannot keep. NO COPY either: the project directory
# is already mounted in the guest at the same absolute path, so there is nothing
# to copy - a COPY would be a second, staler way to say what a path already says.
#
# THE STAMP IS THE WHOLE DESIGN. The file's sha256 is written into the guest
# after a successful apply. Same hash, nothing runs - that is what makes this
# safe to call on every boot. And the stamp is written ONLY if every line
# succeeded: a half-applied layer that claims to be current is worse than one
# that claims nothing, because the next run trusts it and the missing package
# turns up somewhere else entirely.
set -euo pipefail

SELF=$(readlink -f "$0")
ROOT=${FIRECODE_ROOT:-$(cd "$(dirname "$SELF")/.." && pwd)}
FIRECODE=${FIRECODE_BIN:-$ROOT/bin/firecode}
# Overridable so the check below can build a guest it owns. The default is the
# only one anything real should use.
STAMP=${FIRECODE_LAYER_STAMP:-/var/lib/firecode-layer.sha}

vm=""
project=""
dry=no
force=no
while [ $# -gt 0 ]; do
	case $1 in
	--vm)
		vm=${2:?--vm needs a name}
		shift 2
		;;
	--project)
		project=${2:?--project needs a directory}
		shift 2
		;;
	--dry-run)
		dry=yes
		shift
		;;
	--force)
		force=yes
		shift
		;;
	-h | --help)
		sed -n '2,34p' "$SELF" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		printf 'apply-layer: unknown argument %s\n' "$1" >&2
		exit 2
		;;
	esac
done

[ -n "$project" ] || {
	printf 'apply-layer: --project is required\n' >&2
	exit 2
}
spec="$project/firecode.layer"

# A PROJECT WITH NO LAYER FILE IS NOT AN ERROR AND IS NOT A LAYER EITHER. It is
# said out loud rather than exiting 0 quietly, because "applied nothing" and
# "there was nothing to apply" reaching the caller as the same silence is how a
# provisioning step gets believed to have run.
if [ ! -f "$spec" ]; then
	printf 'no %s - this project declares no layer\n' "$spec"
	exit 0
fi

want=$(sha256sum "$spec" | cut -d' ' -f1)

# NO `--` BEFORE THE COMMAND. `firecode in VM <command...>` takes the command
# as plain trailing words; a `--` is passed straight through and bash reads it
# as its own argument, prints its usage and exits non-zero. The first apply
# here failed that way and reported the LAYER's line 3 as the failure, which
# was a true sentence about the wrong thing.
# ADDRESSED BY PROJECT WHEN NO VM IS NAMED, because the VM's name is not
# reliably the project directory's basename and guessing it is the kind of
# assumption that works until somebody names a VM something else. `firecode in`
# resolves the project itself; that is its job, not this script's.
guest() {
	if [ -n "$vm" ]; then
		"$FIRECODE" in "$vm" bash -lc "$1"
	else
		"$FIRECODE" in --project "$project" bash -lc "$1"
	fi
}

have=$(guest "cat $STAMP 2>/dev/null || true" 2>/dev/null | tr -d '[:space:]' || true)
if [ "$have" = "$want" ] && [ "$force" = no ]; then
	printf 'layer is current (%s)\n' "${want:0:12}"
	exit 0
fi

# Parsed here rather than piped into the guest whole, so a line that fails is
# NAMED. A single heredoc would report "the script failed" about a file with
# twenty lines in it.
env_lines=""
run_lines=()
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
	lineno=$((lineno + 1))
	case $line in
	'' | '#'*) continue ;;
	ENV\ *) env_lines="$env_lines export ${line#ENV };" ;;
	RUN\ *) run_lines+=("$lineno:${line#RUN }") ;;
	FROM\ * | COPY\ *)
		printf 'apply-layer: %s:%s uses %s, which this format does not have - see --help for why\n' \
			"$spec" "$lineno" "${line%% *}" >&2
		exit 2
		;;
	*)
		printf 'apply-layer: %s:%s is not ENV, RUN or a comment: %s\n' "$spec" "$lineno" "$line" >&2
		exit 2
		;;
	esac
done <"$spec"

if [ ${#run_lines[@]} -eq 0 ]; then
	printf '%s declares no RUN lines\n' "$spec"
	exit 0
fi

printf 'applying %s (%s), %s step(s)\n' "$spec" "${want:0:12}" "${#run_lines[@]}"
for entry in "${run_lines[@]}"; do
	n=${entry%%:*}
	cmd=${entry#*:}
	printf '  %s:%s  %s\n' "$(basename "$spec")" "$n" "$cmd"
	[ "$dry" = yes ] && continue
	# AS ROOT, because "Dockerfile style" means root and because the first
	# test of this ran as uid 1000 and died on `touch /var/lib/...` with
	# Permission denied. The alternative - every line in the file writing its
	# own `sudo -n` - makes the file a worse copy of the untracked shell script
	# this exists to replace. sudo -n so a guest without passwordless root
	# fails loudly here rather than hanging on a prompt nobody can answer.
	if ! guest "sudo -n bash -c 'set -euo pipefail; cd $project 2>/dev/null || true; $env_lines $cmd'"; then
		printf 'apply-layer: %s:%s failed - the stamp is NOT written, so this runs again next time\n' \
			"$spec" "$n" >&2
		exit 1
	fi
done

if [ "$dry" = yes ]; then
	printf 'dry run: nothing was applied and no stamp written\n'
	exit 0
fi

guest "printf '%s\\n' '$want' | sudo -n tee $STAMP >/dev/null"
printf 'applied, stamped %s\n' "${want:0:12}"
