# U-Boot bbappend for QEMU ADU - enables persistent FAT-backed environment
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:qemuarm64 = " file://qemu-adu-env.cfg"

# Apply our config fragment
UBOOT_ENV_SIZE:qemuarm64 = "0x4000"
