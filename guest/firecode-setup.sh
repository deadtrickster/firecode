#!/usr/bin/env bash
# firecode guest setup - runs inside the microVM, before the agent.
#
# Reproduces the host's layout inside the guest: same user, same uid, same
# home directory, project mounted at the path it has on the host. That is
# what lets a session recorded on the host be resumed in here unchanged -
# every absolute path in it still points at the right thing.
#
# Deliberately not "set -e": a failure in any one step must not stop the
# rest of the setup, otherwise a missing optional drive kills the whole run.
set -u

CONFIG_MNT=/opt/firecode/config
CTL_MNT=/opt/firecode/run
STATE=/var/lib/firecode

# systemd starts this with an empty environment, and git refuses to do
# anything at all without HOME.
export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log() { echo "[firecode] $*"; }

wait_for_label() {
	local label=$1 i
	for ((i = 0; i < 100; i++)); do
		[[ -e /dev/disk/by-label/$label ]] && return 0
		sleep 0.05
	done
	return 1
}

# mkdir -p, but every directory this actually creates belongs to the run user.
# Mount points for a project at, say, /tmp/scratch/thing mean inventing the
# parents, and a root-owned parent is not a detail: Claude Code refuses a temp
# directory it does not own, and builds write next to their source all the time.
mkdir_owned() {
	local path=$1 part="" seg
	local uid=${FIRECODE_UID:-0} gid=${FIRECODE_GID:-0}
	local IFS=/
	for seg in $path; do
		[[ -z $seg ]] && continue
		part="$part/$seg"
		if [[ ! -d $part ]]; then
			mkdir "$part" 2>/dev/null || return 1
			chown "$uid:$gid" "$part" 2>/dev/null
		fi
	done
}

mount_label() {
	local label=$1 target=$2
	shift 2
	mkdir_owned "$target"
	# The control drive is already mounted when this script re-execs itself
	# from that very drive.
	if mountpoint -q "$target"; then
		return 0
	fi
	if ! wait_for_label "$label"; then
		log "WARNING: no block device labelled $label"
		return 1
	fi
	if mount "$@" "/dev/disk/by-label/$label" "$target"; then
		log "mounted $label at $target"
		return 0
	fi
	log "WARNING: could not mount $label at $target"
	return 1
}

# Recreate the host's account, so paths under it and file ownership both line
# up. The agent runs as this user, not as root.
setup_user() {
	[[ -n ${FIRECODE_USER:-} && -n ${FIRECODE_UID:-} ]] || return 0

	# The base image ships its own "ubuntu" account on uid/gid 1000, which is
	# exactly the id a first desktop user has. Whoever is sitting on the id
	# has to go before the host's account can take it.
	local squatter
	# shellcheck disable=SC2153  # set in the env file sourced from the control drive
	if ! getent group "$FIRECODE_USER" >/dev/null; then
		squatter=$(getent group "$FIRECODE_GID" | cut -d: -f1)
		[[ -n $squatter ]] && groupdel -f "$squatter" 2>/dev/null
		groupadd -g "$FIRECODE_GID" "$FIRECODE_USER" 2>/dev/null
	fi
	if ! getent passwd "$FIRECODE_USER" >/dev/null; then
		squatter=$(getent passwd "$FIRECODE_UID" | cut -d: -f1)
		[[ -n $squatter ]] && userdel -f "$squatter" 2>/dev/null
		useradd -u "$FIRECODE_UID" -g "$FIRECODE_GID" -d "$FIRECODE_HOME" \
			-s /bin/bash -M "$FIRECODE_USER" 2>/dev/null
	fi
	if ! getent passwd "$FIRECODE_USER" >/dev/null; then
		log "WARNING: could not create $FIRECODE_USER, falling back to root"
		FIRECODE_USER=root
		return 0
	fi
	mkdir -p "$FIRECODE_HOME"
	chown "$FIRECODE_UID:$FIRECODE_GID" "$FIRECODE_HOME"

	# There is nothing in here worth protecting from its own user, and an
	# unattended agent cannot answer a password prompt.
	echo "$FIRECODE_USER ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/firecode
	chmod 0440 /etc/sudoers.d/firecode
	log "user $FIRECODE_USER ($FIRECODE_UID:$FIRECODE_GID) home $FIRECODE_HOME"
}

setup_network() {
	[[ -n ${FIRECODE_GUEST_IP:-} ]] || return 0
	if ! ip link show eth0 >/dev/null 2>&1; then
		log "no eth0, running without network"
		return 0
	fi
	ip addr add "$FIRECODE_GUEST_IP" dev eth0 2>/dev/null
	ip link set eth0 up
	[[ -n ${FIRECODE_GATEWAY:-} ]] && ip route add default via "$FIRECODE_GATEWAY" 2>/dev/null
	# systemd-resolved is masked in this image, so this is a plain file.
	# Docker could not bake these in, so they are written here.
	rm -f /etc/resolv.conf
	local ns
	for ns in ${FIRECODE_DNS:-1.1.1.1 8.8.8.8}; do
		echo "nameserver $ns" >>/etc/resolv.conf
	done
	log "network up: $FIRECODE_GUEST_IP via ${FIRECODE_GATEWAY:-none}"
}

# Services the host keeps on its loopback - MCP servers, a local llama-server,
# anything else asked for with --host-port. Firecracker forwards a guest vsock
# connection to CID 2 port N onto the host unix socket <uds_path>_N, where a
# host-side socat forwards it to 127.0.0.1:N. So localhost:N in here is
# localhost:N out there, and no configuration on either side has to change.
setup_relays() {
	local p ports=${FIRECODE_RELAY_PORTS:-}
	[[ -n $ports ]] || return 0
	if ! command -v socat >/dev/null 2>&1; then
		log "WARNING: socat missing, host services will not be reachable"
		return 0
	fi
	for p in $ports; do
		# Transient units so the relays outlive this oneshot service.
		if systemd-run --unit="firecode-relay-$p" --collect --quiet \
			socat "TCP-LISTEN:$p,bind=127.0.0.1,reuseaddr,fork" \
			"VSOCK-CONNECT:2:$p" 2>/dev/null; then
			log "localhost:$p reaches the host"
		else
			log "WARNING: could not start the relay for port $p"
		fi
	done
}

# Extra directories the run was given for reference, read-only, each at the
# same absolute path it has on the host.
mount_extras() {
	local spec label target
	for spec in ${FIRECODE_EXTRA:-}; do
		label=${spec%%:*}
		target=${spec#*:}
		[[ -n $label && -n $target ]] || continue
		mount_label "$label" "$target" -o ro
	done
}

# The project, writable, at the path it has on the host - and only there.
mount_project() {
	local target=${FIRECODE_PROJECT:-}
	[[ -n $target ]] || return 0
	mkdir_owned "$target"
	mount_label firecode-src "$target" || return 0

	# mkfs.ext4 -d takes ownership of everything it copies from the staging
	# directory, but the filesystem's own root inode is made by mke2fs and
	# belongs to root. Without this the agent cannot create a single file in
	# the top level of its own project.
	chown "${FIRECODE_UID:-0}:${FIRECODE_GID:-0}" "$target"

	# Every ext4 filesystem gets a lost+found. In the top level of a project
	# it is just a root-owned directory the agent has to stop and think about,
	# and this drive is thrown away rather than fsck'd.
	rm -rf "$target/lost+found"
	# Deliberately no /src symlink. A second name for the project is a second
	# name the agent can put in a commit message or a path, where it means
	# nothing outside this VM. The project is at its host path, and that is
	# the only place it is.
	[[ -L /src ]] && rm -f /src
	[[ -d /src ]] && rmdir /src 2>/dev/null
}

# Give the agent's home directory the host's configuration, writable, and on
# a drive that outlives the VM so sessions are still here on the next run.
overlay_home() {
	local name=$1
	local lower="$CONFIG_MNT/$name" target="${FIRECODE_HOME:-/root}/.$name"
	[[ -d $lower ]] || return 0
	mkdir -p "$target" "$STATE/upper/$name" "$STATE/work/$name"
	if mount -t overlay "firecode-$name" \
		-o "lowerdir=$lower,upperdir=$STATE/upper/$name,workdir=$STATE/work/$name" \
		"$target" 2>/dev/null; then
		log "$target is a writable overlay kept between runs"
	else
		log "no overlayfs, copying $target instead"
		cp -a "$lower/." "$target/" 2>/dev/null || true
	fi
	chown -R "${FIRECODE_UID:-0}:${FIRECODE_GID:-0}" "$target" 2>/dev/null || true
}

setup_git() {
	local as=(runuser -u "${FIRECODE_USER:-root}" --)
	[[ -n ${FIRECODE_GIT_NAME:-} ]] &&
		"${as[@]}" git config --global user.name "$FIRECODE_GIT_NAME"
	[[ -n ${FIRECODE_GIT_EMAIL:-} ]] &&
		"${as[@]}" git config --global user.email "$FIRECODE_GIT_EMAIL"
	# No signing key in here, and an unattended agent cannot answer a
	# passphrase prompt.
	"${as[@]}" git config --global commit.gpgsign false
	"${as[@]}" git config --global tag.gpgsign false
	"${as[@]}" git config --global --add safe.directory '*'
	return 0
}

main() {
	mkdir -p "$STATE" "$CTL_MNT" "$CONFIG_MNT"

	mount_label firecode-ctl "$CTL_MNT" -o ro

	# The harness ships its own guest scripts on the control drive, so fixing
	# one does not mean rebuilding the whole rootfs image. This baked copy is
	# only the bootstrap that gets the control drive mounted.
	if [[ -x $CTL_MNT/firecode-setup.sh && -z ${FIRECODE_REEXEC:-} ]]; then
		export FIRECODE_REEXEC=1
		log "using the harness scripts from the control drive"
		exec "$CTL_MNT/firecode-setup.sh"
	fi

	# shellcheck source=/dev/null
	[[ -f $CTL_MNT/env ]] && . "$CTL_MNT/env"

	setup_user

	# Extras first: the project can sit inside one of them, and then its
	# mount point has to already exist.
	mount_extras
	mount_project
	mount_label firecode-cfg "$CONFIG_MNT" -o ro

	# Docker refuses to bake these into an image, so they are set here.
	echo firecode >/etc/hostname
	hostname firecode 2>/dev/null || true
	printf '127.0.0.1 localhost firecode\n::1 localhost\n' >/etc/hosts

	setup_network
	setup_relays

	# Must be mounted before the overlays: it holds their upper layers, which
	# is what makes the agent's sessions survive the VM.
	mount_label firecode-state "$STATE"

	overlay_home claude
	overlay_home opencode

	# opencode keeps its credentials and its provider/MCP config outside
	# ~/.opencode, so they have to be put back where it looks for them.
	local home=${FIRECODE_HOME:-/root}
	if [[ -f $CONFIG_MNT/opencode-share/auth.json ]]; then
		mkdir -p "$home/.local/share/opencode"
		cp -f "$CONFIG_MNT/opencode-share/auth.json" "$home/.local/share/opencode/auth.json"
		chmod 600 "$home/.local/share/opencode/auth.json"
	fi
	if [[ -d $CONFIG_MNT/opencode-config ]]; then
		mkdir -p "$home/.config/opencode"
		cp -a "$CONFIG_MNT/opencode-config/." "$home/.config/opencode/"
	fi
	chown -R "${FIRECODE_UID:-0}:${FIRECODE_GID:-0}" \
		"$home/.local" "$home/.config" 2>/dev/null || true
	if [[ -f $CONFIG_MNT/claude.json ]]; then
		# Claude rewrites this file, so it must be a real copy, not a symlink
		# onto the read-only drive.
		local conf="${FIRECODE_HOME:-/root}/.claude.json"
		cp -f "$CONFIG_MNT/claude.json" "$conf"
		# Per-project state was stripped on the host - it named host paths for
		# projects that are not in here. But the project *is* here, and without
		# an entry marking it trusted, an interactive session opens on "is this
		# a folder you trust?" instead of on the conversation. In a VM built
		# from that very folder the question has one answer.
		if [[ -n ${FIRECODE_PROJECT:-} ]] && command -v python3 >/dev/null 2>&1; then
			python3 - "$conf" "$FIRECODE_PROJECT" <<'PY' 2>/dev/null || true
import json, sys
path, project = sys.argv[1], sys.argv[2]
with open(path) as fh:
    d = json.load(fh)
d.setdefault("projects", {}).setdefault(project, {})["hasTrustDialogAccepted"] = True
with open(path, "w") as fh:
    json.dump(d, fh, indent=2)
PY
		fi
		chown "${FIRECODE_UID:-0}:${FIRECODE_GID:-0}" "$conf"
	fi

	# The agent binaries live on the read-only config drive so they always
	# match the host's installed version.
	if [[ -d $CONFIG_MNT/bin ]]; then
		local b
		for b in "$CONFIG_MNT"/bin/*; do
			[[ -x $b ]] || continue
			ln -sf "$b" "/usr/local/bin/$(basename "$b")"
		done
	fi

	setup_git

	if [[ -f $CTL_MNT/context.md ]]; then
		cp -f "$CTL_MNT/context.md" "${FIRECODE_HOME:-/root}/FIRECODE.md"
	fi

	# Interactive sessions come in over vsock with a pty of their own, rather
	# than over the serial console, because firecracker's serial input rewrites
	# CR to LF and a raw-mode TUI never sees Enter. socat hands each connection
	# a pty and relays the bytes untouched.
	# Always, not just for interactive runs: socat forks a pty per connection,
	# so this is also how you get a second shell inside a VM that is busy
	# doing something else - to try what it just built, or watch it work.
	if [[ -x $CTL_MNT/console.sh ]]; then
		if systemd-run --unit=firecode-console --collect --quiet \
			socat "VSOCK-LISTEN:${FIRECODE_CONSOLE_PORT:-1024},fork,reuseaddr" \
			"EXEC:$CTL_MNT/console.sh,pty,setsid,ctty,stderr" 2>/dev/null; then
			log "console ready on vsock port ${FIRECODE_CONSOLE_PORT:-1024}"
		else
			log "WARNING: could not start the vsock console"
		fi
	fi

	# One command at a time, for a program rather than a person: the console
	# hands out a pty, this returns output and an exit status.
	if [[ -x $CTL_MNT/execserver.sh ]]; then
		local err
		if err=$(systemd-run --unit=firecode-exec --collect --quiet \
			socat "VSOCK-LISTEN:${FIRECODE_EXEC_PORT:-1026},fork,reuseaddr" \
			"EXEC:$CTL_MNT/execserver.sh" 2>&1); then
			log "exec channel ready on vsock port ${FIRECODE_EXEC_PORT:-1026}"
		else
			log "WARNING: exec channel did not start: $err"
		fi
	fi

	# File transfer in and out of a running VM. Firecracker cannot share a
	# host directory, so this is the only live channel there is.
	if [[ -x $CTL_MNT/fileserver.sh ]]; then
		systemd-run --unit=firecode-files --collect --quiet \
			socat "VSOCK-LISTEN:${FIRECODE_FILES_PORT:-1025},fork,reuseaddr" \
			"EXEC:$CTL_MNT/fileserver.sh" 2>/dev/null ||
			log "WARNING: could not start the file channel"
	fi

	# firecode-agent.service declares Conflicts=serial-getty@ttyS0.service so the
	# agent owns the console. systemd acts on that when the job is queued, not
	# when the unit's condition is evaluated - so in interactive mode, where
	# the agent is skipped for want of an args file, the getty is stopped for a
	# unit that never runs and the console is left dead. Start it back.
	if [[ ${FIRECODE_MODE:-} != auto ]]; then
		systemctl start --no-block serial-getty@ttyS0.service 2>/dev/null ||
			log "WARNING: could not start the console getty"
	fi

	log "setup complete (mode=${FIRECODE_MODE:-interactive} agent=${FIRECODE_AGENT:-none})"
}

main "$@"
