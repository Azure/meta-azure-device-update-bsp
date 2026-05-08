SUMMARY = "QEMU U-Boot boot script for A/B updates"
DESCRIPTION = "Compiles boot.cmd.in into boot.scr for QEMU aarch64 A/B boot"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

DEPENDS = "u-boot-mkimage-native"

SRC_URI = "file://boot.cmd.in"

S = "${WORKDIR}"

BOOT_CMD_FILE = "${WORKDIR}/boot.cmd.in"

do_compile() {
    # Strip any Windows CRLF line endings
    sed -i 's/\r$//' ${BOOT_CMD_FILE}
    # Compile boot script
    mkimage -C none -A arm64 -T script -d ${BOOT_CMD_FILE} ${B}/boot.scr
}

do_install() {
    install -d ${D}/boot
    install -m 0644 ${B}/boot.scr ${D}/boot/boot.scr
}

FILES:${PN} = "/boot/boot.scr"

# Ensure this is deployed to the image
inherit deploy

do_deploy() {
    install -d ${DEPLOYDIR}
    install -m 0644 ${B}/boot.scr ${DEPLOYDIR}/boot.scr
}

addtask deploy after do_compile before do_build

PACKAGE_ARCH = "${MACHINE_ARCH}"
COMPATIBLE_MACHINE = "qemuarm64"
