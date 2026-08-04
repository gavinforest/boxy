#!/usr/bin/env bash
# Core: creation, the box interior, the volume, sudo, and the security
# properties that are supposed to hold.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env

WORK="$TEST_TMP/work"
rm -rf "$WORK"; mkdir -p "$WORK/src"
echo "from the host" > "$WORK/notes.md"

section "create"
out="$(boxy create -d "$WORK" --no-git-key 2>&1)"
assert_contains "reports the instance and its ssh port" "ssh at port 2200" "$out"
assert_contains "says no ports are published by default" "none published" "$out"

section "identity and environment"
assert_eq "runs as the unprivileged box user" "boxyboy" "$(bssh boxy-1 whoami)"
assert_eq "lands in /work"                    "/work"   "$(bssh boxy-1 pwd)"
assert_eq "/work is a directory"              "directory" "$(bssh boxy-1 'stat -c %F /work')"
assert_eq "conda python on non-interactive PATH" "/opt/conda/bin/python" \
    "$(bssh boxy-1 'command -v python')"
assert_eq "conda python on login-shell PATH"     "/opt/conda/bin/python" \
    "$(bssh boxy-1 'bash -lc "command -v python"')"
assert_eq "login shell also lands in /work"      "/work" \
    "$(bssh boxy-1 'bash -lc pwd')"
assert_eq "uv present" "/opt/conda/bin/uv" "$(bssh boxy-1 'command -v uv')"

section "the scientific stack"
assert_contains "numpy/scipy/jax import and compute" "jax-ok" \
    "$(bssh boxy-1 'python -c "
import numpy, scipy, jax, jax.numpy as jnp
assert abs(float(jnp.dot(jnp.arange(4.), jnp.arange(4.))) - 14.0) < 1e-6
print(\"jax-ok\")"')"
assert_contains "marimo runs" "marimo" "$(bssh boxy-1 'command -v marimo')"

section "the mounted volume"
assert_contains "box sees a host file" "from the host" "$(bssh boxy-1 'cat /work/notes.md')"
bssh boxy-1 "printf 'written inside\n' > /work/out.txt" >/dev/null
assert_file_contains "host sees a box file" "$WORK/out.txt" "written inside"

section "package installs need no sudo"
assert_contains "pip install into the conda prefix" "humanize-ok" \
    "$(bssh boxy-1 'pip install -q --no-input humanize >/dev/null 2>&1 && python -c "import humanize; print(\"humanize-ok\")"')"

section "password: sudo only, host-side plaintext"
PW="$(boxy password boxy-1)"
assert_contains "generated a multi-word passphrase" "-" "$PW"
assert_contains "sudo works with it" "uid=0(root)" \
    "$(bssh boxy-1 "echo '$PW' | sudo -S -k id")"
assert_contains "sudo refuses without it" "password is required" \
    "$(bssh boxy-1 'sudo -n true')"
assert_eq "plaintext absent from docker inspect" "0" \
    "$(docker inspect boxy-1 | grep -cF "$PW")"
assert_eq "plaintext absent from the container's environ" "0" \
    "$(docker exec boxy-1 sh -c "tr '\0' '\n' </proc/1/environ | grep -cF '$PW'")"
# -F, not a regex: '$6$' contains two '$', and a trailing '$' in a BRE is an
# end-of-line anchor, so the "obvious" pattern can never match.
assert_eq "sha512 hash IS in /etc/shadow" "1" \
    "$(docker exec boxy-1 grep -cF 'boxyboy:$6$' /etc/shadow)"

section "sshd hardening"
assert_contains "password auth refused" "Permission denied" \
    "$(ssh -F "$SSH_CFG" -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o ConnectTimeout=5 -o NumberOfPasswordPrompts=0 boxy-1 true 2>&1)"
assert_contains "root login refused" "Permission denied" \
    "$(ssh -F "$SSH_CFG" -o User=root -o ConnectTimeout=5 boxy-1 true 2>&1)"

section "host key pinning"
assert_file_contains "known_hosts written before first connect" \
    "$BOXY_STATE_DIR/instances/boxy-1/known_hosts" "ssh-ed25519"
assert_contains "known_hosts matches the box's actual host key" \
    "$(cut -d' ' -f2 < "$BOXY_STATE_DIR/instances/boxy-1/hostkeys/ssh_host_ed25519_key.pub")" \
    "$(cat "$BOXY_STATE_DIR/instances/boxy-1/known_hosts")"

section "boxy never writes to ~/.ssh"
assert_contains "its keypair lives in the state dir" "$BOXY_STATE_DIR" "$BOXY_SSH_KEY"
assert_eq "the keypair was created there" "yes" \
    "$( [ -f "$BOXY_SSH_KEY" ] && echo yes || echo no )"

section "second instance"
boxy create -n api --no-git-key >/dev/null 2>&1
assert_eq "next ssh port is 2201" "2201" "$(boxy info api | awk '/^ssh port/{print $3}')"
assert_contains "ls shows both" "api" "$(boxy ls)"

purge_all
report "core"
