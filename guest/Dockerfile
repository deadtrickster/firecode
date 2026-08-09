FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget git build-essential \
    python3 python3-pip python3-venv \
    ripgrep fd-find jq socat \
    openssh-server sudo vim less \
    && rm -rf /var/lib/apt/lists/*

# node via nodesource or nvm? for simplicity use nodesource
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# bun (fast js runtime, good for many agents)
RUN curl -fsSL https://bun.sh/install | bash -s -- --yes \
    && ln -s /root/.bun/bin/bun /usr/local/bin/bun || true

# common LLM/agent CLIs (optional - user can mount their own)
# RUN npm install -g @anthropic-ai/claude-code || true

# firellm agent entrypoint
COPY agent-entrypoint.sh /opt/firellm/agent-run
RUN chmod +x /opt/firellm/agent-run

# prepare for serial console login if needed
RUN mkdir -p /root/.ssh /work && \
    echo 'root:root' | chpasswd && \
    echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config && \
    echo 'PermitEmptyPasswords yes' >> /etc/ssh/sshd_config

# minimal network setup script (called on boot if needed)
RUN echo '#!/bin/sh\nip link set eth0 up || true\n' > /etc/network/if-up.d/firellm && chmod +x /etc/network/if-up.d/firellm

# default cmd is the agent runner (but firecracker boots via kernel, we use systemd or agetty)
# we will start sshd + a simple vsock agent or just rely on user running in shell
CMD ["/bin/bash"]
