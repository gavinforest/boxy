#!/usr/bin/env bash
# Builds a tinyproxy allowlist from $BOXY_ALLOWLIST (one domain per line) and
# runs the proxy in the foreground.
set -euo pipefail

CONF=/etc/tinyproxy/tinyproxy.conf
FILTER=/etc/tinyproxy/filter
PORT="${BOXY_PROXY_PORT:-8888}"

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
    echo "[boxy-proxy] FATAL: allowlist is empty; refusing to start a proxy that denies everything" >&2
    exit 1
fi

echo "[boxy-proxy] allowing $(wc -l < "$FILTER") domain pattern(s):" >&2
sed 's/^/[boxy-proxy]   /' "$FILTER" >&2

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
