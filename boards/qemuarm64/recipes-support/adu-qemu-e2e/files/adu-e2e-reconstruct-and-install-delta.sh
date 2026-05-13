#!/bin/bash
# adu-e2e-reconstruct-and-install-delta — Reconstruct a target .swu from a
# cached source-recompressed .swu + a binary delta, then install it.
#
# Usage:
#   adu-e2e-reconstruct-and-install-delta \
#       <source-recompressed.swu> <delta.diff> <expected-version-after-install>

set -euo pipefail

SOURCE_SWU="${1:-}"
DELTA="${2:-}"
EXPECTED_VERSION="${3:-}"

if [[ -z "$SOURCE_SWU" || -z "$DELTA" || -z "$EXPECTED_VERSION" ]]; then
    echo "ERR_USAGE: adu-e2e-reconstruct-and-install-delta <source-recompressed.swu> <delta.diff> <expected-version>" >&2
    exit 64
fi
[[ -f "$SOURCE_SWU" ]] || { echo "ERR_NO_SOURCE: $SOURCE_SWU not found" >&2; exit 65; }
[[ -f "$DELTA"      ]] || { echo "ERR_NO_DELTA: $DELTA not found" >&2; exit 66; }

if ! command -v applydiff >/dev/null 2>&1; then
    echo "ERR_NO_APPLYDIFF: applydiff binary missing from rootfs" >&2
    exit 67
fi

RECONSTRUCTED=/adu/.e2e-reconstructed.swu
rm -f "$RECONSTRUCTED"

echo "[e2e-delta] reconstructing $(basename "$DELTA") + $(basename "$SOURCE_SWU") -> $(basename "$RECONSTRUCTED")"
mkdir -p /adu/logs
LOG=/adu/logs/applydiff-$(date +%s).log
if ! applydiff "$SOURCE_SWU" "$DELTA" "$RECONSTRUCTED" 2>&1 | tee "$LOG"; then
    echo "ERR_APPLYDIFF_FAILED: see $LOG" >&2
    exit 68
fi
[[ -s "$RECONSTRUCTED" ]] || { echo "ERR_RECONSTRUCTED_EMPTY: $RECONSTRUCTED" >&2; exit 69; }

echo "[e2e-delta] reconstructed SWU size: $(stat -c %s "$RECONSTRUCTED") bytes"
echo "[e2e-delta] reconstructed SWU sha256: $(sha256sum "$RECONSTRUCTED" | awk '{print $1}')"

exec adu-e2e-install-full "$RECONSTRUCTED" "$EXPECTED_VERSION"
