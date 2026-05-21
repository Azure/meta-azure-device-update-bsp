SUMMARY = "Yocto A/B Update Handler Script"
DESCRIPTION = "Update handler script for A/B partition updates. Invoked by the \
ADU SWUpdate v2 step handler to verify and apply .swu payloads, mutate the \
boot loader environment for the A/B switch, and signal reboot. Machine-specific \
values (root device paths, env tool, swupdate selections) come from \
/etc/adu/board.conf provided by adu-board-config."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://yocto-a-b-update.sh"

S = "${WORKDIR}"

# Per-machine overrides may swap in a board-specific implementation under
# files/${MACHINE}/yocto-a-b-update.sh. The default file is consumed by all
# boards that share the U-Boot fw_setenv + rootA/rootB contract.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit deploy

do_install() {
    install -d ${D}/usr/lib/adu
    install -m 0755 ${WORKDIR}/yocto-a-b-update.sh ${D}/usr/lib/adu/
}

# Also publish the script to DEPLOY_DIR_IMAGE so packaging recipes
# (e.g. adu-delta-test-package) can consume it via an explicit
# do_deploy dependency instead of scraping another recipe's rootfs.
do_deploy() {
    install -d ${DEPLOYDIR}
    install -m 0755 ${WORKDIR}/yocto-a-b-update.sh ${DEPLOYDIR}/yocto-a-b-update.sh
}
addtask do_deploy after do_install before do_build

FILES:${PN} = "/usr/lib/adu/yocto-a-b-update.sh"

# Runtime requirements made explicit. The script invokes swupdate, fw_printenv/
# fw_setenv (libubootenv-bin provides u-boot-fw-utils), and bash. Listing them
# directly avoids relying on transitive pulls through azure-device-update.
RDEPENDS:${PN} = "bash swupdate libubootenv-bin azure-device-update adu-board-config"

# Allow the shell script to ship without ELF post-processing.
INSANE_SKIP:${PN} = "already-stripped"
