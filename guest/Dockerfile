# firellm guest rootfs.
#
# Built with Docker so `firellm prepare` needs no root on the host: the
# container is exported and converted to an ext4 image with `mkfs.ext4 -d`.
#
# The agent binaries (claude, opencode) are deliberately NOT installed here.
# They are carried in on the read-only config drive so the guest always runs
# the same version as the host.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# lean = boots fast, enough for most work. full = adds rust/go/zig/llvm/sbcl.
ARG FIRELLM_TOOLCHAINS=lean

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
RUN apt-get update && apt-get install -y --no-install-recommends \
	git git-lfs openssh-client \
	build-essential make pkg-config \
	python3 python3-pip python3-venv \
	ripgrep fd-find jq unzip tar xz-utils zstd \
	vim less tmux procps psmisc file bash-completion \
	&& ln -sf /usr/bin/fdfind /usr/local/bin/fd \
	&& rm -rf /var/lib/apt/lists/*

# Node (agents and their MCP servers assume it) and bun.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
	&& apt-get install -y --no-install-recommends nodejs \
	&& rm -rf /var/lib/apt/lists/* \
	&& npm install -g pnpm yarn 2>/dev/null || true
RUN curl -fsSL https://bun.sh/install | bash \
	&& ln -sf /root/.bun/bin/bun /usr/local/bin/bun

# Optional heavy toolchains. Skipped by default: they roughly quadruple both
# the build time and the image size.
RUN if [ "$FIRELLM_TOOLCHAINS" = "full" ]; then \
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

# mise, so the guest can match whatever tool versions a project pins.
RUN curl -fsSL https://mise.run | sh \
	&& ln -sf /root/.local/bin/mise /usr/local/bin/mise

# ---------------------------------------------------------------- guest bits
COPY firellm-setup.sh agent-entrypoint.sh profile.sh /opt/firellm/
COPY firellm-context.md /opt/firellm/
COPY systemd/firellm-mounts.service systemd/firellm-agent.service \
	/etc/systemd/system/
COPY mkimage.sh /usr/local/sbin/firellm-mkimage

RUN chmod +x /opt/firellm/firellm-setup.sh /opt/firellm/agent-entrypoint.sh \
	/usr/local/sbin/firellm-mkimage \
	&& mkdir -p /src /opt/firellm/config /opt/firellm/run /var/lib/firellm

# systemctl cannot enable units in a container, so link the wants by hand.
RUN mkdir -p /etc/systemd/system/multi-user.target.wants \
	&& ln -sf /etc/systemd/system/firellm-mounts.service \
	/etc/systemd/system/multi-user.target.wants/firellm-mounts.service \
	&& ln -sf /etc/systemd/system/firellm-agent.service \
	/etc/systemd/system/multi-user.target.wants/firellm-agent.service

# Autologin root on the serial console, for interactive sessions.
RUN mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d \
	&& printf '%s\n' \
	'[Service]' \
	'ExecStart=' \
	'ExecStart=-/sbin/agetty --autologin root --noclear %I 115200,38400,9600 vt220' \
	> /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf \
	&& passwd -d root \
	&& printf '%s\n' \
	'# firellm' \
	'[ -f /opt/firellm/profile.sh ] && . /opt/firellm/profile.sh' \
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
# at boot, in firellm-setup.sh.
RUN : > /etc/machine-id \
	&& printf '# firellm mounts its drives from firellm-setup.sh, by label\n' \
	> /etc/fstab

RUN printf '%s\n' \
	'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
	'FIRELLM=1' \
	'IS_SANDBOX=1' \
	> /etc/environment

CMD ["/sbin/init"]
