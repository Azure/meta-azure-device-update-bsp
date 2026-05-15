FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# i.MX8ULP EVK ships a machine-specific /etc/fstab so that the /adu data
# partition (carved out by imx8ulp-adu-ab.wks.in as the 4th partition on
# /dev/mmcblk0) is mounted at boot. Required for adu-persistent-overlay to
# bind-mount /etc/passwd, /etc/shadow, /etc/group, /etc/gshadow from
# /adu/system/* and so preserve user credentials across A/B rootfs swaps.