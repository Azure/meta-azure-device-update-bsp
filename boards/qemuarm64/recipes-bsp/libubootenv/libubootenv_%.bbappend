# Install QEMU-specific fw_env.config
FILESEXTRAPATHS:prepend:qemuarm64 := "${THISDIR}/files:"

SRC_URI:append:qemuarm64 = " file://fw_env.config"

do_install:append:qemuarm64() {
    install -d ${D}${sysconfdir}
    install -m 0644 ${WORKDIR}/fw_env.config ${D}${sysconfdir}/fw_env.config
}

FILES:${PN}:append:qemuarm64 = " ${sysconfdir}/fw_env.config"
