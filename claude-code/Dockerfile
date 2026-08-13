# syntax=docker/dockerfile:1
FROM ubuntu:24.04

ARG TARGETARCH
ARG DEBIAN_FRONTEND=noninteractive
ARG TTYD_VERSION=1.7.7
ARG NODE_MAJOR=22

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Base toolchain. Anything you want permanently available belongs here rather
# than in the add-on's `extra_packages` option, which re-installs on every start.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash-completion \
        build-essential \
        ca-certificates \
        curl \
        fd-find \
        file \
        git \
        gnupg \
        htop \
        jq \
        less \
        locales \
        nano \
        openssh-client \
        procps \
        python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        rsync \
        sudo \
        tmux \
        tzdata \
        unzip \
        vim \
        wget \
        zip \
    && locale-gen en_US.UTF-8 \
    && ln -s "$(command -v fdfind)" /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# Node.js (also the delivery vehicle for Claude Code)
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# uv (Python toolchain manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# ttyd — serves the terminal that Home Assistant Ingress proxies
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) ttyd_arch="x86_64" ;; \
        arm64) ttyd_arch="aarch64" ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/ttyd \
        "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${ttyd_arch}"; \
    chmod +x /usr/local/bin/ttyd; \
    ttyd --version

# Claude Code
RUN npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force \
    && claude --version

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    HOME=/data/home \
    CLAUDE_CONFIG_DIR=/data/home/.claude

COPY run.sh /usr/local/bin/run.sh
# Baked into the image rather than run from the workspace checkout: the clone
# happens at runtime and can fail, and a service the house depends on must not
# be contingent on that.
COPY dispatch/dispatchd.py /opt/dispatch/dispatchd.py
RUN chmod +x /usr/local/bin/run.sh

LABEL org.opencontainers.image.source="https://github.com/ClaytonSmith/haos-claude-code"

CMD ["/usr/local/bin/run.sh"]
