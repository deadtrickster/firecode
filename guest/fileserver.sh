#!/usr/bin/env bash
# One file transfer, on the far end of a vsock connection.
#
# Firecracker has no virtio-fs and no 9p - a host directory cannot be mounted
# into the guest at all, by design. vsock is the only live channel there is,
# so moving files means streaming them over it.
#
# The protocol is one line, then a stream:
#
#   GET <path>                      the guest sends <path> as a tar stream
#   PUTFILE <size> <mode> <path>    the guest reads exactly <size> bytes and
#                                   makes them the regular file <path>
#   PUTDIR <path>                   the guest reads a tar stream and unpacks it
#                                   into the directory <path>
#
# A PUT is answered with one line, "OK" or "ERR <reason>", and the sender
# reports success only on "OK". There used to be one PUT that treated every
# destination as a directory and answered nothing: a file copied onto an
# existing file left the old contents and still looked like a success, and onto
# a missing path it made a DIRECTORY of that name with the file inside. Three
# runs executed a stale script because of it.
#
# The rules for a file:
#   missing path           written there; missing parents are created
#   existing regular file  replaced atomically - a temp file beside it, then a
#                          rename, so a reader sees the old file or the new one
#   existing directory     refused. To copy into a directory, the sender names
#                          it with a trailing slash and sends <dir>/<name>.
#   anything else          refused (a symlink is not written through)
#   a parent that is not a directory: refused, and nothing is created
# For a directory: unpacked into it if it is one or is missing, refused if the
# path is anything else. Contents are merged, as tar does.
#
# Runs as the same user the agent does, so it can reach exactly what the agent
# can reach and nothing else.
set -u

# shellcheck source=/dev/null
[[ -f /opt/firecode/run/env ]] && . /opt/firecode/run/env
RUN_USER=${FIRECODE_USER:-root}

read -r verb path || exit 1
# Strip the carriage return a line-oriented sender may have added.
path=${path%$'\r'}

ok() { echo "OK"; }
refuse() {
	echo "ERR $*"
	exit 2
}

# The parent of a file about to be written: there, a directory, or refused.
# Never a mkdir over something that exists as a file.
ensure_parent() {
	local parent=$1 err
	if [[ -e $parent || -L $parent ]]; then
		[[ -d $parent ]] || refuse "$parent exists and is not a directory"
		return 0
	fi
	err=$(as_user mkdir -p -- "$parent" 2>&1) || refuse "cannot create $parent: $err"
}

put_file() {
	local size=$1 mode=$2 target=$3 parent base tmp got err
	[[ $size =~ ^[0-9]+$ && $mode =~ ^[0-7]+$ && -n $target ]] ||
		refuse "malformed PUTFILE line"
	if [[ -L $target ]]; then
		refuse "$target is a symlink - not writing through it"
	elif [[ -d $target ]]; then
		refuse "$target is a directory - to copy into it, end the destination with a slash"
	elif [[ -e $target && ! -f $target ]]; then
		refuse "$target exists and is not a regular file"
	fi
	parent=$(dirname -- "$target")
	base=$(basename -- "$target")
	ensure_parent "$parent"
	tmp=$(as_user mktemp "$parent/.$base.firecode-XXXXXX" 2>&1) ||
		refuse "cannot write in $parent: $tmp"
	# Exactly the bytes announced, then checked: a sender that died halfway
	# must not leave half a file where the whole one was.
	# shellcheck disable=SC2016  # expanded by the inner sh, from its arguments
	as_user sh -c 'exec head -c "$1" >"$2"' sh "$size" "$tmp"
	got=$(wc -c <"$tmp" | tr -d ' ')
	if [[ $got != "$size" ]]; then
		rm -f -- "$tmp"
		refuse "short transfer: $got of $size bytes - $target left as it was"
	fi
	as_user chmod "$mode" "$tmp" 2>/dev/null || true
	# The rename is the replacement. Same directory, so it is atomic.
	if ! err=$(as_user mv -f -- "$tmp" "$target" 2>&1); then
		rm -f -- "$tmp"
		refuse "cannot replace $target: $err"
	fi
	ok
}

put_dir() {
	local target=$1 err
	[[ -n $target ]] || refuse "malformed PUTDIR line"
	if [[ -e $target || -L $target ]]; then
		[[ -d $target ]] || refuse "$target exists and is not a directory"
	else
		err=$(as_user mkdir -p -- "$target" 2>&1) || refuse "cannot create $target: $err"
	fi
	err=$(as_user tar -C "$target" -xf - 2>&1 >/dev/null) || refuse "unpacking into $target failed: $err"
	ok
}

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
PUTFILE)
	read -r size mode path <<<"$path"
	put_file "$size" "$mode" "$path"
	;;
PUTDIR)
	put_dir "$path"
	;;
*)
	exit 3
	;;
esac
