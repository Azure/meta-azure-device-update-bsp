# Install i.MX8ULP-specific fw_env.config
FILESEXTRAPATHS:prepend:imx8ulp-lpddr4-evk := "${THISDIR}/files:"

SRC_URI:append:imx8ulp-lpddr4-evk = " file://fw_env.config"

do_install:append:imx8ulp-lpddr4-evk() {
    install -d ${D}${sysconfdir}
    install -m 0644 ${WORKDIR}/fw_env.config ${D}${sysconfdir}/fw_env.config
}

FILES:${PN}:append:imx8ulp-lpddr4-evk = " ${sysconfdir}/fw_env.config"
