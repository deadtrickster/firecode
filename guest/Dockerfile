# firecode guest rootfs.
#
# Built with Docker so `firecode prepare` needs no root on the host: the
# container is exported and converted to an ext4 image with `mkfs.ext4 -d`.
#
# The agent binaries (claude, opencode) are deliberately NOT installed here.
# They are carried in on the read-only config drive so the guest always runs
# the same version as the host.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# lean = boots fast, enough for most work. full = adds rust/go/zig/llvm/sbcl.
ARG FIRECODE_TOOLCHAINS=lean

# Init system and the pieces the guest setup relies on. udev is what gives us
# /dev/disk/by-label, which is how the drives are found regardless of the
# order Firecracker attaches them.
RUN apt-get update && apt-get install -y --no-install-recommends \
	systemd systemd-sysv udev dbus-daemon \
	e2fsprogs util-linux iproute2 iputils-ping netbase \
	ca-certificates curl wget gnupg socat sudo passwd \
	locales tzdata \
	&& rm -rf /var/lib/apt/lists/*

# Everyday tooling an agent expects to find.
#
# fuse3 and its headers are in here rather than left to be installed per
# project: the kernel has CONFIG_FUSE_FS built in, so a filesystem written in
# a VM works - but only if the userspace half exists, and finding out that it
# does not is a detour taken once per project for no reason. libfuse-dev is
# what a C filesystem builds against; fusepy and pyfuse3 cover the two ways
# anyone writes one in Python, and neither is packaged usefully by pip inside
# a VM with no wheels cached.
#
# Nothing across the VM boundary comes from this: firecracker has no
# virtio-fs, so a FUSE mount lives and dies inside the guest, and what travels
# is still the project drive.
RUN apt-get update && apt-get install -y --no-install-recommends \
	git git-lfs openssh-client \
	build-essential make pkg-config \
	python3 python3-pip python3-venv \
	fuse3 libfuse3-dev libfuse-dev \
	python3-fusepy python3-pyfuse3 \
	ripgrep fd-find jq unzip tar xz-utils zstd \
	libicu74 \
	vim less tmux procps psmisc file bash-completion \
	&& ln -sf /usr/bin/fdfind /usr/local/bin/fd \
	&& rm -rf /var/lib/apt/lists/*

# Node (agents and their MCP servers assume it) and bun.
#
# --retry, because a build host on a VPN resolves and connects unreliably, and
# a single curl that gives up takes the whole image with it - twenty minutes
# of work lost to one refused name. curl's own retry covers the transient
# case; the DNS case is handled a level up, where prepare notices "could not
# resolve" and rebuilds on the host network.
RUN curl -fsSL --retry 5 --retry-delay 3 --retry-connrefused --connect-timeout 20 \
	https://deb.nodesource.com/setup_22.x | bash - \
	&& apt-get install -y --no-install-recommends nodejs \
	&& rm -rf /var/lib/apt/lists/* \
	&& npm install -g pnpm yarn 2>/dev/null || true
RUN curl -fsSL --retry 5 --retry-delay 3 --retry-connrefused --connect-timeout 20 \
	https://bun.sh/install | bash \
	&& ln -sf /root/.bun/bin/bun /usr/local/bin/bun

# Optional heavy toolchains. Skipped by default: they roughly quadruple both
# the build time and the image size.
RUN if [ "$FIRECODE_TOOLCHAINS" = "full" ]; then \
	set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends clang clang-tools lld llvm sbcl; \
	rm -rf /var/lib/apt/lists/*; \
	GO_VERSION=1.23.4; \
	curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xz; \
	ln -sf /usr/local/go/bin/go /usr/local/bin/go; \
	ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt; \
	curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
	| sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path; \
	ln -sf /root/.cargo/bin/rustc /usr/local/bin/rustc; \
	ln -sf /root/.cargo/bin/cargo /usr/local/bin/cargo; \
	ln -sf /root/.cargo/bin/rustup /usr/local/bin/rustup; \
	ZIG_VERSION=0.13.0; \
	curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" \
	| tar -C /usr/local -xJ; \
	ln -sf "/usr/local/zig-linux-x86_64-${ZIG_VERSION}/zig" /usr/local/bin/zig; \
	fi

# mise, in a place every user in the guest can read. The default under /root
# is invisible to the account the agent actually runs as.
ENV MISE_DATA_DIR=/opt/mise \
	MISE_CONFIG_DIR=/opt/mise/config \
	MISE_STATE_DIR=/opt/mise/state \
	MISE_CACHE_DIR=/var/cache/mise
RUN curl -fsSL https://mise.run | sh \
	&& install -m 0755 /root/.local/bin/mise /usr/local/bin/mise \
	&& mkdir -p /opt/mise /var/cache/mise && chmod 0755 /opt/mise

# Toolchains for the base image, which every project inherits read-only. This
# is where a dotnet or a JDK belongs: installed once here rather than once per
# workspace, where each VM would download it again.
#
#   firecode prepare --with "dotnet@10 java@temurin-21 uv"
ARG FIRECODE_TOOLS=
# Retried, and with a timeout that suits a toolchain rather than a web page.
# Every install here pulls a few hundred megabytes from a different host -
# dot.net, temurin, astral - and mise gives up after 30 seconds by default, so
# one slow mirror fails a twenty-minute build at the last step. Three attempts
# with a pause between them turns "come back and run it again" into "it took
# a bit longer".
ENV MISE_HTTP_TIMEOUT=300
RUN if [ -n "$FIRECODE_TOOLS" ]; then \
	set -eux; \
	mise use -g $FIRECODE_TOOLS; \
	mise install -y || { sleep 10; mise install -y; } || { sleep 30; mise install -y; }; \
	mise reshim; \
	mise ls --installed; \
	chmod -R a+rX /opt/mise; \
	fi
# These are build-time ENV as far as Docker is concerned; the guest needs them
# too, or mise looks under the user's home, finds nothing, and reports every
# shim as invalid.
RUN printf '%s\n' \
	'export MISE_DATA_DIR=/opt/mise' \
	'export MISE_CONFIG_DIR=/opt/mise/config' \
	'export MISE_STATE_DIR=/opt/mise/state' \
	'export MISE_CACHE_DIR=/var/cache/mise' \
	'export PATH=/opt/mise/shims:$PATH' \
	> /etc/profile.d/10-mise.sh \
	&& chmod 0644 /etc/profile.d/10-mise.sh

# ---------------------------------------------------------------- guest bits
COPY firecode-setup.sh agent-entrypoint.sh profile.sh /opt/firecode/
COPY firecode-context.md /opt/firecode/
COPY systemd/firecode-mounts.service systemd/firecode-agent.service \
	/etc/systemd/system/
COPY mkimage.sh /usr/local/sbin/firecode-mkimage

# An initramfs that assembles the root out of layers before handing over, so a
# VM can share one read-only base image instead of getting a copy of it.
RUN apt-get update && apt-get install -y --no-install-recommends \
	busybox-static cpio && rm -rf /var/lib/apt/lists/*
COPY initramfs/init /usr/local/share/firecode-initrd-init
RUN set -eux; \
	d=$(mktemp -d); \
	mkdir -p "$d/bin" "$d/proc" "$d/sys" "$d/dev" "$d/newroot"; \
	cp /usr/bin/busybox "$d/bin/busybox"; \
	cp /usr/local/share/firecode-initrd-init "$d/init"; \
	chmod +x "$d/init" "$d/bin/busybox"; \
	ln -sf busybox "$d/bin/sh"; \
	(cd "$d" && find . | cpio -o -H newc --quiet | gzip -9) > /firecode-initrd.gz; \
	rm -rf "$d"; \
	ls -l /firecode-initrd.gz

RUN chmod +x /opt/firecode/firecode-setup.sh /opt/firecode/agent-entrypoint.sh \
	/usr/local/sbin/firecode-mkimage \
	&& mkdir -p /src /opt/firecode/config /opt/firecode/run /var/lib/firecode

# systemctl cannot enable units in a container, so link the wants by hand.
RUN mkdir -p /etc/systemd/system/multi-user.target.wants \
	&& ln -sf /etc/systemd/system/firecode-mounts.service \
	/etc/systemd/system/multi-user.target.wants/firecode-mounts.service \
	&& ln -sf /etc/systemd/system/firecode-agent.service \
	/etc/systemd/system/multi-user.target.wants/firecode-agent.service

# Autologin root on the serial console, for interactive sessions.
RUN mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d \
	&& printf '%s\n' \
	'[Service]' \
	'ExecStart=' \
	'ExecStart=-/sbin/agetty --autologin root --noclear %I 115200,38400,9600 vt220' \
	> /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf \
	&& passwd -d root \
	&& printf '%s\n' \
	'# firecode' \
	'[ -f /opt/firecode/profile.sh ] && . /opt/firecode/profile.sh' \
	> /root/.bash_profile

# Units that either hang without real hardware or fight with our own setup.
# systemd-resolved is the important one: the guest writes /etc/resolv.conf
# directly and a stub resolver on 127.0.0.53 would black-hole every lookup.
RUN systemctl mask \
	systemd-resolved.service \
	systemd-networkd.service \
	systemd-networkd-wait-online.service \
	NetworkManager.service \
	e2scrub_reap.service \
	apt-daily.timer \
	apt-daily-upgrade.timer \
	systemd-timesyncd.service \
	2>/dev/null || true

# A machine-id must exist but be empty, so systemd generates a fresh one per
# boot rather than every VM claiming the same identity.
#
# /etc/resolv.conf, /etc/hosts and /etc/hostname are deliberately left alone:
# Docker bind-mounts them during a build, so they cannot be replaced here and
# edits to them are not committed to the image. The guest writes them itself
# at boot, in firecode-setup.sh.
RUN : > /etc/machine-id \
	&& printf '# firecode mounts its drives from firecode-setup.sh, by label\n' \
	> /etc/fstab

RUN printf '%s\n' \
	'PATH=/opt/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
	'FIRECODE=1' \
	'IS_SANDBOX=1' \
	'MISE_DATA_DIR=/opt/mise' \
	'MISE_CONFIG_DIR=/opt/mise/config' \
	'MISE_STATE_DIR=/opt/mise/state' \
	'MISE_CACHE_DIR=/var/cache/mise' \
	> /etc/environment

# The package index, kept rather than deleted.
#
# Every layer above drops /var/lib/apt/lists to keep the image small, which is
# right for an image you ship and wrong for one you work in: the first
# `apt-get install` in a VM then fails to find anything until someone runs
# `apt-get update`, and a script that does not know to do that gets a package
# that does not exist. It costs about 40MB of a 6G image and saves that
# roundtrip in every VM ever booted from it.
#
# Last, so it is the state the image ends in rather than something a later
# layer cleans up again.
RUN apt-get update

CMD ["/sbin/init"]
