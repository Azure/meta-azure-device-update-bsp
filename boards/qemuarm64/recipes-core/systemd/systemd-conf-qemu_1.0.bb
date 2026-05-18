SUMMARY = "systemd-networkd configuration for QEMU virtio-net"
DESCRIPTION = "Ships /etc/systemd/network/20-wired.network so the QEMU \
virtio-net interface (enp0s2) gets a DHCP-assigned address on boot. \
Without this file systemd-networkd starts but has nothing to match, so \
the interface stays down and SSH (host port-forward 2222->22) cannot \
reach the guest. Only installed for MACHINE = qemuarm64."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://20-wired.network"

S = "${WORKDIR}"

COMPATIBLE_MACHINE = "qemuarm64"

RDEPENDS:${PN} = "systemd"

do_install() {
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${WORKDIR}/20-wired.network ${D}${sysconfdir}/systemd/network/20-wired.network
}

FILES:${PN} = "${sysconfdir}/systemd/network/20-wired.network"
