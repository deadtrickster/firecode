#!/usr/bin/env bash
# One file transfer, on the far end of a vsock connection.
#
# Firecracker has no virtio-fs and no 9p - a host directory cannot be mounted
# into the guest at all, by design. vsock is the only live channel there is,
# so moving files means streaming them over it.
#
# The protocol is one line, then a tar stream:
#
#   GET <path>    the guest sends <path> as a tar stream
#   PUT <path>    the guest reads a tar stream and unpacks it into <path>
#
# Runs as the same user the agent does, so it can reach exactly what the agent
# can reach and nothing else.
set -u

# shellcheck source=/dev/null
[[ -f /opt/firellm/run/env ]] && . /opt/firellm/run/env
RUN_USER=${FIRELLM_USER:-root}

read -r verb path || exit 1
# Strip the carriage return a line-oriented sender may have added.
path=${path%$'\r'}

as_user() {
	if [[ $RUN_USER == root ]]; then
		"$@"
	else
		runuser -u "$RUN_USER" -- "$@"
	fi
}

case "$verb" in
GET)
	[[ -e $path ]] || exit 2
	if [[ -d $path ]]; then
		as_user tar -C "$path" -cf - .
	else
		as_user tar -C "$(dirname "$path")" -cf - "$(basename "$path")"
	fi
	;;
PUT)
	as_user mkdir -p "$path" || exit 2
	as_user tar -C "$path" -xf -
	;;
*)
	exit 3
	;;
esac
