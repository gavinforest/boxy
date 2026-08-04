#!/usr/bin/env bash
#
# boxy test runner.
#
#   ./test/run.sh              # every suite
#   ./test/run.sh core         # one suite
#   ./test/run.sh core network
#
# Requires a reachable Docker daemon and a built boxy:latest. Runs entirely
# against a scratch state directory under $TMPDIR, so it cannot disturb a real
# install — but it DOES remove every boxy-managed container on the host, since
# a shared daemon is the one resource it cannot sandbox.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITES="${*:-core network workflow}"

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; O=$'\033[0m'
else B=''; G=''; R=''; O=''; fi

export TEST_TMP="${TMPDIR:-/tmp}/boxy-test.$$"
trap 'rm -rf "$TEST_TMP"' EXIT

total_fail=0
results=""

for s in $SUITES; do
    [ -f "$HERE/$s.sh" ] || { echo "no such suite: $s" >&2; exit 2; }
    printf '\n%s========== %s ==========%s\n' "$B" "$s" "$O"
    bash "$HERE/$s.sh"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        results="$results
  ${G}ok${O}     $s"
    else
        results="$results
  ${R}FAILED${O} $s"
        total_fail=$(( total_fail + 1 ))
    fi
done

printf '\n%s========== summary ==========%s%s\n' "$B" "$O" "$results"
if [ "$total_fail" -gt 0 ]; then
    printf '\n%s%d suite(s) failed%s\n' "$R" "$total_fail" "$O"
    exit 1
fi
printf '\n%sall suites passed%s\n' "$G" "$O"
