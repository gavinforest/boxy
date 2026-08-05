#!/usr/bin/env bash
# boxy container entrypoint — runs as root, PID 1's child (tini).
#
# Everything instance-specific is applied here, from environment, at start.
# The image itself contains no keys, no password, no repo URL.
set -euo pipefail

log() { printf '[boxy] %s\n' "$*" >&2; }
die() { printf '[boxy] FATAL: %s\n' "$*" >&2; exit 1; }

BOXY_USER="${BOXY_USER:-boxyboy}"
BOXY_WORKDIR="${BOXY_WORKDIR:-/work}"
BOXY_NAME="${BOXY_NAME:-boxy}"
CONDA_DIR="${CONDA_DIR:-/opt/conda}"

id -u "$BOXY_USER" >/dev/null 2>&1 || die "user '$BOXY_USER' does not exist in this image"
USER_HOME="$(getent passwd "$BOXY_USER" | cut -d: -f6)"

# Run a command as the box user WITH a correct $HOME.
#
# `runuser -u X -- cmd` deliberately preserves the caller's environment, so
# HOME stays /root. Without this, `git config --global` would land in
# /root/.gitconfig and `git clone` would never see ~boxyboy/.ssh/config — both
# failing silently, in ways only visible on a worktree or proxied box.
as_user() {
    runuser -u "$BOXY_USER" -- env "HOME=$USER_HOME" "USER=$BOXY_USER" "$@"
}

# ---------------------------------------------------------------------------
# 1. UID/GID remap
# ---------------------------------------------------------------------------
# On Linux hosts a bind mount carries the host's numeric ownership straight
# through — there is no translation layer. If the box user's UID does not match
# the host user's, every file on the mounted volume looks like it belongs to
# someone else. Remapping fixes that at start rather than at build.
if [[ -n "${BOXY_GID:-}" && "$BOXY_GID" != "$(id -g "$BOXY_USER")" ]]; then
    log "remapping group $BOXY_USER -> gid $BOXY_GID"
    groupmod -o -g "$BOXY_GID" "$BOXY_USER"
fi
if [[ -n "${BOXY_UID:-}" && "$BOXY_UID" != "$(id -u "$BOXY_USER")" ]]; then
    log "remapping user $BOXY_USER -> uid $BOXY_UID"
    usermod -o -u "$BOXY_UID" "$BOXY_USER"
fi
CUR_UID="$(id -u "$BOXY_USER")"
CUR_GID="$(id -g "$BOXY_USER")"
chown -R "$CUR_UID:$CUR_GID" "$USER_HOME" 2>/dev/null || true

# The conda prefix is ~40k files. If a remap left it owned by the old uid, it
# has to be fixed or `pip install` breaks — but that takes minutes, and
# blocking sshd on it makes a fresh box look hung. Do it in the background and
# say so; SSH is usable immediately, and only conda writes wait.
if [[ "$(stat -c %u "$CONDA_DIR")" != "$CUR_UID" ]]; then
    log "conda prefix owned by $(stat -c %u "$CONDA_DIR"), remapping to $CUR_UID in the background"
    (
        chown -R "$CUR_UID:$CUR_GID" "$CONDA_DIR" \
            && log "conda prefix remap complete" \
            || log "WARNING: conda prefix remap failed; pip/mamba installs may need sudo"
    ) &
fi

# ---------------------------------------------------------------------------
# 2. SSH host keys
# ---------------------------------------------------------------------------
# Persisted on a bind mount from per-instance state so a recreated box keeps
# its fingerprint and does not trigger the scary known_hosts warning.
install -d -m 755 /etc/ssh/hostkeys
if [[ ! -f /etc/ssh/hostkeys/ssh_host_ed25519_key ]]; then
    log "generating ed25519 host key"
    ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/hostkeys/ssh_host_ed25519_key
fi
if [[ ! -f /etc/ssh/hostkeys/ssh_host_rsa_key ]]; then
    log "generating rsa host key"
    ssh-keygen -q -t rsa -b 4096 -N '' -f /etc/ssh/hostkeys/ssh_host_rsa_key
fi
chown root:root /etc/ssh/hostkeys/ssh_host_*
chmod 600 /etc/ssh/hostkeys/ssh_host_*_key
chmod 644 /etc/ssh/hostkeys/ssh_host_*.pub

# ---------------------------------------------------------------------------
# 3. Authorized keys
# ---------------------------------------------------------------------------
SSH_DIR="$USER_HOME/.ssh"
install -d -m 700 -o "$CUR_UID" -g "$CUR_GID" "$SSH_DIR"
if [[ -n "${BOXY_AUTHORIZED_KEYS:-}" ]]; then
    printf '%s\n' "$BOXY_AUTHORIZED_KEYS" \
        | grep -v '^[[:space:]]*$' > "$SSH_DIR/authorized_keys"
    chown "$CUR_UID:$CUR_GID" "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
    log "installed $(wc -l < "$SSH_DIR/authorized_keys") authorized key(s) for $BOXY_USER"
else
    log "WARNING: no BOXY_AUTHORIZED_KEYS supplied — nobody can log in"
fi

# Pin logins to the box user. sshd already refuses root, this closes the rest.
printf 'AllowUsers %s\n' "$BOXY_USER" > /etc/ssh/sshd_config.d/10-boxy.conf
chmod 644 /etc/ssh/sshd_config.d/10-boxy.conf

# ---------------------------------------------------------------------------
# 4. Password (hash only — the plaintext lives on the host, never here)
# ---------------------------------------------------------------------------
if [[ -n "${BOXY_PASSWORD_HASH:-}" ]]; then
    printf '%s:%s\n' "$BOXY_USER" "$BOXY_PASSWORD_HASH" | chpasswd -e
    log "sudo password set for $BOXY_USER (hash supplied by host)"
    # Scrub it from our own environment so it does not leak into child
    # processes or /proc/<pid>/environ of the sshd tree.
    unset BOXY_PASSWORD_HASH
else
    passwd -l "$BOXY_USER" >/dev/null
    log "no password hash supplied — account locked, sudo unavailable"
fi

# ---------------------------------------------------------------------------
# 5. Egress proxy
# ---------------------------------------------------------------------------
# /etc/environment is read by pam_env, which is what makes these visible to
# NON-interactive SSH commands (`ssh box python ...`). Those shells read
# neither /etc/profile nor ~/.bashrc, so anything set only in profile.d would
# be invisible to exactly the case an agent driving the box hits most.
{
    printf 'PATH=%s/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' "$CONDA_DIR"
    printf 'LANG=C.UTF-8\n'
    printf 'BOXY_NAME=%s\n' "$BOXY_NAME"
} > /etc/environment

# ...and a second time for LOGIN shells, which pam_env does not cover.
# Debian's /etc/profile hard-assigns PATH (it does not append), so a login
# shell throws away the image's ENV PATH and loses the conda prefix entirely.
# profile.d is sourced after that assignment, which is the place to undo it.
# `docker exec ... bash -l` hits this; sshd does not, because pam_env has
# already supplied PATH from /etc/environment.
cat > /etc/profile.d/00-boxy-path.sh <<EOF
case ":\$PATH:" in
    *":$CONDA_DIR/bin:"*) ;;
    *) PATH="$CONDA_DIR/bin:\$PATH" ;;
esac
export PATH
EOF
chmod 644 /etc/profile.d/00-boxy-path.sh

if [[ -n "${BOXY_PROXY_URL:-}" ]]; then
    log "egress restricted via proxy $BOXY_PROXY_URL"
    NO_PROXY_LIST="localhost,127.0.0.1,::1,.local"
    {
        printf 'http_proxy=%s\n'  "$BOXY_PROXY_URL"
        printf 'https_proxy=%s\n' "$BOXY_PROXY_URL"
        printf 'HTTP_PROXY=%s\n'  "$BOXY_PROXY_URL"
        printf 'HTTPS_PROXY=%s\n' "$BOXY_PROXY_URL"
        printf 'no_proxy=%s\n'    "$NO_PROXY_LIST"
        printf 'NO_PROXY=%s\n'    "$NO_PROXY_LIST"
    } >> /etc/environment
    cat > /etc/profile.d/boxy-proxy.sh <<EOF
export http_proxy="$BOXY_PROXY_URL" https_proxy="$BOXY_PROXY_URL"
export HTTP_PROXY="$BOXY_PROXY_URL" HTTPS_PROXY="$BOXY_PROXY_URL"
export no_proxy="$NO_PROXY_LIST" NO_PROXY="$NO_PROXY_LIST"
EOF
    chmod 644 /etc/profile.d/boxy-proxy.sh
    # git over https honours http.proxy; git over ssh needs a CONNECT tunnel,
    # wired up in the user's ssh config below.
    as_user git config --global http.proxy "$BOXY_PROXY_URL"
    as_user git config --global https.proxy "$BOXY_PROXY_URL"
fi

# ---------------------------------------------------------------------------
# 6. Client ssh config
# ---------------------------------------------------------------------------
# No keys are installed here. A box's git work is against the shared git dir
# mounted from the host, so it needs no credentials and reaches no remote.
SSH_CONF="$SSH_DIR/config"
: > "$SSH_CONF"
if [[ -n "${BOXY_PROXY_URL:-}" ]]; then
    # Strip scheme, then let netcat CONNECT through the allowlist proxy.
    proxy_hostport="${BOXY_PROXY_URL#*://}"
    cat >> "$SSH_CONF" <<EOF
Host github.com gitlab.com bitbucket.org ssh.github.com
    User git
    ProxyCommand nc -X connect -x $proxy_hostport %h %p
EOF
fi
cat >> "$SSH_CONF" <<'EOF'

Host *
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
EOF
chown "$CUR_UID:$CUR_GID" "$SSH_CONF"
chmod 600 "$SSH_CONF"

# ---------------------------------------------------------------------------
# 7. Workdir
# ---------------------------------------------------------------------------
install -d -o "$CUR_UID" -g "$CUR_GID" "$BOXY_WORKDIR"
# Chown only when ownership actually differs; a large mounted tree is slow.
if [[ "$(stat -c %u "$BOXY_WORKDIR")" != "$CUR_UID" ]]; then
    chown "$CUR_UID:$CUR_GID" "$BOXY_WORKDIR" || true
fi

# A bind-mounted tree carries the host's UIDs, which are not this user's, and
# git refuses to operate on a repo it thinks belongs to someone else. Both
# paths need naming: /work holds the checkout, and for a worktree the objects
# and refs live in the separately mounted git dir.
as_user git config --global --add safe.directory "$BOXY_WORKDIR" || true
if [[ -n "${BOXY_GIT_COMMON_DIR:-}" ]]; then
    as_user git config --global --add safe.directory "$BOXY_GIT_COMMON_DIR" || true
fi

# Land in the workdir. Two places, because they cover different shells:
#   /etc/profile.d  → login shells (an interactive `ssh box`)
#   ~/.bashrc       → `ssh box <cmd>`. Bash notices its stdin is a socket when
#                     started by sshd and reads ~/.bashrc even though the shell
#                     is non-interactive — which is the case an agent driving
#                     this box hits constantly.
printf 'cd %q 2>/dev/null || true\n' "$BOXY_WORKDIR" > /etc/profile.d/boxy-cd.sh
chmod 644 /etc/profile.d/boxy-cd.sh

BASHRC="$USER_HOME/.bashrc"
if ! grep -q '^# >>> boxy >>>' "$BASHRC" 2>/dev/null; then
    # This block must sit ABOVE the `case $- in *i*) ;; *) return;; esac` guard
    # Debian ships at the top of .bashrc, or the non-interactive case returns
    # before ever reaching it.
    boxy_tmp="$(mktemp)"
    {
        printf '# >>> boxy >>>\n'
        printf 'cd %q 2>/dev/null || true\n' "$BOXY_WORKDIR"
        printf '# <<< boxy <<<\n'
        cat "$BASHRC" 2>/dev/null || true
    } > "$boxy_tmp"
    # Copy contents rather than mv, to keep the file's existing ownership.
    cat "$boxy_tmp" > "$BASHRC"
    rm -f "$boxy_tmp"
fi

# ---------------------------------------------------------------------------
# 9. MOTD + hand off to sshd
# ---------------------------------------------------------------------------
{
    printf '\n  boxy: %s\n' "$BOXY_NAME"
    printf '  workdir: %s   user: %s\n' "$BOXY_WORKDIR" "$BOXY_USER"
    if [[ -n "${BOXY_PROXY_URL:-}" ]]; then
        printf '  python: %s   egress: proxied (allowlist)\n' "$(python --version 2>&1)"
    else
        printf '  python: %s\n' "$(python --version 2>&1)"
    fi
    printf '  Bind servers to 0.0.0.0 (e.g. marimo edit --host 0.0.0.0) to reach\n'
    printf '  them from the host on published ports.\n\n'
} > /etc/motd

log "sshd starting"
exec "$@"
