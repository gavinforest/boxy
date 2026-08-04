#!/usr/bin/env bash
# Network modes: egress isolation, the allowlist proxy, and teardown.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env

section "--net none"
boxy create -n nonet --net none --no-git-key >/dev/null 2>&1
assert_eq "ssh still works on an isolated box" "boxyboy" "$(bssh nonet whoami)"
assert_empty "no default route" "$(docker exec nonet ip route show default 2>&1)"
assert_eq "https blocked" "000" \
    "$(bssh nonet 'curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://pypi.org/simple/')"
assert_eq "raw IP blocked" "000" \
    "$(bssh nonet 'curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://1.1.1.1/')"

PW="$(boxy password nonet)"
assert_contains "root inside the box cannot restore the route" "not permitted" \
    "$(bssh nonet "echo '$PW' | sudo -S -k ip route add default via 172.30.0.1")"

section "no resolver: the DNS covert channel is closed"
# Docker's embedded DNS forwards through the daemon, which is OUTSIDE the
# container's netns — so route removal alone leaves a working resolver, and a
# box with no route can exfiltrate in query names and receive in TXT records.
assert_eq "external name resolution is dead" "blocked" \
    "$(bssh nonet 'timeout 8 getent hosts pypi.org >/dev/null 2>&1 && echo RESOLVED || echo blocked')"
assert_eq "TXT lookups cannot smuggle data back" "blocked" \
    "$(bssh nonet 'timeout 8 dig +short +time=2 +tries=1 TXT google.com 2>/dev/null | grep -q . && echo LEAKED || echo blocked')"

section "on-link egress is firewalled"
# Route removal only stops traffic that needs a gateway; the gateway itself is
# on-link. A --network host container binds every host-netns interface, which
# is exactly what a service on a Linux VPS host looks like from inside a box.
docker rm -f boxy-test-hostsvc >/dev/null 2>&1
docker run -d --name boxy-test-hostsvc --network host --entrypoint sh boxy:latest \
    -c 'cd /etc && python -m http.server 39998 --bind 0.0.0.0' >/dev/null 2>&1
sleep 4
GW="$(docker exec nonet ip route | awk '/scope link/{print $1}' | cut -d/ -f1 | sed 's/\.0$/.1/')"
assert_eq "host-netns service is unreachable" "000" \
    "$(bssh nonet "curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://$GW:39998/")"
assert_eq "so is a ping to the gateway" "blocked" \
    "$(bssh nonet "ping -c1 -W2 $GW >/dev/null 2>&1 && echo REACHABLE || echo blocked")"
assert_contains "the box cannot alter its own firewall" "denied" \
    "$(bssh nonet "echo '$PW' | sudo -S -k iptables -P OUTPUT ACCEPT")"
docker rm -f boxy-test-hostsvc >/dev/null 2>&1

section "isolation survives a restart"
# A restart rebuilds the container's network namespace, so BOTH the route
# removal and the iptables rules have to be reapplied — they do not persist.
boxy restart nonet >/dev/null 2>&1
assert_empty "still no default route" "$(docker exec nonet ip route show default 2>&1)"
assert_eq "still blocked" "000" \
    "$(bssh nonet 'curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://pypi.org/simple/')"
assert_contains "firewall rules were reinstalled" "-P OUTPUT DROP" \
    "$(docker exec --privileged nonet iptables -S OUTPUT 2>&1)"
assert_eq "resolver is still dead" "blocked" \
    "$(bssh nonet 'timeout 8 getent hosts pypi.org >/dev/null 2>&1 && echo RESOLVED || echo blocked')"

section "--net limited"
boxy create -n ltd --net limited --no-git-key >/dev/null 2>&1
assert_eq "ssh works" "boxyboy" "$(bssh ltd whoami)"
assert_contains "proxy env is set for non-interactive commands" "boxy-proxy-ltd" \
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
assert_contains "denials are logged" "example.com" "$(docker logs boxy-proxy-ltd 2>&1 | tail -20)"

section "--allow extends the allowlist"
boxy create -n ltd2 --net limited --allow example.com --no-git-key >/dev/null 2>&1
assert_eq "the extra domain is reachable" "200" \
    "$(bssh ltd2 'curl -s -o /dev/null -w "%{http_code}" --max-time 20 http://example.com/')"

section "teardown"
boxy rm ltd >/dev/null 2>&1
assert_empty "container removed"    "$(docker ps -aq -f name='^ltd$')"
assert_empty "proxy sidecar removed" "$(docker ps -aq -f name='^boxy-proxy-ltd$')"
assert_empty "per-box network removed" "$(docker network ls --filter 'name=boxy-iso-ltd$' -q)"
assert_empty "state dir removed"    "$(ls -d "$BOXY_STATE_DIR/instances/ltd" 2>/dev/null)"
boxy rm nonet ltd2 >/dev/null 2>&1
assert_empty "shared egress network dropped once unused" \
    "$(docker network ls --filter 'name=boxy-egress' -q)"

purge_all
report "network"
