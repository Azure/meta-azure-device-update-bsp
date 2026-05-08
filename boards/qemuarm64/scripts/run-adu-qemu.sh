#!/bin/bash
# Launch QEMU for ADU A/B update testing
#
# Usage: ./run-adu-qemu.sh [path-to-wic-image] [path-to-u-boot.bin]
#
# Features:
#   - Boots via U-Boot with persistent NOR flash (pflash)
#   - U-Boot env persists across reboots (fw_setenv works)
#   - Persistent WIC disk (changes survive reboot)
#   - SSH port forwarding on localhost:2222
#   - Serial console output
#   - virtio block + network
#
# Architecture:
#   pflash0 (64MB) — U-Boot firmware (unit=0)
#   pflash1 (64MB) — U-Boot environment storage (unit=1)
#   virtio  (WIC)  — boot + rootA + rootB + data partitions
#
# IMPORTANT: Using -bios instead of pflash makes env volatile!
#   The two-pflash approach is required for fw_setenv persistence.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default paths (adjust for your build output)
DEFAULT_IMAGE="${SCRIPT_DIR}/../tmp/deploy/images/qemuarm64/adu-base-image-qemuarm64.wic"
DEFAULT_UBOOT="${SCRIPT_DIR}/../tmp/deploy/images/qemuarm64/u-boot.bin"

WIC_IMAGE="${1:-$DEFAULT_IMAGE}"
UBOOT="${2:-$DEFAULT_UBOOT}"

if [[ ! -f "$WIC_IMAGE" ]]; then
    echo "ERROR: WIC image not found: $WIC_IMAGE"
    echo "Usage: $0 [path-to-wic-image] [path-to-u-boot.bin]"
    exit 1
fi

if [[ ! -f "$UBOOT" ]]; then
    echo "ERROR: U-Boot binary not found: $UBOOT"
    echo "Usage: $0 [path-to-wic-image] [path-to-u-boot.bin]"
    exit 1
fi

# Make a working copy so original image is preserved
WORK_IMAGE="${WIC_IMAGE}.run"
if [[ ! -f "$WORK_IMAGE" ]]; then
    echo "Creating working copy of WIC image..."
    cp "$WIC_IMAGE" "$WORK_IMAGE"
fi

# Flash images directory (alongside the WIC working copy)
FLASH_DIR="$(dirname "$WORK_IMAGE")"
FLASH0="${FLASH_DIR}/flash0.img"
FLASH1="${FLASH_DIR}/flash1.img"
FLASH_SIZE=64  # MB

# Create flash images if they don't exist
if [[ ! -f "$FLASH0" ]]; then
    echo "Creating pflash0 (U-Boot firmware, ${FLASH_SIZE}MB)..."
    dd if=/dev/zero of="$FLASH0" bs=1M count=$FLASH_SIZE 2>/dev/null
    dd if="$UBOOT" of="$FLASH0" conv=notrunc 2>/dev/null
fi

if [[ ! -f "$FLASH1" ]]; then
    echo "Creating pflash1 (U-Boot env, ${FLASH_SIZE}MB)..."
    dd if=/dev/zero of="$FLASH1" bs=1M count=$FLASH_SIZE 2>/dev/null
fi

echo "============================================"
echo "ADU QEMU Launch"
echo "============================================"
echo "  U-Boot:  $UBOOT"
echo "  Flash0:  $FLASH0 (firmware)"
echo "  Flash1:  $FLASH1 (env storage)"
echo "  Image:   $WORK_IMAGE"
echo "  SSH:     ssh -p 2222 root@localhost"
echo "  Console: serial (press Ctrl-A X to exit)"
echo ""
echo "  To reset env: rm $FLASH1 && rerun"
echo "  To reset all:  rm $FLASH0 $FLASH1 $WORK_IMAGE && rerun"
echo "============================================"
echo ""

exec qemu-system-aarch64 \
    -machine virt \
    -cpu cortex-a57 \
    -m 2048 \
    -nographic \
    -drive if=pflash,format=raw,file="$FLASH0",unit=0 \
    -drive if=pflash,format=raw,file="$FLASH1",unit=1 \
    -drive if=none,file="$WORK_IMAGE",format=raw,id=hd0 \
    -device virtio-blk-pci,drive=hd0 \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0 \
    -rtc base=utc,clock=host
