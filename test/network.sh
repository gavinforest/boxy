#!/usr/bin/env bash
# Network modes: egress isolation, the allowlist proxy, and teardown.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env

section "--net none"
boxy create -n nonet --net none >/dev/null 2>&1
assert_eq "ssh still works on an isolated box" "boxyboy" "$(bssh nonet whoami)"
assert_empty "no default route" "$(docker exec nonet ip route show default 2>&1)"
assert_eq "https blocked" "000" \
    "$(bssh nonet 'curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://pypi.org/simple/')"
assert_eq "raw IP blocked" "000" \
    "$(bssh nonet 'curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://1.1.1.1/')"

section "isolation is Docker's, not boxy's"
# The box is alone on an `internal` network. That is a property of the network
# definition, so there is no runtime state for boxy to apply, lose or repair.
assert_eq "the box's network is internal" "true" \
    "$(docker network inspect boxy-iso-nonet --format '{{.Internal}}')"
assert_eq "the box is on that network alone" "boxy-iso-nonet" \
    "$(docker inspect nonet --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')"
# Docker will not bind a host port for an internal-only container, so the box
# publishes nothing itself — its ports live on the sidecar.
assert_empty "the box binds no host ports" \
    "$(docker port nonet 2>/dev/null || true)"

section "no resolver: the DNS covert channel is closed"
# An internal network has no external resolution at all, so this needs no
# --dns override; peer names still resolve, which is how the sidecar finds
# the box.
assert_eq "external name resolution is dead" "blocked" \
    "$(bssh nonet 'timeout 8 getent hosts pypi.org >/dev/null 2>&1 && echo RESOLVED || echo blocked')"
assert_eq "TXT lookups cannot smuggle data back" "blocked" \
    "$(bssh nonet 'timeout 8 dig +short +time=2 +tries=1 TXT google.com 2>/dev/null | grep -q . && echo LEAKED || echo blocked')"

section "the box cannot reach its own sidecar"
# Traffic only ever flows host -> sidecar -> box, so the sidecar's listeners
# bind to its outward address and the box side is left bare. Without this the
# sidecar would be a dual-homed target sitting on the box's own network.
SIP="$(docker inspect boxy-sidecar-nonet \
    --format '{{(index .NetworkSettings.Networks "boxy-iso-nonet").IPAddress}}')"
assert_eq "the ssh listener is not reachable from the box" "closed" \
    "$(bssh nonet "timeout 3 sh -c 'echo > /dev/tcp/$SIP/2200' 2>/dev/null && echo OPEN || echo closed")"
assert_eq "nor is anything else" "closed" \
    "$(bssh nonet "timeout 3 sh -c 'echo > /dev/tcp/$SIP/8888' 2>/dev/null && echo OPEN || echo closed")"
# curl writes 000 AND exits non-zero when it cannot connect, so a trailing
# `|| echo blocked` yields "000blocked". Assert the status it prints.
assert_eq "the sidecar cannot be used as a router" "000" \
    "$(bssh nonet "curl -s -o /dev/null -w '%{http_code}' --max-time 8 --proxy http://$SIP:8888 https://1.1.1.1/ 2>/dev/null")"

section "isolation survives a restart that boxy knows nothing about"
# This is the bug that motivated the design. Under route-deletion a raw
# `docker restart` rebuilt the network namespace and silently restored full
# connectivity. With an internal network there is nothing to restore.
docker restart nonet >/dev/null 2>&1
sleep 4
assert_empty "still no default route" "$(docker exec nonet ip route show default 2>&1)"
assert_eq "still blocked" "000" \
    "$(bssh nonet 'curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://1.1.1.1/')"
assert_eq "resolver is still dead" "blocked" \
    "$(bssh nonet 'timeout 8 getent hosts pypi.org >/dev/null 2>&1 && echo RESOLVED || echo blocked')"
assert_eq "and the network is still internal" "true" \
    "$(docker network inspect boxy-iso-nonet --format '{{.Internal}}')"

section "root in the box cannot undo it"
PW="$(boxy password nonet)"
assert_contains "no CAP_NET_ADMIN to add a route" "not permitted" \
    "$(bssh nonet "echo '$PW' | sudo -S -k ip link add dummy0 type dummy")"

section "--net limited"
boxy create -n ltd --net limited >/dev/null 2>&1
assert_eq "ssh works" "boxyboy" "$(bssh ltd whoami)"
assert_contains "proxy env is set for non-interactive commands" "boxy-sidecar-ltd" \
    "$(bssh ltd 'echo $HTTPS_PROXY')"
assert_eq "allowlisted domain reachable" "200" \
    "$(bssh ltd 'curl -s -o /dev/null -w "%{http_code}" --max-time 25 https://pypi.org/simple/')"
# A refused CONNECT has no HTTP response to carry a status, so blocked HTTPS
# surfaces as 000 while blocked plain HTTP returns tinyproxy's real 403.
assert_eq "non-allowlisted http refused with 403" "403" \
    "$(bssh ltd 'curl -s -o /dev/null -w "%{http_code}" --max-time 15 http://example.com/')"
assert_eq "non-allowlisted https tunnel dropped" "000" \
    "$(bssh ltd 'curl -s -o /dev/null -w "%{http_code}" --max-time 15 https://example.com/')"
assert_eq "bypassing the proxy does not help" "000" \
    "$(bssh ltd 'curl -s --noproxy "*" -o /dev/null -w "%{http_code}" --max-time 10 https://pypi.org/simple/')"
assert_contains "denials are logged" "example.com" "$(docker logs boxy-sidecar-ltd 2>&1 | tail -20)"

section "--allow extends the allowlist"
boxy create -n ltd2 --net limited --allow example.com >/dev/null 2>&1
assert_eq "the extra domain is reachable" "200" \
    "$(bssh ltd2 'curl -s -o /dev/null -w "%{http_code}" --max-time 20 http://example.com/')"

section "boxes never restart on their own"
# Kept as a deliberate default rather than a safety net: isolation no longer
# depends on it. A box you forgot to remove should not come back on its own.
assert_eq "restart policy is 'no'" "no" \
    "$(docker inspect nonet --format '{{.HostConfig.RestartPolicy.Name}}')"
assert_eq "and the sidecar matches" "no" \
    "$(docker inspect boxy-sidecar-nonet --format '{{.HostConfig.RestartPolicy.Name}}')"

section "info reports isolation without entering the box"
# There is nothing to check inside any more, and so nothing a box could lie
# about: the answer is in the network definition, which the box cannot touch.
out="$(boxy info nonet)"
assert_contains "net mode shown"          "net         none" "$out"
assert_contains "and who enforces it"     "enforced by docker" "$out"
assert_empty "no warnings on a healthy box" "$(printf '%s' "$out" | grep '⚠' || true)"
assert_empty "doctor is clean too" \
    "$(boxy doctor 2>&1 | grep -iE 'ISOLATION|problem' || true)"

section "the sidecar is hardened"
assert_eq "no capabilities at all" "0000000000000000" \
    "$(docker inspect boxy-sidecar-nonet --format '{{.HostConfig.CapDrop}}' >/dev/null 2>&1;
       docker exec boxy-sidecar-nonet sh -c 'grep CapBnd /proc/1/status' | awk '{print $2}')"
assert_eq "and cannot be made a router" "0" \
    "$(docker exec boxy-sidecar-nonet cat /proc/sys/net/ipv4/ip_forward)"

section "published ports work on a sealed box"
# Docker refuses to bind a host port for an internal-only container, so this
# only works because the binding lives on the sidecar. Before this design a
# --net none box could not expose anything at all.
boxy create -n srv --net none -p 28085:8000 >/dev/null 2>&1
bssh srv 'cd /work && echo sealed-but-served > index.html && (nohup python -m http.server 8000 --bind 0.0.0.0 >/dev/null 2>&1 &)' >/dev/null 2>&1
sleep 4
assert_contains "reachable from the host" "sealed-but-served" \
    "$(curl -s --max-time 8 http://127.0.0.1:28085/ || true)"
assert_eq "while the box still has no way out" "000" \
    "$(bssh srv 'curl -s -o /dev/null -w "%{http_code}" --max-time 8 http://1.1.1.1/')"
boxy rm srv >/dev/null 2>&1

section "teardown"
boxy rm ltd >/dev/null 2>&1
assert_empty "container removed"    "$(docker ps -aq -f name='^ltd$')"
assert_empty "sidecar removed" "$(docker ps -aq -f name='^boxy-sidecar-ltd$')"
assert_empty "per-box network removed" "$(docker network ls --filter 'name=boxy-iso-ltd$' -q)"
assert_empty "state dir removed"    "$(ls -d "$BOXY_STATE_DIR/instances/ltd" 2>/dev/null)"
boxy rm nonet ltd2 >/dev/null 2>&1
assert_empty "shared egress network dropped once unused" \
    "$(docker network ls --filter 'name=boxy-egress' -q)"

purge_all
report "network"
