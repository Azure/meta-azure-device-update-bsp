#!/bin/bash
# adu-e2e-confirm-boot — Mark the current partition as Last-Known-Good and
# clear the upgrade latch so U-Boot stops counting boot_attempts.

set -euo pipefail

CURRENT_ROOT="$(findmnt -nro SOURCE /)"
case "$CURRENT_ROOT" in
    /dev/vda2) LABEL=rootA ;;
    /dev/vda3) LABEL=rootB ;;
    *) echo "ERR_UNKNOWN_ROOT: $CURRENT_ROOT" >&2 ; exit 66 ;;
esac

fw_setenv boot_result               success
fw_setenv last_known_good_partition "$LABEL"
fw_setenv upgrade_available         0
fw_setenv boot_attempts             0
fw_setenv rollback_occurred         0

sync
echo "[e2e-confirm] LKG=$LABEL, upgrade flag cleared"
fw_printenv boot_partition upgrade_available boot_attempts last_known_good_partition
