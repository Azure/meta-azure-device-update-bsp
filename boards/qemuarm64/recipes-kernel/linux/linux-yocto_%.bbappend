# Add MTD/CFI flash support for QEMU pflash environment access
FILESEXTRAPATHS:prepend:qemuarm64 := "${THISDIR}/files:"

SRC_URI:append:qemuarm64 = " file://qemu-mtd.cfg"
