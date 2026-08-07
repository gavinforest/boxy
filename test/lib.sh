# Shared assertions and an isolated environment for boxy's tests.
#
# Every suite runs against a scratch BOXY_STATE_DIR / BOXY_CONFIG_DIR and its
# own keypair, so running the tests can never touch a real install, a real
# ~/.ssh, or boxes you actually care about.

BOXY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOXY="$BOXY_ROOT/boxy"

TEST_TMP="${TEST_TMP:-${TMPDIR:-/tmp}/boxy-test.$$}"
export BOXY_STATE_DIR="$TEST_TMP/state"
export BOXY_CONFIG_DIR="$TEST_TMP/config"
export BOXY_SSH_KEY="$TEST_TMP/state/test_ed25519"
# Keep scratch workdirs inside the test tree so a run leaves nothing behind
# in the real temp area.
export BOXY_WORKDIR_BASE="$TEST_TMP/workdirs"
SSH_CFG="$TEST_TMP/state/ssh_config"

PASS=0
FAIL=0
FAILED_NAMES=""

if [ -t 1 ]; then
    G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; O=$'\033[0m'
else
    G=''; R=''; B=''; D=''; O=''
fi

section() { printf '\n%s-- %s%s\n' "$B" "$*" "$O"; }

_pass() { printf '  %sPASS%s %s\n' "$G" "$O" "$1"; PASS=$(( PASS + 1 )); }
_fail() {
    printf '  %sFAIL%s %s\n       %s\n' "$R" "$O" "$1" "$2"
    FAIL=$(( FAIL + 1 ))
    FAILED_NAMES="$FAILED_NAMES
    - $1"
}

# assert_eq LABEL EXPECTED ACTUAL
assert_eq() {
    if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "expected [$2] got [$3]"; fi
}

# assert_contains LABEL NEEDLE HAYSTACK
assert_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then _pass "$1"
    else _fail "$1" "expected to find [$2] in [$3]"; fi
}

# assert_empty LABEL ACTUAL  — a distinct assertion, because `grep -qF ""`
# against an empty string returns 1 and would report a spurious failure.
assert_empty() {
    if [ -z "$2" ]; then _pass "$1"; else _fail "$1" "expected empty, got [$2]"; fi
}

# assert_file_contains LABEL PATH NEEDLE
assert_file_contains() {
    if [ -f "$2" ] && grep -qF -- "$3" "$2"; then _pass "$1"
    else _fail "$1" "expected [$3] inside $2"; fi
}

# Run a command inside a box over SSH and echo its output.
#
# Deliberately NOT `ssh -t`: allocating a TTY when the test harness's own
# stdin is a pipe makes ssh print "Pseudo-terminal will not be allocated…"
# onto the output being asserted. Use `bash -lc` when a login shell is what
# is under test.
bssh() { local n="$1"; shift; ssh -F "$SSH_CFG" -o BatchMode=yes "$n" "$@" 2>&1; }

boxy() { "$BOXY" "$@"; }

# Remove every boxy-managed container and network, whoever created them.
purge_all() {
    local c
    for c in $(docker ps -aq --filter 'label=boxy.managed=1' 2>/dev/null); do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
    docker network ls --filter 'name=boxy-' -q 2>/dev/null \
        | xargs -r docker network rm >/dev/null 2>&1 || true
    docker rm -f boxy-test-hostsvc >/dev/null 2>&1 || true
    rm -rf "$BOXY_STATE_DIR/instances"
}

setup_env() {
    mkdir -p "$TEST_TMP" "$BOXY_STATE_DIR" "$BOXY_CONFIG_DIR"
    command -v docker >/dev/null 2>&1 || { echo "docker not on PATH" >&2; exit 2; }
    docker info >/dev/null 2>&1 || { echo "docker daemon unreachable" >&2; exit 2; }
    docker image inspect boxy-base:latest >/dev/null 2>&1 \
        || { echo "boxy-base:latest missing — run ./boxy build" >&2; exit 2; }
    purge_all
}

report() {
    printf '\n%s%s: %d passed, %d failed%s\n' "$B" "${1:-suite}" "$PASS" "$FAIL" "$O"
    if [ "$FAIL" -gt 0 ]; then
        printf '%sfailed:%s%s\n' "$R" "$O" "$FAILED_NAMES"
        return 1
    fi
    return 0
}
