# syntax=docker/dockerfile:1.7
#
# boxy — a disposable, SSH-reachable dev box.
#
# Design notes:
#   * Nothing secret is baked in. Keys, password hashes, repo URLs and proxy
#     settings all arrive as environment at `docker run` time and are applied by
#     docker/entrypoint.sh. One image serves every instance.
#   * There is no init system. tini is PID 1 (for signal handling and zombie
#     reaping), the entrypoint sets the box up, then execs `sshd -D`.
#   * Multi-arch: builds on linux/amd64 and linux/arm64 from the same file.
#
# Build:  ./boxy build
# Run:    ./boxy create

ARG DEBIAN_VERSION=bookworm

FROM debian:${DEBIAN_VERSION}-slim

# TARGETARCH is set automatically by BuildKit: "amd64" or "arm64".
ARG TARGETARCH
ARG USERNAME=boxyboy
ARG USER_UID=1000
ARG USER_GID=1000
# Both default OFF. The base image is the stack you actually asked for;
# everything optional is a deliberate opt-in via `boxy build --full`.
#   INSTALL_EXTRAS      jupyterlab, polars, pyarrow, scikit-learn   (+462 MB)
#   INSTALL_CLAUDE_CODE @anthropic-ai/claude-code                   (+291 MB)
ARG INSTALL_CLAUDE_CODE=0
ARG INSTALL_EXTRAS=0
ARG PYTHON_VERSION=3.12

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    CONDA_DIR=/opt/conda \
    BOXY_USER=${USERNAME}

# ---------------------------------------------------------------------------
# Base system
# ---------------------------------------------------------------------------
# `whois` is here for mkpasswd(1): boxy hashes the generated password by piping
# it through this image, so the plaintext never needs a shell argument or an
# openssl that may or may not support -6 on the host.
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    sudo \
    tini \
    ca-certificates \
    curl \
    wget \
    git \
    git-lfs \
    gnupg \
    whois \
    less \
    vim-tiny \
    nano \
    tmux \
    htop \
    procps \
    psmisc \
    rsync \
    unzip \
    zip \
    bzip2 \
    xz-utils \
    jq \
    ripgrep \
    fd-find \
    tree \
    file \
    build-essential \
    pkg-config \
    iproute2 \
    iptables \
    iputils-ping \
    netcat-openbsd \
    dnsutils \
    socat \
    locales \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Unprivileged user
# ---------------------------------------------------------------------------
# The password is set at *runtime* from a hash. sudo is gated on that password,
# so an empty/locked account here is the correct starting state.
#
# /opt/conda is created and handed over NOW, before anything is installed into
# it, because everything below runs as this user. A `RUN chown -R` afterwards
# would rewrite every one of ~40k conda files into a fresh layer and double the
# image size — layers are copy-on-write per file, and a metadata change counts.
RUN groupadd --gid "${USER_GID}" "${USERNAME}" \
    && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home \
    --shell /bin/bash "${USERNAME}" \
    && usermod -aG sudo "${USERNAME}" \
    && install -d -m 700 -o "${USER_UID}" -g "${USER_GID}" /home/"${USERNAME}"/.ssh \
    && install -d -m 755 -o "${USER_UID}" -g "${USER_GID}" "${CONDA_DIR}" \
    && install -d -m 755 -o "${USER_UID}" -g "${USER_GID}" /work

# ---------------------------------------------------------------------------
# sshd
# ---------------------------------------------------------------------------
# /run/sshd is the privilege-separation directory; sshd refuses to start
# without it. Host keys live in /etc/ssh/hostkeys, which boxy bind-mounts from
# per-instance state so a recreated box keeps its identity and does not trip
# your known_hosts.
COPY sshd_config /etc/ssh/sshd_config
RUN mkdir -p /run/sshd /etc/ssh/hostkeys /etc/ssh/sshd_config.d \
    && chmod 755 /run/sshd \
    && rm -f /etc/ssh/ssh_host_*

# ===========================================================================
# Everything below installs into /opt/conda AS THE BOX USER, so the prefix is
# writable at runtime (pip install / mamba install without sudo) without a
# single recursive chown.
# ===========================================================================
USER ${USERNAME}
ENV HOME=/home/${USERNAME}

# ---------------------------------------------------------------------------
# Miniforge (conda-forge defaults — no Anaconda ToS entanglement)
# ---------------------------------------------------------------------------
# -b is batch mode: without it the installer waits forever on a license prompt,
# which in a Docker build looks like a hang with no output.
# -u is required because the prefix already exists — we created it above and
# handed it to the box user precisely so this install lands with the right
# ownership. Without -u the installer refuses a non-empty-looking target.
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64) MF_ARCH=x86_64 ;; \
    arm64) MF_ARCH=aarch64 ;; \
    *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/miniforge.sh \
    "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${MF_ARCH}.sh"; \
    bash /tmp/miniforge.sh -b -u -p "${CONDA_DIR}"; \
    rm -f /tmp/miniforge.sh; \
    "${CONDA_DIR}/bin/conda" config --system --set auto_update_conda false; \
    "${CONDA_DIR}/bin/conda" config --system --set always_yes true; \
    "${CONDA_DIR}/bin/conda" clean -afy

ENV PATH=${CONDA_DIR}/bin:${PATH}

# ---------------------------------------------------------------------------
# Scientific / tooling stack
# ---------------------------------------------------------------------------
# Split deliberately: mamba for things with compiled deps and a solver-shaped
# dependency graph, pip for pure-Python and for jax (whose PyPI wheels have the
# broadest arch coverage).
#
# matplotlib-base, NOT matplotlib: conda-forge's `matplotlib` metapackage drags
# in the entire Qt6 GUI toolkit — including static .a libraries — which is dead
# weight in a headless container reached over SSH. matplotlib-base is the same
# plotting library without the interactive backends; Agg still works, so
# savefig() and marimo/notebook rendering are unaffected.
RUN set -eux; \
    mamba install -y -n base -c conda-forge \
    "python=${PYTHON_VERSION}" \
    numpy \
    scipy \
    pandas \
    matplotlib-base \
    ipython \
    nodejs \
    pip \
    ; \
    mamba clean -afy

RUN set -eux; \
    pip install --no-cache-dir \
    "jax[cpu]" \
    marimo \
    tqdm \
    rich \
    httpx \
    uv \
    gomp \
    ; \
    rm -rf "$HOME/.cache/pip"

# Opt-in extras. Anything here is reachable at runtime with `pip install` or
# `uv pip install` anyway — the conda prefix is user-writable — so baking them
# in only pays off if you want them in every box.
RUN set -eux; \
    if [ "${INSTALL_EXTRAS}" = "1" ]; then \
    pip install --no-cache-dir jupyterlab polars pyarrow scikit-learn; \
    rm -rf "$HOME/.cache/pip"; \
    fi

# Optional: Claude Code inside the box, for when you want an agent working
# locally on the volume rather than reaching in over SSH.
# npm's global prefix is conda's own /opt/conda, which this user owns — no
# sudo and no root-owned files in the tree.
RUN set -eux; \
    if [ "${INSTALL_CLAUDE_CODE}" = "1" ]; then \
    npm install -g @anthropic-ai/claude-code; \
    npm cache clean --force; \
    fi

RUN "${CONDA_DIR}/bin/conda" init bash \
    && echo '. /opt/conda/etc/profile.d/conda.sh && conda activate base' \
    >> "$HOME/.bashrc"

# ---------------------------------------------------------------------------
# Back to root for the pieces the entrypoint needs
# ---------------------------------------------------------------------------
USER root
ENV HOME=/root

COPY docker/entrypoint.sh /usr/local/bin/boxy-entrypoint
RUN chmod 755 /usr/local/bin/boxy-entrypoint

ENV DISABLE_AUTOUPDATER=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    BOXY_WORKDIR=/work \
    PATH=${CONDA_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /work
EXPOSE 22
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/boxy-entrypoint"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
