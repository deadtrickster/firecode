#!/usr/bin/env bash
# One command, on the far end of a vsock connection.
#
# The console gives a pty for a person; this is for a program. It takes a
# command, runs it as the agent's user in the project directory, streams what
# it prints, and finishes with the exit status - so a caller can tell the
# difference between a test suite that passed and one that could not start.
#
# Protocol, because something has to be:
#
#   line 1   working directory, or "-" for the project
#   line 2   the command, run through a shell
#   then     everything it printed, verbatim
#   last     a line "__firecode_exit <status>"
#
# socat forks one of these per connection, so several can run at once.
set -u

# shellcheck source=/dev/null
[[ -f /opt/firecode/run/env ]] && . /opt/firecode/run/env

RUN_USER=${FIRECODE_USER:-root}
RUN_HOME=${FIRECODE_HOME:-/root}
PROJECT=${FIRECODE_PROJECT:-$RUN_HOME}

read -r cwd || exit 1
read -r cmd || exit 1
cwd=${cwd%$'\r'}
cmd=${cmd%$'\r'}
[[ $cwd == "-" || -z $cwd ]] && cwd=$PROJECT

declare -a env=(
	"HOME=$RUN_HOME"
	"USER=$RUN_USER"
	"LOGNAME=$RUN_USER"
	"IS_SANDBOX=1"
	"FIRECODE=1"
	"TERM=dumb"
	"PATH=/opt/mise/shims:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
	"MISE_DATA_DIR=/opt/mise"
	"MISE_CONFIG_DIR=/opt/mise/config"
	"MISE_STATE_DIR=/opt/mise/state"
	"MISE_CACHE_DIR=/var/cache/mise"
)

rc=0
if [[ $RUN_USER == root ]]; then
	(cd "$cwd" && env "${env[@]}" bash -lc "$cmd") 2>&1 || rc=$?
else
	runuser -u "$RUN_USER" -- bash -c \
		"cd $(printf '%q' "$cwd") && exec env $(printf '%q ' "${env[@]}") bash -lc $(printf '%q' "$cmd")" 2>&1 || rc=$?
fi

# The trailer is how the caller learns the status; without it a failed command
# and a command that printed nothing look the same.
printf '__firecode_exit %d\n' "$rc"
