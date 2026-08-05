#!/usr/bin/env bash
# Workflow: ports, forwarding, repo cloning, ssh_config, exec, and the
# rm/recreate state contract.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env

WORK="$TEST_TMP/work-wf"
rm -rf "$WORK"; mkdir -p "$WORK"
echo "marker" > "$WORK/marker.txt"

section "ports are not published unless asked"
boxy create -d "$WORK" --no-git-key >/dev/null 2>&1
assert_contains "info reports none published" "(none)" "$(boxy info boxy-1)"
assert_empty "docker publishes only ssh" \
    "$(docker port boxy-1 | grep -v '^22/tcp' || true)"

section "-p publishes with a stated mapping"
boxy create -n pub -p 28000:8000 -p 29999 --no-git-key >/dev/null 2>&1
info_out="$(boxy info pub)"
assert_contains "explicit host:container shown" "localhost:28000 -> 8000" "$info_out"
assert_contains "bare port means the same number" "localhost:29999 -> 29999" "$info_out"
docker exec -d -u boxyboy pub sh -c 'cd /work && python -m http.server 8000 --bind 0.0.0.0'
sleep 3
assert_eq "the published port actually serves" "200" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:28000/)"

section "-p rejects a port already in use"
assert_contains "clear error, no container left behind" "already in use" \
    "$(boxy create -n dup -p 28000:8000 --no-git-key 2>&1)"
assert_empty "nothing was created" "$(docker ps -aq -f name='^dup$')"

section "boxy forward keeps the number identical"
docker exec -d -u boxyboy boxy-1 sh -c 'cd /work && python -m http.server 8000 --bind 0.0.0.0'
sleep 3
boxy forward boxy-1 --bg 8000 >/dev/null 2>&1
sleep 3
assert_eq "localhost:8000 reaches the box's :8000" "200" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:8000/)"
boxy forward boxy-1 --stop >/dev/null 2>&1
sleep 1
assert_eq "tunnel is gone after --stop" "000" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:8000/ 2>/dev/null)"

section "repo cloning"
boxy create -n cloned -r https://github.com/octocat/Hello-World.git --no-git-key >/dev/null 2>&1
assert_contains "repo landed in /work" "README" "$(bssh cloned 'ls /work')"
assert_contains "git work tree is usable" "master" "$(bssh cloned 'git -C /work branch --show-current')"

section "ssh_config works for anything that speaks ssh"
boxy ssh-config >/dev/null 2>&1
assert_file_contains "has a Host block"      "$SSH_CFG" "Host boxy-1"
assert_file_contains "pins the identity"     "$SSH_CFG" "IdentitiesOnly yes"
assert_file_contains "verifies the host key" "$SSH_CFG" "StrictHostKeyChecking yes"
rm -f "$TEST_TMP/fetched.txt"
scp -F "$SSH_CFG" -q boxy-1:/work/marker.txt "$TEST_TMP/fetched.txt" 2>/dev/null
assert_file_contains "scp fetched the right contents" "$TEST_TMP/fetched.txt" "marker"

section "boxy exec (no ssh in the path)"
assert_contains "runs as the box user with a correct HOME" "HOME=/home/boxyboy" \
    "$(boxy exec boxy-1 'echo HOME=$HOME')"
assert_eq "conda is on PATH here too" "/opt/conda/bin/python" \
    "$(boxy exec boxy-1 'command -v python')"
# Without a terminal an interactive shell has nothing driving it and `bash -l`
# blocks forever, so this must fail with a reason rather than hang.
assert_contains "no command and no tty fails fast" "needs a terminal" \
    "$(boxy exec boxy-1 < /dev/null 2>&1)"

section "a default workdir is scratch space in the OS temp area"
scratch_wd="$(boxy info cloned | awk '/^workdir/{print $2}')"
assert_contains "lives under the temp base" "${TMPDIR:-/tmp}" "$scratch_wd"
assert_eq "and it really exists" "yes" "$( [ -d "$scratch_wd" ] && echo yes || echo no )"
boxy create -n cloned2 --no-git-key >/dev/null 2>&1
wd2="$(boxy info cloned2 | awk '/^workdir/{print $2}')"
assert_eq "each box gets its own, never a shared path" "different" \
    "$( [ "$scratch_wd" != "$wd2" ] && echo different || echo same )"

section "rm removes the box and its bookkeeping, and nothing of yours"
boxy rm cloned >/dev/null 2>&1
assert_empty "container gone" "$(docker ps -aq -f name='^cloned$')"
assert_empty "boxy's per-instance state gone" \
    "$(ls -d "$BOXY_STATE_DIR/instances/cloned" 2>/dev/null)"
assert_eq "the scratch workdir is left for the OS to reap" "yes" \
    "$( [ -d "$scratch_wd" ] && echo yes || echo no )"
assert_contains "and your files are still in it" "README" "$(ls "$scratch_wd")"

section "a -d directory is never touched"
boxy rm boxy-1 >/dev/null 2>&1
assert_file_contains "your mounted files survive" "$WORK/marker.txt" "marker"
assert_eq "your directory still exists" "yes" "$( [ -d "$WORK" ] && echo yes || echo no )"

section "rm needs no flags and no confirmation"
out="$(boxy rm cloned2 2>&1)"
assert_contains "reports where the files went" "workdir left for the OS" "$out"
assert_empty "gone without prompting" "$(docker ps -aq -f name='^cloned2$')"

section "name-omission counts boxes, not sidecars"
# A --net limited box brings a proxy container that also carries
# boxy.managed=1. Counting it made "the name may be omitted when exactly one
# box exists" false for every limited box.
purge_all
boxy create -n onlybox --net limited --no-git-key >/dev/null 2>&1
assert_eq "two managed containers exist" "2" \
    "$(docker ps -aq --filter 'label=boxy.managed=1' | grep -c .)"
assert_contains "but the name is still optional" "onlybox" "$(boxy info 2>&1)"
boxy rm onlybox >/dev/null 2>&1

section "messages when the name cannot be inferred"
assert_contains "no boxes at all" "no boxes exist" "$(boxy info 2>&1)"
boxy create -n one --no-git-key >/dev/null 2>&1
boxy create -n two --no-git-key >/dev/null 2>&1
assert_contains "several boxes: names them" "one" "$(boxy info 2>&1)"
purge_all

section "create validates before doing work"
assert_contains "a bad -d is caught up front" "not a directory" \
    "$(boxy create -d /nope/nothing --no-git-key 2>&1)"
assert_empty "and no keypair or state was created for it" \
    "$(ls "$BOXY_STATE_DIR/instances" 2>/dev/null)"

section "orphaned state is reported and reclaimed"
boxy create -n orphan --no-git-key >/dev/null 2>&1
docker rm -f orphan >/dev/null 2>&1          # removed behind boxy's back
assert_contains "doctor notices it" "orphaned state" "$(boxy doctor 2>&1)"
boxy create -n fresh --no-git-key >/dev/null 2>&1
assert_empty "the next create reclaims it" \
    "$(ls -d "$BOXY_STATE_DIR/instances/orphan" 2>/dev/null)"
purge_all

purge_all
report "workflow"
