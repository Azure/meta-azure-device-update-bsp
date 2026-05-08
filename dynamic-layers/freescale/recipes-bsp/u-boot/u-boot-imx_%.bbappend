# Add A/B environment config fragment for i.MX8ULP
FILESEXTRAPATHS:prepend:imx8ulp-lpddr4-evk := "${THISDIR}/files:"

SRC_URI:append:imx8ulp-lpddr4-evk = " file://imx8ulp-adu-env.cfg"
