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
out="$(boxy create "$WORK" 2>&1)"
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

section "the login shell is zsh"
assert_eq "the box user's login shell" "/usr/bin/zsh" \
    "$(bssh boxy-1 'getent passwd boxyboy | cut -d: -f7')"
assert_eq "an ssh command runs under zsh, not bash" "zsh" \
    "$(bssh boxy-1 'echo ${ZSH_VERSION:+zsh}${BASH_VERSION:+bash}')"
# Debian's /etc/zsh/zprofile is comments only — it never sources /etc/profile —
# so a zsh login shell sees nothing in /etc/profile.d. The entrypoint's
# ~/.zshenv block is what puts `cd /work` and the `boxy env` loader back, and
# because zsh reads .zshenv on EVERY invocation it covers the interactive and
# the `ssh box cmd` case in one file. The "lands in /work" assertion above is
# the one that would fail if this block went missing.
assert_contains "the boxy block sources profile.d from .zshenv" "profile.d" \
    "$(docker exec boxy-1 cat /home/boxyboy/.zshenv)"
# bash stays fully configured on purpose: `boxy exec` uses `bash -l`, so a
# broken zsh startup file cannot lock you out of the box.
assert_eq "bash is still a working way in" "/opt/conda/bin/python" \
    "$(bssh boxy-1 'bash -lc "command -v python"')"

section "the prompt"
# The theme's helpers are defined in docker/zshrc rather than pulled in with
# oh-my-zsh, whose git_prompt_info is asynchronous — filled by a precmd worker
# through `zle -F` — and delivers nothing to a session driven by a script.
# These assertions only pass against a synchronous implementation.
assert_contains "the theme is installed" "CRUNCH" \
    "$(docker exec boxy-1 head -1 /etc/zsh/crunch-custom.zsh-theme)"
bssh boxy-1 'mkdir -p /work/pt && cd /work/pt && git -c init.defaultBranch=main init -q . \
    && git config user.email t@t && git config user.name t \
    && echo x > f && git add -A && git commit -qm c' >/dev/null
assert_contains "git_prompt_info names the branch" "main" \
    "$(bssh boxy-1 'zsh -ic "cd /work/pt && git_prompt_info"')"
assert_contains "a clean tree is marked clean" "✓" \
    "$(bssh boxy-1 'zsh -ic "cd /work/pt && git_prompt_info"')"
assert_contains "a dirty tree is marked dirty" "✗" \
    "$(bssh boxy-1 'echo y >> /work/pt/f; zsh -ic "cd /work/pt && git_prompt_info"')"
# The theme prints an RVM segment and no ruby ships in the box. Without the
# stub, every prompt draw would expand to a "command not found".
assert_eq "ruby_prompt_info is stubbed, not missing" "" \
    "$(bssh boxy-1 'zsh -ic "ruby_prompt_info"')"
# The box name is the point of the whole segment: it is what distinguishes a
# box prompt from the host's, and one box from another. It reaches the shell
# through pam_env, so this breaks silently if /etc/environment stops carrying
# BOXY_NAME.
assert_contains "the prompt names the box" "boxy-1" \
    "$(bssh boxy-1 'zsh -ic "print -rP -- \${(e)PROMPT}"')"
# conda's own changeps1 is off, so the env marker is rendered from
# CONDA_DEFAULT_ENV by docker/zshrc. If that regressed, the box name would
# still show and only the env would quietly vanish.
assert_contains "and the active conda env, after it" "(base)" \
    "$(bssh boxy-1 'zsh -ic "print -rP -- \${(e)PROMPT}"')"

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

section "capability policy"
caps_of() { docker exec "$1" sh -c 'capsh --decode=$(grep CapBnd /proc/1/status | cut -f2)' 2>/dev/null \
    | grep -o 'cap_[a-z_]*' | sort | tr '\n' ' '; }
MINCAPS="$(caps_of boxy-1)"
assert_eq "minimal is the default" "minimal" "$(boxy info boxy-1 | awk '/^caps/{print $2}')"
# The four with no plausible use in a dev box.
for dropped in cap_mknod cap_setpcap cap_setfcap cap_fsetid; do
    if printf '%s' "$MINCAPS" | grep -q "$dropped"; then
        _fail "$dropped is dropped" "still present"
    else
        _pass "$dropped is dropped"
    fi
done
# Kept on purpose — each one's absence causes a confusing failure, not an
# honest one. See the BOXY_MINIMAL_CAPS comment in boxy.
for kept in cap_net_raw cap_kill cap_net_bind_service cap_audit_write cap_sys_chroot; do
    assert_contains "$kept is kept" "$kept" "$MINCAPS"
done

section "minimal caps do not break ordinary use"
# ping is the sharp one: /usr/bin/ping has cap_net_raw=ep, and a file
# capability with the effective bit set makes exec() itself fail when the
# capability is outside the bounding set — so dropping NET_RAW would not
# degrade ping, it would make the binary unrunnable.
assert_eq "ping still runs" "works" \
    "$(bssh boxy-1 'ping -c1 -W2 127.0.0.1 >/dev/null 2>&1 && echo works || echo BROKEN')"
assert_eq "unprivileged low-port bind still works" "works" \
    "$(bssh boxy-1 'python -c "import socket;s=socket.socket();s.bind((\"0.0.0.0\",80));print(\"works\")"')"
assert_contains "sudo still reaches uid 0" "uid=0(root)" \
    "$(bssh boxy-1 "echo '$PW' | sudo -S -k id")"

section "--caps docker-default is an escape hatch"
boxy create -n plaincaps --caps docker-default >/dev/null 2>&1
assert_contains "restores the full docker set" "cap_mknod" "$(caps_of plaincaps)"
assert_contains "a bad value is rejected" "--caps must be one of" \
    "$(boxy create -n bogus --caps nonsense 2>&1)"
# `default` was the old spelling and is still accepted, silently, so existing
# configs keep working. It normalises so the label never shows the old name.
boxy rm plaincaps >/dev/null 2>&1
boxy create -n oldcaps --caps default >/dev/null 2>&1
assert_eq "the old 'default' spelling still works" "docker-default" \
    "$(boxy info oldcaps | awk '/^caps/{print $2}')"
assert_contains "and grants the same set" "cap_mknod" "$(caps_of oldcaps)"
boxy rm oldcaps >/dev/null 2>&1
boxy create -n plaincaps --caps docker-default >/dev/null 2>&1
# Release the instance slot again so the port assertion below still describes
# "the second box", not "the fourth".
boxy rm plaincaps >/dev/null 2>&1

section "-- hands the rest to docker run"
# The escape hatch that lets `-v` and `-e` stay off the option list. If this
# stops working, every docker feature boxy does not wrap becomes unreachable.
PTDATA="$TEST_TMP/ptdata"
rm -rf "$PTDATA"; mkdir -p "$PTDATA"; echo "passed-through" > "$PTDATA/hello.txt"
boxy create "$WORK" -n pt --cpus 1 -- -v "$PTDATA:/data" --shm-size 256m --cpus 3 >/dev/null 2>&1
assert_eq "a passthrough mount lands in the box" "passed-through" \
    "$(bssh pt cat /data/hello.txt)"
assert_eq "a passthrough flag boxy has no wrapper for is applied" "268435456" \
    "$(docker inspect pt --format '{{.HostConfig.ShmSize}}')"
# Appended last on purpose: for a flag docker resolves last-wins, the user's
# value has to beat boxy's or the hatch is a suggestion rather than an override.
assert_eq "and beats boxy's own value for the same flag" "3000000000" \
    "$(docker inspect pt --format '{{.HostConfig.NanoCpus}}')"
assert_eq "boxy's own mount still works alongside it" "from the host" \
    "$(bssh pt cat /work/notes.md)"
boxy rm pt >/dev/null 2>&1

section "the network is not passthrough-able"
# boxy's --net picks the network, the sidecar attaches to it, and `boxy info`
# reports isolation by reading it. Letting --network through would leave the
# label describing a container that no longer exists.
assert_contains "--network is refused" "network is boxy's to set" \
    "$(boxy create -n ptnet -- --network host 2>&1)"
assert_contains "and so is the --net=host spelling" "network is boxy's to set" \
    "$(boxy create -n ptnet -- --net=host 2>&1)"
assert_empty "nothing was created for either" \
    "$(ls -d "$BOXY_STATE_DIR/instances/ptnet" 2>/dev/null)"
# A passthrough must not be able to quietly un-isolate a sealed box.
boxy create -n ptiso --net none -- --shm-size 128m >/dev/null 2>&1
assert_eq "an isolated box stays on its internal network" "true" \
    "$(docker network inspect boxy-iso-ptiso --format '{{.Internal}}')"
assert_contains "and info still reports it honestly" "enforced by docker" \
    "$(boxy info ptiso)"
boxy rm ptiso >/dev/null 2>&1

section "boxy works when it is symlinked onto PATH"
# BASH_SOURCE is the path bash was invoked with, not the file it opened, so
# taking its dirname pointed at the symlink's directory. `boxy build` then
# looked for the Dockerfile in /usr/local/bin and `config --init` could not
# find the bundled example — the only two commands that read boxy's own files.
mkdir -p "$TEST_TMP/bin"
ln -sf "$BOXY" "$TEST_TMP/bin/boxy-link"
ln -sf boxy-link "$TEST_TMP/bin/boxy-relative"     # relative, and a second hop
assert_contains "an absolute symlink finds the example config" "wrote" \
    "$(BOXY_CONFIG_DIR="$TEST_TMP/symcfg1" "$TEST_TMP/bin/boxy-link" config --init 2>&1)"
assert_contains "so does a relative link to a link" "wrote" \
    "$(BOXY_CONFIG_DIR="$TEST_TMP/symcfg2" "$TEST_TMP/bin/boxy-relative" config --init 2>&1)"
rm -rf "$TEST_TMP/bin" "$TEST_TMP/symcfg1" "$TEST_TMP/symcfg2"

section "a create that fails partway undoes what it had made"
# The stages after create_prepare_dirs can all fail — docker runs out of
# address pools after a couple of dozen isolated boxes — and until an EXIT
# trap covered them a failure left a git worktree, its branch, and a state
# directory holding the sudo password behind, under a bare docker error.
#
# Forced here by taking the container name the sidecar wants, so the
# sidecar's `docker run` fails for a reason that needs no pool exhaustion.
RBREPO="$TEST_TMP/rbrepo"
rm -rf "$RBREPO"; mkdir -p "$RBREPO"
( cd "$RBREPO" && git init -q && git config user.email t@example.com \
    && git config user.name Tester && git commit -q --allow-empty -m base ) >/dev/null 2>&1
# `docker create`, not run: reserving the name is all that is needed, and a
# container that never starts costs nothing to clean up.
docker create --name boxy-sidecar-rb boxy:latest >/dev/null 2>&1
out="$( cd "$RBREPO" && boxy create worktree -n rb --net none 2>&1 )"
assert_contains "it says it is undoing the work" "undoing what it had already made" "$out"
assert_empty "the state directory is gone" \
    "$(ls -d "$BOXY_STATE_DIR/instances/rb" 2>/dev/null)"
assert_eq "the worktree is deregistered" "1" \
    "$(git -C "$RBREPO" worktree list | grep -c .)"
assert_empty "and the branch it created is gone" \
    "$(git -C "$RBREPO" branch --list 'boxy/rb')"
docker rm -f boxy-sidecar-rb >/dev/null 2>&1

section "container names are validated before any work happens"
assert_contains "one-character name refused up front" "not a usable container name" \
    "$(boxy create -n z 2>&1)"
assert_empty "and nothing was created for it" "$(ls -d "$BOXY_STATE_DIR/instances/z" 2>/dev/null)"

section "second instance"
boxy create -n api >/dev/null 2>&1
assert_eq "next ssh port is 2201" "2201" "$(boxy info api | awk '/^ssh port/{print $3}')"
assert_contains "ls shows both" "api" "$(boxy ls)"

purge_all
report "core"
