#!/usr/bin/env bash
# boxy sidecar: ingress socat listeners, plus an optional egress allowlist.
set -euo pipefail

CONF=/etc/tinyproxy/tinyproxy.conf
FILTER=/etc/tinyproxy/filter

# The egress policy, bind-mounted read only from the host: one domain per line.
# It arrives as a mount rather than an environment variable so that `boxy allow`
# can change it on a running box — an environment variable is fixed for the life
# of a container — and read only so that the sidecar cannot widen its own policy.
# Its absence is what marks an ingress-only (`--net none`) sidecar.
ALLOWLIST=/etc/boxy-proxy/allowlist.txt

# Bumped every time the proxy (re)starts. `boxy allow` reads it before and after
# signalling, so a reload is confirmed rather than assumed, and a sidecar built
# before live reload existed is told apart by this file simply not being there.
GENERATION=/run/boxy-proxy-generation

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

# ---------------------------------------------------------------------------
# Shutdown
# ---------------------------------------------------------------------------
# This script stays PID 1 instead of exec'ing into tinyproxy, so that the proxy
# can be restarted for an allowlist change without taking the socat listeners —
# and with them every live ssh session — down alongside it.
#
# Being PID 1 means signal handling is now ours. Without this trap `docker stop`
# would get no answer at all and would sit out its full ten-second grace period
# before resorting to SIGKILL, on every stop of every isolated box.
shutdown() {
    trap - TERM INT
    local p
    for p in $(jobs -p); do kill "$p" 2>/dev/null || true; done
    exit 0
}
trap shutdown TERM INT

start_ingress

# No allowlist file means an ingress-only sidecar (`--net none`): there is no
# proxy to run, so hold the container open on the socat jobs.
if [[ ! -f "$ALLOWLIST" ]]; then
    log "ingress-only sidecar ready"
    wait || true
    exit 0
fi

# ---------------------------------------------------------------------------
# Egress
# ---------------------------------------------------------------------------
# tinyproxy's filter file is a list of POSIX extended regexes matched against
# the request host. FilterDefaultDeny flips the sense: anything that does NOT
# match is refused. Each entry is anchored and allows subdomains.
#
# Built into a temporary file and moved into place, so that a reload can decide
# the new list is unusable and leave the running filter untouched, rather than
# having already half-written it.
build_filter() {
    local tmp domain escaped
    tmp="$(mktemp)"
    while IFS= read -r domain || [[ -n "$domain" ]]; do
        domain="${domain%%#*}"
        domain="$(printf '%s' "$domain" | tr -d '[:space:]')"
        [[ -z "$domain" ]] && continue
        escaped="${domain//./\\.}"
        printf '^(.*\\.)?%s$\n' "$escaped" >> "$tmp"
    done < "$ALLOWLIST"

    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$FILTER"
    chmod 644 "$FILTER"
}

write_conf() {
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
}

PROXY_PID=""
GEN=0

# -d keeps tinyproxy in the foreground; with no LogFile set it logs to stdout,
# so `docker logs` and the monitoring stack see denials.
start_proxy() {
    tinyproxy -d -c "$CONF" &
    PROXY_PID=$!
    GEN=$(( GEN + 1 ))
    printf '%s\n' "$GEN" > "$GENERATION"
}

# SIGHUP is the reload. tinyproxy has its own SIGHUP handler, but it only
# re-reads the config file — the compiled filter list is built once at startup
# and never revisited — so signalling tinyproxy directly does nothing useful and
# says "Reloading config file finished" while continuing to enforce the old
# policy. Restarting the process is the only thing that actually reloads it.
#
# The handler sets a flag and does nothing else. That is deliberate. A trapped
# signal arriving while bash is blocked in `wait` makes `wait` return with a
# status above 128 WITHOUT reaping the child, so a kill issued from inside the
# handler leaves the supervisor unable to tell when the old proxy has actually
# exited — and it holds :8888 until it does. tinyproxy answers a failed bind by
# exiting rather than retrying, so the replacement would die on arrival.
#
# Killing and reaping from the main loop instead keeps both in ordinary control
# flow, where `wait` blocks until the process is genuinely gone.
RELOAD=0
reload() { RELOAD=1; }
trap reload HUP

# Stop the proxy and do not return until it has released the listening socket.
#
# The signal is allowed to fail loudly. tinyproxy drops to its own user, so root
# here cannot signal it without CAP_KILL, and a swallowed EPERM turns into the
# supervisor waiting forever on a process that was never asked to exit.
stop_proxy() {
    local i=0
    if ! kill "$PROXY_PID" 2>/dev/null; then
        log "cannot signal the proxy (pid $PROXY_PID) — is CAP_KILL missing?"
        return 1
    fi
    wait "$PROXY_PID" 2>/dev/null || true
    while kill -0 "$PROXY_PID" 2>/dev/null; do
        i=$(( i + 1 ))
        if [[ "$i" -gt 100 ]]; then
            log "proxy ignored SIGTERM for five seconds; forcing it"
            kill -9 "$PROXY_PID" 2>/dev/null || true
        fi
        sleep 0.05
    done
}

if ! build_filter; then
    log "FATAL: allowlist is empty; refusing to start a proxy that denies everything"
    exit 1
fi
log "allowing $(wc -l < "$FILTER") domain pattern(s):"
sed "s/^/[boxy-sidecar]   /" "$FILTER" >&2

write_conf
start_proxy

while :; do
    rc=0
    wait "$PROXY_PID" || rc=$?

    if [[ "$RELOAD" == 1 ]]; then
        RELOAD=0
        log "reload requested"
        if ! stop_proxy; then
            log "reload abandoned; the previous policy is still in force"
            continue
        fi
        if build_filter; then
            log "egress allowlist reloaded: $(wc -l < "$FILTER") pattern(s)"
        else
            log "reload refused: new allowlist is empty; keeping the previous filter"
        fi
        start_proxy
        continue
    fi

    # A signal we handle can interrupt `wait` without the proxy having gone
    # anywhere. Nothing to do in that case but wait on it again.
    if kill -0 "$PROXY_PID" 2>/dev/null; then
        continue
    fi

    # Anything else is the proxy falling over on its own. Take the container
    # with it: egress failing closed is safe, but a sidecar that looks healthy
    # while refusing every request is not worth leaving up.
    log "FATAL: tinyproxy exited with status $rc"
    exit "$rc"
done
