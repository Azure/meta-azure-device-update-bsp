#!/bin/bash
# adu-e2e-install-full — Install a full .swu to the inactive slot.
#
# Usage:
#   adu-e2e-install-full <path-to.swu> <expected-version-after-install>

set -euo pipefail

SWU="${1:-}"
EXPECTED_VERSION="${2:-}"

if [[ -z "$SWU" || -z "$EXPECTED_VERSION" ]]; then
    echo "ERR_USAGE: adu-e2e-install-full <swu> <expected-version>" >&2
    exit 64
fi
if [[ ! -f "$SWU" ]]; then
    echo "ERR_NO_SWU: $SWU not found" >&2
    exit 65
fi

CURRENT_ROOT="$(findmnt -nro SOURCE /)"
case "$CURRENT_ROOT" in
    /dev/vda2) ACTIVE_LABEL=rootA; TARGET_LABEL=rootB; SELECTION="stable,copy2" ;;
    /dev/vda3) ACTIVE_LABEL=rootB; TARGET_LABEL=rootA; SELECTION="stable,copy1" ;;
    *) echo "ERR_UNKNOWN_ROOT: $CURRENT_ROOT" >&2 ; exit 66 ;;
esac

echo "[e2e-install] currently on $ACTIVE_LABEL ($CURRENT_ROOT)"
echo "[e2e-install] installing $(basename "$SWU") -> $TARGET_LABEL ($SELECTION)"
echo "[e2e-install] expecting version $EXPECTED_VERSION after reboot"

LOG_DIR=/adu/logs
mkdir -p "$LOG_DIR"
SWUPDATE_LOG="$LOG_DIR/swupdate-$(date +%s).log"

KEY_ARG=()
if [[ -f /etc/swupdate.pem ]]; then
    KEY_ARG=(-k /etc/swupdate.pem)
fi

if ! swupdate -v "${KEY_ARG[@]}" -H qemuarm64:1.0 -i "$SWU" -e "$SELECTION" 2>&1 | tee "$SWUPDATE_LOG"; then
    echo "ERR_SWUPDATE_FAILED: see $SWUPDATE_LOG" >&2
    tail -40 "$SWUPDATE_LOG" >&2 || true
    exit 67
fi

CACHE_DIR=/adu/.delta-source-cache
mkdir -p "$CACHE_DIR"

RECOMP="${SWU%.swu}-recompressed.swu"
ALT_RECOMP="$(dirname "$SWU")/$(basename "$SWU" .swu | sed 's/-qemuarm64$//')-recompressed.swu"

if [[ -f "$RECOMP" ]]; then
    cp -f "$RECOMP" "$CACHE_DIR/"
    echo "[e2e-install] cached delta source: $(basename "$RECOMP")"
elif [[ -f "$ALT_RECOMP" ]]; then
    cp -f "$ALT_RECOMP" "$CACHE_DIR/"
    echo "[e2e-install] cached delta source: $(basename "$ALT_RECOMP")"
else
    echo "[e2e-install] no recompressed source SWU alongside $(basename "$SWU") - skipping cache"
fi

echo "$EXPECTED_VERSION" > /adu/.e2e-expected-version

fw_setenv boot_partition       "$TARGET_LABEL"
fw_setenv upgrade_available    1
fw_setenv boot_attempts        0
fw_setenv boot_result          unknown

echo "[e2e-install] U-Boot env after flip:"
fw_printenv boot_partition upgrade_available boot_attempts

sync
echo "[e2e-install] OK - ready to reboot"
