#!/bin/bash
# adu-e2e-verify-version — Verify /etc/adu-version matches expected value.
#
# Usage:
#   adu-e2e-verify-version <expected-version>
#   adu-e2e-verify-version -        # use /adu/.e2e-expected-version

set -euo pipefail

EXPECTED="${1:--}"

if [[ "$EXPECTED" == "-" ]]; then
    [[ -f /adu/.e2e-expected-version ]] || { echo "ERR_NO_EXPECTED" >&2; exit 64; }
    EXPECTED="$(cat /adu/.e2e-expected-version)"
fi

[[ -f /etc/adu-version ]] || { echo "FAIL: /etc/adu-version missing (expected: $EXPECTED)"; exit 1; }

ACTUAL="$(tr -d '[:space:]' < /etc/adu-version)"
EXPECTED="$(echo "$EXPECTED" | tr -d '[:space:]')"

CURRENT_ROOT="$(findmnt -nro SOURCE /)"
echo "[e2e-verify] root=$CURRENT_ROOT  expected=$EXPECTED  actual=$ACTUAL"

if [[ "$ACTUAL" == "$EXPECTED" ]]; then
    echo "PASS: /etc/adu-version=$ACTUAL on $CURRENT_ROOT"
    exit 0
fi
echo "FAIL: /etc/adu-version=$ACTUAL (expected $EXPECTED) on $CURRENT_ROOT"
exit 1
