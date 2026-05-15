FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# QEMU arm64 ships a machine-specific /etc/fstab so that the /adu data
# partition (carved out by qemu-adu-ab.wks.in as the 4th partition on /dev/vda)
# is mounted at boot. This is required for adu-persistent-overlay to bind-mount
# /etc/passwd, /etc/shadow, /etc/group, /etc/gshadow from /adu/system/* and so
# preserve user credentials across A/B rootfs swaps.