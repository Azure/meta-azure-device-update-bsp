#!/bin/bash
# Automated QEMU A/B boot validation test suite
#
# Tests the complete A/B update boot lifecycle:
#   1. U-Boot env initialization on first boot
#   2. Env persistence across reboots (pflash)
#   3. Linux fw_printenv reads U-Boot env
#   4. Linux fw_setenv → U-Boot roundtrip (partition switch)
#   5. Rollback after max boot attempts exhausted
#   6. Catastrophic failure detection + rescue latch
#
# Requirements:
#   - QEMU aarch64 installed
#   - Build output in standard deploy directory
#   - Runs headless (no display needed)
#
# Usage: ./test-qemu-ab-boot.sh [deploy-dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="${1:-${SCRIPT_DIR}/../tmp/deploy/images/qemuarm64}"

# Resolve deploy dir for Yocto builds (handle tmp-glibc variant)
if [[ ! -d "$DEPLOY" ]]; then
    ALT="${SCRIPT_DIR}/../../../build_qemu/tmp-glibc/deploy/images/qemuarm64"
    if [[ -d "$ALT" ]]; then
        DEPLOY="$ALT"
    else
        echo "ERROR: Deploy directory not found: $DEPLOY"
        echo "Usage: $0 [deploy-dir]"
        exit 1
    fi
fi

UBOOT=$(ls "$DEPLOY"/u-boot-qemuarm64-*.bin 2>/dev/null | head -1)
WIC_ORIG=$(ls "$DEPLOY"/adu-base-image-qemuarm64.rootfs-*.wic 2>/dev/null | head -1)

if [[ -z "$UBOOT" || -z "$WIC_ORIG" ]]; then
    echo "ERROR: Missing build artifacts in $DEPLOY"
    echo "  Need: u-boot-qemuarm64-*.bin and adu-base-image-qemuarm64.rootfs-*.wic"
    exit 1
fi

# Temp files for test isolation
WIC="/tmp/qemu-test-$$.wic"
F0="/tmp/flash0-test-$$.img"
F1="/tmp/flash1-test-$$.img"
FLASH_SIZE=64

PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

cleanup() {
    rm -f "$WIC" "$F0" "$F1"
}
trap cleanup EXIT

QCMD="qemu-system-aarch64 -M virt -cpu cortex-a57 -m 2048 -nographic \
    -drive if=pflash,format=raw,file=$F0,unit=0 \
    -drive if=pflash,format=raw,file=$F1,unit=1 \
    -drive if=none,file=$WIC,format=raw,id=hd0 \
    -device virtio-blk-pci,drive=hd0 \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0"

reset_env() {
    cp "$WIC_ORIG" "$WIC"
    dd if=/dev/zero of="$F0" bs=1M count=$FLASH_SIZE 2>/dev/null
    dd if="$UBOOT" of="$F0" conv=notrunc 2>/dev/null
    dd if=/dev/zero of="$F1" bs=1M count=$FLASH_SIZE 2>/dev/null
}

# Boot timeout for U-Boot only (no Linux)
UBOOT_TIMEOUT=25
# Boot timeout for full Linux boot + login
LINUX_BOOT_WAIT=65
LINUX_LOGIN_WAIT=5
CMD_WAIT=3

echo "============================================"
echo " QEMU A/B Boot - Automated Test Suite"
echo "============================================"
echo "  Deploy: $DEPLOY"
echo "  U-Boot: $(basename "$UBOOT")"
echo "  Image:  $(basename "$WIC_ORIG")"
echo ""

# ─── TEST 1: U-Boot env initialization ───
echo "TEST 1: U-Boot env initialization on first boot"
reset_env
OUT=$(timeout $UBOOT_TIMEOUT $QCMD 2>&1) || true
echo "$OUT" | grep -q "FIRST-BOOT" && pass "Env initialized" || fail "No init marker"
echo "$OUT" | grep -q "boot_partition=rootA" && pass "Default partition=rootA" || fail "Wrong default partition"
echo "$OUT" | grep -q "upgrade_available=0" && pass "Default upgrade_available=0" || fail "Wrong default upgrade"

# ─── TEST 2: Env persistence ───
echo ""
echo "TEST 2: U-Boot env persists across reboots"
OUT=$(timeout $UBOOT_TIMEOUT $QCMD 2>&1) || true
echo "$OUT" | grep -q "Loading Environment from Flash... OK" && pass "Flash env loaded" || fail "Env not from flash"
echo "$OUT" | grep -q "attempt 2/5" && pass "Attempt counter incremented" || fail "Counter not incremented"

# ─── TEST 3: fw_printenv from Linux ───
echo ""
echo "TEST 3: Linux reads U-Boot env via fw_printenv"
OUT=$({
    sleep $LINUX_BOOT_WAIT; echo "root"; sleep $LINUX_LOGIN_WAIT
    echo "fw_printenv boot_partition"; sleep $CMD_WAIT
    echo "fw_printenv upgrade_available"; sleep $CMD_WAIT
    echo "halt -f"; sleep 3
} | timeout 90 $QCMD 2>&1) || true
echo "$OUT" | grep -q "boot_partition=rootA" && pass "Reads boot_partition=rootA" || fail "Cannot read partition"
echo "$OUT" | grep -q "upgrade_available=0" && pass "Reads upgrade_available=0" || fail "Cannot read upgrade"

# ─── TEST 4: fw_setenv → U-Boot roundtrip ───
echo ""
echo "TEST 4: Linux fw_setenv persists to U-Boot (rootA→rootB switch)"
reset_env
# Init env
timeout $UBOOT_TIMEOUT $QCMD >/dev/null 2>&1 || true
# Boot to Linux and switch partition
{
    sleep $LINUX_BOOT_WAIT; echo "root"; sleep $LINUX_LOGIN_WAIT
    echo "fw_setenv boot_partition rootB"; sleep $CMD_WAIT
    echo "fw_setenv upgrade_available 1"; sleep $CMD_WAIT
    echo "fw_setenv boot_attempts 0"; sleep $CMD_WAIT
    echo "sync"; sleep 2
    echo "halt -f"; sleep 5
} | timeout 100 $QCMD >/dev/null 2>&1 || true
# Reboot and verify U-Boot sees the changes
OUT=$(timeout $UBOOT_TIMEOUT $QCMD 2>&1) || true
echo "$OUT" | grep -q "boot_partition=rootB" && pass "U-Boot sees rootB" || fail "U-Boot doesn't see rootB"
echo "$OUT" | grep -q "Booting rootB" && pass "Boots rootB partition" || fail "Not booting rootB"
echo "$OUT" | grep -q "root=/dev/vda3" && pass "Kernel cmdline uses vda3" || fail "Wrong root device"
echo "$OUT" | grep -q "upgrade_available=1" && pass "Upgrade mode active" || fail "Upgrade mode not set"

# ─── TEST 5: Rollback after max attempts ───
echo ""
echo "TEST 5: Rollback after exhausting boot attempts"
ROLLED=0
for i in $(seq 1 8); do
    OUT=$(timeout 20 $QCMD 2>&1) || true
    if echo "$OUT" | grep -q "ROLLBACK"; then
        pass "Rollback triggered on attempt $i"
        ROLLED=1
        echo "$OUT" | grep -q "Rolling back to rootA" && pass "Rollback target is rootA" || fail "Wrong rollback target"
        break
    fi
done
[[ $ROLLED -eq 0 ]] && fail "Rollback never triggered"

# Verify post-rollback state
OUT=$(timeout $UBOOT_TIMEOUT $QCMD 2>&1) || true
echo "$OUT" | grep -q "Booting rootA" && pass "Post-rollback boots rootA" || fail "Not rootA after rollback"
echo "$OUT" | grep -q "upgrade_available=0" && pass "Upgrade flag cleared" || fail "Upgrade flag not cleared"

# ─── TEST 6: Catastrophic failure + rescue latch ───
echo ""
echo "TEST 6: Catastrophic failure detection + rescue latch"
reset_env
timeout $UBOOT_TIMEOUT $QCMD >/dev/null 2>&1 || true
# Set up upgrade to rootB
{
    sleep $LINUX_BOOT_WAIT; echo "root"; sleep $LINUX_LOGIN_WAIT
    echo "fw_setenv boot_partition rootB"; sleep $CMD_WAIT
    echo "fw_setenv upgrade_available 1"; sleep $CMD_WAIT
    echo "fw_setenv boot_attempts 0"; sleep $CMD_WAIT
    echo "sync"; sleep 2
    echo "halt -f"; sleep 5
} | timeout 100 $QCMD >/dev/null 2>&1 || true
# Exhaust rootB attempts → rollback to rootA
for i in $(seq 1 8); do
    OUT=$(timeout 20 $QCMD 2>&1) || true
    echo "$OUT" | grep -q "ROLLBACK" && break
done
# Exhaust rootA attempts → catastrophic
CATASTROPHIC=0
for i in $(seq 1 8); do
    OUT=$(timeout 20 $QCMD 2>&1) || true
    if echo "$OUT" | grep -q "CATASTROPHIC"; then
        pass "Catastrophic failure detected"
        CATASTROPHIC=1
        echo "$OUT" | grep -q "rescue_required" && pass "Rescue latch referenced" || fail "No rescue latch"
        break
    fi
done
[[ $CATASTROPHIC -eq 0 ]] && fail "Catastrophic never detected"
# Verify rescue latch persists on next boot
OUT=$(timeout 20 $QCMD 2>&1) || true
echo "$OUT" | grep -q "RESCUE" && pass "Rescue latch persists across reboot" || fail "Rescue latch lost"

# ─── Results ───
echo ""
echo "============================================"
printf " RESULTS: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
