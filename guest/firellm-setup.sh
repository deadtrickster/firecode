#!/usr/bin/env bash
# firellm guest setup - runs inside the microVM, before the agent.
#
# Mounts the firellm drives, configures networking, relays the host's MCP
# servers over vsock and lays out the agent's home directory. Started by
# firellm-mounts.service, which is ordered before firellm-agent.service.
#
# Deliberately not "set -e": a failure in any one step must not stop the
# rest of the setup, otherwise a missing optional drive kills the whole run.
set -u

CONFIG_MNT=/opt/firellm/config
CTL_MNT=/opt/firellm/run
SRC_MNT=/src
STATE=/var/lib/firellm

# systemd starts this with an empty environment, and git refuses to do
# anything at all without HOME.
export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log() { echo "[firellm] $*"; }

wait_for_label() {
	local label=$1 i
	for ((i = 0; i < 100; i++)); do
		[[ -e /dev/disk/by-label/$label ]] && return 0
		sleep 0.05
	done
	return 1
}

mount_label() {
	local label=$1 target=$2
	shift 2
	mkdir -p "$target"
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

# Give ~/.<name> the contents of the read-only config drive, but writable.
# The agents rewrite their own config and history constantly, so a plain
# bind mount of the read-only drive is not enough.
overlay_home() {
	local name=$1
	local lower="$CONFIG_MNT/$name" target="/root/.$name"
	[[ -d $lower ]] || return 0
	mkdir -p "$target" "$STATE/upper/$name" "$STATE/work/$name"
	if mount -t overlay "firellm-$name" \
		-o "lowerdir=$lower,upperdir=$STATE/upper/$name,workdir=$STATE/work/$name" \
		"$target" 2>/dev/null; then
		log "$target is a writable overlay on the read-only config drive"
	else
		log "no overlayfs, copying ~/.$name instead"
		cp -a "$lower/." "$target/" 2>/dev/null || true
	fi
}

setup_network() {
	[[ -n ${FIRELLM_GUEST_IP:-} ]] || return 0
	if ! ip link show eth0 >/dev/null 2>&1; then
		log "no eth0, running without network"
		return 0
	fi
	ip addr add "$FIRELLM_GUEST_IP" dev eth0 2>/dev/null
	ip link set eth0 up
	[[ -n ${FIRELLM_GATEWAY:-} ]] && ip route add default via "$FIRELLM_GATEWAY" 2>/dev/null
	# systemd-resolved is masked in this image, so this is a plain file.
	# Docker could not bake these in, so they are written here.
	rm -f /etc/resolv.conf
	local ns
	for ns in ${FIRELLM_DNS:-1.1.1.1 8.8.8.8}; do
		echo "nameserver $ns" >>/etc/resolv.conf
	done
	log "network up: $FIRELLM_GUEST_IP via ${FIRELLM_GATEWAY:-none}"
}

# Services the host keeps on its loopback - MCP servers, a local llama-server,
# anything else asked for with --host-port. Firecracker forwards a guest vsock
# connection to CID 2 port N onto the host unix socket <uds_path>_N, where a
# host-side socat forwards it to 127.0.0.1:N. So localhost:N in here is
# localhost:N out there, and no configuration on either side has to change.
setup_relays() {
	local p ports=${FIRELLM_RELAY_PORTS:-${FIRELLM_MCP_PORTS:-}}
	[[ -n $ports ]] || return 0
	if ! command -v socat >/dev/null 2>&1; then
		log "WARNING: socat missing, host services will not be reachable"
		return 0
	fi
	for p in $ports; do
		# Transient units so the relays outlive this oneshot service.
		if systemd-run --unit="firellm-relay-$p" --collect --quiet \
			socat "TCP-LISTEN:$p,bind=127.0.0.1,reuseaddr,fork" \
			"VSOCK-CONNECT:2:$p" 2>/dev/null; then
			log "localhost:$p reaches the host"
		else
			log "WARNING: could not start the relay for port $p"
		fi
	done
}

# Extra host directories the run was given for context, as read-only copies.
# Nothing written here goes anywhere - only /src is copied back out.
mount_extras() {
	local spec label target
	for spec in ${FIRELLM_EXTRA:-}; do
		label=${spec%%:*}
		target=${spec#*:}
		[[ -n $label && -n $target ]] || continue
		mount_label "$label" "$target" -o ro
	done
}

setup_git() {
	[[ -n ${FIRELLM_GIT_NAME:-} ]] && git config --global user.name "$FIRELLM_GIT_NAME"
	[[ -n ${FIRELLM_GIT_EMAIL:-} ]] && git config --global user.email "$FIRELLM_GIT_EMAIL"
	# No signing key in here, and an unattended agent cannot answer a passphrase.
	git config --global commit.gpgsign false
	git config --global tag.gpgsign false
	git config --global --add safe.directory '*'
	return 0
}

main() {
	mkdir -p "$STATE" "$SRC_MNT" "$CTL_MNT" "$CONFIG_MNT"

	mount_label firellm-ctl "$CTL_MNT" -o ro

	# The harness ships its own guest scripts on the control drive, so fixing
	# one does not mean rebuilding the whole rootfs image. This baked copy is
	# only the bootstrap that gets the control drive mounted.
	if [[ -x $CTL_MNT/firellm-setup.sh && -z ${FIRELLM_REEXEC:-} ]]; then
		export FIRELLM_REEXEC=1
		log "using the harness scripts from the control drive"
		exec "$CTL_MNT/firellm-setup.sh"
	fi

	# shellcheck source=/dev/null
	[[ -f $CTL_MNT/env ]] && . "$CTL_MNT/env"

	mount_label firellm-src "$SRC_MNT"
	mount_label firellm-cfg "$CONFIG_MNT" -o ro

	# Docker refuses to bake these into an image, so they are set here.
	echo firellm >/etc/hostname
	hostname firellm 2>/dev/null || true
	printf '127.0.0.1 localhost firellm\n::1 localhost\n' >/etc/hosts

	setup_network
	setup_relays
	mount_extras

	# Must be mounted before the overlays: it holds their upper layers, which
	# is what makes the agent's sessions survive the VM.
	mount_label firellm-state "$STATE"

	overlay_home claude
	overlay_home opencode
	if [[ -f $CONFIG_MNT/claude.json ]]; then
		# Claude rewrites this file, so it must be a real copy, not a symlink
		# onto the read-only drive.
		cp -f "$CONFIG_MNT/claude.json" /root/.claude.json
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
		cp -f "$CTL_MNT/context.md" /root/FIRELLM.md
	fi

	log "setup complete (mode=${FIRELLM_MODE:-interactive} agent=${FIRELLM_AGENT:-none})"
}

main "$@"
