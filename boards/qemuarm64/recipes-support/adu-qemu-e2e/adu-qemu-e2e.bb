SUMMARY = "QEMU e2e SWUpdate validation helpers"
DESCRIPTION = "In-guest helper scripts used by run-qemu-e2e.sh to install \
full and delta updates from inside the QEMU emulator without an ADU service. \
Only installed for MACHINE = qemuarm64."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://adu-e2e-install-full.sh \
    file://adu-e2e-reconstruct-and-install-delta.sh \
    file://adu-e2e-verify-version.sh \
    file://adu-e2e-confirm-boot.sh \
"

S = "${WORKDIR}"

COMPATIBLE_MACHINE = "qemuarm64"

RDEPENDS:${PN} = " \
    bash \
    swupdate \
    libubootenv-bin \
    iot-hub-device-update-delta-processor \
    util-linux-findmnt \
"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/adu-e2e-install-full.sh                    ${D}${bindir}/adu-e2e-install-full
    install -m 0755 ${WORKDIR}/adu-e2e-reconstruct-and-install-delta.sh   ${D}${bindir}/adu-e2e-reconstruct-and-install-delta
    install -m 0755 ${WORKDIR}/adu-e2e-verify-version.sh                  ${D}${bindir}/adu-e2e-verify-version
    install -m 0755 ${WORKDIR}/adu-e2e-confirm-boot.sh                    ${D}${bindir}/adu-e2e-confirm-boot
}

FILES:${PN} = "${bindir}/adu-e2e-*"
