#!/usr/bin/env bash
# The checks this repo gets asked for over and over, in one command.
#
# Not a convenience wrapper. Every check here used to be typed as a fresh
# shell one-liner - a slightly different grep, another curl with another
# timeout, an awk written on the spot - and a command that is never the same
# twice cannot be permitted once. The person behind the agent ends up
# approving near-identical commands all day, which is both tedious and the
# fastest way to train somebody to approve without reading.
#
# So: fixed subcommands, fixed shapes, no arguments that change the string.
# Grant it once.
#
#   dev.sh lint      shellcheck + shfmt + parse every script, compile python
#   dev.sh status    branch, last commits, what is uncommitted
#   dev.sh push      push the current branch
#   dev.sh commit    stage first, put the message in runs/commit-msg.txt,
#                    then run this in the BACKGROUND: it opens the magit
#                    buffer and blocks until C-c C-c or C-c C-k, so the
#                    notification is the answer
#   dev.sh await-commit
#                    the waiting half alone, for a buffer already open
#   dev.sh room      chat server, cursors, identities, who is listening
#   dev.sh server    spawn server pid, runs in flight, recent log
#   dev.sh virt      can this machine run firecracker inside a VM
#   dev.sh lab ...   image | create | status | destroy - a libvirt guest to
#                    run firecode inside, for agents told to ignore
#                    permissions
#   dev.sh listen    arm the room waiter (run it in the BACKGROUND)
#   dev.sh all       every read-only check above
#
# Anything that changes state is its own subcommand and says what it did.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1

PORT=${FIRECODE_CHAT_PORT:-9761}
SPAWN_PORT=${FIRECODE_SPAWN_PORT:-9770}

say() { printf '\n=== %s ===\n' "$1"; }

# Every shell script that ships, so a new one cannot be forgotten.
scripts() {
	printf '%s\n' bin/firecode
	find guest scripts tests -name '*.sh' -type f 2>/dev/null | sort
	[[ -f guest/initramfs/init ]] && printf '%s\n' guest/initramfs/init
	return 0
}

cmd_lint() {
	# Each section reports its own result. Sharing one status across all of
	# them means a shellcheck warning silences the parse and compile lines,
	# and "no output" then reads as "did not run" - which is the opposite of
	# what a check should ever be ambiguous about.
	local rc=0 sec f
	say "shellcheck"
	sec=0
	while read -r f; do
		shellcheck "$f" || sec=1
	done < <(scripts)
	((sec == 0)) && echo "clean" || rc=1

	say "shfmt"
	sec=0
	while read -r f; do
		shfmt -w "$f" || sec=1
	done < <(scripts)
	((sec == 0)) && echo "formatted" || rc=1

	# After formatting, not before: shfmt rewrites the file, and a formatter
	# that breaks a script it just reformatted is exactly the failure this
	# catches. bin/firecode embeds python in single quotes in a dozen places,
	# and an apostrophe in a comment there has taken the whole CLI down for
	# every session on this machine three times in one day.
	say "parse"
	sec=0
	while read -r f; do
		bash -n "$f" || {
			echo "!! $f does not parse"
			sec=1
		}
	done < <(scripts)
	((sec == 0)) && echo "all parse" || rc=1

	say "python"
	sec=0
	local p
	for p in mcp/*.py scripts/*.py; do
		[[ -f $p ]] || continue
		python3 -m py_compile "$p" || sec=1
	done
	((sec == 0)) && echo "compile" || rc=1
	return $rc
}

# Does packing deliver the tree git would have delivered?
#
# firecode stages a project with rsync and `--filter=':- .gitignore'` so that
# ignored build output does not turn a 150K drive into a 10G one. But rsync
# reads that file with ITS rules, not git's, and the two disagree about
# negation: git treats `!pattern` as "re-include this after the rule above",
# rsync's merge treats every line in a `-` file as another exclusion. A
# project that ignores a directory and re-includes one file inside it - the
# usual way to keep an otherwise-empty directory in git - therefore arrives
# with that file missing.
#
# Found via Flowy, where web/dist/.gitkeep is exactly that pattern and its
# absence breaks go:embed, so the delivered tree does not compile while a git
# clone of the same commit does.
cmd_packcheck() {
	local t
	t=$(mktemp -d)
	mkdir -p "$t/src/web/dist"
	# The pattern that actually works in git, and the one Flowy uses:
	# ignore the CONTENTS (`dir/*`), then re-include the one file. Excluding
	# the directory itself (`dir/`) makes the re-include impossible for git
	# too - git will not descend into an excluded directory to reconsider -
	# so testing against that shape would prove nothing about rsync.
	printf '/web/dist/*\n!/web/dist/.gitkeep\n' >"$t/src/.gitignore"
	: >"$t/src/web/dist/.gitkeep"          # zero bytes, re-included by git
	echo 'built' >"$t/src/web/dist/app.js" # ignored build output
	: >"$t/src/empty-at-top.txt"           # zero bytes, never ignored
	echo 'source' >"$t/src/main.go"

	say "what git would keep"
	(cd "$t/src" && git init -q . && git add -A 2>/dev/null &&
		git ls-files | sed 's/^/  /')

	# Exactly what stage_project does now, so this check tracks the code
	# rather than a copy of it that can drift.
	mkdir -p "$t/dst"
	git -C "$t/src" ls-files -z --cached --others --exclude-standard 2>/dev/null |
		rsync -a --files-from=- --from0 "$t/src"/ "$t/dst"/ 2>/dev/null || true

	say "what packing delivered"
	(cd "$t/dst" && find . -type f | sed 's|^\./|  |' | sort)

	say "verdict"
	local bad=0
	[[ -f $t/dst/web/dist/.gitkeep ]] ||
		{
			echo "  MISSING web/dist/.gitkeep - the re-include was lost"
			bad=1
		}
	[[ -f $t/dst/empty-at-top.txt ]] ||
		{
			echo "  MISSING empty-at-top.txt - zero-byte files are being dropped"
			bad=1
		}
	[[ -f $t/dst/web/dist/app.js ]] &&
		echo "  note: ignored build output came along anyway"
	((bad == 0)) && echo "  packing matches git"
	rm -rf "$t"
	return $bad
}

# Can a microVM actually mount a FUSE filesystem?
#
# Not "is /dev/fuse there" - that is necessary and proves nothing. A FUSE
# filesystem needs the device, the kernel side, a working fusermount, and a
# process allowed to complete the mount. So this mounts a real one, reads a
# file out of it, and unmounts, inside a VM, and the verify gate decides.
#
# The answer gates whether a project like "a FUSE filesystem over Postgres"
# can be built by agents in VMs at all.
cmd_fusecheck() {
	local t
	t=$(mktemp -d)
	cat >"$t/fusetest.py" <<'PY'
# The smallest filesystem that proves the whole path works: one directory,
# one file, real content read back through the kernel.
import errno, os, stat, sys

# Debian's python3-fusepy installs the module as `fusepy`; upstream fusepy
# installs it as `fuse`. The rootfs has the Debian one, so importing the
# documented name fails and the mount never happens - which reads exactly
# like "FUSE does not work in here" if nobody looks at the traceback.
try:
    from fuse import FUSE, Operations
except ImportError:
    from fusepy import FUSE, Operations

BODY = b"fuse works in here\n"


class One(Operations):
    def getattr(self, path, fh=None):
        now = 0
        if path == "/":
            return dict(st_mode=(stat.S_IFDIR | 0o755), st_nlink=2,
                        st_ctime=now, st_mtime=now, st_atime=now)
        if path == "/hello":
            return dict(st_mode=(stat.S_IFREG | 0o444), st_nlink=1,
                        st_size=len(BODY), st_ctime=now, st_mtime=now,
                        st_atime=now)
        raise OSError(errno.ENOENT, "")

    def readdir(self, path, fh):
        return [".", "..", "hello"]

    def read(self, path, size, offset, fh):
        return BODY[offset:offset + size]


FUSE(One(), sys.argv[1], foreground=True, ro=True)
PY

	cat >"$t/run.sh" <<'SH'
#!/usr/bin/env bash
# Inside the VM. Every line prints what it found, so a failure says which
# part of the path is missing rather than just "no".
echo "== device"
ls -l /dev/fuse 2>&1 || echo "  /dev/fuse ABSENT"
echo "== kernel side"
grep -qw fuse /proc/filesystems && echo "  fuse in /proc/filesystems" ||
	{ modprobe fuse 2>&1 && grep -qw fuse /proc/filesystems &&
		echo "  fuse loadable via modprobe" || echo "  fuse NOT available"; }
echo "== userspace"
command -v fusermount3 fusermount 2>/dev/null || echo "  no fusermount"
python3 -c 'import fuse; print("  python fusepy present")' 2>&1 |
	tail -1
echo "== a real mount"
mkdir -p /tmp/mnt
# Relative, because the project is the working directory in there - it is
# not mounted at any fixed path, and guessing one cost a run that reported
# "verification failed" while proving nothing about FUSE at all.
python3 ./fusetest.py /tmp/mnt &
fusepid=$!
for _ in $(seq 1 40); do
	mountpoint -q /tmp/mnt && break
	sleep 0.25
done
if mountpoint -q /tmp/mnt; then
	echo "  mounted"
	sed 's/^/  read back: /' /tmp/mnt/hello
	cp /tmp/mnt/hello ./fuse-proof.txt
	fusermount3 -u /tmp/mnt 2>/dev/null || fusermount -u /tmp/mnt 2>/dev/null
	echo "  unmounted"
else
	echo "  MOUNT FAILED"
fi
kill $fusepid 2>/dev/null || true
SH
	chmod +x "$t/run.sh"

	say "mounting a FUSE filesystem inside a microVM"
	# The gate is the answer: the proof file only exists if the mount worked
	# and its contents could be read back through the kernel.
	#
	# The whole transcript goes to a file as well, because the interesting
	# part is what the guest printed about /dev/fuse and fusermount - and
	# piping this into grep to find it means running the VM again for every
	# question, which is both slow and a new command string each time.
	mkdir -p "$ROOT/runs"
	local log="$ROOT/runs/fusecheck.log"
	firecode exec --project "$t" --verify 'grep -q "fuse works in here" fuse-proof.txt' \
		-- bash ./run.sh >"$log" 2>&1
	local rc=$?

	say "what the guest found"
	sed -n 's/.*run\.sh\[[0-9]*\]: //p; s/.*agent-entrypoint\.sh\[[0-9]*\]: \(  .*\)/\1/p' \
		"$log" | grep -vE '^\s*$' | head -20
	say "verdict"
	if ((rc == 0)); then
		echo "  FUSE mounts in a microVM - gate passed on content read back through the kernel"
	else
		echo "  gate failed (rc=$rc) - full transcript: $log"
	fi
	rm -rf "$t"
	return $rc
}

# Does a failed gate actually fail the run?
#
# The verify gate exists so that a run cannot report success it did not earn:
# the check runs after the agent exits, in the project as delivered, and its
# status is supposed to BECOME the run's. If that status is swallowed
# anywhere, every caller that trusts an exit code - a script, a spawn server,
# an orchestrator deciding whether to land work - reads a failure as a pass,
# which is worse than having no gate at all.
#
# Noticed because a FUSE run printed VERIFICATION FAILED and exited 0.
cmd_gatecheck() {
	local t rc
	t=$(mktemp -d)
	echo 'nothing' >"$t/file.txt"

	say "a gate that cannot pass"
	firecode exec --project "$t" --verify 'test -f definitely-not-here' \
		-- bash -c 'true' >"$ROOT/runs/gatecheck.log" 2>&1
	rc=$?
	grep -qi 'VERIFICATION FAILED' "$ROOT/runs/gatecheck.log" &&
		echo "  the run reported: VERIFICATION FAILED"
	echo "  exit status: $rc"

	say "verdict"
	if ((rc == 0)); then
		echo "  BROKEN: the gate failed and the run exited 0."
		echo "  Anything trusting the exit code reads this run as a success."
		rc=1
	else
		echo "  correct: a failed gate is a failed run (exit $rc)"
		rc=0
	fi
	rm -rf "$t"
	return $rc
}

cmd_status() {
	say "branch"
	git rev-parse --abbrev-ref HEAD
	say "recent"
	git log --oneline -5
	say "uncommitted"
	git status --short || true
	say "unpushed"
	git log --oneline '@{u}..HEAD' 2>/dev/null || echo "(no upstream)"
}

cmd_push() {
	say "push"
	git push
}

# Block until the commit sitting in the editor is finished, or abandoned.
#
# `ecommit` opens a magit buffer and returns straight away, so nothing tells
# an agent when C-c C-c actually lands - it finds out by polling git log,
# which means either asking repeatedly or noticing minutes later. Run this in
# the background instead: it exits when HEAD moves, and a background command
# that exits is a notification.
#
# Exits 0 with the new commit, 1 if nothing happened before the timeout, and
# 2 if the commit was abandoned - the staged changes still sitting there with
# HEAD where it was is what C-c C-k leaves behind.
cmd_await_commit() {
	local start
	start=$(git rev-parse HEAD 2>/dev/null) || return 1
	wait_for_commit "$start"
}

# Stage first, write the message to runs/commit-msg.txt, then run this in the
# background. It captures HEAD before opening the editor, which `await-commit`
# on its own cannot do: called as a separate command it can be started after
# C-c C-c has already landed, and then "HEAD is where I found it and nothing
# is staged" describes a finished commit and an abandoned one identically. It
# reported a successful commit as abandoned exactly once before this existed.
cmd_commit() {
	local msg=${FIRECODE_COMMIT_MSG:-runs/commit-msg.txt} start
	if [[ ! -s $msg ]]; then
		echo "no commit message at $msg - write it there first"
		return 2
	fi
	if git diff --cached --quiet 2>/dev/null; then
		echo "nothing staged - git add what you mean to commit first"
		return 2
	fi
	start=$(git rev-parse HEAD 2>/dev/null) || return 1
	say "opening the commit buffer"
	git diff --cached --stat | tail -1
	ecommit -F "$msg" || true
	wait_for_commit "$start"
}

wait_for_commit() {
	local start=$1 now waited=0 limit=${FIRECODE_AWAIT_COMMIT:-1800}
	while ((waited < limit)); do
		sleep 2
		waited=$((waited + 2))
		now=$(git rev-parse HEAD 2>/dev/null)
		if [[ $now != "$start" ]]; then
			say "committed"
			git log --oneline -1
			say "still uncommitted"
			git status --short
			return 0
		fi
		# Nothing staged any more, HEAD unmoved: the buffer was abandoned
		# and somebody unstaged, or another session committed the index.
		if git diff --cached --quiet 2>/dev/null; then
			say "nothing staged and HEAD did not move"
			echo "the commit was abandoned, or its changes were unstaged"
			return 2
		fi
	done
	say "timeout"
	echo "no commit after ${limit}s - the buffer is probably still open"
	return 1
}

cmd_room() {
	say "chat server"
	if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
		echo "up on $PORT"
	else
		echo "DOWN on $PORT - firecode chat serve"
	fi

	say "identities (who each directory speaks as)"
	local f
	for f in runs/chat-self-*; do
		[[ -f $f ]] || continue
		printf '%-52s %s\n' "${f#runs/chat-self-}" "$(tr '\n' ' ' <"$f")"
	done

	say "cursors (how far each reader has read)"
	for f in runs/chat-mark-*; do
		[[ -f $f ]] || continue
		printf '%-52s %s\n' "${f#runs/chat-mark-}" "$(cat "$f")"
	done

	# The one that matters when a message goes unanswered: a waiter is what
	# wakes an idle session, and it has to be restarted after every fire.
	say "waiters (what is listening right now)"
	pgrep -af -- "chat --inbo[x]" || echo "none - nobody would be woken"
}

# Can this machine run firecracker inside a VM, and is the outer layer here?
#
# The answer is one setting deep and everybody guesses it wrong: nested KVM
# has to be on in the host module, and the L1 guest has to be given a CPU that
# actually exposes vmx/svm. host-model, which is the common default, usually
# does not - and then /dev/kvm simply is not there in the guest and the host
# gets blamed.
cmd_virt() {
	say "cpu"
	grep -m1 -E 'model name' /proc/cpuinfo | sed 's/^[^:]*: //'
	printf 'threads with vmx/svm: %s\n' \
		"$(grep -c -E '^flags.*(vmx|svm)' /proc/cpuinfo)"

	say "nested kvm (host)"
	local n
	for n in /sys/module/kvm_intel/parameters/nested \
		/sys/module/kvm_amd/parameters/nested; do
		[[ -r $n ]] && printf '%-44s %s\n' "$n" "$(cat "$n")"
	done
	[[ -e /dev/kvm ]] && echo "/dev/kvm present" || echo "/dev/kvm MISSING"

	say "outer layer"
	command -v virsh virt-install qemu-system-x86_64 2>/dev/null ||
		echo "libvirt/qemu not installed"
	systemctl is-active libvirtd 2>/dev/null || true

	say "libvirt networks"
	virsh -c qemu:///system net-list --all 2>/dev/null || echo "(cannot reach libvirt)"

	say "domains"
	virsh -c qemu:///system list --all 2>/dev/null || true

	say "space"
	df -h "$HOME" | tail -1
}

cmd_server() {
	say "spawn server"
	local pid
	pid=$(ss -lntp 2>/dev/null |
		sed -n "s/.*:$SPAWN_PORT .*pid=\([0-9]*\).*/\1/p" | head -1)
	if [[ -z $pid ]]; then
		echo "DOWN on $SPAWN_PORT - firecode spawn-server restart"
		return 0
	fi
	echo "up on $SPAWN_PORT (pid $pid)"

	# Children are runs. Restarting the server forgets them, so this is the
	# number to look at before bouncing it.
	say "runs in flight"
	pgrep -P "$pid" >/dev/null 2>&1 &&
		pgrep -aP "$pid" || echo "none - safe to restart"

	say "recent log"
	tail -12 runs/spawn-server.log 2>/dev/null || echo "(no log yet)"
}

# A libvirt guest to run firecode inside, for testing agents that are told to
# ignore permissions.
#
# The point is a blast radius: an agent running with permissions disabled can
# reach the L1 guest and nothing else - not this laptop, not the keys, not the
# repositories. Firecracker cannot be the outer layer, because it does not
# give its guests nested VMX, so the outer layer is qemu.
#
# It reports its findings into the chat room rather than over ssh: the guest
# can reach the host at the libvirt gateway, the room is already there, and
# this needs no key material and no interactive console.
# qemu:///session, not qemu:///system.
#
# The system daemon runs qemu as libvirt-qemu, and $HOME here is 0750, so the
# hypervisor cannot even traverse it - the disk is unreadable wherever under
# home it is put. The fixes are all worse than the problem: loosen the home
# directory, hand the disk to another uid, or need root for a test lab. The
# session daemon runs as this user and reads its own files. Nested KVM is
# unaffected - that comes from /dev/kvm and group membership, not from which
# daemon started the guest.
#
# The cost is usermode networking: no bridge, so the guest reaches the host
# at 10.0.2.2 rather than the libvirt gateway, and there are no DHCP leases
# to read an address from. Both are handled below.
LAB_URI=${FIRECODE_LAB_URI:-qemu:///session}
LAB_DIR=${FIRECODE_LAB_DIR:-$HOME/.local/share/firecode-lab}
LAB_NAME=${FIRECODE_LAB_NAME:-fc-nested}
LAB_IMAGE_URL=${FIRECODE_LAB_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}
LAB_BASE="$LAB_DIR/base.img"
LAB_DISK="$LAB_DIR/$LAB_NAME.qcow2"

lab_image() {
	mkdir -p "$LAB_DIR"
	if [[ -s $LAB_BASE ]]; then
		echo "base image already here: $LAB_BASE ($(du -h "$LAB_BASE" | cut -f1))"
		return 0
	fi
	say "downloading the base image"
	echo "$LAB_IMAGE_URL"
	# --retry because this machine goes through a VPN whose DNS is flaky, and
	# a half-downloaded cloud image fails much later and much less clearly.
	curl -fL --retry 5 --retry-connrefused --retry-delay 3 \
		-o "$LAB_BASE.part" "$LAB_IMAGE_URL" || {
		rm -f "$LAB_BASE.part"
		echo "download failed - the VPN DNS is the usual reason"
		return 1
	}
	mv "$LAB_BASE.part" "$LAB_BASE"
	echo "have it: $(du -h "$LAB_BASE" | cut -f1)"
}

lab_create() {
	local mem=${FIRECODE_LAB_MEM:-8192} cpus=${FIRECODE_LAB_CPUS:-4}
	local size=${FIRECODE_LAB_DISK:-40G}
	[[ -s $LAB_BASE ]] || {
		echo "no base image - run: dev.sh lab image"
		return 2
	}
	if virsh -c "$LAB_URI" dominfo "$LAB_NAME" >/dev/null 2>&1; then
		echo "$LAB_NAME already exists - dev.sh lab destroy first"
		return 2
	fi

	say "disk"
	# An overlay, so rebuilding costs seconds and the download is kept.
	qemu-img create -f qcow2 -F qcow2 -b "$LAB_BASE" "$LAB_DISK" "$size"

	# cloud-init does the whole verification, because the interesting answer
	# is available before anybody logs in: is there a /dev/kvm in here, and
	# does firecracker actually boot something.
	say "cloud-init"
	cat >"$LAB_DIR/user-data" <<-CLOUDINIT
		#cloud-config
		hostname: $LAB_NAME
		users:
		  - name: dead
		    sudo: ALL=(ALL) NOPASSWD:ALL
		    shell: /bin/bash
		    lock_passwd: false
		    plain_text_passwd: firecode
		ssh_pwauth: true
		package_update: true
		packages: [qemu-guest-agent, curl, python3]
		write_files:
		  - path: /usr/local/bin/lab-report
		    permissions: '0755'
		    content: |
		      #!/bin/bash
		      # Say what we found, into the room on the host.
		      report() {
		        python3 - "\$1" <<'PY'
		      import json, sys, urllib.request
		      # The host is at a different address depending on how the guest
		      # was networked - 10.0.2.2 under usermode, the gateway under a
		      # libvirt NAT - and the guest has no way to know which it got.
		      # Try them rather than make the caller care.
		      body = json.dumps({"from": "nested-lab", "to": "claude-host",
		                         "text": sys.argv[1]}).encode()
		      for host in ("10.0.2.2", "192.168.122.1", "192.168.124.1"):
		          req = urllib.request.Request("http://%s:9761/say" % host, data=body,
		                                       headers={"Content-Type": "application/json"})
		          try:
		              urllib.request.urlopen(req, timeout=10)
		              print("reported to", host)
		              break
		          except Exception as exc:
		              print(host, "no:", exc)
		      PY
		      }
		      kvm=\$( [ -e /dev/kvm ] && echo present || echo MISSING )
		      vmx=\$(grep -c -E '^flags.*(vmx|svm)' /proc/cpuinfo)
		      vsock=\$(modprobe vhost_vsock 2>&1 && echo ok || echo "failed")
		      report "nested lab up. /dev/kvm: \$kvm. cpus exposing vmx/svm: \$vmx. vhost_vsock: \$vsock. kernel: \$(uname -r)"
		runcmd:
		  - [ systemctl, enable, --now, qemu-guest-agent ]
		  - [ modprobe, kvm_intel ]
		  - [ modprobe, vhost_vsock ]
		  - [ /usr/local/bin/lab-report ]
	CLOUDINIT

	# Our own seed disk, rather than virt-install --cloud-init.
	#
	# That option attached an ISO and the guest ignored it: cloud-init took
	# its datasource from DMI instead, applied an empty config and finished
	# in sixteen seconds - right hostname nowhere, no packages, no runcmd,
	# and nothing in the log saying it had skipped anything. A NoCloud seed
	# is just two files on a volume labelled cidata, so building it here
	# removes the layer that was silently deciding otherwise.
	say "seed disk"
	mkdir -p "$LAB_DIR/seed"
	cp "$LAB_DIR/user-data" "$LAB_DIR/seed/user-data"
	# instance-id is what makes cloud-init treat this as a new machine and
	# run the per-instance modules again; without it a rebuilt guest can
	# decide it has already done all this.
	cat >"$LAB_DIR/seed/meta-data" <<-META
		instance-id: $LAB_NAME-$(date +%s)
		local-hostname: $LAB_NAME
	META
	genisoimage -output "$LAB_DIR/seed.iso" -volid cidata -joliet -rock \
		"$LAB_DIR/seed/user-data" "$LAB_DIR/seed/meta-data" >/dev/null 2>&1 ||
		{
			echo "could not build the seed iso"
			return 1
		}

	say "creating $LAB_NAME"
	# host-passthrough is the whole point: host-model would hand the guest a
	# cpu with no vmx and /dev/kvm would never appear.
	virt-install \
		--connect "$LAB_URI" \
		--name "$LAB_NAME" \
		--memory "$mem" --vcpus "$cpus" \
		--cpu host-passthrough,check=none \
		--disk "path=$LAB_DISK,format=qcow2,bus=virtio" \
		--disk "path=$LAB_DIR/seed.iso,device=cdrom" \
		--import \
		--os-variant ubuntu24.04 \
		--network "${FIRECODE_LAB_NET:-user}",model=virtio \
		--serial "file,path=$LAB_DIR/console.log" \
		--graphics none --noautoconsole || return 1

	echo
	echo "booting. It reports into the room when cloud-init finishes -"
	echo "watch with: firecode chat --read, or dev.sh lab status"
}

lab_status() {
	say "$LAB_NAME"
	virsh -c "$LAB_URI" dominfo "$LAB_NAME" 2>/dev/null || {
		echo "not defined - dev.sh lab create"
		return 2
	}
	say "address"
	# Usermode networking has no leases to read, so the agent is the only
	# source. Absent until qemu-guest-agent is installed and running, which
	# is a first-boot job - "no address" here means "still setting up", not
	# "broken".
	virsh -c "$LAB_URI" domifaddr "$LAB_NAME" --source agent 2>/dev/null ||
		echo "(no address yet - guest agent not up)"

	say "what it has said in the room"
	firecode chat --read --since 0 2>/dev/null |
		grep -i 'nested-lab' | tail -5 || echo "(nothing yet)"
}

lab_destroy() {
	virsh -c "$LAB_URI" destroy "$LAB_NAME" 2>/dev/null || true
	virsh -c "$LAB_URI" undefine "$LAB_NAME" --nvram 2>/dev/null ||
		virsh -c "$LAB_URI" undefine "$LAB_NAME" 2>/dev/null || true
	rm -f "$LAB_DISK"
	echo "$LAB_NAME gone. The base image is kept - dev.sh lab create rebuilds in seconds."
}

# What the guest actually printed.
#
# A guest that never reports is indistinguishable from one that failed to
# boot, unless its console was written down. `virsh console` is interactive
# and cannot be read from a script, so the domain gets a serial file instead
# and this reads it.
lab_console() {
	local log="$LAB_DIR/console.log"
	if [[ ! -s $log ]]; then
		echo "no console log at $log"
		echo "(a domain created before this existed has no serial file -"
		echo " dev.sh lab destroy && dev.sh lab create gives it one)"
		return 2
	fi
	say "last of the console"
	tail -40 "$log"
	say "cloud-init verdict"
	grep -aiE 'cloud-init.*(finished|failed)|lab-report|reported to|no:' "$log" |
		tail -10 || echo "(cloud-init has not finished)"
}

# Wait for the guest to say something, in the BACKGROUND.
#
# Never in the foreground. A blocking wait typed as a plain command holds the
# whole session while it runs, and the session cannot be interrupted to do
# anything else - which has now happened twice here, both times to a sleep
# that was only guessing at how long a boot takes. Backgrounded, the exit IS
# the notification and the session stays free meanwhile.
lab_await() {
	local waited=0 limit=${FIRECODE_LAB_WAIT:-900} found
	while ((waited < limit)); do
		found=$(firecode chat --read --since 0 2>/dev/null | grep -c 'nested-lab' || true)
		if [[ $found =~ ^[0-9]+$ ]] && ((found > 0)); then
			say "the guest reported"
			firecode chat --read --since 0 2>/dev/null | grep 'nested-lab' | tail -3
			return 0
		fi
		# A guest that has died is not worth waiting fifteen minutes for.
		if ! virsh -c "$LAB_URI" domstate "$LAB_NAME" 2>/dev/null | grep -q running; then
			say "the guest is not running"
			virsh -c "$LAB_URI" domstate "$LAB_NAME" 2>/dev/null
			lab_console
			return 2
		fi
		sleep 10
		waited=$((waited + 10))
	done
	say "nothing after ${limit}s"
	lab_console
	return 1
}

# Run a command in the guest, without ssh.
#
# Usermode networking means nothing reaches in, which is the property this
# lab is for - and it also means no ssh, no scp, no console that a script can
# drive. The guest agent is the way in that does not weaken any of that: it
# rides the virtio channel, needs no listening port in the guest, and stops
# working the moment the guest is shut down.
#
# The python is a heredoc rather than python3 -c '...' on purpose. An
# apostrophe inside a single-quoted -c closes the quote and turns the rest
# into shell; that has taken this CLI down three times in a day, and a
# quoted heredoc simply cannot do it.
lab_exec() {
	local cmd="$*"
	if [[ -z $cmd ]]; then
		echo "lab exec <command>   - runs it in the guest via the agent"
		return 2
	fi
	python3 - "$LAB_URI" "$LAB_NAME" "$cmd" <<'PY'
import base64, json, subprocess, sys, time

uri, dom, cmd = sys.argv[1], sys.argv[2], sys.argv[3]


def agent(payload):
    out = subprocess.run(
        ["virsh", "-c", uri, "qemu-agent-command", dom, json.dumps(payload)],
        capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit("guest agent not answering: %s" % (out.stderr.strip() or
                 "is the guest up, and has qemu-guest-agent started?"))
    return json.loads(out.stdout)


started = agent({"execute": "guest-exec",
                 "arguments": {"path": "/bin/bash",
                               "arg": ["-lc", cmd],
                               "capture-output": True}})
pid = started["return"]["pid"]

# No timeout of its own: the caller decides how long to wait by how it runs
# this, and a package install over a VPN is legitimately slow.
while True:
    st = agent({"execute": "guest-exec-status",
                "arguments": {"pid": pid}})["return"]
    if st.get("exited"):
        break
    time.sleep(1)

for stream in ("out-data", "err-data"):
    blob = st.get(stream)
    if blob:
        sys.stdout.write(base64.b64decode(blob).decode("utf-8", "replace"))
code = st.get("exitcode", 0)
if code:
    print("[exit %d]" % code)
sys.exit(code)
PY
}

# Put Flowy in the guest, at a named commit.
#
# A bundle rather than a copied tree: it carries the history, so the guest can
# say which commit it is testing and prove it, and a tree copied out of a
# workspace that is still being written to is a tree nobody can name.
lab_flowy() {
	local src=${FLOWY_SRC:-/tmp/firecode-scratch/flowy}
	local want=${1:-51db8f7}
	[[ -d $src/.git ]] || {
		echo "no flowy workspace at $src"
		return 2
	}
	say "bundling $src at $want"
	git -C "$src" rev-parse --short HEAD | sed 's/^/workspace tip: /'
	git -C "$src" bundle create "$LAB_DIR/flowy.bundle" --all >/dev/null 2>&1 || {
		echo "bundle failed"
		return 1
	}
	du -h "$LAB_DIR/flowy.bundle" | cut -f1 | sed 's/^/bundle: /'

	lab_push "$LAB_DIR/flowy.bundle" /root/flowy.bundle || return 1

	# Into the unprivileged user's home, not root's.
	#
	# The guest agent runs everything as root, and the gate stands up its own
	# Postgres - which initdb flatly refuses to do as root, correctly. So the
	# tree lives where the user that will run it can own it, and the gate is
	# run as that user rather than the tree being chowned back and forth.
	say "cloning in the guest at $want"
	# chown last: git refuses to read a tree owned by somebody else, so
	# handing it over before the verification breaks the verification.
	lab_exec "rm -rf /home/dead/flowy && \
		git clone -q /root/flowy.bundle /home/dead/flowy && \
		cd /home/dead/flowy && git checkout -q $want && \
		echo -n 'guest tip: ' && git rev-parse --short HEAD && \
		git log --oneline -1 && ls run-tests.sh schema.sql go.mod && \
		chown -R dead:dead /home/dead/flowy && echo 'owned by dead'"
}

# Put firecode itself in the guest, so agents in there can spawn microVMs.
#
# The rootfs is a 6G sparse file holding about 894M, and HTTP does not know
# about holes - so it is compressed for the trip, which also makes the
# transfer honest about what it is moving. Everything else is small.
#
# What this does NOT do is prove nesting works; that is one gated run, which
# is `lab firecode-smoke`.
lab_firecode() {
	local comp=gzip ext=gz decomp="gzip -d"
	if command -v zstd >/dev/null 2>&1; then
		comp="zstd -T0 -3" ext=zst decomp="zstd -d"
	fi

	say "bundling firecode"
	git -C "$ROOT" bundle create "$LAB_DIR/firecode.bundle" --all >/dev/null 2>&1 ||
		return 1
	lab_push "$LAB_DIR/firecode.bundle" /root/firecode.bundle || return 1
	lab_exec "rm -rf /root/firecode && git clone -q /root/firecode.bundle /root/firecode && \
		cd /root/firecode && git log --oneline -1 && mkdir -p images vendor/bin" || return 1

	say "compressing the rootfs (894M of a 6G sparse file)"
	local rootfs="$ROOT/images/agent-firecode.ext4"
	[[ -f $rootfs ]] || {
		echo "no rootfs at $rootfs"
		return 2
	}
	if [[ ! -s $LAB_DIR/agent-firecode.ext4.$ext ]]; then
		$comp -c "$rootfs" >"$LAB_DIR/agent-firecode.ext4.$ext" || return 1
	fi
	du -h "$LAB_DIR/agent-firecode.ext4.$ext" | cut -f1 | sed 's/^/compressed: /'
	lab_push "$LAB_DIR/agent-firecode.ext4.$ext" "/root/rootfs.$ext" || return 1
	lab_exec "cd /root/firecode/images && $decomp -c /root/rootfs.$ext > agent-firecode.ext4 && \
		rm -f /root/rootfs.$ext && ls -lh agent-firecode.ext4" || return 1

	# The working tree wins over the bundle.
	#
	# `git bundle --all` carries committed refs, so a fix that is still
	# uncommitted here does not travel - and in a lab the whole point is
	# testing what I am editing right now. This cost one confusing round
	# already: a $HOME fix verified on the host and still broken in the
	# guest, because the guest had the committed version.
	say "working-tree overrides"
	lab_push "$ROOT/bin/firecode" /root/firecode/bin/firecode || return 1
	lab_push "$ROOT/scripts/chat.py" /root/firecode/scripts/chat.py || true

	say "kernel and binaries"
	local kern
	kern=$(find "$ROOT/images" -maxdepth 1 -name 'vmlinux-*' -type f | sort | head -1)
	lab_push "$kern" "/root/firecode/images/$(basename "$kern")" || return 1
	# The initramfs, which is what assembles the layered root - without it a
	# run dies at "no initrd" having looked otherwise completely set up.
	lab_push "$ROOT/images/initrd.gz" /root/firecode/images/initrd.gz || return 1
	lab_push "$ROOT/vendor/bin/firecracker" /root/firecode/vendor/bin/firecracker || return 1
	lab_push "$ROOT/vendor/bin/jailer" /root/firecode/vendor/bin/jailer || return 1
	lab_exec "chmod +x /root/firecode/vendor/bin/* /root/firecode/bin/firecode; \
		ln -sf /root/firecode/bin/firecode /usr/local/bin/firecode; \
		firecode doctor 2>&1 | head -25"
}

# Does nesting actually hold? One trivial gated run settles it.
#
# The orchestrator named the two things that would break it: an absolute host
# path baked into the rootfs, and the jailer chroot pointing outside the
# guest. Both show up here or not at all - config drive assembles, VM boots,
# the gate runs in the project as delivered, and its exit status is the
# answer.
lab_firecode_smoke() {
	# `exec`, not an agent.
	#
	# Nesting is a question about the config drive, the boot and the gate -
	# not about models or credentials. Running an agent here would drag in
	# the relay and a binary that is not installed yet, and a failure would
	# then be ambiguous between "nesting is broken" and "auth is not wired".
	# A command whose whole job is to touch a file settles nesting alone.
	say "prerequisites the guest doctor named"
	lab_exec "export DEBIAN_FRONTEND=noninteractive; \
		command -v socat >/dev/null || apt-get install -y -qq socat; \
		command -v socat && (ip link show fccode1 >/dev/null 2>&1 || \
		firecode net-setup --count 2 2>&1 | tail -3)"

	say "a gated run inside the guest"
	lab_exec "mkdir -p /root/smoke && cd /root/smoke && \
		timeout 900 firecode exec --project /root/smoke --verify 'test -f ok' \
		-- bash -c 'touch ok' 2>&1 | tail -30; echo \"--- exit \$? ---\""
}

# The gate, unmodified, in the guest. Timed, because 282 checks in a nested
# VM is a number worth knowing on its own - and reported separately from the
# verdict, since a slow lab says nothing about the code.
lab_gate() {
	say "running ./run-tests.sh in the guest, as dead"
	lab_exec "su - dead -c 'cd ~/flowy && export PATH=/usr/lib/postgresql/16/bin:\$PATH && \
		start=\$(date +%s); ./run-tests.sh 2>&1 | tail -40; rc=\${PIPESTATUS[0]}; \
		echo \"--- gate exit \$rc after \$((\$(date +%s)-start))s ---\"'"
}

cmd_lab() {
	case "${1:-status}" in
	image) lab_image ;;
	create) lab_create ;;
	status) lab_status ;;
	console) lab_console ;;
	await) lab_await ;;
	exec)
		shift
		lab_exec "$@"
		;;
	push)
		shift
		lab_push "$@"
		;;
	flowy)
		shift
		lab_flowy "$@"
		;;
	gate) lab_gate ;;
	agent) lab_agent_setup ;;
	work)
		shift
		lab_work "$@"
		;;
	tail)
		shift
		lab_tail "$@"
		;;
	firecode) lab_firecode ;;
	firecode-smoke) lab_firecode_smoke ;;
	destroy) lab_destroy ;;
	*) echo "lab: image | create | status | console | await | exec | destroy" ;;
	esac
}

# Post what is in runs/chat-msg.txt to the room.
#
#   dev.sh say <recipient>    addressed, so their waiter fires
#   dev.sh say                to the room, waking nobody
#
# The message lives in a file rather than the command line for the same
# reason the commit message does: `cat >file <<EOF ... "$(cat file)"` is a
# different command string every time, so it can never be approved once, and
# a long message pasted into an argument is unreadable in the approval prompt
# anyway. Write the file with an editor, send it with a fixed command.
cmd_say() {
	local msg=${FIRECODE_CHAT_MSG:-runs/chat-msg.txt}
	if [[ ! -s $msg ]]; then
		echo "no message at $msg - write it there first"
		return 2
	fi
	local as=${FIRECODE_CHAT_NAME:-claude-host}
	if [[ -n ${1:-} ]]; then
		firecode chat --as "$as" --to "$1" "$(cat "$msg")"
	else
		firecode chat --as "$as" "$(cat "$msg")"
	fi
}

# Copy a file into the guest.
#
# There is no scp: the guest has no inbound route, which is the property this
# lab exists for. It can reach the host though, so the host serves the file
# for as long as it takes to fetch it and not one second longer, bound to
# loopback, and the guest pulls it. Checksummed, because a truncated 894M
# rootfs fails much later and much less clearly than a mismatched hash.
lab_push() {
	local src=${1:?usage: dev.sh lab push <file> [dest]}
	local dest=${2:-/root/$(basename "$src")}
	[[ -f $src ]] || {
		echo "no such file: $src"
		return 2
	}
	mkdir -p "$LAB_DIR/push"
	cp -f "$src" "$LAB_DIR/push/"
	local name port sum
	name=$(basename "$src")
	port=${FIRECODE_LAB_PUSH_PORT:-18761}
	sum=$(sha256sum "$LAB_DIR/push/$name" | cut -d' ' -f1)

	say "serving $name ($(du -h "$src" | cut -f1)) on 127.0.0.1:$port"
	python3 -m http.server "$port" --bind 127.0.0.1 \
		--directory "$LAB_DIR/push" >/dev/null 2>&1 &
	local server=$!
	sleep 1

	say "fetching it in the guest"
	lab_exec "curl -fsS -o '$dest' http://10.0.2.2:$port/'$name' && \
		echo -n 'sha256: ' && sha256sum '$dest' | cut -d' ' -f1 && \
		ls -lh '$dest'"
	local rc=$?

	kill "$server" 2>/dev/null || true
	wait "$server" 2>/dev/null || true
	echo "host sha256: $sum"
	return $rc
}

# The credential boundary: a relay on the host, agents in the lab.
#
# This is what makes permissions-disabled agents in the lab acceptable. The
# OAuth token never enters the VM - the guest holds a placeholder key and an
# ANTHROPIC_BASE_URL pointing back at the host, so an agent in there can do
# its work and still has nothing worth stealing. Revocation stays one process
# on this machine: kill the relay and every agent in the lab stops, at once,
# without touching the VM.
#
# Bound to loopback deliberately. Usermode networking maps the host loopback
# to 10.0.2.2 for the guest, so the lab reaches it while the network does not.
cmd_relay() {
	local port=${FIRECODE_RELAY_PORT:-9790}
	if ss -ltn 2>/dev/null | grep -q ":$port "; then
		echo "relay already up on $port"
		return 0
	fi
	mkdir -p "$ROOT/runs"
	setsid python3 "$ROOT/scripts/auth-relay.py" --port "$port" --provider claude \
		>"$ROOT/runs/auth-relay.log" 2>&1 &
	disown 2>/dev/null || true
	sleep 2
	if ss -ltn 2>/dev/null | grep -q ":$port "; then
		echo "relay on 127.0.0.1:$port - the lab reaches it at 10.0.2.2:$port"
		tail -2 "$ROOT/runs/auth-relay.log"
	else
		echo "relay did not come up - see $ROOT/runs/auth-relay.log"
		tail -5 "$ROOT/runs/auth-relay.log"
		return 1
	fi
}

# Put an agent in the lab, pointed at the relay.
lab_agent_setup() {
	local port=${FIRECODE_RELAY_PORT:-9790}
	say "installing Claude Code in the guest"
	lab_exec "npm install -g @anthropic-ai/claude-code >/dev/null 2>&1; \
		claude --version 2>&1 | head -1"

	# Written to the unprivileged user's profile, since that is who runs
	# things here - initdb refuses root and so will half the gate.
	say "pointing it at the relay"
	lab_exec "cat > /home/dead/.agent-env <<'ENV'
export ANTHROPIC_BASE_URL=http://10.0.2.2:$port
export ANTHROPIC_API_KEY=relayed-no-real-credential-in-this-vm
export FIRECODE_MODEL_CTX=200000
export IS_SANDBOX=1
ENV
chown dead:dead /home/dead/.agent-env
grep -q agent-env /home/dead/.bashrc || echo '. /home/dead/.agent-env' >> /home/dead/.bashrc
echo written"

	say "can an agent in the lab reach the model?"
	lab_exec "su - dead -c '. /home/dead/.agent-env && \
		timeout 120 claude -p \"reply with exactly: lab agent alive\" 2>&1 | tail -3'"
}

# Set an agent to work in the lab, on a brief, unattended.
#
#   dev.sh lab work <name> [project-dir]
#
# The brief is a file (runs/agent-brief.txt) for the same reason commit
# messages and room posts are: a long prompt in an argument is a command
# string nobody can approve twice and nobody can read once.
#
# Permissions are disabled in there deliberately - that is what the lab is
# for. The blast radius is the guest: no host filesystem, no host keys, and
# the credential it holds is a placeholder pointing at a relay that can be
# killed from outside. It reports into the room under its own name, so it can
# be followed without watching a log.
lab_work() {
	local name=${1:?usage: dev.sh lab work <name> [project-dir]}
	local proj=${2:-/home/dead/$name}
	local brief=${FIRECODE_AGENT_BRIEF:-runs/agent-brief.txt}
	if [[ ! -s $brief ]]; then
		echo "no brief at $brief - write it there first"
		return 2
	fi

	lab_push "$brief" "/tmp/brief-$name.txt" || return 1
	say "starting $name in $proj"
	lab_exec "mkdir -p '$proj' && chown -R dead:dead '$proj' /tmp/brief-$name.txt && \
		su - dead -c 'cd $proj && . /home/dead/.agent-env && \
		nohup claude --dangerously-skip-permissions -p \"\$(cat /tmp/brief-$name.txt)\" \
		> /home/dead/$name.log 2>&1 &' && echo started"
	echo
	echo "  follow with: dev.sh lab tail $name"
}

# What is the agent doing right now.
lab_tail() {
	local name=${1:?usage: dev.sh lab tail <name>}
	lab_exec "tail -30 /home/dead/$name.log 2>/dev/null || echo 'no log yet'"
}

# Arm the room waiter. Run it in the BACKGROUND - it blocks until somebody
# addresses you, and that return is the wake-up.
cmd_listen() {
	exec firecode chat --inbox --as "${FIRECODE_CHAT_NAME:-claude-host}"
}

case "${1:-all}" in
lint) cmd_lint ;;
packcheck) cmd_packcheck ;;
fusecheck) cmd_fusecheck ;;
gatecheck) cmd_gatecheck ;;
status) cmd_status ;;
push) cmd_push ;;
await-commit) cmd_await_commit ;;
commit) cmd_commit ;;
room) cmd_room ;;
server) cmd_server ;;
virt) cmd_virt ;;
lab)
	shift
	cmd_lab "$@"
	;;
listen) cmd_listen ;;
relay) cmd_relay ;;
say)
	shift
	cmd_say "$@"
	;;
all)
	cmd_status
	cmd_room
	cmd_server
	;;
*)
	sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
	;;
esac
