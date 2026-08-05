#!/usr/bin/env bash
# boxy sidecar: ingress socat listeners, plus an optional egress allowlist.
set -euo pipefail

CONF=/etc/tinyproxy/tinyproxy.conf
FILTER=/etc/tinyproxy/filter
PORT="${BOXY_PROXY_PORT:-8888}"

log() { printf '[boxy-sidecar] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Ingress
# ---------------------------------------------------------------------------
# BOXY_RELAY is "listen:target:port" per line. Each becomes a socat listener
# bound to ONE address: the one on the interface that owns the default route.
#
# That interface is the outside-facing one by construction — the box's network
# is `internal` and so carries no default route — and binding there rather than
# to 0.0.0.0 is what keeps the box from having anything to connect to on this
# container. Traffic only ever flows host -> here -> box; the box never
# initiates to us, so nothing needs to listen on the private side.
#
# Deriving it from the route rather than hardcoding eth0 matters: Docker
# numbers interfaces in attachment order, and this container is attached to a
# second network after creation, so the ordering is not guaranteed to survive
# a restart.
start_ingress() {
    [[ -n "${BOXY_RELAY:-}" ]] || return 0

    local out_if out_ip
    out_if="$(ip route show default | awk '{print $5}' | head -1)"
    [[ -n "$out_if" ]] || { log "FATAL: no default route; cannot place listeners"; exit 1; }
    out_ip="$(ip -4 -o addr show dev "$out_if" | awk '{print $4}' | cut -d/ -f1)"
    [[ -n "$out_ip" ]] || { log "FATAL: no address on $out_if"; exit 1; }
    log "ingress listeners bind to $out_ip ($out_if); the box side stays bare"

    # The box is on a network attached after this container started, so give
    # its name a moment to become resolvable before pointing socat at it.
    local target first
    first="$(printf '%s\n' "$BOXY_RELAY" | grep -v '^[[:space:]]*$' | head -1)"
    target="$(printf '%s' "$first" | cut -d: -f2)"
    local waited=0
    until getent hosts "$target" >/dev/null 2>&1; do
        waited=$(( waited + 1 ))
        [[ "$waited" -gt 100 ]] && { log "FATAL: $target never became resolvable"; exit 1; }
        sleep 0.1
    done

    local line lp th tp
    while IFS= read -r line; do
        [[ -z "${line// }" ]] && continue
        lp="${line%%:*}"; th="$(printf '%s' "$line" | cut -d: -f2)"; tp="${line##*:}"
        log "  :$lp -> $th:$tp"
        socat "TCP-LISTEN:$lp,fork,reuseaddr,bind=$out_ip" "TCP:$th:$tp" &
    done <<< "$BOXY_RELAY"
}

start_ingress

# With no allowlist this is an ingress-only sidecar (`--net none`): there is no
# proxy to exec into, so hold the container open on the socat jobs.
if [[ -z "${BOXY_ALLOWLIST:-}" ]]; then
    log "ingress-only sidecar ready"
    wait
    exit 0
fi

# tinyproxy's filter file is a list of POSIX extended regexes matched against
# the request host. FilterDefaultDeny flips the sense: anything that does NOT
# match is refused. Each entry is anchored and allows subdomains.
: > "$FILTER"
while IFS= read -r domain; do
    domain="${domain%%#*}"
    domain="$(printf '%s' "$domain" | tr -d '[:space:]')"
    [[ -z "$domain" ]] && continue
    escaped="${domain//./\\.}"
    printf '^(.*\\.)?%s$\n' "$escaped" >> "$FILTER"
done <<< "${BOXY_ALLOWLIST:-}"

if [[ ! -s "$FILTER" ]]; then
    echo "[boxy-sidecar] FATAL: allowlist is empty; refusing to start a proxy that denies everything" >&2
    exit 1
fi

echo "[boxy-sidecar] allowing $(wc -l < "$FILTER") domain pattern(s):" >&2
sed "s/^/[boxy-sidecar]   /" "$FILTER" >&2

cat > "$CONF" <<EOF
User tinyproxy
Group tinyproxy
Port ${PORT}
Listen 0.0.0.0
Timeout 600
MaxClients 100

# Only reachable from the box's private network in the first place; this is
# belt-and-braces against the proxy ever landing somewhere routable.
Allow 10.0.0.0/8
Allow 172.16.0.0/12
Allow 192.168.0.0/16

DisableViaHeader Yes
LogLevel Notice

# CONNECT is what carries TLS. 443 for https, 22 so git-over-ssh can tunnel.
ConnectPort 443
ConnectPort 22

FilterURLs Off
FilterType ere
FilterCaseSensitive No
FilterDefaultDeny Yes
Filter "${FILTER}"
EOF

# -d keeps tinyproxy in the foreground; with no LogFile set it logs to stdout,
# so `docker logs` and the monitoring stack see denials.
exec tinyproxy -d -c "$CONF"
